from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from rigovo.application.graph.nodes.execute_agent import _run_agentic_loop
from rigovo.domain.interfaces.llm_provider import LLMResponse, LLMUsage


@pytest.mark.asyncio
async def test_file_events_arrive_before_agent_finishes_and_exclude_failed_writes(tmp_path):
    published = []
    calls = 0

    async def invoke(**kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            return LLMResponse(content="", usage=LLMUsage(10, 10), model="test",
                               tool_calls=[
                                   {"id": "ok", "name": "write_file", "input": {"path": "main.cpp", "content": "code"}},
                                   {"id": "bad", "name": "write_file", "input": {"path": ".env", "content": "secret"}},
                               ])
        # The successful write must already be observable during the next LLM
        # round, before an agent_complete event or final pipeline persistence.
        assert [event["path"] for event in published] == ["main.cpp"]
        return LLMResponse(content="Done", usage=LLMUsage(10, 10), model="test")

    executor = SimpleNamespace(
        _execution_root=tmp_path,
        execute=AsyncMock(side_effect=[json.dumps({"path": "main.cpp", "created": True}),
                                      json.dumps({"error": "Protected file"})]),
    )
    await _run_agentic_loop(
        llm=SimpleNamespace(invoke=invoke), messages=[], tool_defs=[], tool_executor=executor,
        agent_config={}, role="reviewer", stream_identity="reviewer-1",
        state={"task_id": "task-1", "workspace_root": str(tmp_path), "target_root": str(tmp_path)},
        max_rounds=2, event_callback=published.append,
    )
    assert published[0]["task_id"] == "task-1"
    assert published[0]["instance_id"] == "reviewer-1"
    assert published[0]["file_root"] == str(tmp_path)
