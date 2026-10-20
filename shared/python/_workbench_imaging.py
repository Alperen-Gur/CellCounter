"""Bounded scientific image operations; exact raster labels are authoritative."""
from __future__ import annotations

import base64
import importlib
import importlib.util
import io
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from _workbench_schema import WorkbenchError

MAX_PIXELS = 16_000_000
MAX_ELEMENTS = 64_000_000
MAX_DECODE_BYTES = 256 * 1024 * 1024
MAX_CELLS = 20_000
SUPPORTED_AXES = ("YX", "YXS", "YXC", "CYX", "ZYX", "ZCYX", "CZYX",
                  "TYX", "TCYX", "TZYX", "TCZYX", "TZCYX", "ZYXS", "TZYXS")
_DEPS = {"numpy": "numpy", "scipy": "scipy", "PIL": "Pillow",
         "skimage": "scikit-image", "tifffile": "tifffile"}


def dependencies():
    result = {}
    for module, package in _DEPS.items():
        try:
            present = importlib.util.find_spec(module) is not None
        except (ImportError, ValueError):
            present = False
        result[package] = present
    return result


def require(*names):
    loaded = []
    for name in names:
        try:
            loaded.append(importlib.import_module(name))
        except ImportError as exc:
            raise WorkbenchError(
                "missing-dependency",
                f"Install the workbench analysis requirements to use {_DEPS.get(name, name)}.",
                {"package": _DEPS.get(name, name), "requirements": "requirements-analysis.txt"},
            ) from exc
    return loaded


def _bounded(shape, dtype, axes):
    if axes not in SUPPORTED_AXES or len(shape) != len(axes):
        raise WorkbenchError("unsupported-axes", f"Unsupported image axes {axes!r}.",
                             {"supportedAxes": list(SUPPORTED_AXES)})
    if any(int(size) <= 0 for size in shape):
        raise WorkbenchError("invalid-image", "Image axis lengths must be positive.")
    sizes = dict(zip(axes, map(int, shape)))
    elements = math.prod(map(int, shape))
    if sizes["X"] * sizes["Y"] > MAX_PIXELS or elements > MAX_ELEMENTS or elements * dtype.itemsize > MAX_DECODE_BYTES:
        raise WorkbenchError("image-too-large", "Source exceeds the 16-megapixel plane or 256 MiB decode budget.")
    if sizes.get("C", sizes.get("S", 1)) > 32:
        raise WorkbenchError("image-too-large", "At most 32 channels are supported.")
    if dtype.kind not in "uifb" or (dtype.kind in "ui" and dtype.itemsize > 4):
        raise WorkbenchError("unsupported-dtype", "Supported source pixels are real floats, booleans and up to 32-bit integers.")
    return sizes


def _ome_calibration(xml):
    result = {"voxelSizeUm": {"x": None, "y": None, "z": None}, "timeStepSeconds": None}
    if not xml or len(xml) > 2 * 1024 * 1024:
        return result
    try:
        pixels = next(node for node in ET.fromstring(xml).iter() if node.tag.split("}")[-1] == "Pixels")
        conversions = {"µm": 1.0, "um": 1.0, "micrometer": 1.0, "nm": 0.001, "mm": 1000.0}
        for axis in "XYZ":
            try:
                value = float(pixels.attrib["PhysicalSize" + axis]) * conversions[pixels.attrib.get("PhysicalSize" + axis + "Unit", "µm")]
                if math.isfinite(value) and value > 0:
                    result["voxelSizeUm"][axis.lower()] = value
            except (ValueError, KeyError):
                pass
        units = {"s": 1, "ms": 0.001, "µs": 0.000001, "us": 0.000001, "min": 60, "h": 3600}
        if "TimeIncrement" in pixels.attrib:
            value = float(pixels.attrib["TimeIncrement"]) * units[pixels.attrib.get("TimeIncrementUnit", "s")]
            if math.isfinite(value) and value > 0:
                result["timeStepSeconds"] = value
    except (ValueError, KeyError, StopIteration, ET.ParseError):
        pass
    return result


def inspect_source(path):
    np, = require("numpy")
    if Path(path).suffix.lower() in (".tif", ".tiff"):
        tifffile, = require("tifffile")
        try:
            with tifffile.TiffFile(path) as source:
                if len(source.series) != 1:
                    raise WorkbenchError("unsupported-series", "Select a single TIFF series before import.")
                series = source.series[0]
                axes = series.axes.upper()
                shape, dtype = tuple(series.shape), np.dtype(series.dtype)
                sizes = _bounded(shape, dtype, axes)
                calibration = _ome_calibration(source.ome_metadata)
        except WorkbenchError:
            raise
        except Exception as exc:
            raise WorkbenchError("invalid-image", f"Cannot inspect TIFF: {exc}") from exc
    else:
        require("PIL")
        from PIL import Image
        try:
            with Image.open(path) as source:
                width, height = source.size
                if width * height > MAX_PIXELS:
                    raise WorkbenchError("image-too-large", "Source exceeds the 16-megapixel plane budget.")
                if getattr(source, "n_frames", 1) != 1:
                    raise WorkbenchError("unsupported-frames", "Import animated or multiframe images as an explicitly labelled TIFF.")
                if source.mode not in ("1", "L", "I", "F", "RGB", "RGBA", "P") and "16" not in source.mode:
                    raise WorkbenchError("unsupported-mode", f"Unsupported raster mode {source.mode!r}.")
                channels = 3 if source.mode in ("RGB", "RGBA", "P") else 1
                axes = "YXS" if channels > 1 else "YX"
                shape = (height, width, channels) if channels > 1 else (height, width)
                dtype = np.dtype("float32" if source.mode == "F" else "int32" if source.mode == "I"
                                 else "uint16" if "16" in source.mode else "bool" if source.mode == "1" else "uint8")
                sizes = _bounded(shape, dtype, axes)
                calibration = _ome_calibration(None)
        except WorkbenchError:
            raise
        except Exception as exc:
            raise WorkbenchError("invalid-image", f"Cannot inspect image: {exc}") from exc
    x, y = (calibration["voxelSizeUm"][axis] for axis in "xy")
    scale = 1 / x if x is not None and y is not None and math.isclose(x, y, rel_tol=1e-9) else None
    return {
        "width": sizes["X"], "height": sizes["Y"],
        "channels": sizes.get("C", sizes.get("S", 1)),
        "axes": axes, "shape": list(shape), "dtype": str(dtype),
        "zCount": sizes.get("Z", 1), "timeCount": sizes.get("T", 1),
        "metadataPxPerUm": scale,
        **calibration,
    }


def load_array(path, metadata=None):
    np, = require("numpy")
    metadata = metadata or inspect_source(path)
    axes = metadata["axes"]
    if Path(path).suffix.lower() in (".tif", ".tiff"):
        tifffile, = require("tifffile")
        with tifffile.TiffFile(path) as source:
            array = source.series[0].asarray()
    else:
        from PIL import Image
        with Image.open(path) as source:
            if source.mode in ("RGB", "RGBA", "P"):
                array = np.asarray(source.convert("RGB"))
            elif source.mode in ("1", "L", "I", "F") or "16" in source.mode:
                array = np.asarray(source)
            else:
                raise WorkbenchError("unsupported-mode", f"Unsupported raster mode {source.mode!r}.")
    _bounded(array.shape, array.dtype, axes)
    return array, metadata


def load_plane(path, parameters, time_index=None):
    metadata = inspect_source(path)
    _check_plane_selection(metadata, parameters, time_index)
    array, _ = load_array(path, metadata)
    return plane_from_array(array, metadata, parameters, time_index), metadata


def _check_plane_selection(metadata, parameters, time_index):
    if metadata["timeCount"] > 1 and time_index is None:
        raise WorkbenchError("unsupported-time-selection",
                             "This workflow currently requires a single time point. Use volume operations with an explicit timeIndex.")
    if time_index is not None and (type(time_index) is not int or not 0 <= time_index < metadata["timeCount"]):
        raise WorkbenchError("time-unavailable", "Selected time point is unavailable.")
    channel = parameters["channel"]
    if type(channel) is not int or not 0 <= channel < metadata["channels"]:
        raise WorkbenchError("channel-unavailable", "Selected channel is unavailable.",
                             {"channel": channel, "channels": metadata["channels"]})


def plane_from_array(array, metadata, parameters, time_index=None, *, validate_finite=True):
    """Select an exact plane from an already bounded, decoded acquisition."""
    np, = require("numpy")
    _check_plane_selection(metadata, parameters, time_index)
    axes = metadata["axes"]
    channel = parameters["channel"]
    if "T" in axes:
        index = axes.index("T")
        selection = [slice(None)] * array.ndim
        selection[index] = 0 if time_index is None else time_index
        array = array[tuple(selection)]
        axes = axes[:index] + axes[index + 1:]
    if "C" in axes or "S" in axes:
        index = axes.index("C") if "C" in axes else axes.index("S")
        selection = [slice(None)] * array.ndim
        selection[index] = channel
        array = array[tuple(selection)]
        axes = axes[:index] + axes[index + 1:]
    if "Z" in axes:
        index = axes.index("Z")
        projection = parameters["zProjection"]
        if projection == "middle":
            array = np.take(array, array.shape[index] // 2, axis=index)
        elif projection == "mean":
            array = array.mean(axis=index, dtype=np.float64)
        else:
            array = array.max(axis=index)
        axes = axes[:index] + axes[index + 1:]
    if axes != "YX":
        raise WorkbenchError("unsupported-axes", f"Selected source has unsupported axes {axes!r}.")
    plane = np.asarray(array, dtype=np.float64)
    if validate_finite and not np.isfinite(plane).all():
        raise WorkbenchError("invalid-pixels", "Quantitative analysis does not accept NaN or infinite source pixels.")
    return plane


def segment(plane, parameters, valid_support=None):
    np, = require("numpy")
    require("scipy", "skimage")
    from scipy import ndimage as ndi
    from skimage.feature import peak_local_max
    from skimage.segmentation import watershed
    from _workbench_classical import threshold_mask
    try:
        binary, stats, _ = threshold_mask(plane, parameters, valid_support)
    except ValueError as exc:
        raise WorkbenchError("threshold-failed", str(exc)) from exc
    if not binary.any():
        return np.zeros(plane.shape, dtype=np.uint32), stats
    distance = ndi.distance_transform_edt(binary)
    peaks = peak_local_max(distance, min_distance=parameters["minDistancePx"],
                           labels=binary, exclude_border=False)
    markers = np.zeros(binary.shape, dtype=np.int32)
    for number, (row, column) in enumerate(peaks, 1):
        markers[row, column] = number
    # Each disconnected foreground component needs a seed, including thin or edge objects.
    components, component_count = ndi.label(binary)
    next_marker = len(peaks) + 1
    seeded = set(map(int, components[markers > 0]))
    for label, slc in enumerate(ndi.find_objects(components), 1):
        if slc is None or label in seeded:
            continue
        local = np.where(components[slc] == label, distance[slc], -1)
        row, column = np.unravel_index(local.argmax(), local.shape)
        markers[row + slc[0].start, column + slc[1].start] = next_marker
        next_marker += 1
    if next_marker > MAX_CELLS + 1 or component_count > MAX_CELLS:
        raise WorkbenchError("too-many-objects", "Segmentation exceeds the 20,000-object limit.")
    labels = watershed(-distance, markers, mask=binary).astype(np.uint32)
    # Splitting can create fragments smaller than the original connected
    # component. Enforce the advertised object minimum on final instances too.
    sizes = np.bincount(labels.ravel())
    keep = sizes >= parameters["minAreaPx"]
    keep[0] = False
    labels[~keep[labels]] = 0
    stats["foregroundPixels"] = int(np.count_nonzero(labels))
    return labels, stats


def measure(labels, plane, px_per_um, voxel_size_um=None):
    np, = require("numpy")
    require("scipy", "skimage")
    from skimage.measure import regionprops, find_contours, approximate_polygon
    if labels.shape != plane.shape or labels.ndim != 2:
        raise WorkbenchError("invalid-labels", "Mask and selected source plane dimensions differ.")
    unique = np.unique(labels)
    if len(unique[unique > 0]) > MAX_CELLS:
        raise WorkbenchError("too-many-objects", "Measurements exceed the 20,000-object limit.")
    # Compact working labels avoid regionprops allocating by arbitrary uint32 label IDs.
    original_ids = unique[unique > 0]
    dense = np.searchsorted(original_ids, labels).astype(np.int32) + 1
    dense[labels == 0] = 0
    cells = []
    contour_points = 0
    for prop in regionprops(dense, intensity_image=plane):
        label_id = int(original_ids[prop.label - 1])
        area = int(prop.area)
        cy, cx = prop.centroid
        row0, col0, _, _ = prop.bbox
        contours = find_contours(np.pad(prop.image.astype(np.uint8), 1), 0.5)
        polygons = []
        # Keep every component and hole. These are display derivatives only;
        # measurements always use the complete exact raster label.
        for contour in contours:
            if len(contour) > 512:
                contour = approximate_polygon(contour, tolerance=0.75)
            if len(contour) > 2048:
                stride = math.ceil(len(contour) / 2048)
                contour = contour[::stride]
            polygons.append([[float(point[1] + col0 - 0.5), float(point[0] + row0 - 0.5)]
                             for point in contour])
        polygon = max(polygons, key=len) if polygons else []
        contour_points += sum(map(len, polygons))
        if contour_points > 200_000:
            raise WorkbenchError("too-many-boundaries", "Mask display exceeds 200,000 contour points.")
        xy = [voxel_size_um.get(axis) for axis in "xy"] if voxel_size_um is not None else []
        pixel_area = (xy[0] * xy[1] if xy and all(value is not None for value in xy)
                      else 1 / (px_per_um ** 2) if px_per_um and not xy else None)
        physical_area = area * pixel_area if pixel_area is not None else None
        cell = {
            "labelId": label_id, "cx": float(cx + 0.5), "cy": float(cy + 0.5),
            "areaPx": area, "areaUm2": physical_area,
            "diameterUm": 2 * math.sqrt(physical_area / math.pi) if physical_area is not None else None,
            "meanIntensity": float(prop.mean_intensity), "contourPx": polygon, "contoursPx": polygons,
        }
        cells.append(cell)
    return cells


def encode_labels(labels):
    np, = require("numpy")
    output = io.BytesIO()
    np.save(output, np.asarray(labels, dtype=np.uint32), allow_pickle=False)
    return output.getvalue()


def read_labels(path, shape):
    np, = require("numpy")
    if Path(path).stat().st_size > MAX_PIXELS * 4 + 65536:
        raise WorkbenchError("invalid-labels", "Stored labels exceed the supported allocation budget.")
    # A memory map validates the declared byte span against the file before
    # allocating an array; a corrupt NPY header cannot demand an unbounded heap.
    labels = np.load(path, allow_pickle=False, mmap_mode="r")
    if labels.dtype != np.dtype("uint32") or tuple(labels.shape) != tuple(shape) or labels.ndim != 2:
        raise WorkbenchError("invalid-labels", "Stored labels have an unexpected dtype or shape.")
    return labels


def edit_labels(labels, arguments):
    np, = require("numpy")
    result = labels.copy()
    action = arguments["action"]
    existing = set(map(int, np.unique(labels))) - {0}
    if action in ("delete", "merge"):
        ids = arguments.get("labelIds")
        if not ids or len(set(ids)) != len(ids) or not set(ids).issubset(existing):
            raise WorkbenchError("invalid-labels", "labelIds must name distinct existing objects.")
        if action == "merge" and len(ids) < 2:
            raise WorkbenchError("invalid-labels", "Merging requires at least two objects.")
        if "polygon" in arguments or "labelId" in arguments:
            raise WorkbenchError("invalid-arguments", "Polygon fields do not apply to this edit.")
        selected = np.isin(result, ids)
        result[selected] = 0 if action == "delete" else min(ids)
    else:
        polygon = arguments.get("polygon")
        if polygon is None or "labelIds" in arguments:
            raise WorkbenchError("invalid-arguments", "Polygon editing requires polygon vertices.")
        height, width = result.shape
        if any(x < 0 or y < 0 or x > width or y > height for x, y in polygon):
            raise WorkbenchError("invalid-polygon", "Polygon vertices must be within the source pixel boundaries.")
        signed_area = sum(polygon[i][0] * polygon[(i + 1) % len(polygon)][1] -
                          polygon[(i + 1) % len(polygon)][0] * polygon[i][1] for i in range(len(polygon))) / 2
        if abs(signed_area) < 0.5:
            raise WorkbenchError("invalid-polygon", "Polygon must enclose at least half a pixel.")
        label = arguments.get("labelId")
        if label is None:
            label = max(existing, default=0) + 1
            if label > 0xffffffff:
                raise WorkbenchError("invalid-labels", "No further uint32 label IDs are available.")
        elif label not in existing:
            raise WorkbenchError("invalid-labels", "labelId must name an existing object; omit it to create a new object.")
        # Explicit polygon replaces one object's geometry. Other labels are never silently overwritten.
        require("skimage")
        from skimage.draw import polygon as raster_polygon
        points = np.asarray(polygon)
        rows, cols = raster_polygon(points[:, 1] - 0.5, points[:, 0] - 0.5, shape=result.shape)
        if not len(rows):
            raise WorkbenchError("invalid-polygon", "Polygon contains no pixel centres.")
        collisions = result[rows, cols]
        if np.any((collisions != 0) & (collisions != label)):
            raise WorkbenchError("label-overlap", "Polygon overlaps another object. Merge or delete that object explicitly.")
        result[result == label] = 0
        result[rows, cols] = label
    if np.array_equal(result, labels):
        raise WorkbenchError("no-change", "The correction does not change any label pixels.")
    return result


def preview_data(plane, labels=None, max_size=768):
    np, = require("numpy")
    require("PIL")
    from PIL import Image
    low, high = float(plane.min()), float(plane.max())
    scaled = np.zeros(plane.shape, dtype=np.uint8) if high <= low else np.rint((plane - low) / (high - low) * 255).astype(np.uint8)
    rgb = np.repeat(scaled[:, :, None], 3, axis=2)
    if labels is not None:
        boundary = labels > 0
        interior = np.zeros(labels.shape, dtype=bool)
        interior[1:-1, 1:-1] = (
            (labels[1:-1, 1:-1] == labels[:-2, 1:-1]) &
            (labels[1:-1, 1:-1] == labels[2:, 1:-1]) &
            (labels[1:-1, 1:-1] == labels[1:-1, :-2]) &
            (labels[1:-1, 1:-1] == labels[1:-1, 2:])
        )
        boundary &= ~interior
        rgb[boundary] = (63, 220, 190)
    image = Image.fromarray(rgb)
    image.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    output = io.BytesIO()
    image.save(output, format="PNG")
    return {"dataUrl": "data:image/png;base64," + base64.b64encode(output.getvalue()).decode("ascii"),
            "width": int(plane.shape[1]), "height": int(plane.shape[0]),
            "previewWidth": image.width, "previewHeight": image.height,
            "displayRange": [low, high], "overlayIncluded": labels is not None}
