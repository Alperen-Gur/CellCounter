#!/usr/bin/env bash
#
# install_python.sh — Provision the local Python sidecar that powers
# CellCounter's real Cellpose detection.
#
# Usage:
#   install_python.sh <VENV_PATH> [<SCRIPTS_DIR>]
#
#   VENV_PATH    Absolute path where the venv should be created. Required when
#                run from inside the sandboxed .app — the bundle is read-only,
#                so we MUST install into a writeable location under
#                ~/Library/Containers/.../Application Support/CellCounter/python/.
#   SCRIPTS_DIR  Optional. Directory containing the *_detect.py / *_train.py
#                helpers. Defaults to "$(dirname VENV_PATH)" (the host copies
#                bundled scripts there before invoking us). Used purely for
#                logging — the sidecar discovery happens Swift-side.
#
# When invoked with no args (e.g. directly from a dev shell), it falls back
# to the old behavior of provisioning <repo>/Resources/python/venv.
#
# Re-run safely: pip install is idempotent and existing venv is reused.

set -euo pipefail

VENV_DIR="${1:-}"
SCRIPTS_DIR_ARG="${2:-}"

if [ -z "${VENV_DIR}" ]; then
    # Backwards-compat default: dev-repo layout, two parents up from this script.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
    VENV_DIR="${REPO_ROOT}/Resources/python/venv"
    SCRIPTS_DIR="${REPO_ROOT}/Resources/python"
elif [ -n "${SCRIPTS_DIR_ARG}" ]; then
    SCRIPTS_DIR="${SCRIPTS_DIR_ARG}"
else
    SCRIPTS_DIR="$(dirname "${VENV_DIR}")"
fi

PY_DIR="$(dirname "${VENV_DIR}")"

echo "==> CellCounter Python sidecar installer"
echo "    venv:        ${VENV_DIR}"
echo "    scripts dir: ${SCRIPTS_DIR}"

if [ ! -d "${PY_DIR}" ]; then
    echo "    creating ${PY_DIR}"
    mkdir -p "${PY_DIR}"
fi

DETECT_SCRIPT="${SCRIPTS_DIR}/cellpose_detect.py"
if [ ! -f "${DETECT_SCRIPT}" ]; then
    echo "!!  cellpose_detect.py missing at ${DETECT_SCRIPT}"
    echo "    (the Swift host should have copied it before launching me.)"
fi

if [ ! -d "${VENV_DIR}" ]; then
    echo "==> creating venv with /usr/bin/env python3"
    /usr/bin/env python3 -m venv "${VENV_DIR}"
else
    echo "==> venv already exists; reusing"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

echo "==> upgrading pip"
pip install --upgrade pip

echo "==> installing cellpose + deps (this can take a few minutes)"
pip install cellpose numpy pillow scikit-image tifffile torch torchvision

# Optional vendor microscope-format readers used by CellCounting/python/_imageio.py
# (Zeiss .czi, Nikon .nd2, Leica .lif, Olympus .oif/.oib/.oir). All pure-Python
# BSD-3-Clause; the GPL alternatives (bioformats, bioio-czi, readlif,
# aicspylibczi, pyometiff, czitools) are deliberately NOT used. Best-effort:
# several have no release for older Python minors, and _imageio degrades to the
# PIL path with an "install <pkg> to open <ext>" message when one is absent.
echo "==> installing optional vendor format readers (best effort)"
for _cc_pkg in imagecodecs 'czifile>=2019.7.2,<2027' 'nd2>=0.10,<1' 'liffile<2027' 'oiffile<2027' 'oirfile<2027'; do
    if pip install "${_cc_pkg}"; then
        echo "    ok:      ${_cc_pkg}"
    else
        echo "    skipped: ${_cc_pkg} (unavailable for this Python — optional)"
    fi
done

deactivate || true

cat <<EOF

==> Done.

The venv is ready at:
    ${VENV_DIR}

Expect roughly ~2 GB of disk used (torch + cellpose weights cache on first
run can add more). The CellCounter app picks this up automatically through
CellposeAvailability.swift — no further configuration needed.
EOF
