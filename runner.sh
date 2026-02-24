#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
python3 -m venv .venv
source .venv/bin/activate

python3 -m pip install --upgrade pip
python3 -m pip install -e .
npm --prefix apps/desktop install

# Launch locally.

RIGOVO_IDENTITY_PROVIDER=local \
RIGOVO_E2E_PY_INSTALL=never \
bash scripts/e2e_desktop.sh
