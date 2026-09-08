from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID, uuid4

import pytest

import rigovo.api.control_plane as control_plane
from rigovo.domain.entities.audit_entry import AuditAction, AuditEntry
from rigovo.domain.entities.task import PipelineStep, Task
from rigovo.infrastructure.persistence.sqlite_audit_repo import SqliteAuditRepository
from rigovo.infrastructure.persistence.sqlite_task_repo import SqliteTaskRepository
from tests.unit.api.test_control_plane_confidence_stack import client as client


def save_task(client, workspace: Path, steps: list[PipelineStep] | None = None) -> Task:
    workspace.mkdir(parents=True, exist_ok=True)
    task = Task(workspace_id=UUID(int=0), description="Create files", workspace_path=str(workspace))
    task.pipeline_steps = steps or []
    asyncio.run(SqliteTaskRepository(client.app.state.container.get_db()).save(task))
    return task


def test_files_merge_persisted_and_live_steps_and_filter_runtime(client, tmp_path):
    workspace = tmp_path / "workspace"
    task = save_task(client, workspace, [
        PipelineStep(uuid4(), "coder-1", "Coder", files_changed=["src/main.cpp", ".rigour/events.jsonl"]),
        PipelineStep(uuid4(), "coder-1", "Coder", files_changed=["src/server.cpp"]),
    ])
    (workspace / "README.md").write_text("Live file")
    control_plane._live_agent_progress[str(task.id)] = {
        "coder-2": {"files_changed": ["tests/test_server.cpp", ".rigovo/local.db"],
                    "output": '  ⚡ write_file("README.md", 9 chars)\n'},
    }
    response = client.get(f"/v1/tasks/{task.id}/files")
    assert response.status_code == 200
    assert response.json()["files"] == ["README.md", "src/main.cpp", "src/server.cpp", "tests/test_server.cpp"]
    assert response.json()["by_agent"]["coder-1"] == ["src/main.cpp", "src/server.cpp"]


def test_content_reads_task_target_and_supports_empty_files(client, tmp_path):
    workspace = tmp_path / "workspace"
    target = workspace / "new-product"
    target.mkdir(parents=True)
    (target / "main.cpp").write_text("int main() {}")
    (target / "empty.txt").write_text("")
    task = save_task(client, workspace, [
        PipelineStep(uuid4(), "coder-1", "Coder", files_changed=["main.cpp", "empty.txt", "removed.txt"]),
    ])
    task.approval_data = {"target_root": str(target)}
    asyncio.run(SqliteTaskRepository(client.app.state.container.get_db()).save(task))
    query = client.get(f"/v1/tasks/{task.id}/files", params={"path": "main.cpp"})
    segment = client.get(f"/v1/tasks/{task.id}/files/main.cpp")
    assert query.json() == segment.json() == {"path": "main.cpp", "content": "int main() {}"}
    assert client.get(f"/v1/tasks/{task.id}/files", params={"path": "empty.txt"}).json()["content"] == ""
    assert "error" in client.get(f"/v1/tasks/{task.id}/files/removed.txt").json()


def test_preview_rejects_traversal_symlinks_and_unrelated_files(client, tmp_path):
    workspace = tmp_path / "workspace"
    task = save_task(client, workspace)
    secret = tmp_path / "outside.txt"
    secret.write_text("private")
    (workspace / "link.txt").symlink_to(secret)
    (workspace / "unrelated.txt").write_text("belongs to another task")
    for path in ("../outside.txt", str(secret), "link.txt", ".rigovo/local.db"):
        assert client.get(f"/v1/tasks/{task.id}/files", params={"path": path}).status_code == 403
    assert client.get(f"/v1/tasks/{task.id}/files/unrelated.txt").status_code == 404


def test_successful_write_is_visible_before_completion_and_survives_cache_clear(client, tmp_path):
    workspace = tmp_path / "workspace"
    task = save_task(client, workspace)
    (workspace / "main.cpp").write_text("int main() {}")
    control_plane._on_agent_event({
        "type": "file_written", "task_id": str(task.id), "role": "coder",
        "instance_id": "coder-1", "path": "main.cpp", "file_root": str(workspace),
    })
    # Simulate loss of in-memory progress on a service restart.
    control_plane._live_agent_progress.pop(str(task.id), None)
    response = client.get(f"/v1/tasks/{task.id}/files")
    assert response.json()["files"] == ["main.cpp"]
    assert client.get(f"/v1/tasks/{task.id}/files/main.cpp").json()["content"] == "int main() {}"


def test_missing_task_returns_error_instead_of_empty_files(client):
    assert client.get(f"/v1/tasks/{uuid4()}/files").status_code == 404


def test_mission_governance_and_audit_support_limited_audit_queries(client, tmp_path):
    task = save_task(client, tmp_path / "workspace")
    repo = SqliteAuditRepository(client.app.state.container.get_db())
    for number in range(3):
        asyncio.run(repo.append(AuditEntry(workspace_id=task.workspace_id,
                                         task_id=task.id, action=AuditAction.TASK_STARTED,
                                         summary=f"event {number}")))
    assert [entry.summary for entry in asyncio.run(repo.list_by_task(task.id, limit=2))] == ["event 1", "event 2"]
    for endpoint in ("mission", "governance", "audit?limit=2"):
        assert client.get(f"/v1/tasks/{task.id}/{endpoint}").status_code == 200


def test_files_from_one_task_are_not_listed_for_another(client, tmp_path):
    workspace = tmp_path / "workspace"
    first = save_task(client, workspace)
    second = save_task(client, workspace)
    control_plane._on_agent_event({"type": "file_written", "task_id": str(first.id),
                                   "role": "coder", "path": "first.cpp"})
    assert client.get(f"/v1/tasks/{first.id}/files").json()["files"] == ["first.cpp"]
    assert client.get(f"/v1/tasks/{second.id}/files").json()["files"] == []


def test_file_manifest_survives_approval_transitions(client, tmp_path):
    task = save_task(client, tmp_path / "workspace")
    task.approval_data = {"file_manifest": {"coder-1": ["main.cpp"]},
                          "file_root": task.workspace_path}
    task.await_approval("code_ready", {"message": "Review generated code"})
    assert task.approval_data["file_manifest"]["coder-1"] == ["main.cpp"]
    task.approve()
    assert task.approval_data["file_manifest"]["coder-1"] == ["main.cpp"]
    assert "message" not in task.approval_data


@pytest.mark.parametrize("start_aware,end_aware", [(False, True), (True, False), (True, True)])
def test_restarted_task_detail_handles_mixed_timestamp_formats(client, tmp_path, start_aware, end_aware):
    task = save_task(client, tmp_path / "workspace")
    started = datetime(2026, 1, 1, 12, 0)
    completed = started + timedelta(seconds=3)
    task.started_at = started.replace(tzinfo=timezone.utc) if start_aware else started
    task.completed_at = completed.replace(tzinfo=timezone.utc) if end_aware else completed
    asyncio.run(SqliteTaskRepository(client.app.state.container.get_db()).save(task))
    response = client.get(f"/v1/tasks/{task.id}/detail")
    assert response.status_code == 200
    assert response.json()["ui_summary"]["elapsed_ms"] == 3000
