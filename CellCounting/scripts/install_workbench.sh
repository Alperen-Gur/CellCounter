#!/usr/bin/env bash
# Dedicated canonical GUI/CLI/MCP environment; detector environments stay separate.
set -euo pipefail
_CC_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CC_WRAPPER_DIR}/_lib_install.sh"
CC_VENV_DEFAULT_NAME="venv_workbench"
CC_FAMILY_LABEL="Workbench and MCP"
CC_DETECT_FILENAME="workbench.py"
CC_MIN_PYTHON_MINOR=11
CC_PIP_PACKAGES=""
CC_REQUIREMENTS_FILES="requirements-analysis.txt requirements-mcp.txt requirements-zarr.txt requirements-reporting.txt"
CC_DONE_EXTRA_NOTE="The Workbench, command-line operations and MCP share this environment.
Registered model interpreters and existing detector environments are unchanged."
cc_install_run "$@"
