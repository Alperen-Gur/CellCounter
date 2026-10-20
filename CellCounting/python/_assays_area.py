"""Compatibility exports from the canonical shared numerical kernel."""
import _workbench_assays_area as _shared

# Keep public and historical private helper names for existing callers.
globals().update({name: value for name, value in vars(_shared).items() if not name.startswith("__")})
