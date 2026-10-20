"""Large TIFF source catalog with bounded selective reads and exact ROI copies."""
from __future__ import annotations

from _workbench_indexed import image_capacity

import copy
import io
import math
from pathlib import Path
import uuid

MAX_SOURCES = 1000
MAX_PAGES = 4096
MAX_SOURCE_PIXELS = 1000000000
MAX_SEGMENTS = 200000
MAX_SEGMENT_BYTES = 32 * 1024 ** 2
MAX_ROI_PIXELS = 16000000


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    selection = {"sourceId": _ID, "pageIndex": {"type": "integer", "minimum": 0, "maximum": MAX_PAGES-1},
                 "channel": {"type": "integer", "minimum": 0, "maximum": 31}}
    return [
        _op("source.import", "Retain a large TIFF source without eagerly decoding its full plane.",
            _object({"paths": {"type": "array", "items": _STRING, "minItems": 1, "maxItems": 10},
                     "seriesIndex": {"type": "integer", "enum": [0]}}, ["paths"]), True),
        _op("source.list", "List retained large TIFF sources and their explicit read capabilities.", _object()),
        _op("source.inspect", "Read large-source dimensions, physical calibration and bounded-access information.",
            _object({"sourceId": _ID}, ["sourceId"])),
        _op("source.overview", "Read a bounded display-only TIFF overview with explicit source-pixel mapping.",
            _object({**selection, "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048}},
                    ["sourceId"])),
        _op("source.extract", "Create an ordinary source-resolution image from a bounded selected-channel XY region.",
            _object({**selection,
                     "x": {"type": "integer", "minimum": 0}, "y": {"type": "integer", "minimum": 0},
                     "width": {"type": "integer", "minimum": 1, "maximum": MAX_ROI_PIXELS},
                     "height": {"type": "integer", "minimum": 1, "maximum": MAX_ROI_PIXELS},
                     "name": {"type": "string", "minLength": 1, "maxLength": 200}},
                    ["sourceId", "x", "y", "width", "height"]), True),
    ]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def describe(source):
    return {key: copy.deepcopy(value) for key, value in source.items() if key not in ("sourcePath", "importedFrom")}


def artifact_references(document):
    return {source["sourcePath"]: source["sourceHash"] for source in document.get("largeSources", [])}


def _source(document, source_id):
    value = next((item for item in document.get("largeSources", []) if item["id"] == source_id), None)
    if value is None:
        fail("source-not-found", "The large TIFF source is not part of this project.")
    return value


def _page_info(page):
    from _workbench_imaging import require
    np, = require("numpy")
    page = page.aspage()
    if (page.axes not in ("YX", "YXS", "SYX") or page.imagedepth != 1
            or page.planarconfig not in (1, 2) or page.photometric not in (0, 1, 2)
            or (page.is_tiled and min(page.tilewidth, page.tilelength) < 1)
            or (page.is_tiled and page.tiledepth != 1)
            or (not page.is_tiled and page.rowsperstrip < 1)):
        fail("unsupported-source-layout", "This source reader supports ordinary grayscale or RGB TIFF pages with explicit XY pixels.")
    width, height, channels = page.imagewidth, page.imagelength, page.samplesperpixel
    if min(width, height, channels) < 1 or width * height > MAX_SOURCE_PIXELS or channels > 32:
        fail("source-too-large", "Large TIFF pages support at most one billion pixels and 32 channels.")
    dtype = np.dtype(page.dtype)
    if dtype.kind not in "uifb" or (dtype.kind in "ui" and dtype.itemsize > 4) or dtype.itemsize > 8:
        fail("unsupported-dtype", "Large sources support real floats and up to 32-bit integer raw samples.")
    if len(page.dataoffsets) > MAX_SEGMENTS:
        fail("source-too-large", "The TIFF page contains too many segments for bounded selective reading.")
    if page.is_memmappable:
        access = "memmap"
        segment_bytes = 0
    else:
        samples = channels if page.planarconfig == 1 else 1
        segment_bytes = ((page.tilewidth * page.tilelength * page.tiledepth) if page.is_tiled
                         else min(page.rowsperstrip, height) * width) * samples * dtype.itemsize
        access = "segments" if segment_bytes <= MAX_SEGMENT_BYTES else "unsupported"
    return {"width": width, "height": height, "channels": channels, "dtype": str(dtype),
            "pageAxes": page.axes, "access": access, "tiled": bool(page.is_tiled),
            "maximumSegmentBytes": segment_bytes, "compression": str(page.compression.name)}


def inspect_file(path):
    from _workbench_imaging import require, _ome_calibration
    from _workbench_store import MAX_SOURCE_BYTES
    tifffile, = require("tifffile")
    if path.suffix.lower() not in (".tif", ".tiff") or not path.is_file():
        fail("unsupported-source-format", "The large-source reader currently accepts local TIFF files.")
    if path.stat().st_size > MAX_SOURCE_BYTES:
        fail("source-too-large", "Retained TIFF sources are currently limited to 512 MiB per file.")
    try:
        with tifffile.TiffFile(path) as file:
            series = file.series[0]
            pages = series.pages
            if not 1 <= len(pages) <= MAX_PAGES:
                fail("unsupported-source-layout", "Select a TIFF series containing between 1 and 4,096 pages.")
            first = _page_info(pages[0])
            access = {first["access"]}
            for page in pages[1:]:
                info = _page_info(page)
                if any(info[key] != first[key] for key in ("width", "height", "channels", "dtype", "pageAxes")):
                    fail("unsupported-source-layout", "Pages in the selected TIFF series must have consistent dimensions and sample layout.")
                access.add(info["access"])
            calibration = _ome_calibration(file.ome_metadata)
            limitations = [
                "The first TIFF series and explicit stored pages are used; page numbers are not inferred biological Z or T coordinates.",
                "Overviews are display-only nearest-sample views. Extracted regions retain original source resolution and dtype.",
            ]
            if "unsupported" in access:
                limitations.append("Some compressed strips exceed the 32 MiB segment budget; their extraction requires a tiled or uncompressed TIFF.")
            return {**first, "access": "unsupported" if "unsupported" in access else
                    "memmap" if access == {"memmap"} else "segments",
                    "seriesIndex": 0, "seriesCount": len(file.series), "pageCount": len(pages),
                    "axes": series.axes, "shape": list(series.shape), **calibration,
                    "limits": {"roiPixels": MAX_ROI_PIXELS, "segmentBytes": MAX_SEGMENT_BYTES,
                               "sourceBytes": MAX_SOURCE_BYTES}, "limitations": limitations}
    except (ValueError, IndexError, KeyError, OSError) as exc:
        fail("invalid-source", f"Cannot inspect the TIFF source: {exc}")


def _selected_page(file, source, page_index, channel):
    if page_index >= source["pageCount"] or channel >= source["channels"]:
        fail("invalid-source-selection", "The selected page or channel is unavailable.")
    page = file.series[source["seriesIndex"]].pages[page_index].aspage()
    info = _page_info(page)
    if any(info[key] != source[key] for key in ("width", "height", "channels", "dtype", "pageAxes")):
        fail("source-changed", "The selected TIFF page no longer matches its retained metadata.")
    if info["access"] == "unsupported":
        fail("unsupported-source-layout", "A compressed strip exceeds the 32 MiB decoding budget. Use a tiled or uncompressed TIFF.")
    return page, info


def _read_grid(path, source, page_index, channel, xs, ys):
    """Read only requested source pixel centres, preserving stored sample values."""
    from _workbench_imaging import require
    np, tifffile = require("numpy", "tifffile")
    if len(xs) * len(ys) > MAX_ROI_PIXELS:
        fail("region-too-large", "Extracted regions are limited to 16,000,000 source pixels.")
    with tifffile.TiffFile(path) as file:
        page, info = _selected_page(file, source, page_index, channel)
        if info["access"] == "memmap":
            # NumPy maps only touched pages. No page.asarray() or source-sized
            # allocation is allowed in the large-source reader.
            mapped = np.memmap(path, dtype=page.dtype, mode="r", offset=page.dataoffsets[0], shape=page.shape)
            if page.axes == "YXS":
                plane = mapped[..., channel]
            elif page.axes == "SYX":
                plane = mapped[channel]
            else:
                plane = mapped
            result = plane[np.ix_(ys, xs)]
            del plane, mapped
        else:
            result = np.zeros((len(ys), len(xs)), dtype=page.dtype)
            segment_width = page.tilewidth if page.is_tiled else page.imagewidth
            segment_height = page.tilelength if page.is_tiled else page.rowsperstrip
            tiles_x = math.ceil(page.imagewidth / segment_width)
            tiles_y = math.ceil(page.imagelength / segment_height)
            separate_offset = channel * tiles_x * tiles_y if page.planarconfig == 2 else 0
            segment_channel = 0 if page.planarconfig == 2 else channel
            rows = np.unique(ys // segment_height)
            columns = np.unique(xs // segment_width)
            for tile_y in rows:
                out_y = np.flatnonzero(ys // segment_height == tile_y)
                for tile_x in columns:
                    out_x = np.flatnonzero(xs // segment_width == tile_x)
                    index = separate_offset + int(tile_y) * tiles_x + int(tile_x)
                    count = page.databytecounts[index]
                    if count > MAX_SEGMENT_BYTES:
                        fail("segment-too-large", "An encoded TIFF segment exceeds the 32 MiB read budget.")
                    if count == 0:
                        continue
                    file.filehandle.seek(page.dataoffsets[index])
                    encoded = file.filehandle.read(count)
                    if len(encoded) != count:
                        fail("invalid-source", "A TIFF segment ends before its declared byte count.")
                    try:
                        decoded, position, _ = page.decode(encoded, index, jpegtables=page.jpegtables)
                    except (ValueError, NotImplementedError, ImportError) as exc:
                        fail("unsupported-source-codec", "This TIFF codec is unavailable in the configured runtime.",
                             {"reason": str(exc)[:300]})
                    if decoded is None:
                        continue
                    if decoded.nbytes > MAX_SEGMENT_BYTES or decoded.ndim != 4 or decoded.shape[0] != 1:
                        fail("invalid-source", "The TIFF decoder returned an unsupported segment layout.")
                    local_x, local_y = xs[out_x] - position[3], ys[out_y] - position[2]
                    if (local_x.min() < 0 or local_y.min() < 0 or local_x.max() >= decoded.shape[2]
                            or local_y.max() >= decoded.shape[1] or segment_channel >= decoded.shape[3]):
                        fail("invalid-source", "The TIFF segment coordinates do not cover the requested source pixels.")
                    result[np.ix_(out_y, out_x)] = decoded[0, :, :, segment_channel][np.ix_(local_y, local_x)]
        if not np.isfinite(result).all():
            fail("invalid-source", "The selected source pixels contain non-finite values.")
        return result


def _import(store, document, args):
    from _workbench_schema import absolute_path
    from _workbench_store import utc_now
    sources = document.setdefault("largeSources", [])
    if len(sources) + len(args["paths"]) > MAX_SOURCES:
        fail("source-limit", "A project supports at most 1,000 retained large sources.")
    acquisitions = {(item.get("importedFrom"), item["sourceHash"]): item for item in sources}
    added, duplicates = [], []
    for name in args["paths"]:
        path = absolute_path(name, "paths")
        inspect_file(path)
        reference, digest, size = store.import_file(str(path))
        if (str(path), digest) in acquisitions:
            duplicates.append(acquisitions[(str(path), digest)]["id"])
            continue
        metadata = inspect_file(store.artifact_path(reference))
        source = {"id": str(uuid.uuid4()), "name": path.name, "sourcePath": reference,
                  "sourceHash": digest, "sourceBytes": size, "importedFrom": str(path),
                  "importedAt": utc_now(), **metadata}
        sources.append(source)
        acquisitions[(str(path), digest)] = source
        added.append(source["id"])
    return {"sources": [describe(source) for source in sources],
            "importedSourceIds": added, "duplicateSourceIds": duplicates}


def _overview(store, source, args):
    from _workbench_imaging import require, preview_data
    np, = require("numpy")
    width, height = source["width"], source["height"]
    maximum = args.get("maxSize", 768)
    shrink = min(1, maximum / max(width, height))
    pw, ph = max(1, int(round(width * shrink))), max(1, int(round(height * shrink)))
    sx, sy = width / pw, height / ph
    # Sampling uses source pixel centres; ROI coordinates use source edges.
    xs = np.minimum(width - 1, np.floor((np.arange(pw) + .5) * sx).astype(np.int64))
    ys = np.minimum(height - 1, np.floor((np.arange(ph) + .5) * sy).astype(np.int64))
    page_index, channel = args.get("pageIndex", 0), args.get("channel", 0)
    path = store.verify_artifact(source["sourcePath"], source["sourceHash"])
    pixels = _read_grid(path, source, page_index, channel, xs, ys)
    rendered = preview_data(pixels, max_size=maximum)
    return {**rendered, "sourceId": source["id"], "pageIndex": page_index, "channel": channel,
            "width": width, "height": height, "previewWidth": pw, "previewHeight": ph,
            "scale": {"x": sx, "y": sy},
            "transform": {"scale": [sx, sy], "offset": [(sx-1)/2, (sy-1)/2]},
            "sampling": "nearest-source-pixel-at-display-centre", "coordinateSpace": "source-pixel-edges",
            "intensityUnits": "raw-source"}


def _extract(store, document, source, args):
    from _workbench_imaging import require
    from _workbench_store import utc_now
    np, tifffile = require("numpy", "tifffile")
    x, y, width, height = (args[key] for key in ("x", "y", "width", "height"))
    if width * height > MAX_ROI_PIXELS:
        fail("region-too-large", "Extracted regions are limited to 16,000,000 source pixels.")
    if x + width > source["width"] or y + height > source["height"]:
        fail("region-outside-source", "The requested XY rectangle lies outside the original source page.")
    if len(document["images"]) >= image_capacity(document):
        fail("project-too-large", "A project supports at most 1,000 ordinary analysis images.")
    page_index, channel = args.get("pageIndex", 0), args.get("channel", 0)
    path = store.verify_artifact(source["sourcePath"], source["sourceHash"])
    pixels = _read_grid(path, source, page_index, channel,
                        np.arange(x, x + width, dtype=np.int64), np.arange(y, y + height, dtype=np.int64))
    encoded = io.BytesIO()
    tifffile.imwrite(encoded, pixels, photometric="minisblack", metadata={"axes": "YX"})
    reference, digest = store.put_bytes(encoded.getvalue(), ".tif")
    voxels = copy.deepcopy(source["voxelSizeUm"])
    scale = (1/voxels["x"] if voxels.get("x") is not None and voxels.get("y") is not None
             and math.isclose(voxels["x"], voxels["y"], rel_tol=1e-9) else None)
    region = {"sourceId": source["id"], "sourceHash": source["sourceHash"], "sourceName": source["name"],
              "seriesIndex": source["seriesIndex"], "pageIndex": page_index, "channel": channel,
              "x": x, "y": y, "width": width, "height": height,
              "originalDimensions": [source["width"], source["height"]],
              "originUm": {"x": x * voxels["x"] if voxels.get("x") is not None else None,
                           "y": y * voxels["y"] if voxels.get("y") is not None else None},
              "coordinateSpace": "source-pixel-edges", "resampled": False}
    image = {"id": str(uuid.uuid4()), "name": args.get("name", f"{source['name']} · ROI {x},{y} {width}×{height}"),
             "sourcePath": reference, "sourceHash": digest, "sourceBytes": len(encoded.getbuffer()),
             "importedAt": utc_now(), "pxPerUm": scale, "voxelSizeUm": voxels,
             "timeStepSeconds": None, "calibrationSource": "source-metadata",
             "width": width, "height": height, "channels": 1, "axes": "YX", "shape": [height, width],
             "dtype": str(pixels.dtype), "zCount": 1, "timeCount": 1, "undoStack": [],
             "sourceRegion": region}
    document["images"].append(image)
    from _workbench_core import _inspection
    descriptor = next(value for value in _inspection(document)["images"] if value["id"] == image["id"])
    return {"image": descriptor, "imageId": image["id"], "sourceId": source["id"], "region": region}


def execute(store, document, operation, args, revision):
    if operation == "source.import":
        return _import(store, document, args)
    if operation == "source.list":
        return {"sources": [describe(source) for source in document.get("largeSources", [])]}
    source = _source(document, args["sourceId"])
    if operation == "source.inspect":
        return {"source": describe(source)}
    if operation == "source.overview":
        return _overview(store, source, args)
    return _extract(store, document, source, args)
