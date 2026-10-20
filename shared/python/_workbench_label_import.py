"""Exact, non-executable external label import with frozen preview identity."""
from __future__ import annotations

import copy
import hashlib
import io
import math
import os
import stat
import uuid

MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_DECODE_BYTES = 128 * 1024 * 1024
MAX_IMPORTS = 1000


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    common = {
        "imageId": _ID, "path": _STRING,
        "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
        "sourceParameters": _object({
            "channel": {"type": "integer", "minimum": 0, "maximum": 31},
            "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]},
        }),
        "timeIndex": {"type": "integer", "minimum": 0, "default": 0},
        "channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0},
    }
    return [
        _op("mask.import.preview", "Preview exact integer TIFF or NPY labels on a selected source grid without saving.",
            _object({**common, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}},
                    ["imageId", "path"])),
        _op("mask.import.run", "Import exact external labels, preserve their original file, and recompute canonical measurements.",
            _object({**common, "previewFingerprint": {
                "type": "string", "minLength": 64, "maxLength": 64,
            }}, ["imageId", "path"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _read_file(value):
    from _workbench_schema import absolute_path
    path = absolute_path(value, "path")
    if path.suffix.lower() not in (".npy", ".tif", ".tiff"):
        fail("unsupported-label-file", "External labels must be an integer .npy, .tif or .tiff file.")
    try:
        with path.open("rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_FILE_BYTES:
                fail("invalid-label-file", "Label input must be a nonempty regular file of at most 256 MiB.")
            contents = stream.read(MAX_FILE_BYTES + 1)
            after = os.fstat(stream.fileno())
        if (len(contents) != before.st_size or
                (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            fail("label-file-changed", "The external label file changed while it was read. Preview the completed file again.")
    except OSError as exc:
        fail("label-file-unavailable", f"Cannot read the external label file: {exc}")
    return path, contents, hashlib.sha256(contents).hexdigest()


def _check_header(shape, dtype, expected):
    if dtype.kind not in "ui" or dtype.itemsize > 8 or dtype.hasobject or dtype.fields:
        fail("invalid-label-dtype", "Labels require signed or unsigned integer samples of at most 64 bits; floats, booleans and objects are not labels.")
    if tuple(shape) != tuple(expected):
        fail("label-shape-mismatch", f"Label shape {list(shape)} must exactly match the selected source shape {list(expected)}. Labels are never resized.")
    if any(type(size) is not int or size <= 0 for size in shape) or math.prod(shape) * dtype.itemsize > MAX_DECODE_BYTES:
        fail("labels-too-large", "The decoded label raster exceeds the 128 MiB allocation budget.")


def _decode_npy(contents, expected):
    from _workbench_imaging import require
    np, = require("numpy")
    stream = io.BytesIO(contents)
    version = np.lib.format.read_magic(stream)
    if version == (1, 0):
        shape, _, dtype = np.lib.format.read_array_header_1_0(stream, max_header_size=65536)
    elif version == (2, 0):
        shape, _, dtype = np.lib.format.read_array_header_2_0(stream, max_header_size=65536)
    else:
        fail("unsupported-label-file", "NPY label files must use the plain integer NPY 1.0 or 2.0 format.")
    _check_header(shape, dtype, expected)
    if stream.tell() + math.prod(shape) * dtype.itemsize != len(contents):
        fail("invalid-label-file", "NPY data length does not exactly match its declared integer raster.")
    # Header validation precedes allocation; object arrays never reach np.load.
    labels = np.load(io.BytesIO(contents), allow_pickle=False, max_header_size=65536)
    return labels, {"format": "npy", "axes": "YX" if len(expected) == 2 else "ZYX",
                    "dtype": str(dtype), "shape": list(shape)}


def _decode_tiff(contents, expected):
    from _workbench_imaging import require
    tifffile, = require("tifffile")
    with tifffile.TiffFile(io.BytesIO(contents)) as tif:
        if len(tif.series) != 1:
            fail("ambiguous-label-file", "Select a TIFF containing one label series, without alternate images or pyramids.")
        series = tif.series[0]
        if len(series.levels) != 1:
            fail("ambiguous-label-file", "Pyramidal label TIFFs are not accepted; export the exact full-resolution raster.")
        original_shape = tuple(map(int, series.shape))
        shape = list(original_shape)
        axes = series.axes.upper()
        if len(axes) != len(shape):
            fail("ambiguous-label-file", "TIFF axes do not describe one exact label raster.")
        # A selected OME label export may retain singleton T/C dimensions.
        # Removing those axes does not choose among time points or channels.
        remove = [index for index, axis in enumerate(axes) if axis in "TC"]
        if any(shape[index] != 1 for index in remove):
            fail("ambiguous-label-file", "A label TIFF must contain exactly one time point and one channel.")
        selected_axes = "".join(axis for index, axis in enumerate(axes) if index not in remove)
        selected_shape = tuple(size for index, size in enumerate(shape) if index not in remove)
        if len(expected) == 3 and selected_axes in ("QYX", "IYX"):
            selected_axes = "ZYX"  # An explicitly requested volume interprets TIFF pages as Z.
        singleton_z = len(expected) == 3 and expected[0] == 1 and selected_axes == "YX"
        if singleton_z:
            selected_axes = "ZYX"
            selected_shape = (1, *selected_shape)
        wanted_axes = "YX" if len(expected) == 2 else "ZYX"
        if selected_axes != wanted_axes:
            fail("ambiguous-label-file", f"Selected labels require {wanted_axes}; TIFF axes {axes!r} are not an unambiguous matching raster.")
        _check_header(selected_shape, series.dtype, expected)
        if len(tif.pages) > (expected[0] if len(expected) == 3 else 1):
            fail("ambiguous-label-file", "The TIFF contains additional image pages outside the selected label raster.")
        for page in series.pages:
            if int(getattr(page, "samplesperpixel", 1)) != 1 or int(getattr(page, "photometric", 1)) == 2:
                fail("invalid-label-dtype", "Colour TIFF pixels cannot be interpreted as instance label IDs.")
        labels = series.asarray()
        if tuple(labels.shape) != original_shape or labels.dtype != series.dtype:
            fail("invalid-label-file", "Decoded TIFF labels differ from the validated header.")
        if remove:
            labels = labels.squeeze(axis=tuple(remove))
        if singleton_z:
            labels = labels[None, ...]
        return labels, {"format": "tiff", "axes": wanted_axes, "fileAxes": axes,
                        "dtype": str(series.dtype), "shape": list(selected_shape),
                        "fileShape": list(original_shape)}


def _load_labels(path, contents, expected):
    from _workbench_imaging import require, MAX_CELLS
    from _workbench_schema import WorkbenchError
    np, = require("numpy")
    try:
        labels, metadata = (_decode_npy(contents, expected) if path.suffix.lower() == ".npy"
                            else _decode_tiff(contents, expected))
    except WorkbenchError:
        raise
    except (ValueError, TypeError, OSError, EOFError, OverflowError, KeyError, IndexError) as exc:
        fail("invalid-label-file", f"The external label raster could not be decoded: {exc}")
    low, high = int(labels.min()), int(labels.max())
    if low < 0 or high > 0xffffffff:
        fail("invalid-label-range", "Label IDs must be between zero and 4,294,967,295; zero is background.")
    labels = np.ascontiguousarray(labels, dtype=np.uint32)
    ids = np.unique(labels)
    count = int(np.count_nonzero(ids))
    if count > MAX_CELLS:
        fail("too-many-objects", "A label import can contain at most 20,000 distinct nonzero IDs.")
    return labels, metadata, {"labelCount": count, "foregroundSampleCount": int(np.count_nonzero(labels)),
                              "maxLabelId": high}


def _selection(image, args):
    from _workbench_schema import analysis_parameters
    import _workbench_volume as volume
    target = args.get("target", "plane")
    if target == "volume":
        if "sourceParameters" in args:
            fail("invalid-arguments", "Volume imports use timeIndex and channel, without a Z projection.")
        selected = {"target": target, "timeIndex": args.get("timeIndex", 0), "channel": args.get("channel", 0)}
        volume.selection(image, selected["timeIndex"], selected["channel"])
        frame = volume.get_frame(image, selected["timeIndex"], selected["channel"], required=False)
        return selected, volume.parameters(), (image.get("zCount", 1), image["height"], image["width"]), frame
    if "timeIndex" in args or "channel" in args:
        fail("invalid-arguments", "Plane imports use sourceParameters.channel and sourceParameters.zProjection.")
    supplied = {"channel": 0, "zProjection": "max", **image.get("preferredSourceParameters", {})}
    previous = image.get("analysis")
    if previous:
        supplied.update({key: previous["parameters"][key] for key in ("channel", "zProjection")})
    supplied.update(args.get("sourceParameters", {}))
    selected = {"target": target, "sourceParameters": supplied}
    return selected, analysis_parameters({"parameters": supplied}), (image["height"], image["width"]), previous


def describe(record):
    return {key: copy.deepcopy(value) for key, value in record.items()
            if key not in ("originalPath", "labelsPath", "sourcePath", "supportPath", "provenancePath")}


def artifact_references(document):
    references = {}
    for record in document.get("labelImports", []):
        for path_key, hash_key in (("originalPath", "sourceHash"), ("labelsPath", "labelsHash"),
                                   ("sourcePath", "imageSourceHash"), ("supportPath", "supportHash"),
                                   ("provenancePath", "provenanceHash")):
            if record.get(path_key):
                references[record[path_key]] = record[hash_key]
    return references


def execute(store, document, operation, args, revision, actor):
    from _workbench_core import _image, _source, _set_analysis
    from _workbench_store import canonical, utc_now
    from _workbench_assays import processing_provenance
    from _workbench_imaging import preview_data
    import _workbench_volume as volume
    import _workbench_support as support
    if operation == "mask.import.run" and len(document.get("labelImports", [])) >= MAX_IMPORTS:
        fail("label-import-limit", "A project can retain at most 1,000 external label import records.")
    image = _image(document, args["imageId"])
    selected, parameters, expected, previous = _selection(image, args)
    path, contents, checksum = _read_file(args["path"])
    labels, metadata, summary = _load_labels(path, contents, expected)
    raw = (_source(store, image, parameters) if selected["target"] == "plane" else
           volume.load_source(store, image, selected["timeIndex"], selected["channel"]))
    if raw.shape != labels.shape:
        fail("source-changed", "The selected source geometry changed after import.")
    valid = support.load(store, image, labels.shape, parameters)
    if valid is not None and ((labels > 0) & ~valid).any():
        fail("labels-outside-support", "Imported labels include unsupported fill samples. Set these pixels or voxels to zero before importing.")
    summary["validSupport"] = support.summary(image, valid, labels.shape)
    source = {"name": path.name, "sha256": checksum, "bytes": len(contents), **metadata}
    identity = {
        "schemaVersion": 1, "imageId": image["id"], "imageSourceHash": image["sourceHash"],
        "imageShape": image["shape"], "imageAxes": image["axes"], "selection": selected,
        "externalSourceHash": checksum, "labelShape": list(labels.shape),
        "voxelSizeUm": volume.calibration(image), "pxPerUm": image["pxPerUm"],
        "validSupport": support.fingerprint(image), "processing": processing_provenance(document, image),
        "sourceRegion": image.get("sourceRegion"),
        "replacedAnalysis": ({key: previous.get(key) for key in ("labelsHash", "analysisRevision", "inputFingerprint")}
                             if previous else None),
    }
    fingerprint = hashlib.sha256(canonical(identity).encode("utf-8")).hexdigest()
    result = {"imageId": image["id"], "target": selected["target"], "selection": selected,
              "source": source, "summary": summary, "previewFingerprint": fingerprint,
              "notes": ["Original nonzero label IDs are preserved; disconnected pieces with the same ID remain one object.",
                        "The target image supplies calibration and source intensities; external TIFF calibration is not applied.",
                        "Preview pixels may be downsampled. Saved labels and measurements use the complete selected grid."]}
    if operation == "mask.import.preview":
        if selected["target"] == "plane":
            result.update(preview_data(raw, labels, max_size=args.get("maxSize", 768)))
        else:
            index = raw.shape[0] // 2
            preview = preview_data(raw[index], labels[index], max_size=args.get("maxSize", 768))
            result.update({key: value for key, value in preview.items() if key != "dataUrl"})
            result.update({"overlayDataUrl": preview["dataUrl"], "previewIndex": index, "previewPlane": "xy",
                           "display": volume.display(raw, labels, image, selected["timeIndex"], selected["channel"])})
        return result
    if "previewFingerprint" in args and args["previewFingerprint"] != fingerprint:
        fail("stale-label-preview", "The external labels, source selection, calibration, support or saved mask changed. Preview again before applying.")
    import_id = str(uuid.uuid4())
    original_path, original_hash = store.put_bytes(contents, ".import-labels." + ("npy" if metadata["format"] == "npy" else "tif"))
    origin = {"kind": "external-label-import", "importId": import_id, "source": source,
              "previewFingerprint": fingerprint, "selection": copy.deepcopy(selected)}
    stats = {"method": "external-label-import", "labelImport": origin,
             "notes": ["Exact supplied label IDs define objects; no thresholding or model prediction was applied."]}
    if selected["target"] == "plane":
        analysis = _set_analysis(store, image, labels, raw, parameters, revision, stats=stats)
        saved = image["analysis"]
        image["preferredSourceParameters"] = copy.deepcopy(selected["sourceParameters"])
    else:
        saved = volume.save_frame(store, image, raw, labels, parameters, selected["timeIndex"], selected["channel"], revision, stats=stats)
        analysis = volume.result(image, saved)
        image["preferredVolumeSelection"] = {key: selected[key] for key in ("timeIndex", "channel")}
    provenance = {**identity, "importId": import_id, "createdAt": utc_now(), "actor": copy.deepcopy(actor),
                  "importRevision": revision, "source": source, "labelsHash": saved["labelsHash"],
                  "summary": summary, "notes": result["notes"]}
    provenance_path, provenance_hash = store.put_bytes(canonical(provenance).encode("utf-8"), ".label-import.json")
    record = {"importId": import_id, "imageId": image["id"], "target": selected["target"],
              "selection": selected, "source": source, "sourceHash": original_hash, "originalPath": original_path,
              "sourcePath": image["sourcePath"], "imageSourceHash": image["sourceHash"],
              "labelsPath": saved["labelsPath"], "labelsHash": saved["labelsHash"],
              "provenancePath": provenance_path, "provenanceHash": provenance_hash,
              "createdAt": provenance["createdAt"], "actor": copy.deepcopy(actor), "importRevision": revision,
              "analysisRevision": saved["analysisRevision"], "previewFingerprint": fingerprint, "summary": summary}
    if support.descriptor(image):
        record.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    document.setdefault("labelImports", []).append(record)
    return {"imageId": image["id"], "target": selected["target"], "selection": selected,
            "import": describe(record), "analysis": analysis}
