"""Read-only OMERO source adapter with explicit host-local credential profiles.

The optional OMERO interpreter is separate from the scientific environment.
Only the fixed worker sees credentials; portable projects retain public server
identity, selected raw pixels and their immutable provenance.
"""
from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import uuid

ENGINE = "omero-raw-1"
OMERO_VERSION = "5.23.0"
LIMITS = {"profiles": 32, "pageSize": 100, "regionPixels": 16000000,
          "rawBytes": 128 * 1024**2, "tileSize": 1024, "responseBytes": 2 * 1024**2,
          "configurationBytes": 2 * 1024**2, "requestSeconds": 180, "receipts": 256}
_registry_path = None
NOTES = ["All server operations are read-only and require an explicitly configured named profile.",
         "TLS certificate chain and host name validation are required; insecure fallback is unavailable.",
         "Imports retain one exact T/C/Z XY region in the server's raw dtype, not rendered RGB or JPEG pixels.",
         "A selected-region pixel hash is not a hash of the entire remote image or original uploaded file.",
         "Unknown physical calibration remains unknown. Imported local pixels remain usable without server credentials."]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def file_hash(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def _path(value, *, existing=True):
    if not isinstance(value, str) or not Path(value).is_absolute() or "\0" in value:
        fail("omero-configuration", "OMERO runtime and credential references must be absolute local paths.")
    path = Path(value)
    if existing and not path.is_file():
        fail("omero-configuration", "A configured local OMERO runtime, credential or CA file is unavailable.")
    return path


def configure(path):
    global _registry_path
    value = _path(path, existing=False)
    if value.is_symlink() or not value.parent.is_dir():
        fail("omero-configuration", "Choose a registry file in an existing local directory, without a file symlink.")
    _registry_path = value.absolute()
    # Unrelated analysis commands must remain usable if an optional registry is
    # malformed. OMERO operations validate its current bytes when accessed.


def configured_path():
    return str(_registry_path) if _registry_path else None


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def _json_file(path, maximum, *, private=False):
    from _workbench_host_registry import read_json
    return read_json(path, maximum, private=private, code="omero-configuration")


def _profile(value):
    allowed = {"id", "name", "host", "port", "username", "passwordEnv", "credentialFile", "caFile"}
    if not isinstance(value, dict) or set(value) - allowed:
        fail("omero-profile", "A profile accepts only named connection and explicit credential references, never credential values.")
    value = copy.deepcopy(value)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", value.get("id", "")):
        fail("omero-profile", "Profile IDs use 1–64 letters, numbers, dots, underscores or hyphens.")
    for key, maximum in (("name", 200), ("username", 255)):
        if not isinstance(value.get(key), str) or not 1 <= len(value[key]) <= maximum or any(ord(c) < 32 for c in value[key]):
            fail("omero-profile", "A profile requires a nonempty name and user name without control characters.")
    if not isinstance(value.get("host"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", value["host"]):
        fail("omero-profile", "Use an explicit DNS host name or IPv4 address, without a URL, port, path or credentials.")
    value["port"] = value.get("port", 4064)
    if type(value["port"]) is not int or not 1 <= value["port"] <= 65535:
        fail("omero-profile", "The OMERO TLS port must be between 1 and 65535.")
    if ("passwordEnv" in value) == ("credentialFile" in value):
        fail("omero-profile", "Choose exactly one explicit password environment-variable name or local credential-file reference.")
    if "passwordEnv" in value and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,127}", value["passwordEnv"]):
        fail("omero-profile", "The password environment-variable name is invalid.")
    for key in ("credentialFile", "caFile"):
        if key in value:
            _path(value[key], existing=False)
    return value


def _registry():
    if _registry_path is None:
        fail("omero-not-configured", "Choose an OMERO profile registry in the application, or supply --omero-profiles to the installed Workbench command.")
    if not _registry_path.exists():
        return {"schemaVersion": 1, "profiles": [], "receipts": []}
    value = _json_file(_registry_path, LIMITS["configurationBytes"])
    if value.get("schemaVersion") != 1 or set(value) - {"schemaVersion", "pythonPath", "pythonSha256", "profiles", "receipts"}:
        fail("omero-configuration", "The OMERO registry schema is unsupported.")
    if not isinstance(value.get("profiles"), list) or len(value["profiles"]) > LIMITS["profiles"]:
        fail("omero-configuration", "The OMERO registry supports at most 32 named profiles.")
    value["profiles"] = [_profile(item) for item in value["profiles"]]
    if len({item["id"] for item in value["profiles"]}) != len(value["profiles"]):
        fail("omero-configuration", "OMERO profile IDs must be unique.")
    if "pythonPath" in value or "pythonSha256" in value:
        _path(value.get("pythonPath"), existing=False)
        if not isinstance(value.get("pythonSha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["pythonSha256"]):
            fail("omero-configuration", "The isolated interpreter requires its exact SHA-256 hash.")
    receipts = value.setdefault("receipts", [])
    if not isinstance(receipts, list) or len(receipts) > LIMITS["receipts"]:
        fail("omero-configuration", "The OMERO configuration receipt journal is invalid.")
    return value


def _configuration_hash(registry):
    return digest({key: value for key, value in registry.items() if key != "receipts"}) if _registry_path and _registry_path.exists() else "missing"


def _public_profile(value):
    return {key: value[key] for key in ("id", "name", "host", "port", "username")} | {
        "credentialKind": "environment" if "passwordEnv" in value else "local-file",
        "certificateAuthority": "custom-ca" if value.get("caFile") else "platform-ca",
        "secure": True}


def runtime_inspect():
    if _registry_path is None:
        return {"configured": False, "configurationHash": "missing", "profiles": [], "requiredOmeroVersion": OMERO_VERSION,
                "status": "configuration-required", "notes": ["Select a host-local registry before setting an isolated interpreter or profiles."]}
    registry = _registry()
    python = registry.get("pythonPath")
    exists = bool(python and Path(python).is_file())
    return {"configured": bool(python), "registryPath": str(_registry_path), "configurationHash": _configuration_hash(registry),
            "pythonPath": python, "pythonSha256": registry.get("pythonSha256"), "interpreterPresent": exists,
            "status": "not-probed" if exists else "runtime-required", "requiredOmeroVersion": OMERO_VERSION,
            "profiles": [_public_profile(item) for item in registry["profiles"]],
            "notes": ["Presence is not readiness. Probe the configured runtime explicitly; no server connection is made by the probe.",
                      "Install requirements-omero.txt in a separate environment, including a compatible Ice 3.6 platform wheel."]}


def configure_request(request):
    from _workbench_host_registry import transact
    if _registry_path is None: _registry()
    args, operation = request["arguments"], request["operation"]
    def mutate(registry):
        if operation == "omero.runtime.configure":
            python = _path(args["pythonPath"])
            if python.stat().st_size > 512 * 1024**2:
                fail("omero-runtime-limit", "The isolated interpreter exceeds the512MiB executable file limit.")
            if file_hash(python) != args["pythonSha256"]:
                fail("omero-runtime-changed", "The selected interpreter does not match the supplied SHA256 hash.")
            registry.update(pythonPath=str(python), pythonSha256=args["pythonSha256"])
        elif operation == "omero.profile.save":
            profile = _profile({("id" if key == "profileId" else key): value for key, value in args.items() if key != "expectedConfigurationHash"})
            profiles = [item for item in registry["profiles"] if item["id"] != profile["id"]]
            if len(profiles) >= LIMITS["profiles"]:
                fail("omero-profile-limit", "The registry already contains32 named profiles.")
            registry["profiles"] = sorted(profiles + [profile], key=lambda item: item["id"])
        else:
            fail("unsupported-operation", "Unsupported OMERO configuration write.")
        return {"profiles": [_public_profile(item) for item in registry["profiles"]],
                "pythonPath": registry.get("pythonPath"), "pythonSha256": registry.get("pythonSha256"), "status": "not-probed"}
    return transact(_registry_path, request, _registry, mutate, maximum=LIMITS["configurationBytes"],
                    receipt_limit=LIMITS["receipts"], conflict_code="omero-configuration-conflict")


def profile_for_worker(registry, profile_id):
    result = next((item for item in registry["profiles"] if item["id"] == profile_id), None)
    if result is None:
        fail("omero-profile-missing", "The named OMERO profile is not configured on this host.")
    return result


@contextlib.contextmanager
def invoke(operation, args):
    registry = _registry()
    python = _path(registry.get("pythonPath"))
    if python.stat().st_size > 512 * 1024**2:
        fail("omero-runtime-limit", "The isolated interpreter exceeds the 512 MiB executable file limit.")
    if file_hash(python) != registry.get("pythonSha256"):
        fail("omero-runtime-changed", "The configured OMERO interpreter changed. Explicitly rebind its current SHA-256 before using it.")
    profile = profile_for_worker(registry, args["profileId"]) if "profileId" in args else None
    # No credential values in argv, request JSON, stdout/stderr, project or receipt.
    env = {key: value for key, value in os.environ.items() if key in {
        "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT", "TEMP", "TMP", "TMPDIR", "HOME", "USERPROFILE", "LANG", "LC_ALL"}}
    if profile and profile.get("passwordEnv"):
        key = profile["passwordEnv"]
        if key in os.environ: env[key] = os.environ[key]
    with tempfile.TemporaryDirectory(prefix="cellcounter-omero-") as directory:
        root = Path(directory)
        request_path, response_path = root / "request.json", root / "result.json"
        request_path.write_bytes(encoded({"schemaVersion": 1, "operation": operation, "arguments": args,
                                         "registryPath": str(_registry_path), "configurationHash": _configuration_hash(registry)}))
        worker = Path(__file__).with_name("_workbench_omero_worker.py")
        try:
            completed = subprocess.run([str(python), "-I", str(worker), "--request", str(request_path), "--response", str(response_path)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       env=env, cwd=root, timeout=LIMITS["requestSeconds"], check=False)
        except subprocess.TimeoutExpired:
            fail("omero-timeout", "The bounded OMERO request timed out. Check connectivity and retry the same read or preview a smaller region.")
        except OSError:
            fail("omero-runtime-unavailable", "The configured isolated OMERO interpreter could not start.")
        if not response_path.is_file() or response_path.stat().st_size > LIMITS["responseBytes"]:
            fail("omero-runtime-unavailable", "The OMERO worker did not return a bounded response. Probe or repair its isolated environment.")
        response = _json_file(response_path, LIMITS["responseBytes"])
        if response.get("ok") is not True:
            error = response.get("error", {})
            code = error.get("code", "omero-request-failed")
            message = error.get("message", "The OMERO read could not complete.")
            fail(code if isinstance(code, str) else "omero-request-failed", message if isinstance(message, str) else "The OMERO read could not complete.")
        if completed.returncode or not isinstance(response.get("result"), dict):
            fail("omero-invalid-response", "The OMERO worker returned an invalid result.")
        yield response["result"], root


def _selection(args):
    return {key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex", "x", "y")} | {key: args[key] for key in ("width", "height")}


def _raw_result(result, root):
    from _workbench_imaging import require
    np, = require("numpy")
    artifact = result.get("raw", {})
    if artifact.get("path") != "pixels.npy":
        fail("omero-invalid-response", "The worker raw-pixel output path is invalid.")
    path = root / "pixels.npy"
    if path.is_symlink() or not path.is_file() or path.stat().st_size > LIMITS["rawBytes"] + 4096 or file_hash(path) != artifact.get("sha256"):
        fail("omero-invalid-response", "The raw-pixel output does not match its size or hash.")
    # The bounded region is consumed before its request directory is removed.
    # Avoid a Windows file mapping that would outlive TemporaryDirectory cleanup.
    try: pixels = np.load(path, allow_pickle=False)
    except (ValueError, OSError): fail("omero-invalid-response", "The raw-pixel output is not a safe numeric array.")
    selection = result["selection"]
    if pixels.shape != (selection["height"], selection["width"]) or pixels.dtype.kind not in "uif" or pixels.dtype.itemsize > 8 or pixels.nbytes > LIMITS["rawBytes"]:
        fail("omero-invalid-response", "The raw-pixel output shape or dtype is unsupported.")
    if not np.isfinite(pixels).all():
        fail("omero-nonfinite", "This region contains non-finite raw samples. Select a valid region before importing.")
    canonical_pixels = np.asarray(pixels, dtype=pixels.dtype.newbyteorder("<"), order="C")
    if hashlib.sha256(memoryview(canonical_pixels).cast("B")).hexdigest() != result.get("pixelSha256"):
        fail("omero-invalid-response", "The decoded raw pixel hash does not match the worker's selected-region identity.")
    return pixels, path


def _fingerprint(result):
    return digest({key: result[key] for key in ("connection", "image", "selection", "pixelSha256")})


def _import(store, document, args):
    from _workbench_imaging import require
    from _workbench_store import utc_now
    np, tifffile = require("numpy", "tifffile")
    if len(document.get("images", [])) >= 1000:
        fail("project-too-large", "A project currently supports at most 1,000 ordinary analysis images.")
    with invoke("raw-region", {key: value for key, value in args.items() if key not in ("previewFingerprint", "name")}) as (result, root):
        pixels, raw_path = _raw_result(result, root)
        if args["previewFingerprint"] != _fingerprint(result):
            fail("omero-preview-changed", "The remote image metadata, selected raw pixels or connection identity changed. Preview the region again before importing.")
        metadata = result["image"]
        voxels = metadata["voxelSizeUm"]
        ome = {"axes": "YX"}
        for axis in "XY":
            if voxels[axis.lower()] is not None:
                ome["PhysicalSize" + axis] = voxels[axis.lower()]
                ome["PhysicalSize" + axis + "Unit"] = "µm"
        output = io.BytesIO()
        tifffile.imwrite(output, pixels, ome=True, photometric="minisblack", metadata=ome)
        source_path, source_hash = store.put_bytes(output.getvalue(), ".ome.tif")
        raw_reference, raw_hash, _ = store.import_file(raw_path, ".omero-raw.npy")
        provenance = {"schemaVersion": 1, "engineVersion": ENGINE, **{key: result[key] for key in
                      ("connection", "image", "selection", "pixelSha256", "observedAt")},
                      "rawArtifact": {"path": raw_reference, "sha256": raw_hash}, "previewFingerprint": args["previewFingerprint"],
                      "notes": NOTES}
        provenance_path, provenance_hash = store.put_bytes(encoded(provenance), ".omero.json")
        selection = result["selection"]
        region = {"kind": "omero", "profileId": args["profileId"], "server": result["connection"]["server"],
                  "groupId": args["groupId"], "imageId": args["imageId"], "pixelsId": metadata["pixelsId"], **selection,
                  "originalDimensions": metadata["dimensions"], "pixelSha256": result["pixelSha256"],
                  "provenancePath": provenance_path, "provenanceHash": provenance_hash,
                  "rawPath": raw_reference, "rawHash": raw_hash, "resampled": False,
                  "coordinateSpace": "source-pixel-edges", "originUm": {axis: selection[axis] * voxels[axis] if voxels[axis] is not None else None for axis in ("x", "y")}}
        scale = 1 / voxels["x"] if voxels["x"] is not None and voxels["y"] is not None and math.isclose(voxels["x"], voxels["y"], rel_tol=1e-9) else None
        image = {"id": str(uuid.uuid4()), "name": args.get("name") or f"{metadata['name']} · T{selection['timeIndex']} C{selection['channel']} Z{selection['zIndex']} ROI",
                 "sourcePath": source_path, "sourceHash": source_hash, "sourceBytes": output.getbuffer().nbytes,
                 "importedAt": utc_now(), "pxPerUm": scale, "voxelSizeUm": {"x": voxels["x"], "y": voxels["y"], "z": None},
                 "calibrationSource": "omero-metadata", "timeStepSeconds": None,
                 "width": selection["width"], "height": selection["height"], "channels": 1, "zCount": 1, "timeCount": 1,
                 "axes": "YX", "shape": list(pixels.shape), "dtype": str(pixels.dtype), "undoStack": [], "sourceRegion": region}
        document.setdefault("images", []).append(image)
        from _workbench_core import _inspection
        descriptor = next(item for item in _inspection(document)["images"] if item["id"] == image["id"])
        return {"imageId": image["id"], "image": descriptor, "provenance": provenance, "sourceRegion": region}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    integer = {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
    profile = {"profileId": {"type": "string", "minLength": 1, "maxLength": 64}}
    selected = {**profile, "groupId": integer, "imageId": integer}
    page = {"offset": {"type": "integer", "minimum": 0, "maximum": 10000000, "default": 0},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 50}}
    region = {**selected, **{key: {"type": "integer", "minimum": 0, "default": 0} for key in ("timeIndex", "channel", "zIndex", "x", "y")},
              **{key: {"type": "integer", "minimum": 1, "maximum": LIMITS["regionPixels"]} for key in ("width", "height")}}
    result = [_op("omero.catalogue", "Describe secure read-only OMERO raw-pixel import and its limits.", _object(), project=False),
              _op("omero.runtime.inspect", "Read host-local OMERO runtime configuration without invoking code or connecting.", _object(), project=False),
              _op("omero.runtime.candidate", "Read a candidate isolated interpreter's exact file identity without executing it.", _object({"pythonPath": _STRING}, ["pythonPath"]), project=False),
              _op("omero.runtime.probe", "Explicitly inspect the fixed isolated OMERO runtime, without a server connection.", _object(), project=False),
              _op("omero.profile.list", "List public named connection profiles, without credentials or network activity.", _object(), project=False),
              _op("omero.connection.inspect", "Connect to one named OMERO profile and inspect the authenticated read-only context.", _object(profile, ["profileId"]), project=False),
              _op("omero.group.list", "Page through groups available to the authenticated user.", _object({**profile, **page}, ["profileId"]), project=False),
              _op("omero.object.list", "Page through an explicit OMERO group and hierarchy without fetching image pixels.", _object({**profile, "groupId": integer,
                  "kind": {"type": "string", "enum": ["project", "dataset", "image", "screen", "plate", "well"]}, "parentId": integer,
                  "parentKind": {"type": "string", "enum": ["project", "dataset", "screen", "plate", "well"]}, **page}, ["profileId", "groupId", "kind"]), project=False),
              _op("omero.image.inspect", "Read exact OMERO image/pixels axes, dtype, dimensions and known calibration.", _object(selected, list(selected)), project=False),
              _op("omero.import.preview", "Preview one bounded raw T/C/Z region and freeze its pixel and metadata identity.", _object({**region, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}}, [*selected, "width", "height"]), project=False),
              _op("omero.import.run", "Import a freshly verified previewed raw OMERO region as an independent canonical source image.", _object({**region, "previewFingerprint": _ID, "name": {"type": "string", "minLength": 1, "maxLength": 200}}, [*selected, "width", "height", "previewFingerprint"]), True),
              _op("omero.runtime.configure", "Bind a preinstalled isolated interpreter to this host-local OMERO registry using exact hash CAS.",
                  _object({"pythonPath": _STRING, "pythonSha256": {"type": "string", "minLength": 64, "maxLength": 64}, "expectedConfigurationHash": _ID}, ["pythonPath", "pythonSha256", "expectedConfigurationHash"]), True, False),
              _op("omero.profile.save", "Save a named host-local connection profile using references, never credential values.", _object({**profile,
                  "name": {"type": "string", "minLength": 1, "maxLength": 200}, "host": _STRING, "port": {"type": "integer", "minimum": 1, "maximum": 65535, "default": 4064},
                  "username": _STRING, "passwordEnv": _STRING, "credentialFile": _STRING, "caFile": _STRING, "expectedConfigurationHash": _ID},
                  ["profileId", "name", "host", "username", "expectedConfigurationHash"]), True, False)]
    for operation in result:
        if operation["name"] in ("omero.runtime.configure", "omero.profile.save"):
            operation.update(requiresExpectedRevision=False, affectsProjectRevision=False, hostLocalConfiguration=True)
        if operation["name"] == "omero.runtime.probe": operation["usesExecutableCode"] = True
        if "profileId" in operation["inputSchema"]["properties"] and operation["name"] != "omero.profile.save":
            operation["networkProfileArgument"] = "profileId"
    return result


def execute(store, document, operation, args, revision):
    if operation == "omero.catalogue":
        return {"engineVersion": ENGINE, "requiredOmeroVersion": OMERO_VERSION, "limits": LIMITS, "notes": NOTES,
                "networkAccess": "read-only", "targets": ["selected-raw-plane-region"], "wholeImageContentHash": False}
    if operation == "omero.runtime.inspect": return runtime_inspect()
    if operation == "omero.runtime.candidate":
        candidate = _path(args["pythonPath"])
        if candidate.stat().st_size > 512 * 1024**2:
            fail("omero-runtime-limit", "The candidate interpreter exceeds the 512 MiB executable file limit.")
        return {"pythonPath": str(candidate), "pythonSha256": file_hash(candidate), "bytes": candidate.stat().st_size, "executed": False}
    if operation == "omero.profile.list":
        inspected = runtime_inspect()
        return {"profiles": inspected["profiles"], "configurationHash": inspected["configurationHash"], "configured": inspected["configured"]}
    if operation == "omero.import.run": return _import(store, document, args)
    mapped = {"omero.runtime.probe": "probe", "omero.connection.inspect": "connection", "omero.group.list": "groups",
              "omero.object.list": "objects", "omero.image.inspect": "image", "omero.import.preview": "raw-region"}
    if operation not in mapped: fail("unsupported-operation", "Unsupported OMERO operation.")
    with invoke(mapped[operation], {key: value for key, value in args.items() if key != "maxSize"}) as (result, root):
        if operation != "omero.import.preview": return result
        from _workbench_imaging import preview_data
        pixels, _ = _raw_result(result, root)
        return {**{key: value for key, value in result.items() if key != "raw"}, **preview_data(pixels, max_size=args.get("maxSize", 768)),
                "previewFingerprint": _fingerprint(result), "intensityUnits": "raw-source", "notes": NOTES}


def artifact_references(document):
    result = {}
    for image in document.get("images", []):
        region = image.get("sourceRegion", {})
        if region.get("kind") == "omero":
            for path, checksum in (("provenancePath", "provenanceHash"), ("rawPath", "rawHash")):
                result[region[path]] = region[checksum]
    return result


def validate_document(document):
    for image in document.get("images", []):
        region = image.get("sourceRegion", {})
        if region.get("kind") != "omero": continue
        if region.get("resampled") is not False or any(not isinstance(region.get(key), str) for key in ("profileId", "provenancePath", "provenanceHash", "rawPath", "rawHash", "pixelSha256")):
            fail("invalid-project", "The retained OMERO region provenance is invalid.")
        if any(type(region.get(key)) is not int or region[key] < 0 for key in ("groupId", "imageId", "pixelsId", "timeIndex", "channel", "zIndex", "x", "y")):
            fail("invalid-project", "The retained OMERO source selection is invalid.")
