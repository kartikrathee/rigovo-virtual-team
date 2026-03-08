#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${ROOT_DIR}/apps/desktop"
API_HOST="${RIGOVO_API_HOST:-127.0.0.1}"
API_PORT="8787"  # Fixed — must match WorkOS redirect URI
API_URL="http://${API_HOST}:${API_PORT}"
CALLBACK_URI="http://127.0.0.1:${API_PORT}/v1/auth/callback"
API_LOG="${ROOT_DIR}/.rigovo/e2e-api.log"
API_PID=""
API_LOG_PID=""
E2E_INSTALL="${RIGOVO_E2E_INSTALL:-auto}" # auto|always|never
PY_INSTALL="${RIGOVO_E2E_PY_INSTALL:-auto}" # auto|always|never
PY_INSTALL_TIMEOUT="${RIGOVO_E2E_PY_INSTALL_TIMEOUT:-300}" # seconds

cleanup() {
  echo "[rigovo] cleaning up..."
  if [[ -n "${API_PID}" ]] && kill -0 "${API_PID}" >/dev/null 2>&1; then
    kill "${API_PID}" >/dev/null 2>&1 || true
    wait "${API_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${API_LOG_PID}" ]] && kill -0 "${API_LOG_PID}" >/dev/null 2>&1; then
    kill "${API_LOG_PID}" >/dev/null 2>&1 || true
    wait "${API_LOG_PID}" >/dev/null 2>&1 || true
  fi
}

wait_for_health() {
  local retries=30
  local delay=1
  local i
  for ((i=1; i<=retries; i++)); do
    if curl -fsS "${API_URL}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}

kill_port() {
  local port="$1"
  local pids
  pids="$(lsof -ti :"${port}" 2>/dev/null || true)"
  if [[ -n "${pids}" ]]; then
    echo "[rigovo] killing stale process(es) on port ${port}: ${pids}"
    echo "${pids}" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
}

start_api() {
  API_URL="http://${API_HOST}:${API_PORT}"
  echo "[rigovo] starting control-plane API at ${API_URL}"
(
  cd "${ROOT_DIR}"
  PYTHONPATH="${ROOT_DIR}/src:${PYTHONPATH:-}" \
  PYTHONUNBUFFERED=1 \
  RIGOVO_API_PORT="${API_PORT}" \
  python3 -m rigovo.main serve --host "${API_HOST}" --port "${API_PORT}" --project "${ROOT_DIR}"
) >"${API_LOG}" 2>&1 &
API_PID=$!
  # Keep the API's actual PID for health/cleanup, and mirror its log to the
  # launching terminal without putting the server behind a pipeline.
  tail -n +1 -f "${API_LOG}" &
  API_LOG_PID=$!

  sleep 0.5
  if ! kill -0 "${API_PID}" >/dev/null 2>&1; then
    echo "[rigovo] API process died immediately. Log output:"
    tail -n 40 "${API_LOG}" 2>/dev/null || true
    exit 1
  fi
}

echo "[rigovo] project root: ${ROOT_DIR}"

# ── Prerequisites ──
for cmd in python3 node npm curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[rigovo] missing required command: $cmd"
    exit 1
  fi
done

# Create .env if it doesn't exist (non-secret config only)
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  touch "${ROOT_DIR}/.env"
fi

echo "[rigovo] WorkOS client ID: embedded in config.py (public)"
echo "[rigovo] API keys: stored encrypted in .rigovo/local.db (set via Settings UI)"

# ── Install Python dependencies (optional) ──
# IMPORTANT: use python3 -m pip (not bare pip) to guarantee packages go into
# the SAME Python that will run the API server.
run_with_timeout() {
  local timeout_s="$1"
  shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${timeout_s}" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_s}" "$@"
  else
    "$@"
  fi
}

if [[ "${PY_INSTALL}" == "always" ]] || [[ "${PY_INSTALL}" == "auto" ]]; then
  echo "[rigovo] installing Python dependencies (python3 -m pip, timeout=${PY_INSTALL_TIMEOUT}s)..."
  if ! run_with_timeout "${PY_INSTALL_TIMEOUT}" python3 -m pip install -e "${ROOT_DIR}[dev]" --quiet 2>&1 | tail -5; then
    echo "[rigovo] WARNING: pip install timed out or failed."
    echo "[rigovo]          set RIGOVO_E2E_PY_INSTALL=never if env is already prepared."
  fi
elif [[ "${PY_INSTALL}" == "never" ]]; then
  echo "[rigovo] skipping Python install (RIGOVO_E2E_PY_INSTALL=never)"
fi

# Verify critical dependency: psycopg (required for PostgreSQL backend)
if [[ "${PY_INSTALL}" != "never" ]]; then
  if ! python3 -c "import psycopg" 2>/dev/null; then
    echo "[rigovo] psycopg not found after install — installing directly..."
    python3 -m pip install "psycopg[binary]>=3.2" 2>&1 | tail -5
    if ! python3 -c "import psycopg" 2>/dev/null; then
      echo "[rigovo] ERROR: psycopg still not importable. PostgreSQL features will not work."
      echo "[rigovo] Try manually: python3 -m pip install 'psycopg[binary]'"
    fi
  fi
  python3 -c "import psycopg; print(f'[rigovo] psycopg {psycopg.__version__} OK')" 2>/dev/null || true
else
  echo "[rigovo] skipped psycopg check (RIGOVO_E2E_PY_INSTALL=never)"
fi

# ── Install desktop deps if needed ──
if [[ "${E2E_INSTALL}" == "always" ]] || [[ "${E2E_INSTALL}" == "auto" && ! -d "${DESKTOP_DIR}/node_modules" ]]; then
  echo "[rigovo] installing desktop dependencies..."
  cd "${DESKTOP_DIR}" && npm install
  cd "${ROOT_DIR}"
elif [[ "${E2E_INSTALL}" == "never" ]]; then
  echo "[rigovo] skipping install (RIGOVO_E2E_INSTALL=never)"
fi

# ── Ensure Electron's native executable is present ──
# The .bin/electron wrapper can exist even when the downloaded app is missing.
ELECTRON_BIN="${DESKTOP_DIR}/node_modules/.bin/electron"
electron_ready() {
  (
    cd "${DESKTOP_DIR}"
    # Read the installation metadata directly: newer Electron entry points can
    # start a download on require(), which this check must not trigger.
    node <<'NODE'
const fs = require("fs");
const path = require("path");
const electronDir = path.dirname(require.resolve("electron/package.json"));
const executable = fs.readFileSync(path.join(electronDir, "path.txt"), "utf8").trim();
if (!executable) throw new Error("Electron executable path is empty");
const dist = process.env.ELECTRON_OVERRIDE_DIST_PATH || path.join(electronDir, "dist");
fs.accessSync(path.join(dist, executable), fs.constants.X_OK);
NODE
  ) >/dev/null 2>&1
}

if [[ ! -x "${ELECTRON_BIN}" ]] || ! electron_ready; then
  echo "[rigovo] Electron's native executable is missing or not executable."
  echo "[rigovo] Installation may be incomplete, or macOS may have removed the app."
  echo "[rigovo] If macOS reported malware, resolve that warning before reinstalling."
  echo "[rigovo] Otherwise, run: npm --prefix apps/desktop rebuild electron --ignore-scripts=false"
  exit 1
fi

mkdir -p "${ROOT_DIR}/.rigovo"

trap cleanup EXIT INT TERM

# ── Clean and rebuild desktop app (ensures latest source is compiled) ──
echo "[rigovo] rebuilding desktop app (main + preload + renderer)..."
rm -rf "${DESKTOP_DIR}/out"
cd "${DESKTOP_DIR}" && npx electron-vite build
cd "${ROOT_DIR}"
echo "[rigovo] build complete"

# Keep the downloaded Electron.app unchanged; editing Info.plist can invalidate
# a bundle signature. Configure application branding in the packaged app.

# ── Start API — always fresh on port 8787 (must match WorkOS redirect URI) ──
# Always kill and restart to ensure latest Python code is running.
kill_port "${API_PORT}"
start_api

if ! wait_for_health; then
  echo "[rigovo] API failed health check after 30s. tailing logs:"
  tail -n 120 "${API_LOG}" || true
  exit 1
fi

echo "[rigovo] API healthy at ${API_URL}"
echo "[rigovo] logs: ${API_LOG}"

# ── Launch Electron desktop app ──
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  Rigovo Virtual Team                                     │"
echo "  │                                                          │"
echo "  │  API:      ${API_URL}                                    │"
echo "  │  Callback: ${CALLBACK_URI}                               │"
echo "  │                                                          │"
echo "  │  WorkOS redirect URI:                                    │"
echo "  │  http://127.0.0.1:8787/v1/auth/callback                 │"
echo "  │                                                          │"
echo "  │  API keys → Settings UI (encrypted in SQLite)            │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
cd "${DESKTOP_DIR}" && VITE_RIGOVO_API="${API_URL}" RIGOVO_API_PORT="${API_PORT}" npx electron-vite dev
