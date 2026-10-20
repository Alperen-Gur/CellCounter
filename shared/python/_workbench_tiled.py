"""Durable threshold connected components over bounded local NGFF tiles.

Immutable radix-index nodes and checkpoint records keep growing tile metadata
outside the project document. Each unit reads only its own tile and already
available neighbours. Global union/filtering is an explicit bounded checkpoint.
"""
from __future__ import annotations

from _workbench_indexed import RecordList

import copy
import io
import json
import math
from pathlib import Path
import sqlite3
import tempfile
import uuid

import _workbench_zarr as ngff

ENGINE = "tiled-components-1"
LIMITS = {"analyses": 64, "tiles": 4096, "tileSize": 1024, "halo": 64,
          "regionPixels": 1000000000, "localComponents": 1000000,
          "workingBytes": 512 * 1024**2, "retainedBytes": 8 * 1024**3,
          "indexDepth": 3, "artifactNodes": 200000, "pageSize": 500}
NOTES = ["This method computes global threshold-connected components on one selected T/C/Z plane; it does not run tiled watershed or learned models.",
         "Tiles own nonoverlapping core pixels. Halo components and shared-edge equivalences are reconciled before the global minimum-area filter.",
         "Object IDs are deterministic in first-source-pixel order. Tile boundaries never define biological replicates.",
         "Raw tile snapshots, exact chunk read identities, labels and object tables are retained independently of the external dataset.",
         "External source freshness is unknown between explicit read/verification checkpoints; saved outputs retain their original source identities.",
         "Read, histogram, segmentation, global reconciliation, label publication and source verification are durable checkpoints."]
EXPORT_FORMATS = [
    {"id": "labels-ngff-zip", "name": "Exact labels (OME-Zarr ZIP)", "extension": "zip", "mediaType": "application/zip",
     "description": "Chunked uint32 labels as NGFF 0.4/Zarr 2 with selected-level axes, coordinate transforms and complete analysis provenance."},
    {"id": "objects-csv", "name": "Global object measurements (CSV)", "extension": "csv", "mediaType": "text/csv",
     "description": "Globally reconciled objects with calibrated area, source pixel-edge coordinates, source identities and analysis parameters."},
]


def fail(code, message, details=None):
    ngff.fail(code, message, details)


def parameters_schema():
    from _workbench_schema import _object
    return _object({"method": {"type": "string", "enum": ["manual", "otsu"], "default": "otsu"},
                    "threshold": {"type": "number"},
                    "polarity": {"type": "string", "enum": ["bright", "dark"], "default": "bright"},
                    "connectivity": {"type": "integer", "enum": [4, 8], "default": 8},
                    "minAreaPx": {"type": "integer", "minimum": 1, "maximum": LIMITS["regionPixels"], "default": 9}})


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    region = _object({**{key: {"type": "integer", "minimum": 0} for key in ("x", "y")},
                      **{key: {"type": "integer", "minimum": 1} for key in ("width", "height")}}, ["x", "y", "width", "height"])
    args = {**ngff.selection_schema(), "region": region,
            "tileSize": {"type": "integer", "minimum": 64, "maximum": LIMITS["tileSize"], "default": 512},
            "halo": {"type": "integer", "minimum": 1, "maximum": LIMITS["halo"], "default": 1},
            "parameters": parameters_schema()}
    result = [
        _op("tiled.analysis.catalogue", "Describe bounded global threshold/connected-component tile analysis.", _object(), project=False),
        _op("tiled.analysis.preview", "Plan source-resolution tiles, halos, memory and durable checkpoints without segmenting.", _object(args, ["sourceId", "arrayPath"])),
        _op("tiled.analysis.create", "Freeze a durable chunked-source analysis plan with independent immutable tile outputs.",
            _object({**args, "name": {"type": "string", "minLength": 1, "maxLength": 200}}, ["sourceId", "arrayPath"]), True),
        _op("tiled.analysis.list", "List compact durable tiled-analysis progress.", _object()),
        _op("tiled.analysis.export.catalogue", "Describe exact chunked-label and global object-table exports.", _object(), project=False),
        _op("tiled.analysis.export", "Verify source identities and retain/publish completed tiled results without overwriting files.",
            _object({"analysisId": _ID, "format": {"type": "string", "enum": [item["id"] for item in EXPORT_FORMATS]},
                     "destination": _STRING}, ["analysisId", "format", "destination"]), True),
    ]
    for name, description in (("get", "Inspect retained tiled-analysis progress and last source verification."),
                              ("advance", "Execute one bounded tile or global reconciliation checkpoint."),
                              ("pause", "Pause before the next checkpoint while retaining completed work."),
                              ("resume", "Resume a paused or failed analysis without changing its frozen source or parameters."),
                              ("cancel", "Cancel remaining units and retain completed evidence and outputs.")):
        result.append(_op("tiled.analysis." + name, description, _object({"analysisId": _ID}, ["analysisId"]), name != "get"))
    paging = {"analysisId": _ID, "offset": {"type": "integer", "minimum": 0, "default": 0},
              "limit": {"type": "integer", "minimum": 1, "maximum": LIMITS["pageSize"], "default": 100}}
    result.extend([
        _op("tiled.analysis.objects", "Read a bounded page of globally reconciled object measurements.", _object(paging, ["analysisId"])),
        _op("tiled.analysis.tiles", "Read a bounded page of retained tile checkpoint descriptors.", _object(paging, ["analysisId"])),
        _op("tiled.analysis.labels.region", "Read exact retained uint32 labels for a bounded region plus a display preview.",
            _object({"analysisId": _ID, **region["properties"],
                     "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}},
                    ["analysisId", "x", "y", "width", "height"])),
    ])
    return result


def catalogue():
    return {"engineVersion": ENGINE, "parametersSchema": parameters_schema(), "limits": LIMITS,
            "targets": ["plane"], "methods": ["manual", "otsu"], "notes": NOTES}


def _json(store, reference, maximum=32 * 1024**2):
    if not reference:
        return None
    path = store.verify_artifact(reference["path"], reference["sha256"])
    if path.stat().st_size > maximum:
        fail("tiled-artifact-budget", "A retained tile index or checkpoint exceeds its metadata bound.")
    return json.loads(path.read_text())


def _put_json(store, value, suffix):
    from _workbench_store import canonical
    content = canonical(value).encode()
    path, checksum = store.put_bytes(content, suffix)
    return {"path": path, "sha256": checksum, "bytes": len(content)}


def _array(store, reference):
    np, _ = ngff._runtime()
    path = store.verify_artifact(reference["path"], reference["sha256"])
    if path.stat().st_size > LIMITS["workingBytes"] // 2:
        fail("tiled-artifact-budget", "A retained numeric tile exceeds its working-set bound.")
    value = np.load(path, allow_pickle=False, mmap_mode="r")
    if not isinstance(value, np.ndarray) or value.dtype.hasobject or value.nbytes > LIMITS["workingBytes"] // 2:
        fail("tiled-artifact-budget", "The retained numeric array exceeds its decoded working-set bound.")
    return value


def _put_array(store, value, suffix=".tiled.npy"):
    np, _ = ngff._runtime()
    encoded = io.BytesIO()
    np.save(encoded, value, allow_pickle=False)
    path, checksum = store.put_bytes(encoded.getvalue(), suffix)
    return {"path": path, "sha256": checksum, "bytes": len(encoded.getbuffer())}


def _tile_get(store, root, index):
    reference = root
    for digit in f"{index:03x}":
        node = _json(store, reference, 65536)
        if node is None:
            return None
        reference = node.get("children", {}).get(digit)
    return _json(store, reference)


def _tile_set(store, root, index, tile):
    digits = f"{index:03x}"
    def update(reference, depth):
        if depth == LIMITS["indexDepth"]:
            return _put_json(store, tile, ".tiled-tile.json")
        node = _json(store, reference, 65536) or {"children": {}}
        children = dict(node["children"])
        children[digits[depth]] = update(children.get(digits[depth]), depth+1)
        return _put_json(store, {"children": children}, ".tiled-index.json")
    return update(root, 0)


def _tiles(store, root):
    def visit(reference, depth):
        node = _json(store, reference)
        if node is None:
            return
        if depth == LIMITS["indexDepth"]:
            yield node
        else:
            for key in sorted(node["children"]):
                yield from visit(node["children"][key], depth+1)
    yield from visit(root, 0)


def _checkpoint(store, analysis, event):
    from _workbench_store import utc_now
    analysis["checkpointHead"] = _put_json(store, {"previous": analysis.get("checkpointHead"),
                                                       "event": event, "at": utc_now()}, ".tiled-log.json")
    analysis["progress"]["completed"] += 1
    analysis["updatedAt"] = utc_now()


def _record_tile(store, analysis, tile, phase):
    analysis["tileRoot"] = _tile_set(store, analysis.get("tileRoot"), tile["index"], tile)
    _checkpoint(store, analysis, {"phase": phase, "tile": tile})


def _analysis(document, analysis_id):
    result = next((value for value in document.get("tiledAnalyses", []) if value["id"] == analysis_id), None)
    if result is None:
        fail("tiled-analysis-not-found", "The tiled analysis is not part of this project.")
    return result


def _parameters(value):
    from _workbench_schema import validate_value
    schema = parameters_schema()
    validate_value(value or {}, schema, "parameters")
    result = {key: definition["default"] for key, definition in schema["properties"].items() if "default" in definition}
    result.update(value or {})
    if result["method"] == "manual" and "threshold" not in result:
        fail("tiled-threshold-required", "Manual thresholding requires a finite threshold in source intensity units.")
    if result["method"] != "manual" and "threshold" in result:
        fail("tiled-unused-threshold", "Remove the manual threshold when using global Otsu.")
    return result


def plan(document, args):
    source = ngff.source(document, args["sourceId"])
    array = ngff.array_descriptor(source, args["arrayPath"])
    axes = [axis["name"] for axis in array["axes"]]
    shape = dict(zip(axes, array["shape"]))
    if shape["x"] * shape["y"] >= 2**63:
        fail("tiled-coordinate-budget", "The source plane exceeds the exact 64-bit pixel-order coordinate bound.")
    for axis, key in (("t", "timeIndex"), ("c", "channel"), ("z", "zIndex")):
        if not 0 <= args.get(key, 0) < shape.get(axis, 1):
            fail("tiled-selection-outside-source", "The selected frame, channel or Z plane is unavailable at this resolution level.")
    region = copy.deepcopy(args.get("region") or {"x": 0, "y": 0, "width": shape["x"], "height": shape["y"]})
    if region["x"] + region["width"] > shape["x"] or region["y"] + region["height"] > shape["y"] or region["width"] * region["height"] > LIMITS["regionPixels"]:
        fail("tiled-region-budget", "Choose an in-bounds region containing at most one billion source pixels.")
    tile_size, halo = args.get("tileSize", 512), args.get("halo", 1)
    nx, ny = math.ceil(region["width"] / tile_size), math.ceil(region["height"] / tile_size)
    count = nx * ny
    if count > LIMITS["tiles"]:
        fail("tiled-tile-budget", "This region requires more than 4,096 tiles. Increase tile size within its bound or use a smaller region.")
    np, _ = ngff._runtime()
    itemsize = np.dtype(array["dtype"]).itemsize
    chunk_bytes = math.prod(array["chunks"]) * itemsize
    working = chunk_bytes * 2 + (tile_size + 2 * halo)**2 * (itemsize + 32) + tile_size**2 * 96
    if working > LIMITS["workingBytes"]:
        fail("tiled-working-budget", "Chunk decoding, halo, labels and component statistics exceed the 512 MiB working-set budget. Choose smaller tiles or rechunk the source.")
    parameters = _parameters(args.get("parameters"))
    return {"sourceId": source["id"], "sourceName": source["name"], "metadataHash": source["metadataHash"],
            "array": copy.deepcopy(array), "selection": {"arrayPath": array["path"], **{key: args.get(key, 0) for key in ("timeIndex", "channel", "zIndex")}},
            "region": region, "tileSize": tile_size, "halo": halo, "grid": {"columns": nx, "rows": ny},
            "tileCount": count, "checkpointCount": count * (5 if parameters["method"] == "otsu" else 4) + 1,
            "estimatedMaximumWorkingBytes": working, "parameters": parameters, "limits": LIMITS, "notes": NOTES}


def describe(value):
    keys = ("id", "name", "sourceId", "sourceName", "metadataHash", "selection", "region", "tileSize", "halo", "grid", "tileCount",
            "status", "phase", "progress", "parameters", "threshold", "histogramPolicy", "objectCount", "localComponentCount",
            "createdAt", "createdRevision", "updatedAt", "sourceVerifiedAt", "error", "retainedBytes", "estimatedMaximumWorkingBytes")
    result = {key: copy.deepcopy(value[key]) for key in keys if key in value}
    result["engineVersion"] = ENGINE
    result["sourceInputsCurrent"] = False if value.get("error", {}).get("code") == "zarr-source-changed" else None
    result["sourceCurrentness"] = "changed" if result["sourceInputsCurrent"] is False else "not-rechecked"
    result["outputsRetained"] = value["status"] == "completed"
    result["nextUnit"] = {"type": "tiled-" + value["phase"], "tileIndex": value["cursor"] if value["phase"] != "reconcile" else None} if value["status"] in ("pending", "running") else None
    result["notes"] = NOTES
    return result


def _tile_geometry(analysis, index):
    region, size, halo = analysis["region"], analysis["tileSize"], analysis["halo"]
    row, column = divmod(index, analysis["grid"]["columns"])
    x, y = region["x"] + column * size, region["y"] + row * size
    width, height = min(size, region["x"] + region["width"] - x), min(size, region["y"] + region["height"] - y)
    ex, ey = max(region["x"], x - halo), max(region["y"], y - halo)
    right, bottom = min(region["x"] + region["width"], x + width + halo), min(region["y"] + region["height"], y + height + halo)
    return {"index": index, "x": x, "y": y, "width": width, "height": height,
            "expanded": {"x": ex, "y": ey, "width": right-ex, "height": bottom-ey}}


def _core(raw, tile):
    x, y = tile["x"] - tile["expanded"]["x"], tile["y"] - tile["expanded"]["y"]
    return raw[y:y+tile["height"], x:x+tile["width"]]


def _budget(analysis, *references):
    analysis["retainedBytes"] += sum(reference.get("bytes", 0) for reference in references if reference)
    if analysis["retainedBytes"] > LIMITS["retainedBytes"]:
        fail("tiled-storage-budget", "This analysis exceeds its 8 GiB retained-artifact budget. Completed artifacts remain preserved; use a smaller region for a new analysis.")


def _read_unit(store, document, analysis):
    np, _ = ngff._runtime()
    source = ngff.source(document, analysis["sourceId"])
    if source["metadataHash"] != analysis["metadataHash"]:
        fail("zarr-source-changed", "The source metadata no longer matches this frozen analysis.")
    tile = _tile_geometry(analysis, analysis["cursor"])
    expanded = tile["expanded"]
    raw, identity = ngff.read_grid(source, analysis["selection"], np.arange(expanded["x"], expanded["x"]+expanded["width"]), np.arange(expanded["y"], expanded["y"]+expanded["height"]))
    tile["raw"] = _put_array(store, raw, ".tiled-source.npy")
    tile["readIdentity"] = ngff.retain_identity(store, source, identity)
    core = _core(raw, tile)
    tile["minimum"], tile["maximum"] = float(core.min()), float(core.max())
    analysis["minimum"] = min(analysis.get("minimum", tile["minimum"]), tile["minimum"])
    analysis["maximum"] = max(analysis.get("maximum", tile["maximum"]), tile["maximum"])
    _budget(analysis, tile["raw"])
    _record_tile(store, analysis, tile, "read")
    analysis["cursor"] += 1
    if analysis["cursor"] == analysis["tileCount"]:
        analysis["cursor"] = 0
        if analysis["parameters"]["method"] == "manual":
            analysis["threshold"] = analysis["parameters"]["threshold"]
            analysis["phase"] = "segment"
        else:
            analysis["phase"] = "histogram"
            low, high = analysis["minimum"], analysis["maximum"]
            integer = np.dtype(analysis["array"]["dtype"]).kind in "uib" and high - low <= 65535
            analysis["histogramPolicy"] = "exact-integer" if integer else "1024-equal-width-bins"
            count = int(high-low+1) if integer else 1024
            analysis["histogram"] = [0] * max(1, count)


def _histogram_unit(store, analysis):
    np, _ = ngff._runtime()
    tile = _tile_get(store, analysis["tileRoot"], analysis["cursor"])
    raw = _core(_array(store, tile["raw"]), tile)
    low, high = analysis["minimum"], analysis["maximum"]
    if analysis["histogramPolicy"] == "exact-integer":
        counts = np.bincount((raw.astype(np.int64)-int(low)).ravel(), minlength=len(analysis["histogram"]))
    elif high <= low:
        counts = np.zeros(1024, dtype=np.int64)
        counts[0] = raw.size
    else:
        counts, _ = np.histogram(raw, bins=1024, range=(low, high))
    analysis["histogram"] = (np.asarray(analysis["histogram"], dtype=np.int64) + counts).tolist()
    _checkpoint(store, analysis, {"phase": "histogram", "tileIndex": tile["index"], "sampleCount": int(raw.size)})
    analysis["cursor"] += 1
    if analysis["cursor"] == analysis["tileCount"]:
        from skimage.filters import threshold_otsu
        if high <= low:
            threshold = low
        else:
            centers = np.arange(int(low), int(high)+1, dtype=np.float64) if analysis["histogramPolicy"] == "exact-integer" else low + (np.arange(1024)+.5)*(high-low)/1024
            threshold = float(threshold_otsu(hist=(np.asarray(analysis["histogram"], dtype=np.int64), centers)))
        analysis["threshold"] = threshold
        analysis["phase"], analysis["cursor"] = "segment", 0


def _component_statistics(labels, raw, tile, full_width):
    np, _ = ngff._runtime()
    count = int(labels.max())
    ids = labels.ravel()
    rows, columns = np.indices(labels.shape, dtype=np.int64)
    xs, ys = (columns + tile["x"]).ravel(), (rows + tile["y"]).ravel()
    stats = np.zeros(count+1, dtype=[("area", "<u8"), ("sumX", "<f8"), ("sumY", "<f8"), ("sumIntensity", "<f8"),
                                   ("firstPixel", "<u8"), ("minX", "<i8"), ("minY", "<i8"), ("maxX", "<i8"), ("maxY", "<i8")])
    stats["area"] = np.bincount(ids, minlength=count+1)
    stats["sumX"] = np.bincount(ids, weights=xs+.5, minlength=count+1)
    stats["sumY"] = np.bincount(ids, weights=ys+.5, minlength=count+1)
    stats["sumIntensity"] = np.bincount(ids, weights=raw.astype(np.float64).ravel(), minlength=count+1)
    stats["firstPixel"].fill(np.iinfo(np.uint64).max)
    stats["minX"].fill(np.iinfo(np.int64).max); stats["minY"].fill(np.iinfo(np.int64).max)
    np.minimum.at(stats["firstPixel"], ids, ys.astype(np.uint64)*full_width + xs.astype(np.uint64))
    np.minimum.at(stats["minX"], ids, xs); np.minimum.at(stats["minY"], ids, ys)
    np.maximum.at(stats["maxX"], ids, xs); np.maximum.at(stats["maxY"], ids, ys)
    if not np.isfinite(stats["sumIntensity"]).all():
        fail("tiled-intensity-overflow", "Intensity sums exceed finite float64 precision; rescale an explicit derived source before analysis.")
    return stats


def _seams(store, analysis, tile, labels):
    np, _ = ngff._runtime()
    edges, index, columns = [], tile["index"], analysis["grid"]["columns"]
    def add(a, b, offset_a, offset_b):
        nonzero = (a > 0) & (b > 0)
        if nonzero.any():
            edges.append(np.column_stack((a[nonzero].astype(np.uint32)+offset_a, b[nonzero].astype(np.uint32)+offset_b)))
    if index % columns:
        left = _tile_get(store, analysis["tileRoot"], index-1)
        neighbour = _array(store, left["localLabels"])
        a, b = labels[:, 0], neighbour[:, -1]
        add(a, b, tile["componentOffset"], left["componentOffset"])
        if analysis["parameters"]["connectivity"] == 8:
            add(a[1:], b[:-1], tile["componentOffset"], left["componentOffset"])
            add(a[:-1], b[1:], tile["componentOffset"], left["componentOffset"])
    if index >= columns:
        above = _tile_get(store, analysis["tileRoot"], index-columns)
        neighbour = _array(store, above["localLabels"])
        a, b = labels[0, :], neighbour[-1, :]
        add(a, b, tile["componentOffset"], above["componentOffset"])
        if analysis["parameters"]["connectivity"] == 8:
            add(a[1:], b[:-1], tile["componentOffset"], above["componentOffset"])
            add(a[:-1], b[1:], tile["componentOffset"], above["componentOffset"])
            # The diagonal crossing four tiles is not represented by either
            # same-width edge. Include each top corner's adjacent tile.
            if index % columns:
                diagonal = _tile_get(store, analysis["tileRoot"], index-columns-1)
                values = _array(store, diagonal["localLabels"])
                add(labels[0:1, 0].ravel(), values[-1:, -1].ravel(), tile["componentOffset"], diagonal["componentOffset"])
            if index % columns + 1 < columns:
                diagonal = _tile_get(store, analysis["tileRoot"], index-columns+1)
                values = _array(store, diagonal["localLabels"])
                add(labels[0:1, -1].ravel(), values[-1:, 0].ravel(), tile["componentOffset"], diagonal["componentOffset"])
    return np.unique(np.concatenate(edges), axis=0) if edges else np.empty((0, 2), dtype=np.uint32)


def _segment_unit(store, analysis):
    np, _ = ngff._runtime()
    from scipy import ndimage
    tile = _tile_get(store, analysis["tileRoot"], analysis["cursor"])
    raw = _array(store, tile["raw"])
    foreground = raw > analysis["threshold"] if analysis["parameters"]["polarity"] == "bright" else raw < analysis["threshold"]
    labels, _ = ndimage.label(foreground, structure=ndimage.generate_binary_structure(2, 1 if analysis["parameters"]["connectivity"] == 4 else 2))
    owned = _core(labels, tile)
    identities, inverse = np.unique(owned, return_inverse=True)
    if identities[0] != 0:
        inverse += 1
        count = len(identities)
    else:
        count = len(identities)-1
    labels = inverse.reshape(owned.shape).astype(np.uint32)
    offset = analysis["localComponentCount"]
    if offset + count > LIMITS["localComponents"]:
        fail("tiled-component-budget", "Local components exceed the one-million reconciliation bound. Choose a smaller region or a more selective threshold.")
    tile["componentOffset"], tile["componentCount"] = offset, count
    tile["localLabels"] = _put_array(store, labels, ".tiled-local.npy")
    axes = [axis["name"] for axis in analysis["array"]["axes"]]
    full_width = analysis["array"]["shape"][axes.index("x")]
    tile["statistics"] = _put_array(store, _component_statistics(labels, _core(raw, tile), tile, full_width), ".tiled-stats.npy")
    tile["equivalences"] = _put_array(store, _seams(store, analysis, tile, labels), ".tiled-edges.npy")
    analysis["localComponentCount"] += count
    _budget(analysis, tile["localLabels"], tile["statistics"], tile["equivalences"])
    _record_tile(store, analysis, tile, "segment")
    analysis["cursor"] += 1
    if analysis["cursor"] == analysis["tileCount"]:
        analysis["phase"], analysis["cursor"] = "reconcile", 0


def _retain_file(store, path, suffix):
    from _workbench_store import file_hash
    checksum = file_hash(path)
    reference = f"artifacts/{checksum}{suffix}"
    store.retain_verified_file(path, reference, checksum)
    return {"path": reference, "sha256": checksum, "bytes": path.stat().st_size}


def _reconcile(store, analysis):
    np, _ = ngff._runtime()
    count = analysis["localComponentCount"]
    parent = np.arange(count+1, dtype=np.uint32)
    rank = np.zeros(count+1, dtype=np.uint8)
    def root(item):
        while parent[item] != item:
            parent[item] = parent[parent[item]]
            item = int(parent[item])
        return item
    for tile in _tiles(store, analysis["tileRoot"]):
        for a, b in _array(store, tile["equivalences"]):
            a, b = root(int(a)), root(int(b))
            if a == b:
                continue
            if rank[a] < rank[b]:
                a, b = b, a
            parent[b] = a
            if rank[a] == rank[b]:
                rank[a] += 1
    for index in range(1, count+1):
        parent[index] = root(index)
    totals = np.zeros(count+1, dtype=[("area", "<u8"), ("sumX", "<f8"), ("sumY", "<f8"), ("sumIntensity", "<f8"),
                                    ("firstPixel", "<u8"), ("minX", "<i8"), ("minY", "<i8"), ("maxX", "<i8"), ("maxY", "<i8")])
    totals["firstPixel"].fill(np.iinfo(np.uint64).max)
    totals["minX"].fill(np.iinfo(np.int64).max); totals["minY"].fill(np.iinfo(np.int64).max)
    for tile in _tiles(store, analysis["tileRoot"]):
        local = _array(store, tile["statistics"])[1:]
        roots = parent[tile["componentOffset"]+1:tile["componentOffset"]+tile["componentCount"]+1]
        for field in ("area", "sumX", "sumY", "sumIntensity"):
            np.add.at(totals[field], roots, local[field])
        for field in ("firstPixel", "minX", "minY"):
            np.minimum.at(totals[field], roots, local[field])
        for field in ("maxX", "maxY"):
            np.maximum.at(totals[field], roots, local[field])
    selected = np.flatnonzero(totals["area"] >= analysis["parameters"]["minAreaPx"])
    selected = selected[selected != 0]
    selected = selected[np.argsort(totals["firstPixel"][selected], kind="stable")]
    final_ids = np.zeros(count+1, dtype=np.uint32)
    final_ids[selected] = np.arange(1, len(selected)+1, dtype=np.uint32)
    mapping = final_ids[parent]
    mapping[0] = 0
    analysis["mapping"] = _put_array(store, mapping, ".tiled-map.npy")
    voxels = analysis["array"]["voxelSizeUm"]
    area_scale = voxels["x"] * voxels["y"] if voxels.get("x") is not None and voxels.get("y") is not None else None
    with tempfile.TemporaryDirectory(prefix="cellcounter-tiled-", dir=store.root) as temporary:
        database = Path(temporary) / "objects.sqlite"
        connection = sqlite3.connect(database)
        try:
            connection.execute("CREATE TABLE objects (id INTEGER PRIMARY KEY, areaPx INTEGER NOT NULL, centroidX REAL, centroidY REAL, meanIntensity REAL, areaUm2 REAL, minX INTEGER, minY INTEGER, maxX INTEGER, maxY INTEGER)")
            def rows():
                for object_id, component in enumerate(selected, 1):
                    item = totals[component]
                    area = int(item["area"])
                    intensity = float(item["sumIntensity"] / area)
                    if not math.isfinite(intensity):
                        fail("tiled-intensity-overflow", "Global intensity means exceed finite precision.")
                    yield (object_id, area, float(item["sumX"] / area), float(item["sumY"] / area), intensity,
                           area * area_scale if area_scale is not None else None,
                           int(item["minX"]), int(item["minY"]), int(item["maxX"])+1, int(item["maxY"])+1)
            connection.executemany("INSERT INTO objects VALUES (?,?,?,?,?,?,?,?,?,?)", rows())
            connection.commit()
        finally:
            connection.close()
        analysis["objects"] = _retain_file(store, database, ".tiled-objects.sqlite")
    analysis["objectCount"] = len(selected)
    _budget(analysis, analysis["mapping"], analysis["objects"])
    _checkpoint(store, analysis, {"phase": "reconcile", "mapping": analysis["mapping"], "objects": analysis["objects"], "objectCount": len(selected)})
    analysis["phase"], analysis["cursor"] = "publish", 0


def _publish_unit(store, analysis):
    np, _ = ngff._runtime()
    tile = _tile_get(store, analysis["tileRoot"], analysis["cursor"])
    local = _array(store, tile["localLabels"])
    mapping = _array(store, analysis["mapping"])
    provisional = local.astype(np.uint32) + tile["componentOffset"]
    provisional[local == 0] = 0
    labels = mapping[provisional]
    tile["labels"] = _put_array(store, labels, ".tiled-labels.npy")
    _budget(analysis, tile["labels"])
    _record_tile(store, analysis, tile, "publish")
    analysis["cursor"] += 1
    if analysis["cursor"] == analysis["tileCount"]:
        analysis["phase"], analysis["cursor"] = "verify", 0


def _verify_unit(store, document, analysis):
    from _workbench_store import utc_now
    source = ngff.source(document, analysis["sourceId"])
    tile = _tile_get(store, analysis["tileRoot"], analysis["cursor"])
    identity = ngff.load_json(store, tile["readIdentity"])
    ngff.verify_reads(source["path"], identity["readSet"])
    ngff.verify_reads(source["path"], source["metadataReadSet"])
    _checkpoint(store, analysis, {"phase": "verify", "tileIndex": tile["index"], "readIdentity": tile["readIdentity"]})
    analysis["cursor"] += 1
    if analysis["cursor"] == analysis["tileCount"]:
        analysis["status"], analysis["phase"] = "completed", "completed"
        analysis["sourceVerifiedAt"] = utc_now()
        analysis["cursor"] = 0


def _objects(store, analysis, args):
    if not analysis.get("objects"):
        fail("tiled-results-pending", "Run the global reconciliation checkpoint before opening object measurements.")
    path = store.verify_artifact(analysis["objects"]["path"], analysis["objects"]["sha256"])
    connection = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        rows = [dict(row) for row in connection.execute("SELECT * FROM objects WHERE id > ? ORDER BY id LIMIT ?", (args.get("offset", 0), args.get("limit", 100)))]
    finally:
        connection.close()
    offset = args.get("offset", 0)
    return {"analysisId": analysis["id"], "objects": rows, "total": analysis["objectCount"], "offset": offset,
            "nextOffset": offset+len(rows) if offset+len(rows) < analysis["objectCount"] else None,
            "coordinateSpace": "selected-level source-pixel-edges", "voxelSizeUm": analysis["array"]["voxelSizeUm"],
            "sourceInputsCurrent": None, "sourceVerifiedAt": analysis.get("sourceVerifiedAt"), "notes": NOTES}


def labels_region(store, analysis, args):
    import base64
    np, _ = ngff._runtime()
    from _workbench_imaging import preview_data
    x, y, width, height = (args[key] for key in ("x", "y", "width", "height"))
    region = analysis["region"]
    if x < region["x"] or y < region["y"] or x+width > region["x"]+region["width"] or y+height > region["y"]+region["height"] or width*height > 1000000:
        fail("tiled-region-budget", "Read an in-bounds label region of at most one million pixels per request.")
    labels = np.zeros((height, width), dtype=np.uint32)
    size, columns = analysis["tileSize"], analysis["grid"]["columns"]
    for row in range((y-region["y"])//size, (y+height-1-region["y"])//size+1):
        for column in range((x-region["x"])//size, (x+width-1-region["x"])//size+1):
            tile = _tile_get(store, analysis["tileRoot"], row*columns+column)
            if not tile or not tile.get("labels"):
                fail("tiled-results-pending", "A requested tile has not reached exact-label publication yet.")
            selected = _array(store, tile["labels"])
            left, top = max(x, tile["x"]), max(y, tile["y"])
            right, bottom = min(x+width, tile["x"]+tile["width"]), min(y+height, tile["y"]+tile["height"])
            labels[top-y:bottom-y, left-x:right-x] = selected[top-tile["y"]:bottom-tile["y"], left-tile["x"]:right-tile["x"]]
    preview = preview_data((labels > 0).astype(np.float64), labels, max_size=args.get("maxSize", 768))
    return {**preview, "analysisId": analysis["id"], "x": x, "y": y,
            "labelsBase64": base64.b64encode(labels.astype("<u4", copy=False).tobytes()).decode(), "dtype": "uint32-le", "order": "yx",
            "sourceInputsCurrent": None, "sourceVerifiedAt": analysis.get("sourceVerifiedAt"), "notes": NOTES}


def execute(store, document, operation, args, revision):
    from _workbench_schema import WorkbenchError
    from _workbench_store import utc_now
    if operation == "tiled.analysis.catalogue":
        return catalogue()
    if operation == "tiled.analysis.export.catalogue":
        return {"formats": copy.deepcopy(EXPORT_FORMATS)}
    if operation == "tiled.analysis.preview":
        return {"plan": plan(document, args)}
    if operation == "tiled.analysis.create":
        records = document.setdefault("tiledAnalyses", [])
        if len(records) >= LIMITS["analyses"]:
            fail("tiled-analysis-limit", "A project supports at most 64 retained tiled analyses.")
        frozen = plan(document, args)
        source = ngff.source(document, frozen["sourceId"])
        ngff.verify_reads(source["path"], source["metadataReadSet"])
        value = {key: copy.deepcopy(item) for key, item in frozen.items() if key not in ("notes", "limits", "checkpointCount")}
        value.update({"id": str(uuid.uuid4()), "name": args.get("name", f"{source['name']} · tiled analysis"),
                      "status": "pending", "phase": "read", "cursor": 0, "createdAt": utc_now(), "createdRevision": revision,
                      "progress": {"completed": 0, "total": frozen["checkpointCount"]}, "engineVersion": ENGINE,
                      "tileRoot": None, "checkpointHead": None, "localComponentCount": 0, "retainedBytes": 0})
        records.append(value)
        return {"analysis": describe(value)}
    if operation == "tiled.analysis.list":
        return {"analyses": [describe(value) for value in document.get("tiledAnalyses", [])]}
    value = _analysis(document, args["analysisId"])
    if operation == "tiled.analysis.get":
        return {"analysis": describe(value)}
    if operation == "tiled.analysis.objects":
        return _objects(store, value, args)
    if operation == "tiled.analysis.labels.region":
        return labels_region(store, value, args)
    if operation == "tiled.analysis.tiles":
        offset, limit = args.get("offset", 0), args.get("limit", 100)
        rows = []
        for index in range(offset, min(value["tileCount"], offset+limit)):
            tile = _tile_get(store, value.get("tileRoot"), index)
            rows.append({**_tile_geometry(value, index), "status": "labels-retained" if tile and tile.get("labels") else "segmented" if tile and tile.get("localLabels") else "source-retained" if tile else "pending",
                         "componentCount": tile.get("componentCount") if tile else None})
        return {"analysisId": value["id"], "tiles": rows, "offset": offset, "total": value["tileCount"],
                "nextOffset": offset+len(rows) if offset+len(rows) < value["tileCount"] else None}
    if operation == "tiled.analysis.pause":
        if value["status"] not in ("pending", "running"):
            fail("tiled-state", "Only an active tiled analysis can be paused.")
        value["status"] = "paused"
    elif operation == "tiled.analysis.resume":
        if value["status"] not in ("paused", "failed"):
            fail("tiled-state", "Resume a paused or failed analysis; create a new analysis to change its source or parameters.")
        source = ngff.source(document, value["sourceId"])
        if source["metadataHash"] != value["metadataHash"]:
            fail("zarr-source-changed", "The frozen source metadata changed. Create a new analysis.")
        ngff.verify_reads(source["path"], source["metadataReadSet"])
        value["status"] = "pending"
        value.pop("error", None)
    elif operation == "tiled.analysis.cancel":
        if value["status"] in ("completed", "cancelled"):
            fail("tiled-state", "This analysis is already terminal.")
        value["status"] = "cancelled"
    elif operation == "tiled.analysis.advance":
        if value["status"] not in ("pending", "running"):
            fail("tiled-state", "Resume the analysis before advancing its next checkpoint.")
        # Compute into a private document branch. A failed unit cannot partially
        # advance metadata; immutable unreferenced artifacts are safe to retain.
        trial = copy.deepcopy(value)
        trial["status"] = "running"
        source = ngff.source(document, value["sourceId"])
        original_head, original_count = source.get("readIdentityHead"), source.get("readIdentityCount", 0)
        try:
            phase = trial["phase"]
            if phase == "read":
                _read_unit(store, document, trial)
            elif phase == "histogram":
                _histogram_unit(store, trial)
            elif phase == "segment":
                _segment_unit(store, trial)
            elif phase == "reconcile":
                _reconcile(store, trial)
            elif phase == "publish":
                _publish_unit(store, trial)
            elif phase == "verify":
                _verify_unit(store, document, trial)
            else:
                fail("project-corrupt", "The tiled checkpoint phase is invalid.")
        except (WorkbenchError, OSError, ValueError, RuntimeError) as error:
            source["readIdentityHead"], source["readIdentityCount"] = original_head, original_count
            value["status"] = "failed"
            value["error"] = {"code": error.code if isinstance(error, WorkbenchError) else "tiled-checkpoint-failed",
                              "message": str(error), "phase": value["phase"], "tileIndex": value["cursor"]}
        else:
            value.clear(); value.update(trial)
    else:
        fail("unknown-operation", "Unsupported tiled-analysis operation.")
    return {"analysis": describe(value)}


def artifact_references(document, read_json=None):
    references, queued = {}, []
    for output in document.get("tiledExports", []):
        queued.extend([output["file"], output["provenance"]])
    for value in document.get("tiledAnalyses", []):
        for key in ("tileRoot", "checkpointHead", "mapping", "objects"):
            if value.get(key):
                queued.append(value[key])
    if queued and read_json is None:
        fail("artifact-reader-required", "Tiled index and checkpoint chains require a verified artifact reader.")
    def nested(value):
        if isinstance(value, dict):
            if isinstance(value.get("path"), str) and value["path"].startswith("artifacts/") and isinstance(value.get("sha256"), str):
                queued.append(value)
            else:
                for item in value.values():
                    nested(item)
        elif isinstance(value, (list, RecordList)):
            for item in value:
                nested(item)
    while queued:
        reference = queued.pop()
        path, checksum = reference["path"], reference["sha256"]
        if path in references:
            if references[path] != checksum:
                fail("project-corrupt", "A tiled artifact has contradictory hashes.")
            continue
        if len(references) >= LIMITS["artifactNodes"]:
            fail("tiled-artifact-budget", "The retained tile graph exceeds its traversal bound.")
        references[path] = checksum
        if path.endswith((".tiled-index.json", ".tiled-tile.json", ".tiled-log.json", ".tiled-provenance.json", ".zarr-read.json")):
            node = read_json(path, checksum, max_bytes=32 * 1024**2)
            nested(node)
    return references


def validate_document(document):
    values = document.get("tiledAnalyses", [])
    if not isinstance(values, (list, RecordList)) or len(values) > LIMITS["analyses"]:
        fail("project-corrupt", "Invalid tiled-analysis catalogue.")
    ids = set()
    for value in values:
        if not isinstance(value, dict) or not isinstance(value.get("id"), str) or value["id"] in ids:
            fail("project-corrupt", "Tiled analysis IDs must be unique.")
        ids.add(value["id"])
        if value.get("status") not in ("pending", "running", "paused", "failed", "cancelled", "completed") or value.get("phase") not in ("read", "histogram", "segment", "reconcile", "publish", "verify", "completed"):
            fail("project-corrupt", "Invalid tiled-analysis status or phase.")
        if not 1 <= value.get("tileCount", 0) <= LIMITS["tiles"] or not 0 <= value.get("cursor", -1) <= value["tileCount"]:
            fail("project-corrupt", "Invalid tiled-analysis checkpoint index.")
        if not 0 <= value.get("localComponentCount", -1) <= LIMITS["localComponents"]:
            fail("project-corrupt", "Invalid tiled component count.")
        _parameters(value.get("parameters"))


def prepare_export(store, document, arguments, revision, request_id, actor):
    """Use the shared durable publication journal; no external writes pre-CAS."""
    import csv
    import zipfile
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORT_BYTES
    from _workbench_store import canonical, utc_now
    np, zarr = ngff._runtime()
    value = _analysis(document, arguments["analysisId"])
    if value["status"] != "completed":
        fail("tiled-results-pending", "Complete all tiled checkpoints before exporting scientific results.")
    if len(document.get("tiledExports", [])) >= 1000:
        fail("tiled-export-limit", "The project retains at most 1,000 tiled exports.")
    definition = next(item for item in EXPORT_FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    source = ngff.source(document, value["sourceId"])
    ngff.verify_reads(source["path"], source["metadataReadSet"])
    # This explicit export requires exact current source bytes. Ordinary get/list
    # remains cheap and never makes that promise from directory timestamps.
    for tile in _tiles(store, value["tileRoot"]):
        identity = ngff.load_json(store, tile["readIdentity"])
        ngff.verify_reads(source["path"], identity["readSet"])
    provenance = {"schemaVersion": 1, "engineVersion": ENGINE, "exportId": str(uuid.uuid4()),
                  "analysisId": value["id"], "name": value["name"], "projectId": document["id"],
                  "sourceRevision": revision, "requestId": request_id, "actor": copy.deepcopy(actor), "createdAt": utc_now(),
                  "sourceId": source["id"], "metadataHash": source["metadataHash"], "sourceVerifiedAt": utc_now(),
                  "metadataReference": {"path": source["metadataPath"], "sha256": source["metadataSha256"]},
                  "selection": value["selection"], "region": value["region"], "array": value["array"],
                  "parameters": value["parameters"], "threshold": value["threshold"], "histogramPolicy": value.get("histogramPolicy"),
                  "objectCount": value["objectCount"], "tileRoot": value["tileRoot"], "checkpointHead": value["checkpointHead"],
                  "notes": NOTES}
    provenance_reference = _put_json(store, provenance, ".tiled-provenance.json")
    with tempfile.TemporaryDirectory(prefix="cellcounter-tiled-export-", dir=store.root) as temporary:
        folder = Path(temporary)
        output = folder / ("results." + definition["extension"])
        if definition["id"] == "objects-csv":
            database = store.verify_artifact(value["objects"]["path"], value["objects"]["sha256"])
            connection = sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True)
            try:
                with output.open("w", encoding="utf-8", newline="") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(["analysisId", "sourceId", "metadataHash", "arrayPath", "timeIndex", "channel", "zIndex",
                                     "objectId", "areaPx", "centroidX", "centroidY", "meanIntensity", "areaUm2", "minX", "minY", "maxX", "maxY", "threshold", "polarity", "connectivity", "provenanceSha256"])
                    selected = value["selection"]
                    prefix = [value["id"], source["id"], source["metadataHash"], selected["arrayPath"], selected["timeIndex"], selected["channel"], selected["zIndex"]]
                    # Protect arbitrary array-path text in spreadsheet clients.
                    prefix = ["'"+item if isinstance(item, str) and item.lstrip().startswith(("=", "+", "-", "@")) else item for item in prefix]
                    for row_index, row in enumerate(connection.execute("SELECT * FROM objects ORDER BY id")):
                        writer.writerow([*prefix, *row, value["threshold"], value["parameters"]["polarity"], value["parameters"]["connectivity"], provenance_reference["sha256"]])
                        if row_index % 1024 == 0 and stream.tell() > MAX_EXPORT_BYTES:
                            fail("tiled-export-budget", "The CSV exceeds the 256 MiB publication limit. Read paged objects or export a smaller analysis.")
            finally:
                connection.close()
        else:
            import numcodecs
            from zarr.storage import LocalStore
            source_axes = value["array"]["axes"]
            axis_names = [axis["name"] for axis in source_axes]
            indices = [axis_names.index(axis) for axis in "yx"]
            axes = [copy.deepcopy(source_axes[index]) for index in indices]
            scale = [value["array"]["scale"][index] for index in indices]
            translation = [value["array"]["translation"][index] + value["region"][axis]*value["array"]["scale"][index] for index, axis in zip(indices, "yx")]
            zarr_root = folder / "labels.ome.zarr"
            storage = LocalStore(zarr_root)
            with zarr.config.set({"async.concurrency": 1, "threading.max_workers": 1}):
                group = zarr.open_group(store=storage, mode="w", zarr_format=2)
                array = zarr.create_array(storage, name="0", shape=(value["region"]["height"], value["region"]["width"]),
                                          chunks=(value["tileSize"], value["tileSize"]), dtype="<u4", zarr_format=2,
                                          compressors=[numcodecs.Zlib(level=1)], filters=None, fill_value=0,
                                          chunk_key_encoding={"name": "v2", "separator": "."})
                encoded_bytes = 0
                for tile in _tiles(store, value["tileRoot"]):
                    x, y = tile["x"]-value["region"]["x"], tile["y"]-value["region"]["y"]
                    array[y:y+tile["height"], x:x+tile["width"]] = _array(store, tile["labels"])
                    chunk = zarr_root / "0" / f"{y // value['tileSize']}.{x // value['tileSize']}"
                    encoded_bytes += chunk.stat().st_size if chunk.is_file() else 0
                    if encoded_bytes > MAX_EXPORT_BYTES:
                        fail("tiled-export-budget", "Encoded labels exceed the 256 MiB publication budget. Retained exact tile artifacts remain available.")
                group.attrs.update({"multiscales": [{"version": "0.4", "name": value["name"], "axes": axes,
                                      "datasets": [{"path": "0", "coordinateTransformations": [{"type": "scale", "scale": scale}, {"type": "translation", "translation": translation}]}]}],
                                    "image-label": {"version": "0.4"}, "cellcounter": {"analysisId": value["id"], "provenanceSha256": provenance_reference["sha256"]}})
            (zarr_root / "cellcounter-provenance.json").write_text(canonical(provenance)+"\n", encoding="utf-8")
            # Include exact source read identities so the exported evidence does
            # not depend on interpreting project-relative artifact names alone.
            evidence = zarr_root / "cellcounter-read-identities"
            evidence.mkdir()
            for tile in _tiles(store, value["tileRoot"]):
                content = (canonical(ngff.load_json(store, tile["readIdentity"]))+"\n").encode()
                encoded_bytes += len(content)
                if encoded_bytes > MAX_EXPORT_BYTES:
                    fail("tiled-export-budget", "Labels and source read provenance exceed the 256 MiB publication budget.")
                (evidence / f"{tile['index']:04d}.json").write_bytes(content)
            with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
                for path in sorted(zarr_root.rglob("*")):
                    if path.is_file():
                        archive.write(path, "labels.ome.zarr/" + path.relative_to(zarr_root).as_posix())
                        if output.stat().st_size > MAX_EXPORT_BYTES:
                            fail("tiled-export-budget", "The chunked label ZIP exceeds the 256 MiB publication limit. Exact label regions and project-retained tile artifacts remain available.")
        if output.stat().st_size > MAX_EXPORT_BYTES:
            fail("tiled-export-budget", "The scientific export exceeds the 256 MiB publication limit.")
        contents = output.read_bytes()
    file_path, checksum = store.put_bytes(contents, ".tiled-export." + definition["extension"])
    entry = {"exportId": provenance["exportId"], "analysisId": value["id"], "format": definition["id"],
             "file": {"path": file_path, "sha256": checksum, "bytes": len(contents)}, "provenance": provenance_reference,
             "destination": str(destination), "revision": revision, "createdAt": provenance["createdAt"]}
    document.setdefault("tiledExports", []).append(entry)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"exportId": entry["exportId"], "analysisId": value["id"], "destination": str(destination),
            "sha256": checksum, "bytes": len(contents), "format": definition["id"], "mediaType": definition["mediaType"],
            "provenance": provenance, "provenanceSha256": provenance_reference["sha256"]}, publish, temporary, publication
