#!/usr/bin/env bash
# Keep the repository CLI entry point on the same pinned installer as the app.
# Usage: install_python.sh <VENV_PATH> [<SCRIPTS_DIR>]
set -euo pipefail

_CC_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CC_REPO_ROOT="$(cd "${_CC_ENTRY_DIR}/.." && pwd)"
if [ -z "${1:-}" ]; then
    # Preserve the historical no-argument repository destination.
    set -- "${_CC_REPO_ROOT}/Resources/python/venv" "${_CC_REPO_ROOT}/Resources/python"
fi
exec /bin/bash "${_CC_REPO_ROOT}/CellCounting/scripts/install_python.sh" "$@"
