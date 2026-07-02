#!/usr/bin/env bash
#
# install_python_cp4.sh — Provision a SECOND, isolated Python venv for the
# Cellpose 4.x / CPSAM family. Mirrors install_python.sh but targets
# `venv4/` (not `venv/`) so the 3.x and 4.x installs coexist on disk.
#
# Pass-16 background:
#   * Cellpose 4.0 (2025) ships a brand-new SAM-based architecture (CPSAM).
#     The first construction of `CellposeModel()` downloads ~1.15 GB of
#     transformer weights — which used to land in cellpose 3.x venvs and
#     made detection look like "stuck at 92%". We now keep 3.x intact in
#     `venv/` and put CPSAM in `venv4/`, so users can switch between them.
#   * Weight download happens lazily on first detection run, NOT at install
#     time. The install_python_cp4.sh job is ONLY `pip install`.
#
# Usage:
#   install_python_cp4.sh <VENV_PATH> [<SCRIPTS_DIR>]
#
#   VENV_PATH    Absolute path where the cp4 venv should be created. The Swift
#                host always passes the writeable
#                ~/Library/Application Support/CellCounter/python/venv4/ path.
#   SCRIPTS_DIR  Optional. Directory containing cellpose4_detect.py.
#                Defaults to "$(dirname VENV_PATH)".
#
# Re-run safely: pip install is idempotent and existing venv is reused.
#
# Pass-18 (K4): shared bootstrap logic lives in `_lib_install.sh`. This file
# only specifies the 4.x-specific bits.

set -euo pipefail

_CC_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_CC_WRAPPER_DIR}/_lib_install.sh"

CC_VENV_DEFAULT_NAME="venv4"
CC_FAMILY_LABEL="Cellpose-SAM (cp4)"
CC_DETECT_FILENAME="cellpose4_detect.py"
# numpy<2 is still required by parts of the cellpose stack.
# CPSAM weights (~1.15 GB) are NOT downloaded here — they're pulled lazily on
# first detection run inside cellpose4_detect.py via CellposeModel(...).
CC_PIP_PACKAGES='cellpose>=4 numpy<2 pillow scikit-image torch torchvision'
CC_DONE_EXTRA_NOTE="Expect roughly ~2 GB of disk used by the venv itself; on the first detection
run cellpose 4 will additionally fetch ~1.15 GB of CPSAM transformer weights
into ~/.cellpose/models/. Total disk impact: ~3.5 GB.

The CellCounter app picks this venv up automatically through
Cellpose4Availability.swift — no further configuration needed."

cc_install_run "$@"
