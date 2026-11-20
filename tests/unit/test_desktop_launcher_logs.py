from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import sys


def test_api_logs_are_saved_and_mirrored_and_follower_is_cleaned_up(tmp_path):
    source = (Path(__file__).parents[2] / "scripts/e2e_desktop.sh").read_text()
    functions = source[source.index("cleanup() {"):source.index('\necho "[rigovo] project root:')]
    binaries = tmp_path / "bin"
    binaries.mkdir()
    server = binaries / "python3"
    server.write_text(f"#!{sys.executable}\nimport sys,time\n"
                      "print('API stdout', flush=True)\n"
                      "print('API stderr', file=sys.stderr, flush=True)\n"
                      "time.sleep(10)\n")
    server.chmod(0o755)
    log = tmp_path / "api.log"
    script = f'''set -euo pipefail
ROOT_DIR={shlex.quote(str(tmp_path))}
API_LOG={shlex.quote(str(log))}
API_HOST=127.0.0.1
API_PORT=9999
API_PID=""
API_LOG_PID=""
{functions}
trap cleanup EXIT
start_api
sleep 1.1
printf 'OWNED_PIDS=%s,%s\\n' "$API_PID" "$API_LOG_PID"
cleanup
'''
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                            env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}"},
                            timeout=8)
    assert result.returncode == 0, result.stderr
    assert "API stdout" in result.stdout and "API stderr" in result.stdout
    assert "API stdout" in log.read_text() and "API stderr" in log.read_text()
    pids = next(line for line in result.stdout.splitlines() if line.startswith("OWNED_PIDS="))
    for pid in pids.removeprefix("OWNED_PIDS=").split(","):
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError(f"Launcher process {pid} was not cleaned up")
