#!/usr/bin/env bash
#
# _lib_install.sh — shared bootstrap library for install_python*.sh.
#
# Pass-18 (K4): both install_python.sh (cellpose 3.x → venv/) and
# install_python_cp4.sh (cellpose 4.x → venv4/) used to be ~95% identical.
# This file owns the duplicated logic; the two wrappers stay slim and only
# specify pip args + the venv basename so all the Swift call sites (which
# care about script *names* and not contents) keep working unchanged.
#
# Sourced — not executed directly. Wrapper scripts set:
#
#     CC_VENV_DEFAULT_NAME   e.g. "venv"   or "venv4"
#     CC_FAMILY_LABEL        e.g. "Cellpose 3.x"  or "Cellpose-SAM (cp4)"
#     CC_DETECT_FILENAME     e.g. "cellpose_detect.py" or "cellpose4_detect.py"
#     CC_PIP_PACKAGES        the full `pip install …` argument vector (word-split)
#     CC_DONE_EXTRA_NOTE     (optional) trailing free-text after the standard banner
#     _CC_WRAPPER_DIR        directory of the wrapper script (for dev-mode fallback)
#
# then call `cc_install_run "$@"`.

set -euo pipefail

cc_install_run() {
    local VENV_DIR="${1:-}"
    local SCRIPTS_DIR_ARG="${2:-}"
    local SCRIPTS_DIR

    if [ -z "${VENV_DIR}" ]; then
        # Backwards-compat default: dev-repo layout, two parents up from the
        # wrapper script.
        local REPO_ROOT
        REPO_ROOT="$(cd "${_CC_WRAPPER_DIR}/.." && pwd)"
        VENV_DIR="${REPO_ROOT}/Resources/python/${CC_VENV_DEFAULT_NAME}"
        SCRIPTS_DIR="${REPO_ROOT}/Resources/python"
    elif [ -n "${SCRIPTS_DIR_ARG}" ]; then
        SCRIPTS_DIR="${SCRIPTS_DIR_ARG}"
    else
        SCRIPTS_DIR="$(dirname "${VENV_DIR}")"
    fi

    local PY_DIR
    PY_DIR="$(dirname "${VENV_DIR}")"

    echo "==> CellCounter ${CC_FAMILY_LABEL} sidecar installer"
    echo "    venv:        ${VENV_DIR}"
    echo "    scripts dir: ${SCRIPTS_DIR}"

    if [ ! -d "${PY_DIR}" ]; then
        echo "    creating ${PY_DIR}"
        mkdir -p "${PY_DIR}"
    fi

    local DETECT_SCRIPT="${SCRIPTS_DIR}/${CC_DETECT_FILENAME}"
    if [ ! -f "${DETECT_SCRIPT}" ]; then
        echo "!!  ${CC_DETECT_FILENAME} missing at ${DETECT_SCRIPT}"
        echo "    (the Swift host should have copied it before launching me.)"
    fi

    # Belt-and-braces: a previous run can leave a venv dir without a usable
    # pip. The Swift caller also checks this, but duplicating here lets the
    # script be safe to run by hand.
    if [ -d "${VENV_DIR}" ] && [ ! -x "${VENV_DIR}/bin/pip" ]; then
        echo "==> removing half-installed venv at ${VENV_DIR}"
        rm -rf "${VENV_DIR}"
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

    echo "==> installing ${CC_FAMILY_LABEL} + deps (this can take a few minutes)"
    # shellcheck disable=SC2086 — CC_PIP_PACKAGES is intentionally word-split
    pip install ${CC_PIP_PACKAGES}

    deactivate || true

    echo
    echo "==> Done."
    echo
    echo "The venv is ready at:"
    echo "    ${VENV_DIR}"
    echo
    if [ -n "${CC_DONE_EXTRA_NOTE:-}" ]; then
        echo "${CC_DONE_EXTRA_NOTE}"
    fi
}
