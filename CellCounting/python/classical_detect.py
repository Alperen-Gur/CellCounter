#!/usr/bin/env python3
"""Legacy CLI compatibility entrypoint for the shared classical detector.

One-shot: ``classical_detect.py --image … --pxPerUm …`` runs one image and
exits.

``--serve``: keeps one interpreter, with NumPy, SciPy and scikit-image
already imported, for many images. Requests use the `serve_ndjson` protocol
in `_cellpose_common`. Each request runs the same `main` a one-shot process
runs, with the same argument list, so the payload is the same. The detector
has no model, so nothing else is kept between requests.
"""
import os
import sys

# Same rule as every other entry script: the sibling helpers are importable
# from the staged python dir even when the interpreter does not add the
# script's own directory to the import path (for example `python -I`).
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from _workbench_classical_legacy import (  # noqa: E402
    main, parse_args, _resolve_method, _global_threshold, _adaptive_threshold,
    _resolve_polarity, _METHODS, _MODEL_METHOD,
)


def run_request(argv) -> None:
    """Run `main` exactly as a one-shot process started with `argv` would.

    The shared kernel's parser reads `sys.argv`, so the argument list is
    swapped in for the duration of the call. Requests are served one at a
    time, so nothing else reads `sys.argv` meanwhile.
    """
    previous = sys.argv
    sys.argv = [previous[0] if previous else __file__, *argv]
    try:
        main()
    finally:
        sys.argv = previous


def serve() -> None:
    import _cellpose_common as cc

    cc.log("[cellpose_detect] classical worker ready")
    cc.serve_ndjson(run_request, after_response=cc.release_request_memory)


if __name__ == "__main__":
    if "--serve" in sys.argv[1:]:
        serve()
    else:
        main()
