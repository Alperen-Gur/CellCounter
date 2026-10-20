"""Fixed isolated OMERO read worker. Never forwards server exceptions or logs."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.metadata
import json
import logging
import math
import os
from pathlib import Path
import sys

# This is a packaged fixed program, not a project-provided executable.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _workbench_omero import (LIMITS, OMERO_VERSION, _configuration_hash, _json_file,
                              _path, _registry, configure, digest, encoded, fail,
                              file_hash, profile_for_worker)


def runtime():
    try:
        installed = importlib.metadata.version("omero-py")
        import numpy as np
        import Ice
        import omero
        from omero.gateway import BlitzGateway
    except ImportError:
        fail("omero-runtime-missing", "The isolated interpreter needs requirements-omero.txt and a compatible Ice 3.6 platform wheel. Workbench and model environments should remain unchanged.")
    if installed != OMERO_VERSION or not Ice.stringVersion().startswith("3.6.") or int(np.__version__.split(".")[0]) != 2:
        fail("omero-runtime-version", "The isolated reader requires omero-py 5.23.0, Ice 3.6 and NumPy 2. Repair or explicitly rebind its environment.")
    return np, Ice, omero, BlitzGateway


def _credential(profile):
    if "passwordEnv" in profile:
        password = os.environ.get(profile["passwordEnv"])
    else:
        data = _json_file(_path(profile["credentialFile"]), 32768, private=True)
        if set(data) != {"password"}:
            fail("omero-credential-file", "The private credential file must contain only a password field.")
        password = data["password"]
    if not isinstance(password, str) or not password or len(password) > 16384 or "\0" in password:
        fail("omero-credential-unavailable", "The configured credential reference is unavailable or invalid. Update it locally before connecting.")
    return password


@contextlib.contextmanager
def connection(profile, group_id=None):
    _, _, omero, BlitzGateway = runtime()
    password = _credential(profile)
    props = {"IceSSL.VerifyPeer": "2", "IceSSL.CheckCertName": "1", "IceSSL.UsePlatformCAs": "1",
             "Ice.Default.Secure": "1", "Ice.Default.PreferSecure": "1",
             "Ice.Default.Router": f"OMERO.Glacier2/router:ssl -h {profile['host']} -p {profile['port']}",
             "Ice.Override.ConnectTimeout": "20000", "Ice.Override.Timeout": "45000",
             "Ice.RetryIntervals": "-1", "Ice.MessageSizeMax": "32768",
             "Ice.ThreadPool.Client.SizeMax": "2", "Ice.ThreadPool.Server.SizeMax": "1",
             "omero.dump": "", "omero.keep_alive": "0"}
    if profile.get("caFile"):
        ca = _path(profile["caFile"])
        if ca.stat().st_size > 4 * 1024**2:
            fail("omero-ca-file", "The configured CA file exceeds the 4 MiB trust-store limit.")
        props["IceSSL.CAs"] = str(ca)
        props["IceSSL.UsePlatformCAs"] = "0"
    client = None
    gateway = None
    try:
        client = omero.client(args=[], host=profile["host"], port=profile["port"], pmap=props)
        client.setAgent("CellCounter read-only raw source adapter")
        client.createSession(profile["username"], password)
        gateway = BlitzGateway(client_obj=client, username=profile["username"], passwd=password,
                               secure=True, anonymous=False)
        if group_id is not None:
            members = set(int(value) for value in gateway.getEventContext().memberOfGroups)
            if group_id not in members:
                fail("omero-group-denied", "The selected group is not in the authenticated user's explicit memberships.")
            if int(gateway.getEventContext().groupId) != group_id and gateway.setGroupForSession(group_id) is not True:
                fail("omero-group-denied", "The requested OMERO group could not be selected.")
        yield gateway
    finally:
        password = None
        with contextlib.suppress(Exception):
            if gateway is not None: gateway.close()
            elif client is not None: client.closeSession()


def public_connection(conn, profile):
    context = conn.getEventContext()
    return {"profileId": profile["id"], "server": {"host": profile["host"], "port": profile["port"], "transport": "tls",
            "certificateValidation": "chain-and-hostname", "caSha256": file_hash(profile["caFile"]) if profile.get("caFile") else None},
            "user": {"id": int(context.userId), "username": profile["username"]}, "groupId": int(context.groupId)}


def _text(value, maximum=2000):
    text = str(value or "")
    return "".join(c for c in text if c in "\n\t" or ord(c) >= 32)[:maximum]


def _quantity(value):
    if value is None: return None
    number = float(value.getValue())
    if not math.isfinite(number): return None
    return {"value": number, "unit": str(value.getUnit())}


def _image(conn, image_id, group_id):
    image = conn.getObject("Image", image_id)
    if image is None:
        fail("omero-image-unavailable", "The selected image is not visible in the selected group.")
    if int(image.getDetails().getGroup().getId()) != group_id:
        fail("omero-group-mismatch", "The image belongs to a different group. Select its actual group explicitly.")
    if not image.canDownload():
        fail("omero-raw-denied", "The server denies raw-pixel download for this image. A rendered display cannot substitute for raw scientific data.")
    pixels = image.getPrimaryPixels()
    if pixels is None:
        fail("omero-pixels-unavailable", "The selected image has no accessible primary pixels.")
    raw = pixels._obj
    sizes = {axis.lower(): int(getattr(raw, "getSize" + axis)().getValue()) for axis in "XYZCT"}
    if any(value < 1 or value > 2147483647 for value in sizes.values()):
        fail("omero-dimensions", "The image dimensions are invalid or exceed the supported index range.")
    np, _, _, _ = runtime()
    try: dtype = np.dtype(pixels.get_numpy_type())
    except (KeyError, TypeError): fail("omero-dtype", "This image uses an unsupported non-real OMERO pixel type.")
    if dtype.kind not in "uif" or dtype.itemsize > 8:
        fail("omero-dtype", "Only exact real integer and floating-point raw pixels are supported.")
    voxel, physical, notes = {}, {}, []
    for axis in "XYZ":
        value = getattr(raw, "getPhysicalSize" + axis)()
        physical[axis.lower()] = _quantity(value)
        try:
            converted = getattr(image, "getPixelSize" + axis)(units="MICROMETER")
            scale = None if converted is None else float(converted.getValue())
        except Exception:
            scale = None
        voxel[axis.lower()] = scale if scale is not None and math.isfinite(scale) and scale > 0 else None
        if value is not None and voxel[axis.lower()] is None:
            notes.append(f"The {axis} calibration cannot be converted to micrometres and is retained only in original units.")
    time_value = _quantity(raw.getTimeIncrement())
    seconds = None
    if time_value is not None:
        factor = {"SECOND": 1, "MILLISECOND": .001, "MICROSECOND": .000001, "NANOSECOND": 1e-9,
                  "MINUTE": 60, "HOUR": 3600}.get(time_value["unit"])
        if factor is not None and time_value["value"] > 0: seconds = time_value["value"] * factor
    details = raw.getDetails()
    event = details.getUpdateEvent() if details is not None else None
    description = {"id": image_id, "name": _text(image.getName(), 500), "pixelsId": int(pixels.getId()), "groupId": group_id,
                   "dimensions": sizes, "axes": "TCZYX", "shape": [sizes[key] for key in "tczyx"], "dtype": dtype.name,
                   "voxelSizeUm": voxel, "physicalSize": physical, "timeIncrement": time_value, "timeStepSeconds": seconds,
                   "pixelsUpdateEventId": int(event.getId().getValue()) if event is not None else None,
                   "notes": notes}
    return image, pixels, description


def _groups(conn, args):
    from omero.sys import ParametersI
    from omero.rtypes import rlong
    params = ParametersI()
    params.add("userId", rlong(int(conn.getEventContext().userId)))
    offset, limit = args.get("offset", 0), args.get("limit", 50)
    params.page(offset, limit + 1)
    query = ("select obj from ExperimenterGroup obj where exists (select link.id from GroupExperimenterMap link "
             "where link.parent.id = obj.id and link.child.id = :userId) order by obj.id")
    values = conn.getQueryService().findAllByQuery(query, params, conn.SERVICE_OPTS)
    return {"groups": [{"id": int(item.getId().getValue()), "name": _text(item.getName().getValue(), 200)} for item in values[:limit]],
            "offset": offset, "nextOffset": offset + limit if len(values) > limit else None}


def _objects(conn, args):
    from omero.sys import ParametersI
    from omero.rtypes import rlong
    kind, parent = args["kind"], args.get("parentId")
    classes = {"project": "Project", "dataset": "Dataset", "image": "Image", "screen": "Screen", "plate": "Plate", "well": "Well"}
    parent_kind = args.get("parentKind")
    expected_parent = {"dataset": "project", "image": "dataset", "plate": "screen", "well": "plate"}
    if parent is None and parent_kind is not None:
        fail("omero-parent", "A parent kind requires an explicit parent ID.")
    if parent is not None:
        parent_kind = parent_kind or expected_parent.get(kind)
        if parent_kind != expected_parent.get(kind) and not (kind == "image" and parent_kind == "well"):
            fail("omero-parent", "Choose a supported hierarchy: Project → Dataset → Image or Screen → Plate → Well → Image.")
    params = ParametersI()
    params.add("groupId", rlong(args["groupId"]))
    clauses = ["obj.details.group.id = :groupId"]
    if parent is not None:
        params.add("parentId", rlong(parent))
        link = {"dataset": ("ProjectDatasetLink", "parent", "child"), "plate": ("ScreenPlateLink", "parent", "child")}.get(kind)
        if kind == "image" and parent_kind == "dataset": link = ("DatasetImageLink", "parent", "child")
        if link:
            clauses.append(f"exists (select link.id from {link[0]} link where link.{link[1]}.id = :parentId and link.{link[2]}.id = obj.id)")
        elif kind == "well": clauses.append("obj.plate.id = :parentId")
        elif kind == "image" and parent_kind == "well": clauses.append("exists (select ws.id from WellSample ws where ws.well.id = :parentId and ws.image.id = obj.id)")
    offset, limit = args.get("offset", 0), args.get("limit", 50)
    params.page(offset, limit + 1)
    query = f"select obj from {classes[kind]} obj where {' and '.join(clauses)} order by obj.id"
    values = conn.getQueryService().findAllByQuery(query, params, conn.SERVICE_OPTS)
    results = []
    for item in values[:limit]:
        record = {"id": int(item.getId().getValue()), "kind": kind, "groupId": args["groupId"]}
        if kind == "well":
            record.update(row=int(item.getRow().getValue()), column=int(item.getColumn().getValue()))
            record["name"] = f"Well row {record['row'] + 1}, column {record['column'] + 1}"
        else: record["name"] = _text(item.getName().getValue(), 500)
        results.append(record)
    return {"objects": results, "kind": kind, "parentId": parent, "parentKind": parent_kind,
            "offset": offset, "nextOffset": offset + limit if len(values) > limit else None,
            "notes": ["Pages are ordered by stable server IDs. Server additions or removals can change subsequent pages."]}


def _raw(conn, profile, args, root):
    np, _, _, _ = runtime()
    _, pixels, metadata = _image(conn, args["imageId"], args["groupId"])
    selected = {key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex", "x", "y")} | {key: args[key] for key in ("width", "height")}
    dims = metadata["dimensions"]
    x, y, width, height = (selected[key] for key in ("x", "y", "width", "height"))
    dtype = np.dtype(metadata["dtype"]).newbyteorder("<")
    if width * height > LIMITS["regionPixels"] or width * height * dtype.itemsize > LIMITS["rawBytes"]:
        fail("omero-region-limit", "Choose a region no larger than 16 million pixels and 128 MiB of raw values.")
    if x + width > dims["x"] or y + height > dims["y"] or any(selected[field] >= dims[axis] for field, axis in (("timeIndex", "t"), ("channel", "c"), ("zIndex", "z"))):
        fail("omero-selection", "The requested T/C/Z index or XY region is outside the selected raw image.")
    output = np.empty((height, width), dtype=dtype)
    tiles = [(selected["zIndex"], selected["channel"], selected["timeIndex"],
              (x + tx, y + ty, min(LIMITS["tileSize"], width - tx), min(LIMITS["tileSize"], height - ty)))
             for ty in range(0, height, LIMITS["tileSize"]) for tx in range(0, width, LIMITS["tileSize"])]
    received = 0
    for index, plane in enumerate(pixels.getTiles(tiles)):
        if index >= len(tiles): fail("omero-tile-response", "The server returned more tiles than requested.")
        tile = tiles[index][3]
        if plane.shape != (tile[3], tile[2]) or np.dtype(plane.dtype).newbyteorder("<") != dtype:
            fail("omero-tile-response", "The server returned raw tiles with an unexpected shape or dtype.")
        if not np.isfinite(plane).all(): fail("omero-nonfinite", "The selected region contains non-finite raw samples.")
        output[tile[1] - y:tile[1] - y + tile[3], tile[0] - x:tile[0] - x + tile[2]] = plane
        received += 1
    if received != len(tiles): fail("omero-tile-response", "The server did not return every requested raw tile.")
    _, _, after = _image(conn, args["imageId"], args["groupId"])
    if after != metadata:
        fail("omero-source-changed", "The image metadata changed during the raw read. Preview again after the source is stable.")
    pixel_hash = hashlib.sha256(memoryview(output).cast("B")).hexdigest()
    destination = root / "pixels.npy"
    with destination.open("xb") as stream: np.save(stream, output, allow_pickle=False)
    from datetime import datetime, timezone
    return {"connection": public_connection(conn, profile), "image": metadata, "selection": selected,
            "pixelSha256": pixel_hash, "pixelHashEncoding": "C-order YX little-endian raw dtype",
            "observedAt": datetime.now(timezone.utc).isoformat(),
            "raw": {"path": "pixels.npy", "sha256": file_hash(destination), "bytes": destination.stat().st_size}}


def execute(request, root):
    configure(request["registryPath"])
    registry = _registry()
    if _configuration_hash(registry) != request["configurationHash"]:
        fail("omero-configuration-conflict", "OMERO configuration changed before execution. Read its current state before retrying.")
    operation, args = request["operation"], request["arguments"]
    if operation == "probe":
        np, Ice, _, _ = runtime()
        return {"ready": True, "omeroVersion": OMERO_VERSION, "numpyVersion": np.__version__, "iceVersion": Ice.stringVersion(),
                "pythonVersion": sys.version.split()[0], "configurationHash": request["configurationHash"], "networkUsed": False}
    if operation not in ("connection", "groups", "objects", "image", "raw-region"):
        fail("omero-operation", "This fixed worker supports only its declared read operations.")
    profile = profile_for_worker(registry, args["profileId"])
    with connection(profile, args.get("groupId")) as conn:
        if operation == "connection": return {"connection": public_connection(conn, profile)}
        if operation == "groups": return {**_groups(conn, args), "connection": public_connection(conn, profile)}
        if operation == "objects": return {**_objects(conn, args), "connection": public_connection(conn, profile)}
        if operation == "image":
            _, _, image = _image(conn, args["imageId"], args["groupId"])
            return {"image": image, "connection": public_connection(conn, profile)}
        return _raw(conn, profile, args, root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", required=True); parser.add_argument("--response", required=True)
    args = parser.parse_args()
    destination = Path(args.response)
    # Disable dependency logging before importing OMERO. Exceptions are never
    # rendered: endpoint, credential and session details remain inside worker.
    logging.disable(logging.CRITICAL)
    try:
        request = _json_file(Path(args.request), 65536)
        if request.get("schemaVersion") != 1: fail("omero-protocol", "Unsupported OMERO worker protocol.")
        result = execute(request, destination.parent)
        response = {"ok": True, "result": result}
    except Exception as exc:
        from _workbench_schema import WorkbenchError
        if isinstance(exc, WorkbenchError):
            error = {"code": exc.code, "message": exc.message}
        else:
            error = {"code": "omero-request-failed", "message": "The OMERO read failed. Check the named profile's credentials, TLS CA and host name, group access and server availability. Server diagnostics are withheld to protect credentials and sessions."}
        response = {"ok": False, "error": error}
    payload = encoded(response)
    if len(payload) > LIMITS["responseBytes"]:
        payload = encoded({"ok": False, "error": {"code": "omero-response-limit", "message": "The server metadata exceeded the bounded response size."}})
    with destination.open("xb") as stream:
        stream.write(payload); stream.flush(); os.fsync(stream.fileno())
    return 0 if response["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
