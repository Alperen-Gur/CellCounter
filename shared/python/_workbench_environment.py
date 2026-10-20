"""Observed Python distribution inventories, without executing package imports.

This module uses only the standard library so the same capture code can run in
the shared workbench and an explicitly selected external model interpreter.
An inventory records installed distribution metadata, not a restorable lockfile
or a proof that every installed code byte or system driver is identical.
"""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import platform
import re
import sys

MAX_PACKAGES = 4096
MAX_BYTES = 2 * 1024 ** 2
MAX_DIFFERENCES = 200
_NAME = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,198}[A-Za-z0-9])?$")
_HASH = re.compile(r"^[0-9a-f]{64}$")


def notes():
    return [
        "Records observed Python, platform and installed distribution names/versions without importing those packages.",
        "Package metadata does not verify package file bytes, editable source changes, system libraries or GPU drivers.",
        "The inventory is not an installation lockfile; it does not install dependencies or guarantee identical numerical results.",
        "Environment variables, package download URLs and installation paths are not included.",
    ]


def _text(value, label, maximum=200, *, empty=False):
    if (not isinstance(value, str) or len(value) > maximum or
            (not empty and not value) or any(ord(character) < 32 or ord(character) == 127 for character in value)):
        raise ValueError(f"Invalid {label} in the Python environment inventory.")
    return value


def _encode(value):
    # Match the project store's canonical encoding so its retained file cannot
    # exceed this bound when non-ASCII metadata is escaped during publication.
    return json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False,
                      separators=(",", ":")).encode("utf-8")


def _seal(body):
    encoded = _encode(body)
    if len(encoded) > MAX_BYTES - 100:
        raise ValueError("The Python environment inventory exceeds its 2 MiB limit.")
    return {**body, "hash": hashlib.sha256(encoded).hexdigest()}


def capture():
    """Capture the current interpreter's observed installed distributions once."""
    packages = []
    for distribution in importlib.metadata.distributions():
        if len(packages) >= MAX_PACKAGES:
            raise ValueError("The Python environment contains more than 4096 distribution records.")
        metadata = distribution.metadata
        name = _text(metadata.get("Name"), "distribution name")
        if not _NAME.fullmatch(name):
            raise ValueError("A Python distribution has an unsupported name in its metadata.")
        version = _text(metadata.get("Version"), "distribution version")
        packages.append({"name": re.sub(r"[-_.]+", "-", name).lower(), "version": version})
    packages.sort(key=lambda item: (item["name"], item["version"]))
    return _seal({
        "schemaVersion": 1, "kind": "python-environment",
        "python": {
            "implementation": _text(sys.implementation.name, "Python implementation"),
            "version": _text(platform.python_version(), "Python version"),
            "cacheTag": _text(sys.implementation.cache_tag or "", "Python cache tag", empty=True),
        },
        "platform": {
            "system": _text(platform.system(), "platform system", empty=True),
            "machine": _text(platform.machine(), "platform machine", empty=True),
            "byteOrder": sys.byteorder,
        },
        "packages": packages,
    })


def validate(value):
    """Validate strict inventory fields, bounds, canonical order and digest."""
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "kind", "python", "platform", "packages", "hash"}:
        raise ValueError("The Python environment inventory has unsupported fields.")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["kind"] != "python-environment":
        raise ValueError("Unsupported Python environment inventory version or kind.")
    interpreter = value["python"]
    if not isinstance(interpreter, dict) or set(interpreter) != {"implementation", "version", "cacheTag"}:
        raise ValueError("Invalid Python interpreter inventory fields.")
    normalized_python = {key: _text(interpreter[key], "Python " + key, empty=key == "cacheTag")
                         for key in ("implementation", "version", "cacheTag")}
    machine = value["platform"]
    if not isinstance(machine, dict) or set(machine) != {"system", "machine", "byteOrder"}:
        raise ValueError("Invalid Python platform inventory fields.")
    if machine["byteOrder"] not in ("little", "big"):
        raise ValueError("Invalid Python byte order in the inventory.")
    normalized_platform = {"system": _text(machine["system"], "platform system", empty=True),
                           "machine": _text(machine["machine"], "platform machine", empty=True),
                           "byteOrder": machine["byteOrder"]}
    packages = value["packages"]
    if not isinstance(packages, list) or len(packages) > MAX_PACKAGES:
        raise ValueError("Invalid or oversized Python distribution inventory.")
    normalized_packages = []
    for entry in packages:
        if not isinstance(entry, dict) or set(entry) != {"name", "version"}:
            raise ValueError("Invalid Python distribution inventory fields.")
        name = _text(entry["name"], "distribution name")
        if not _NAME.fullmatch(name) or name != re.sub(r"[-_.]+", "-", name).lower():
            raise ValueError("Python distribution names must be normalized.")
        normalized_packages.append({"name": name, "version": _text(entry["version"], "distribution version")})
    if normalized_packages != sorted(normalized_packages, key=lambda item: (item["name"], item["version"])):
        raise ValueError("Python distribution inventory must use canonical name/version order.")
    body = {"schemaVersion": 1, "kind": "python-environment", "python": normalized_python,
            "platform": normalized_platform, "packages": normalized_packages}
    supplied_hash = value["hash"]
    if not isinstance(supplied_hash, str) or not _HASH.fullmatch(supplied_hash):
        raise ValueError("Invalid Python environment inventory hash.")
    result = _seal(body)
    if result["hash"] != supplied_hash:
        raise ValueError("The Python environment inventory hash does not match its contents.")
    return result


def summary(value):
    value = validate(value)
    return {"hash": value["hash"], "pythonVersion": value["python"]["version"],
            "implementation": value["python"]["implementation"],
            "system": value["platform"]["system"], "machine": value["platform"]["machine"],
            "packageCount": len(value["packages"])}


def retain(store, value):
    """Retain an inventory in a shared project; unused in external workers."""
    from _workbench_store import canonical
    value = validate(value)
    path, checksum = store.put_bytes((canonical(value) + "\n").encode("utf-8"), ".python-environment.json")
    return {"hash": value["hash"], "inventoryPath": path, "inventoryHash": checksum,
            "summary": summary(value)}


def differences(expected, actual):
    """Return bounded descriptions; repeated metadata records remain visible."""
    expected, actual = validate(expected), validate(actual)
    changes = []
    count = 0
    def changed(message):
        nonlocal count
        count += 1
        if len(changes) < MAX_DIFFERENCES:
            changes.append(message)
    def versions(values):
        if not values:
            return "not installed"
        result = ", ".join(values[:4])
        return result + (f" (+{len(values) - 4} records)" if len(values) > 4 else "")
    for section in ("python", "platform"):
        for key in expected[section]:
            left, right = expected[section][key], actual[section][key]
            if left != right:
                changed(f"{section}.{key}: recorded {left or 'unspecified'}, current {right or 'unspecified'}.")
    inventories = []
    for value in (expected, actual):
        packages = {}
        for entry in value["packages"]:
            packages.setdefault(entry["name"], []).append(entry["version"])
        inventories.append(packages)
    left, right = inventories
    for name in sorted(set(left) | set(right)):
        if left.get(name) != right.get(name):
            # A malformed environment may contain many records for one name.
            # Preserve multiplicity but bound the explanatory text, not the hash.
            changed(f"{name}: recorded {versions(left.get(name))}, current {versions(right.get(name))}.")
    if count > MAX_DIFFERENCES:
        return changes + [f"{count - MAX_DIFFERENCES} additional environment differences."]
    return changes


def normalize_constraints(value):
    """Validate optional PEP440 metadata requirements; never install packages."""
    if not isinstance(value, dict) or set(value) - {"python", "packages"}:
        raise ValueError("Dependencies accept Python and named distribution version constraints only.")
    try:
        from packaging.specifiers import SpecifierSet, InvalidSpecifier
    except ImportError as error:
        raise ValueError("Dependency declarations require the packaging distribution in the selected runtime.") from error
    def specifier(spec):
        if not isinstance(spec, str) or not spec.strip() or not 1 <= len(spec) <= 200 or any(ord(character) < 32 for character in spec):
            raise ValueError("Version constraints must be bounded PEP440 specifiers without URLs or markers.")
        try: return str(SpecifierSet(spec))
        except InvalidSpecifier as error: raise ValueError("Invalid PEP440 dependency constraint.") from error
    result = {}
    if "python" in value: result["python"] = specifier(value["python"])
    packages = value.get("packages", [])
    if not isinstance(packages, list) or len(packages) > 64: raise ValueError("Declare at most64 distribution dependencies.")
    normalized, seen = [], set()
    for package in packages:
        if not isinstance(package, dict) or set(package) != {"name", "specifier"} or not isinstance(package["name"], str) or not _NAME.fullmatch(package["name"]):
            raise ValueError("Each package requires a distribution name and a PEP440 version specifier.")
        name = re.sub(r"[-_.]+", "-", package["name"]).lower()
        if name in seen: raise ValueError("Distribution dependency names must be distinct.")
        seen.add(name); normalized.append({"name": name, "specifier": specifier(package["specifier"])})
    result["packages"] = sorted(normalized, key=lambda item: item["name"])
    return result


def check_constraints(inventory, constraints):
    inventory = validate(inventory); constraints = normalize_constraints(constraints)
    from packaging.specifiers import SpecifierSet
    from packaging.version import InvalidVersion
    observed = {}
    for item in inventory["packages"]: observed.setdefault(item["name"], []).append(item["version"])
    requirements = ([{"name": "python", "specifier": constraints["python"]}] if "python" in constraints else []) + constraints["packages"]
    results = []
    for requirement in requirements:
        versions = [inventory["python"]["version"]] if requirement["name"] == "python" else observed.get(requirement["name"], [])
        try: satisfied = len(versions) == 1 and SpecifierSet(requirement["specifier"]).contains(versions[0], prereleases=True)
        except InvalidVersion: satisfied = False
        results.append({**requirement, "observedVersions": versions, "satisfied": satisfied})
    failed = [item for item in results if not item["satisfied"]]
    if failed:
        raise ValueError("Observed runtime dependencies do not satisfy: " + "; ".join(item["name"] + item["specifier"] + " (observed " + (", ".join(item["observedVersions"]) or "missing") + ")" for item in failed))
    return {"satisfied": True, "requirements": results, "environmentHash": inventory["hash"], "scope": "observed-distribution-metadata"}
