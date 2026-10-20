"""Scoped OME-NGFF 0.4/0.5 local reads through the maintained Zarr library.

A source identity freezes metadata. Each scientific read separately freezes its
exact encoded byte ranges, including absent chunks (Zarr fill values). No claim
is made that cataloguing a directory has hashed every unseen chunk.
"""
from __future__ import annotations

from _workbench_indexed import RecordList

from _workbench_indexed import image_capacity

import copy
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import stat
import uuid

ENGINE = "zarr-local-1"
ZARR_VERSION = "3.1.3"
LIMITS = {"sources": 128, "arrays": 128, "metadataBytes": 8 * 1024**2,
          "chunkBytes": 32 * 1024**2, "readBytes": 256 * 1024**2,
          "readRanges": 65536, "regionPixels": 16000000, "readIdentities": 32768}
SPACE_UNITS = {"meter": 1e6, "metre": 1e6, "centimeter": 1e4, "millimeter": 1e3,
               "micrometer": 1., "micrometre": 1., "nanometer": .001,
               "picometer": .000001, "angstrom": .0001}
TIME_UNITS = {"second": 1., "millisecond": .001, "microsecond": .000001,
              "nanosecond": 1e-9, "minute": 60., "hour": 3600., "day": 86400.}
V2_CODECS = {"zlib", "gzip", "blosc", "zstd", "bz2", "lzma", "lz4", "shuffle",
             "delta", "astype", "fixedscaleoffset", "quantize", "bitround", "packbits",
             "crc32", "crc32c", "adler32", "fletcher32", "jenkins_lookup3"}
V3_CODECS = {"bytes", "transpose", "blosc", "gzip", "zstd", "crc32c", "sharding_indexed"}
NOTES = ["Select a local NGFF image group explicitly; plate/collection roots are not silently reduced to the first image.",
         "Catalogue metadata is frozen; scientific outputs retain exact chunk/range read identities, not an unsupported whole-dataset hash claim.",
         "Missing chunks use the declared Zarr fill value and are included in read provenance. Non-finite selected samples are rejected.",
         "Unknown physical units stay unknown. Display overviews never become scientific measurements.",
         "Remote stores, arbitrary codecs and non-standard axis mappings are not enabled by this local reader."]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _runtime():
    try:
        import numpy as np
        import zarr
    except ImportError:
        fail("zarr-runtime-missing", "Install or repair the Workbench runtime, including requirements-zarr.txt, before reading chunked sources.")
    if zarr.__version__ != ZARR_VERSION:
        fail("zarr-runtime-version", f"This reader requires Zarr {ZARR_VERSION}. Repair the dedicated Workbench runtime; model environments need not change.")
    return np, zarr


def selection_schema():
    from _workbench_schema import _ID
    return {"sourceId": _ID, "arrayPath": {"type": "string", "minLength": 1, "maxLength": 1024},
            **{key: {"type": "integer", "minimum": 0, "default": 0} for key in ("timeIndex", "channel", "zIndex")}}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    selected = selection_schema()
    return [
        _op("zarr.catalogue", "Describe bounded local NGFF 0.4/Zarr 2 and NGFF 0.5/Zarr 3 support.", _object(), project=False),
        _op("zarr.import", "Catalogue one local NGFF image group and retain its exact metadata.",
            _object({"path": _STRING, "name": {"type": "string", "minLength": 1, "maxLength": 200}}, ["path"]), True),
        _op("zarr.list", "List registered chunked image sources without decoding arrays.", _object()),
        _op("zarr.get", "Read source arrays, axes, multiscale transforms and calibration.", _object({"sourceId": _ID}, ["sourceId"])),
        _op("zarr.rebind", "Relocate a source only after its metadata and all retained scientific read identities match.",
            _object({"sourceId": _ID, "path": _STRING}, ["sourceId", "path"]), True),
        _op("zarr.overview", "Read a bounded selected-level display with exact source-pixel mapping.",
            _object({**selected, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}}, ["sourceId", "arrayPath"])),
        _op("zarr.extract", "Retain an exact selected-level source region as a canonical image with chunk provenance.",
            _object({**selected, **{key: {"type": "integer", "minimum": 0} for key in ("x", "y")},
                     **{key: {"type": "integer", "minimum": 1, "maximum": LIMITS["regionPixels"]} for key in ("width", "height")},
                     "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["sourceId", "arrayPath", "x", "y", "width", "height"]), True),
    ]


def catalogue():
    import importlib.metadata
    try:
        installed = importlib.metadata.version("zarr")
    except importlib.metadata.PackageNotFoundError:
        installed = None
    return {"engineVersion": ENGINE, "requiredZarrVersion": ZARR_VERSION, "installedZarrVersion": installed,
            "runtimeReady": installed == ZARR_VERSION, "generations": [{"ngffVersion": "0.4", "zarrFormat": 2}, {"ngffVersion": "0.5", "zarrFormat": 3}],
            "storage": ["local-directory"], "axes": ["yx", "zyx", "cyx", "czyx", "tyx", "tzyx", "tcyx", "tczyx"],
            "codecs": {"v2": sorted(V2_CODECS), "v3": sorted(V3_CODECS)}, "limits": LIMITS, "notes": NOTES}


def safe_root(value):
    from _workbench_schema import absolute_path
    path = absolute_path(value, "path")
    # absolute_path may normalize; the lexical path is checked as well.
    lexical = Path(value).expanduser()
    for item in (lexical, *lexical.parents):
        if item.is_symlink():
            fail("zarr-unsafe-path", "Choose a real local directory without symbolic-link ancestors.")
    if not path.is_dir():
        fail("zarr-source-missing", "The local Zarr directory is unavailable. Rebind its original content before continuing.")
    return path.resolve()


def safe_key(key):
    if not isinstance(key, str) or not key or "\\" in key or ":" in key or "\0" in key:
        fail("zarr-unsafe-path", "Zarr keys must be safe relative paths.")
    parts = key.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(key).is_absolute():
        fail("zarr-unsafe-path", "Zarr keys cannot leave their registered source directory.")
    return key


class ScopedReads:
    def __init__(self, root, maximum_bytes=LIMITS["readBytes"]):
        self.root = safe_root(str(root))
        self.maximum_bytes = maximum_bytes
        self.bytes = 0
        self.records = {}

    def read(self, key, start=0, end=None, suffix=None, maximum=None):
        safe_key(key)
        path = self.root
        for part in key.split("/"):
            path = path / part
            if path.is_symlink():
                fail("zarr-unsafe-path", "A Zarr metadata or chunk path is a symbolic link.", {"path": key})
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except FileNotFoundError:
            record = {"path": key, "missing": True, "sha256": None, "bytes": 0}
            self._remember((key, None, None), record)
            return None
        except OSError as error:
            fail("zarr-read-failed", f"Cannot read the selected Zarr key: {error}", {"path": key})
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or self.root not in path.resolve().parents:
                fail("zarr-unsafe-path", "Zarr reads require regular files inside the registered directory.")
            size = before.st_size
            begin = max(0, size - suffix) if suffix is not None else start
            stop = size if end is None else min(size, end)
            if begin < 0 or stop < begin:
                fail("zarr-invalid-range", "The codec requested an invalid encoded byte range.")
            length = stop - begin
            if length > (maximum or LIMITS["chunkBytes"]) or self.bytes + length > self.maximum_bytes:
                fail("zarr-read-budget", "This selection exceeds the bounded encoded-read budget. Select a smaller region or coarser level.")
            stream.seek(begin)
            content = stream.read(length)
            after = os.fstat(stream.fileno())
            if len(content) != length or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                fail("zarr-source-changed", "The source changed while a selected range was being read.")
        self.bytes += length
        record = {"path": key, "offset": begin, "bytes": length, "fileBytes": size, "sha256": hashlib.sha256(content).hexdigest()}
        self._remember((key, begin, length), record)
        return content

    def _remember(self, identity, record):
        previous = self.records.get(identity)
        if previous is not None and previous != record:
            fail("zarr-source-changed", "A selected source range changed during this operation.")
        self.records[identity] = record
        if len(self.records) > LIMITS["readRanges"]:
            fail("zarr-read-budget", "This selection exceeds the source-range count budget. Choose a coarser level or smaller region.")

    def identities(self):
        return sorted(self.records.values(), key=lambda value: (value["path"], value.get("offset", -1), value["bytes"]))

    def json(self, key, required=True):
        raw = self.read(key, maximum=LIMITS["metadataBytes"])
        if raw is None:
            if required:
                fail("zarr-metadata-missing", "Required NGFF metadata is missing.", {"path": key})
            return None
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError):
            fail("zarr-invalid-metadata", "NGFF metadata must be bounded UTF-8 JSON.", {"path": key})
        if not isinstance(value, dict):
            fail("zarr-invalid-metadata", "NGFF metadata must contain a JSON object.")
        return value


def verify_reads(root, records):
    reader = ScopedReads(root)
    # Individual identities may cover more than one normal read budget. Rebind
    # streams one bounded range at a time, without accumulating its raw bytes.
    for record in records:
        reader.bytes = 0
        content = reader.read(record["path"], record.get("offset", 0),
                              record.get("offset", 0) + record["bytes"] if not record.get("missing") else None,
                              maximum=max(LIMITS["chunkBytes"], LIMITS["metadataBytes"]))
        if record.get("missing"):
            if content is not None:
                fail("zarr-source-changed", "A formerly absent source chunk now exists.", {"path": record["path"]})
        elif content is None or reader.records.get((record["path"], record["offset"], record["bytes"])) != record:
            fail("zarr-source-changed", "A source byte range no longer matches its retained scientific identity.", {"path": record["path"]})
    return True


def _store(reader):
    _, zarr = _runtime()
    from zarr.storage import LocalStore
    from zarr.abc.store import RangeByteRequest, OffsetByteRequest, SuffixByteRequest
    from zarr.core.buffer.core import default_buffer_prototype

    class ScopedLocalStore(LocalStore):
        def __init__(self, root=reader.root, *, read_only=True):
            if not read_only:
                fail("zarr-read-only", "Registered source directories are read-only.")
            super().__init__(root, read_only=True)

        async def get(self, key, prototype=None, byte_range=None):
            kwargs = {}
            if isinstance(byte_range, RangeByteRequest):
                kwargs = {"start": byte_range.start, "end": byte_range.end}
            elif isinstance(byte_range, OffsetByteRequest):
                kwargs = {"start": byte_range.offset}
            elif isinstance(byte_range, SuffixByteRequest):
                kwargs = {"suffix": byte_range.suffix}
            elif byte_range is not None:
                fail("zarr-invalid-range", "The codec requested an unsupported byte range.")
            data = reader.read(key, **kwargs)
            return None if data is None else (prototype or default_buffer_prototype()).buffer.from_bytes(data)

        async def get_partial_values(self, prototype, key_ranges):
            return [await self.get(key, prototype, byte_range) for key, byte_range in key_ranges]

        async def exists(self, key):
            return await self.get(key, byte_range=RangeByteRequest(0, 0)) is not None

    return ScopedLocalStore()


def _transforms(items, count):
    scale, translation = [1.] * count, [0.] * count
    if not isinstance(items, (list, RecordList)) or len(items) > 4:
        fail("zarr-invalid-transform", "NGFF coordinate transforms must be bounded scale/translation lists.")
    scales = 0
    for item in items:
        kind = item.get("type") if isinstance(item, dict) else None
        values = item.get(kind) if kind in ("scale", "translation") else None
        if not isinstance(values, (list, RecordList)) or len(values) != count or any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in values):
            fail("zarr-unsupported-transform", "Only explicit finite scale and translation vectors are supported; referenced transform arrays require a separate adapter.")
        if kind == "scale":
            scales += 1
            if any(value <= 0 for value in values):
                fail("zarr-invalid-transform", "Spatial and temporal scales must be positive.")
            scale = [a * b for a, b in zip(scale, values)]
            translation = [a * b for a, b in zip(translation, values)]
        else:
            translation = [a + b for a, b in zip(translation, values)]
    if scales != 1:
        fail("zarr-invalid-transform", "Each NGFF transform list must contain exactly one scale vector.")
    return scale, translation


def _codec_names(metadata, generation):
    if generation == 2:
        items = [metadata.get("compressor"), *(metadata.get("filters") or [])]
        names = [item.get("id") for item in items if item is not None]
        if any(name not in V2_CODECS for name in names):
            fail("zarr-unsupported-codec", "This array uses a codec outside the bounded numeric reader catalogue.", {"codecs": names})
        return names
    result = []
    def visit(items, depth=0):
        if not isinstance(items, (list, RecordList)) or len(items) > 16 or depth > 2:
            fail("zarr-unsupported-codec", "The array codec pipeline exceeds its supported bounds.")
        for item in items:
            name = item.get("name") if isinstance(item, dict) else None
            if name not in V3_CODECS:
                fail("zarr-unsupported-codec", "This Zarr 3 codec is not enabled in the local numeric reader.", {"codec": name})
            result.append(name)
            if name == "sharding_indexed":
                config = item.get("configuration", {})
                visit(config.get("codecs", []), depth + 1)
                visit(config.get("index_codecs", []), depth + 1)
    visit(metadata.get("codecs", []))
    return result


def inspect_dataset(path):
    np, zarr = _runtime()
    reader = ScopedReads(path, LIMITS["metadataBytes"])
    v3 = reader.json("zarr.json", required=False)
    if v3 is not None:
        if v3.get("zarr_format") != 3 or v3.get("node_type") != "group":
            fail("zarr-invalid-group", "Select the NGFF image group, not an individual array.")
        ome = v3.get("attributes", {}).get("ome", {})
        if ome.get("version") != "0.5":
            fail("zarr-unsupported-version", "Zarr 3 images require OME-NGFF version 0.5 metadata.")
        generation, version = 3, "0.5"
    else:
        group = reader.json(".zgroup")
        if group.get("zarr_format") != 2:
            fail("zarr-unsupported-version", "This reader supports Zarr format 2 and 3.")
        ome = reader.json(".zattrs")
        generation, version = 2, "0.4"
    multiscales = ome.get("multiscales")
    if not isinstance(multiscales, (list, RecordList)) or not 1 <= len(multiscales) <= 16:
        fail("zarr-image-group-required", "Choose an image group containing multiscales metadata. Plate or collection roots must be opened at an explicit image subgroup.")
    arrays, raw_metadata, names = [], {}, set()
    for group_index, multiscale in enumerate(multiscales):
        if generation == 2 and multiscale.get("version") != "0.4":
            fail("zarr-unsupported-version", "Zarr 2 images require NGFF 0.4 metadata.")
        axes = multiscale.get("axes")
        if not isinstance(axes, (list, RecordList)) or not 2 <= len(axes) <= 5 or any(not isinstance(axis, dict) for axis in axes):
            fail("zarr-invalid-axes", "Declare between two and five explicit NGFF axes.")
        axis_names = [axis.get("name") for axis in axes]
        if any(not isinstance(name, str) for name in axis_names) or "".join(axis_names) not in catalogue()["axes"] or len(set(axis_names)) != len(axis_names):
            fail("zarr-unsupported-axes", "Use ordered named t/c/z/y/x axes; custom axis mappings are not inferred.")
        for axis in axes:
            expected = "time" if axis["name"] == "t" else "channel" if axis["name"] == "c" else "space"
            if axis.get("type") != expected:
                fail("zarr-invalid-axes", "NGFF axis names and semantic types disagree.")
        global_scale, global_translation = _transforms(multiscale["coordinateTransformations"], len(axes)) if multiscale.get("coordinateTransformations") else ([1.] * len(axes), [0.] * len(axes))
        datasets = multiscale.get("datasets")
        if not isinstance(datasets, (list, RecordList)) or not datasets:
            fail("zarr-invalid-multiscales", "Each multiscale image must declare its resolution arrays.")
        for level, dataset in enumerate(datasets):
            key = safe_key(dataset.get("path"))
            if key in names or len(arrays) >= LIMITS["arrays"]:
                fail("zarr-array-limit", "Use at most 128 distinct resolution arrays per registered image group.")
            names.add(key)
            meta = reader.json(f"{key}/{'zarr.json' if generation == 3 else '.zarray'}")
            shape = meta.get("shape")
            chunks = meta.get("chunks") if generation == 2 else meta.get("chunk_grid", {}).get("configuration", {}).get("chunk_shape")
            if not isinstance(shape, (list, RecordList)) or len(shape) != len(axes) or any(type(value) is not int or value < 1 or value > 2**40 for value in shape):
                fail("zarr-invalid-shape", "Array shape must match the declared axes with positive bounded extents.")
            if not isinstance(chunks, (list, RecordList)) or len(chunks) != len(shape) or any(type(value) is not int or value < 1 for value in chunks):
                fail("zarr-invalid-chunks", "Only regular positive chunk grids are supported.")
            try:
                dtype = np.dtype(meta.get("dtype") if generation == 2 else meta.get("data_type"))
            except (TypeError, ValueError):
                fail("zarr-unsupported-dtype", "This reader supports fixed-size real numeric arrays.")
            if dtype.kind not in "uibf" or dtype.itemsize > 8 or dtype.hasobject:
                fail("zarr-unsupported-dtype", "Object, complex, structured and variable-length arrays are not enabled.")
            if math.prod(chunks) * dtype.itemsize > LIMITS["chunkBytes"]:
                fail("zarr-chunk-budget", "A decoded chunk or shard exceeds 32 MiB. Rechunk the source or select a different array.")
            codecs = _codec_names(meta, generation)
            scale, translation = _transforms(dataset.get("coordinateTransformations"), len(axes))
            translation = [a * b + c for a, b, c in zip(translation, global_scale, global_translation)]
            scale = [a * b for a, b in zip(scale, global_scale)]
            calibration = {axis: None for axis in "xyz"}
            time_step = None
            for index, axis in enumerate(axes):
                unit = axis.get("unit")
                if axis["name"] in calibration and unit in SPACE_UNITS:
                    calibration[axis["name"]] = scale[index] * SPACE_UNITS[unit]
                if axis["name"] == "t" and unit in TIME_UNITS:
                    time_step = scale[index] * TIME_UNITS[unit]
            arrays.append({"path": key, "multiscaleIndex": group_index, "level": level,
                           "name": multiscale.get("name"), "shape": shape, "axes": copy.deepcopy(axes),
                           "chunks": chunks, "dtype": str(dtype), "scale": scale, "translation": translation,
                           "voxelSizeUm": calibration, "timeStepSeconds": time_step, "codecs": codecs})
            raw_metadata[key] = meta
    identities = reader.identities()
    return {"ngffVersion": version, "zarrFormat": generation, "arrays": arrays,
            "metadataHash": digest(identities), "metadataReadSet": identities,
            "metadata": {"ome": ome, "arrays": raw_metadata}, "notes": NOTES}


def source(document, source_id):
    found = next((value for value in document.get("zarrSources", []) if value["id"] == source_id), None)
    if found is None:
        fail("zarr-source-not-found", "The selected chunked source is not registered in this project.")
    return found


def array_descriptor(source_record, array_path):
    found = next((value for value in source_record["arrays"] if value["path"] == array_path), None)
    if found is None:
        fail("zarr-array-not-found", "Choose an array from this source's explicit resolution list.")
    return found


def describe(value):
    result = {key: copy.deepcopy(item) for key, item in value.items() if key not in ("metadataReadSet", "readIdentities", "readIdentityHead", "metadataPath", "metadataSha256")}
    result["available"] = Path(value["path"]).is_dir()
    result["readIdentityCount"] = value.get("readIdentityCount", len(value.get("readIdentities", [])))
    result["sourceInputsCurrent"] = None
    result["availabilityScope"] = "directory-presence-only; exact ranges are checked when used or rebound"
    return result


def read_grid(source_record, args, xs, ys):
    np, zarr = _runtime()
    descriptor = array_descriptor(source_record, args["arrayPath"])
    root = safe_root(source_record["path"])
    verify_reads(root, source_record["metadataReadSet"])
    if len(xs) * len(ys) > LIMITS["regionPixels"]:
        fail("zarr-region-budget", "A single read is limited to 16 million selected pixels.")
    reader = ScopedReads(root)
    axes = [axis["name"] for axis in descriptor["axes"]]
    selection, indices = {}, []
    for axis, extent in zip(axes, descriptor["shape"]):
        if axis == "x":
            chosen = np.asarray(xs, dtype=np.int64)
        elif axis == "y":
            chosen = np.asarray(ys, dtype=np.int64)
        else:
            chosen = int(args.get({"t": "timeIndex", "c": "channel", "z": "zIndex"}[axis], 0))
        if np.any(np.asarray(chosen) < 0) or np.any(np.asarray(chosen) >= extent):
            fail("zarr-selection-outside-source", "The selected frame, channel, plane or XY region is outside this resolution level.")
        indices.append(chosen)
        if axis not in "xy":
            selection[axis] = chosen
    for axis, key in (("t", "timeIndex"), ("c", "channel"), ("z", "zIndex")):
        if axis not in axes and args.get(key, 0) != 0:
            fail("zarr-selection-outside-source", f"This array has no {axis.upper()} axis; its selection must be zero.")
    try:
        with zarr.config.set({"async.concurrency": 1, "threading.max_workers": 1}):
            array = zarr.open_array(store=_store(reader), path=descriptor["path"], mode="r", zarr_format=source_record["zarrFormat"])
            if tuple(array.shape) != tuple(descriptor["shape"]) or str(array.dtype) != descriptor["dtype"]:
                fail("zarr-source-changed", "The selected array no longer matches its registered geometry or dtype.")
            pixels = np.asarray(array.get_orthogonal_selection(tuple(indices)))
    except (ValueError, TypeError, KeyError) as error:
        fail("zarr-decode-failed", f"The pinned Zarr reader could not decode this selection: {error}")
    if pixels.shape != (len(ys), len(xs)) or not np.isfinite(pixels).all():
        fail("zarr-invalid-samples", "Selected source samples must form a finite YX plane.")
    identities = reader.identities()
    verify_reads(root, identities)
    return pixels, {"sourceId": source_record["id"], "metadataHash": source_record["metadataHash"],
                    "arrayPath": descriptor["path"], "timeIndex": args.get("timeIndex", 0),
                    "channel": args.get("channel", 0), "zIndex": args.get("zIndex", 0),
                    "readSet": identities, "readSetHash": digest(identities), "engineVersion": ENGINE,
                    "zarrVersion": ZARR_VERSION}


def retain_identity(store, source_record, identity):
    from _workbench_store import canonical
    if source_record.get("readIdentityCount", 0) >= LIMITS["readIdentities"]:
        fail("zarr-identity-budget", "The source has reached its retained read-identity limit. Create a new project before adding further reads.")
    node = {"identity": identity, "previous": source_record.get("readIdentityHead")}
    path, checksum = store.put_bytes(canonical(node).encode(), ".zarr-read.json")
    reference = {"path": path, "sha256": checksum}
    source_record["readIdentityHead"] = reference
    source_record["readIdentityCount"] = source_record.get("readIdentityCount", 0) + 1
    return reference


def load_json(store, reference):
    path = store.verify_artifact(reference["path"], reference["sha256"])
    if path.stat().st_size > LIMITS["metadataBytes"] * 4:
        fail("zarr-artifact-budget", "The retained chunk identity exceeds its metadata limit.")
    value = json.loads(path.read_text())
    return value.get("identity", value)


def artifact_references(document, read_json=None):
    result = {}
    independent = []
    for image in document.get("images", []):
        region = image.get("sourceRegion", {})
        if region.get("kind") == "zarr" and region.get("readIdentity"):
            independent.append(region["readIdentity"])
        if region.get("kind") == "zarr" and region.get("metadataReference"):
            reference = region["metadataReference"]
            result[reference["path"]] = reference["sha256"]
    for value in document.get("zarrSources", []):
        result[value["metadataPath"]] = value["metadataSha256"]
        for reference in value.get("readIdentities", []):
            result[reference["path"]] = reference["sha256"]
        reference = value.get("readIdentityHead")
        visited = set()
        if reference and read_json is None:
            fail("artifact-reader-required", "Zarr scientific provenance requires a verified artifact reader.")
        while reference:
            key = reference["path"]
            if key in visited or len(visited) >= LIMITS["readIdentities"]:
                fail("project-corrupt", "The source read-identity chain is cyclic or exceeds its bound.")
            visited.add(key)
            result[key] = reference["sha256"]
            node = read_json(key, reference["sha256"], max_bytes=LIMITS["metadataBytes"] * 4)
            if not isinstance(node, dict) or not isinstance(node.get("identity", {}).get("readSet"), (list, RecordList)):
                fail("project-corrupt", "Invalid retained source read-identity node.")
            reference = node.get("previous")
        if len(visited) != value.get("readIdentityCount", 0):
            fail("project-corrupt", "The source read-identity count does not match its retained chain.")
    visited = set()
    while independent:
        reference = independent.pop()
        key = reference["path"]
        if key in visited or key in result:
            continue
        if len(visited) >= LIMITS["readIdentities"] or read_json is None:
            fail("artifact-reader-required", "Retained ROI source identities require a bounded verified artifact reader.")
        visited.add(key)
        result[key] = reference["sha256"]
        node = read_json(key, reference["sha256"], max_bytes=LIMITS["metadataBytes"] * 4)
        if node.get("previous"):
            independent.append(node["previous"])
    return result


def validate_document(document):
    values = document.get("zarrSources", [])
    if not isinstance(values, (list, RecordList)) or len(values) > LIMITS["sources"]:
        fail("project-corrupt", "Invalid registered Zarr source catalogue.")
    identifiers = set()
    for value in values:
        if not isinstance(value, dict) or not isinstance(value.get("id"), str) or value["id"] in identifiers:
            fail("project-corrupt", "Zarr source identities must be unique.")
        identifiers.add(value["id"])
        if value.get("zarrFormat") not in (2, 3) or value.get("ngffVersion") not in ("0.4", "0.5") or not 1 <= len(value.get("arrays", [])) <= LIMITS["arrays"]:
            fail("project-corrupt", "Invalid NGFF source generation or arrays.")
        if not isinstance(value.get("path"), str) or not Path(value["path"]).is_absolute() or not 0 <= value.get("readIdentityCount", 0) <= LIMITS["readIdentities"]:
            fail("project-corrupt", "Invalid source location or retained read count.")
        for array in value["arrays"]:
            safe_key(array["path"])
        if digest(value.get("metadataReadSet", [])) != value.get("metadataHash"):
            fail("project-corrupt", "Registered NGFF metadata identity is inconsistent.")


def execute(store, document, operation, args, revision):
    from _workbench_store import canonical, utc_now
    if operation == "zarr.catalogue":
        return catalogue()
    if operation == "zarr.import":
        if len(document.setdefault("zarrSources", [])) >= LIMITS["sources"]:
            fail("zarr-source-limit", "The project supports at most 128 chunked sources.")
        root = safe_root(args["path"])
        inspected = inspect_dataset(root)
        path, checksum = store.put_bytes(canonical(inspected.pop("metadata")).encode(), ".ngff.json")
        value = {"id": str(uuid.uuid4()), "name": args.get("name", root.name), "path": str(root),
                 "createdAt": utc_now(), "createdRevision": revision, "engineVersion": ENGINE,
                 "metadataPath": path, "metadataSha256": checksum, "readIdentityHead": None, "readIdentityCount": 0, **inspected}
        document["zarrSources"].append(value)
        return {"source": describe(value)}
    if operation == "zarr.list":
        return {"sources": [describe(value) for value in document.get("zarrSources", [])]}
    value = source(document, args["sourceId"])
    if operation == "zarr.get":
        return {"source": describe(value)}
    if operation == "zarr.rebind":
        root = safe_root(args["path"])
        verify_reads(root, value["metadataReadSet"])
        for reference in value.get("readIdentities", []):
            identity = load_json(store, reference)
            verify_reads(root, identity["readSet"])
        reference, seen = value.get("readIdentityHead"), set()
        while reference:
            if reference["path"] in seen or len(seen) >= LIMITS["readIdentities"]:
                fail("project-corrupt", "The source read identity chain is invalid.")
            seen.add(reference["path"])
            node = json.loads(store.verify_artifact(reference["path"], reference["sha256"]).read_text())
            verify_reads(root, node["identity"]["readSet"])
            reference = node.get("previous")
        value.setdefault("locationHistory", []).append({"path": value["path"], "replacedAt": utc_now(), "revision": revision})
        value["path"] = str(root)
        value["lastVerifiedAt"] = utc_now()
        return {"source": describe(value), "verifiedReadIdentities": len(seen)}
    np, = __import__("_workbench_imaging").require("numpy")
    descriptor = array_descriptor(value, args["arrayPath"])
    axes = [axis["name"] for axis in descriptor["axes"]]
    full_width, full_height = (descriptor["shape"][axes.index(axis)] for axis in "xy")
    if operation == "zarr.overview":
        from _workbench_imaging import preview_data
        maximum = args.get("maxSize", 768)
        ratio = min(1., maximum / max(full_width, full_height))
        width, height = max(1, round(full_width * ratio)), max(1, round(full_height * ratio))
        sx, sy = full_width / width, full_height / height
        xs = np.minimum(full_width-1, np.floor((np.arange(width)+.5)*sx).astype(np.int64))
        ys = np.minimum(full_height-1, np.floor((np.arange(height)+.5)*sy).astype(np.int64))
        pixels, identity = read_grid(value, args, xs, ys)
        return {**preview_data(pixels.astype(np.float64), max_size=maximum), "sourceId": value["id"],
                "arrayPath": descriptor["path"], "selection": {key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex")},
                "width": full_width, "height": full_height, "previewWidth": width, "previewHeight": height,
                "displayTransform": {"scale": [sx, sy], "offset": [(sx-1)/2, (sy-1)/2]},
                "voxelSizeUm": descriptor["voxelSizeUm"], "readSetHash": identity["readSetHash"], "notes": NOTES}
    if operation != "zarr.extract":
        fail("unknown-operation", "Unsupported chunked-source operation.")
    x, y, width, height = (args[key] for key in ("x", "y", "width", "height"))
    if width * height > LIMITS["regionPixels"] or x + width > full_width or y + height > full_height:
        fail("zarr-region-budget", "Choose an in-bounds region containing at most 16 million source pixels.")
    if len(document["images"]) >= image_capacity(document):
        fail("project-too-large", "The project supports at most 1,000 canonical images.")
    pixels, identity = read_grid(value, args, np.arange(x, x+width), np.arange(y, y+height))
    read_reference = retain_identity(store, value, identity)
    import tifffile
    encoded = io.BytesIO()
    voxels = copy.deepcopy(descriptor["voxelSizeUm"])
    ome = {"axes": "YX"}
    for axis in "XY":
        if voxels.get(axis.lower()) is not None:
            ome[f"PhysicalSize{axis}"] = voxels[axis.lower()]
            ome[f"PhysicalSize{axis}Unit"] = "µm"
    tifffile.imwrite(encoded, pixels, photometric="minisblack", ome=True, metadata=ome)
    path, checksum = store.put_bytes(encoded.getvalue(), ".ome.tif")
    scale = 1/voxels["x"] if voxels.get("x") and voxels.get("y") and math.isclose(voxels["x"], voxels["y"], rel_tol=1e-9) else None
    region = {"kind": "zarr", "sourceId": value["id"], "metadataHash": value["metadataHash"], "readIdentity": read_reference,
              "metadataReference": {"path": value["metadataPath"], "sha256": value["metadataSha256"]},
              "readSetHash": identity["readSetHash"], "arrayPath": descriptor["path"],
              **{key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex")},
              "x": x, "y": y, "width": width, "height": height,
              "scale": descriptor["scale"], "translation": descriptor["translation"], "axes": descriptor["axes"],
              "originalDimensions": [full_width, full_height], "resampled": False, "coordinateSpace": "source-pixel-edges"}
    image = {"id": str(uuid.uuid4()), "name": args.get("name", f"{value['name']} · {descriptor['path']} ROI {x},{y}"),
             "sourcePath": path, "sourceHash": checksum, "sourceBytes": len(encoded.getbuffer()), "importedAt": utc_now(),
             "pxPerUm": scale, "voxelSizeUm": voxels, "timeStepSeconds": None, "calibrationSource": "ngff-metadata",
             "width": width, "height": height, "channels": 1, "axes": "YX", "shape": [height, width],
             "dtype": str(pixels.dtype), "zCount": 1, "timeCount": 1, "undoStack": [], "sourceRegion": region}
    document["images"].append(image)
    return {"imageId": image["id"], "image": {key: item for key, item in image.items() if key != "sourcePath"}, "sourceId": value["id"], "region": region}
