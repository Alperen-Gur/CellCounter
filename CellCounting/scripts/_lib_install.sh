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
#     CC_PIP_OPTIONAL_PACKAGES
#                            (optional) space-separated requirements installed
#                            BEST-EFFORT, one pip call each, failures ignored.
#                            Used for the vendor microscope-format readers,
#                            which are genuinely optional (the sidecar falls
#                            back to PIL and reports "install czifile to open
#                            .czi") and several of which have no release for
#                            older Python minors. A hard failure here must
#                            never abort an otherwise-good cellpose install.
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

    local PYTHON_BOOTSTRAP=""
    if [ -n "${CC_MIN_PYTHON_MINOR:-}" ]; then
        # Prefer a supported interpreter already installed by the user. Never
        # repair a 3.9/3.10 environment in place or silently keep its ABI.
        local candidate
        for candidate in "${CC_PYTHON_EXECUTABLE:-}" "${VENV_DIR}/bin/python3" \
            /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 \
            /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 \
            /opt/homebrew/bin/python3 /usr/local/bin/python3 \
            "$(command -v python3 2>/dev/null || true)"; do
            if [ -n "${candidate}" ] && [ -x "${candidate}" ] &&
                "${candidate}" -I -c "import sys; sys.exit(not (sys.version_info.major == 3 and sys.version_info.minor >= ${CC_MIN_PYTHON_MINOR}))"; then
                PYTHON_BOOTSTRAP="${candidate}"
                break
            fi
        done
        if [ -z "${PYTHON_BOOTSTRAP}" ]; then
            echo "!! Python 3.${CC_MIN_PYTHON_MINOR} or later is required for the Workbench and MCP."
            echo "   Install a supported Python interpreter, then use Install or repair again."
            exit 1
        fi
        if [ -d "${VENV_DIR}" ] && ! "${VENV_DIR}/bin/python3" -I -c \
            "import sys; sys.exit(not (sys.version_info.major == 3 and sys.version_info.minor >= ${CC_MIN_PYTHON_MINOR}))"; then
            local prior_venv="${VENV_DIR}.before-python-upgrade-$(date +%Y%m%d-%H%M%S)-$$"
            echo "==> preserving the older Python environment at ${prior_venv}"
            mv "${VENV_DIR}" "${prior_venv}"
        fi
    fi
    if [ ! -d "${VENV_DIR}" ]; then
        echo "==> creating venv"
        if [ -n "${PYTHON_BOOTSTRAP}" ]; then
            "${PYTHON_BOOTSTRAP}" -m venv "${VENV_DIR}"
        else
            /usr/bin/env python3 -m venv "${VENV_DIR}"
        fi
    else
        echo "==> venv already exists; reusing"
    fi

    # shellcheck disable=SC1091
    source "${VENV_DIR}/bin/activate"

    echo "==> upgrading pip"
    pip install --upgrade pip

    echo "==> installing ${CC_FAMILY_LABEL} + deps (this can take a few minutes)"
    # shellcheck disable=SC2086 — CC_PIP_PACKAGES is intentionally word-split
    if [ -n "${CC_PIP_PACKAGES:-}" ]; then pip install ${CC_PIP_PACKAGES}; fi

    if [ -n "${CC_REQUIREMENTS_FILES:-}" ]; then
        local requirements_name workbench_requirements
        for requirements_name in ${CC_REQUIREMENTS_FILES}; do
        workbench_requirements="${SCRIPTS_DIR}/${requirements_name}"
        if [ ! -f "${workbench_requirements}" ]; then
            # Source-only repository installer, same canonical requirements.
            workbench_requirements="${_CC_WRAPPER_DIR}/../../shared/python/${requirements_name}"
        fi
        if [ ! -f "${workbench_requirements}" ]; then
            echo "!! Workbench requirements were not bundled. Reinstall the application."
            exit 1
        fi
        echo "==> installing pinned Workbench requirements: ${requirements_name}"
        pip install -r "${workbench_requirements}"
        done
    fi

    # Optional vendor microscope-format readers (Zeiss .czi, Nikon .nd2,
    # Leica .lif, Olympus .oif/.oib/.oir). All pure-Python BSD-3-Clause.
    # Installed one at a time and never allowed to fail the run: a package with
    # no wheel for this Python simply stays absent, and _imageio.py degrades to
    # the PIL path with an actionable "install <pkg> to open <ext>" message.
    if [ -n "${CC_PIP_OPTIONAL_PACKAGES:-}" ]; then
        echo "==> installing optional vendor format readers (best effort)"
        # shellcheck disable=SC2086 — intentionally word-split
        for _cc_pkg in ${CC_PIP_OPTIONAL_PACKAGES}; do
            if pip install "${_cc_pkg}" 'numpy<2'; then
                echo "    ok:      ${_cc_pkg}"
            else
                echo "    skipped: ${_cc_pkg} (unavailable for this Python — optional)"
            fi
        done
    fi

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
