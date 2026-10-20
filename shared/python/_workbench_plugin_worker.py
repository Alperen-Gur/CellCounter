"""Run a trusted plugin with its original argv and record its isolated Python environment."""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import runpy
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entry")
    parser.add_argument("--request")
    parser.add_argument("--response")
    parser.add_argument("--environment", required=True)
    parser.add_argument("--capture-only", action="store_true")
    parser.add_argument("--expected-environment-hash")
    args = parser.parse_args()
    # Load this one bundled stdlib-only helper without adding its directory to
    # sys.path: -I must keep the plugin's package search path isolated exactly as
    # it was when the plugin script was launched directly.
    helper = Path(__file__).resolve().with_name("_workbench_environment.py")
    spec = importlib.util.spec_from_file_location("_cellcounter_environment_capture", helper)
    if spec is None or spec.loader is None:
        raise RuntimeError("The bundled Python environment recorder is unavailable.")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    inventory = module.capture()
    with Path(args.environment).open("x", encoding="utf-8") as stream:
        json.dump(inventory, stream, sort_keys=True, ensure_ascii=False, allow_nan=False,
                  separators=(",", ":"))
        stream.write("\n")
    if args.expected_environment_hash is not None and inventory["hash"] != args.expected_environment_hash:
        return 42
    if args.capture_only:
        return 0
    if not args.entry or not args.request or not args.response:
        parser.error("Plugin execution requires --entry, --request and --response.")
    with Path(args.request).open("r", encoding="utf-8") as stream:
        request = json.load(stream)
    if request.get("dependencies") is not None:
        try: module.check_constraints(inventory, request["dependencies"])
        except ValueError as error:
            print(str(error), file=sys.stderr)
            return 43
    # No inventory fields are added to the scientific plugin request/response
    # protocol. Existing scripts still receive exactly their two file arguments.
    sys.argv = [args.entry, args.request, args.response]
    runpy.run_path(args.entry, run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
