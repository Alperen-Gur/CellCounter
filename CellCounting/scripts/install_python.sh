#!/usr/bin/env bash
#
# install_python.sh — Provision the local Python sidecar that powers
# CellCounter's real Cellpose detection (the **3.x** family).
#
# Usage:
#   install_python.sh <VENV_PATH> [<SCRIPTS_DIR>]
#
#   VENV_PATH    Absolute path where the venv should be created. Required when
#                run from inside the app — the bundle is read-only, so we MUST
#                install into a writeable location under
#                ~/Library/Application Support/CellCounter/python/.
#   SCRIPTS_DIR  Optional. Directory containing the *_detect.py / *_train.py
#                helpers. Defaults to "$(dirname VENV_PATH)" (the host copies
#                bundled scripts there before invoking us). Used purely for
#                logging — the sidecar discovery happens Swift-side.
#
# When invoked with no args (e.g. from a dev shell), falls back to provisioning
# <repo>/Resources/python/venv.
#
# Re-run safely: pip install is idempotent and existing venv is reused.
#
# Pass-18 (K4): shared bootstrap logic lives in `_lib_install.sh`. This file
# only specifies the 3.x-specific bits (pip arg, default venv name, banner).
# Pass-13: pinned to cellpose 3.x because cellpose 4.0 (2025) ships CPSAM
# which silently ignores `model_type=` and pulls ~1.15 GB of weights on
# first run — that's now the 4.x sidecar (install_python_cp4.sh).

set -euo pipefail

_CC_WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_CC_WRAPPER_DIR}/_lib_install.sh"

CC_VENV_DEFAULT_NAME="venv"
CC_FAMILY_LABEL="Cellpose 3.x"
CC_DETECT_FILENAME="cellpose_detect.py"
# numpy<2 is required by cellpose 3.x.
# tifffile is required (not optional): it is the OME-TIFF / ImageJ / LSM reader
# behind _imageio.py, and is pure Python + BSD-3 so it installs everywhere.
CC_PIP_PACKAGES='cellpose>=3.0,<4 numpy<2 pillow scikit-image tifffile torch torchvision'
# Optional vendor microscope-format readers used by _imageio.py. All are
# pure-Python BSD-3-Clause (MIT-compatible). The GPL alternatives — bioformats,
# bioio-czi, readlif, aicspylibczi, pyometiff, czitools — are deliberately NOT
# used. Installed best-effort (see _lib_install.sh): a package with no wheel
# for this Python just stays absent and _imageio falls back to PIL with an
# actionable "install <pkg> to open <ext>" message.
#
# czifile / liffile / oirfile carry upstream "API is not stable" notices, so
# they are capped below the next calendar-year release train; nd2 and oiffile
# are range-pinned for the same reason. imagecodecs is only needed for
# compressed CZI/TIFF payloads and ships as a binary wheel.
CC_PIP_OPTIONAL_PACKAGES='imagecodecs czifile>=2019.7.2,<2027 nd2>=0.10,<1 liffile<2027 oiffile<2027 oirfile<2027'
CC_DONE_EXTRA_NOTE="Expect roughly ~2 GB of disk used (torch + cellpose weights cache on first
run can add more). The CellCounter app picks this up automatically through
CellposeAvailability.swift — no further configuration needed."

cc_install_run "$@"
