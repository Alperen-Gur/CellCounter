#!/usr/bin/env python3
"""Legacy CLI compatibility entrypoint for the shared classical detector."""
from _workbench_classical_legacy import (
    main, parse_args, _resolve_method, _global_threshold, _adaptive_threshold,
    _resolve_polarity, _METHODS, _MODEL_METHOD,
)

if __name__ == "__main__":
    main()
