#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/rigovo/app"
APP_REPO="https://github.com/rigovo/rigovo-virtual-team.git"
WORKSPACE="/srv/rigovo/workspace"
SERVICE_FILE="/etc/systemd/system/rigovo.service"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 python3-venv build-essential

if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q '^v20\.'; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y --no-install-recommends nodejs
fi

if ! id rigovo >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/rigovo --shell /usr/sbin/nologin rigovo
fi

install -d -o rigovo -g rigovo /opt/rigovo /srv/rigovo/workspace /var/lib/rigovo

if [ ! -d "$APP_DIR/.git" ]; then
  runuser -u rigovo -- git clone --depth 1 "$APP_REPO" "$APP_DIR"
fi

if [ ! -x "$APP_DIR/.venv/bin/uv" ]; then
  runuser -u rigovo -- python3 -m venv "$APP_DIR/.venv"
  runuser -u rigovo -- "$APP_DIR/.venv/bin/python" -m pip install --upgrade pip uv
fi

runuser -u rigovo -- "$APP_DIR/.venv/bin/uv" sync --locked --project "$APP_DIR" --no-dev

cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Rigovo Virtual Engineering Team control plane
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=rigovo
Group=rigovo
WorkingDirectory=/srv/rigovo/workspace
Environment=HOME=/var/lib/rigovo
Environment=RIGOVO_CLOUD_ENABLED=false
Environment=RIGOVO_IDENTITY_PROVIDER=local
Environment=RIGOVO_WORKTREE_MODE=project
ExecStart=/opt/rigovo/app/.venv/bin/rigovo serve --host 127.0.0.1 --port 8787 --project /srv/rigovo/workspace
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
PrivateDevices=true
CapabilityBoundingSet=
ReadWritePaths=/srv/rigovo/workspace /var/lib/rigovo

[Install]
WantedBy=multi-user.target
UNIT

chown -R rigovo:rigovo /opt/rigovo "$WORKSPACE" /var/lib/rigovo
systemctl daemon-reload
systemctl enable --now rigovo.service

for attempt in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1:8787/health >/dev/null; then
    break
  fi
  sleep 5
done
curl --fail --silent http://127.0.0.1:8787/health >/dev/null

if [ ! -e /var/lib/rigovo/workspace-registered ]; then
  curl --fail --silent --show-error \
    -H 'Content-Type: application/json' \
    -d '{"path":"/srv/rigovo/workspace","name":"Rigovo VM Workspace"}' \
    http://127.0.0.1:8787/v1/projects >/dev/null
  touch /var/lib/rigovo/workspace-registered
  chown rigovo:rigovo /var/lib/rigovo/workspace-registered
fi
