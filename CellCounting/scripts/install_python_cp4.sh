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
# The tested package set. Exact pins, so every Mac runs the same Cellpose,
# PyTorch and image stack, and re-running this script moves an existing venv4
# to exactly this set (pip changes any installed version that differs).
#   * cellpose 4.2.1.1, torch 2.12.0 + torchvision 0.27.0 (torchvision pins
#     that torch), opencv-python-headless 4.13.0.92: the set verified together.
#   * numpy 2.x: opencv-python-headless 4.13 requires numpy>=2 on Python 3.9+,
#     so the old `numpy<2` contradicted it.
#   * scipy, scikit-image and tifffile are the numpy-2 builds from the tested
#     venv; pinned because they feed Cellpose's post-processing, CellCounter's
#     measurements and image reading. tifffile 2026.5.15 needs Python 3.12+.
# Keep in sync with CellposeSAMRuntime.pinnedPackages (Swift).
# CPSAM weights (~1.15 GB; Cellpose-SAM v2 has its own ~1.2 GB file) are NOT
# downloaded here — they're pulled lazily on first detection run inside
# cellpose4_detect.py via CellposeModel(...).
# tifffile is required (not optional): it is the OME-TIFF / ImageJ / LSM reader
# behind _imageio.py, and is pure Python + BSD-3 so it installs everywhere.
CC_PIP_PACKAGES='cellpose==4.2.1.1 torch==2.12.0 torchvision==0.27.0 opencv-python-headless==4.13.0.92 numpy>=2,<3 scipy==1.17.1 scikit-image==0.26.0 tifffile==2026.5.15 pillow'
# The tested interpreter is Python 3.12. scipy 1.17.1 and scikit-image 0.26.0
# need 3.11+, tifffile 2026.5.15 needs 3.12+. A venv4 made with an older
# Python is moved aside (venv4.before-python-upgrade-…), not changed in place
# (see _lib_install.sh); without a suitable Python nothing is changed.
CC_MIN_PYTHON_MINOR=12
# The optional readers below are installed together with the pinned set, so
# none of them can move numpy, tifffile or anything else off its pin.
CC_OPTIONAL_COMPANIONS="${CC_PIP_PACKAGES}"
# Before changing an existing venv4, write its package list next to it
# (python/venv4-packages-before-cellpose-<old version>.txt), so results made
# with the old Cellpose can be reproduced.
CC_RECORD_PACKAGES_OF="cellpose"
# Optional vendor microscope-format readers used by _imageio.py — kept
# byte-identical to install_python.sh so both venvs open the same file types.
# All pure-Python BSD-3-Clause; the GPL alternatives (bioformats, bioio-czi,
# readlif, aicspylibczi, pyometiff, czitools) are deliberately NOT used.
# czifile / liffile / oirfile have upstream "API is not stable" notices, hence
# the calendar-year caps. Installed best-effort — see _lib_install.sh.
CC_PIP_OPTIONAL_PACKAGES='imagecodecs czifile>=2019.7.2,<2027 nd2>=0.10,<1 liffile<2027 oiffile<2027 oirfile<2027'
CC_DONE_EXTRA_NOTE="Expect roughly ~2 GB of disk used by the venv itself; on the first detection
run cellpose 4 will additionally fetch ~1.15 GB of CPSAM transformer weights
into ~/.cellpose/models/ (Cellpose-SAM v2 downloads its own ~1.2 GB file the
first time it is used). Total disk impact: ~3.5 GB.

The CellCounter app picks this venv up automatically through
Cellpose4Availability.swift — no further configuration needed."

cc_install_run "$@"
