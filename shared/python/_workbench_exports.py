"""Built-in scientific exports using durable, no-overwrite publication."""
from __future__ import annotations

import copy
import csv
import io
import math
import os
from pathlib import Path
import tempfile
import uuid

MAX_EXPORT_BYTES = 256 * 1024 ** 2
MAX_EXPORTS = 1000
FORMATS = [
    {"id": "labels-ome-tiff", "name": "Exact instance labels (OME-TIFF)", "extension": "ome.tif",
     "mediaType": "image/tiff", "targets": ["plane", "volume"], "requiresAnalysis": True,
     "description": "Full-resolution uint32 instance labels; zero is background. Calibration and provenance are embedded."},
    {"id": "source-ome-tiff", "name": "Selected source pixels (OME-TIFF)", "extension": "ome.tif",
     "mediaType": "image/tiff", "targets": ["plane", "volume"], "requiresAnalysis": False,
     "description": "Full-resolution selected pixels preserve native dtype. Mean Z projections use float64 without integer rounding."},
    {"id": "support-ome-tiff", "name": "Valid acquired domain (OME-TIFF)", "extension": "ome.tif",
     "mediaType": "image/tiff", "targets": ["plane", "volume"], "requiresAnalysis": False,
     "description": "Exact uint8 support mask on the selected source grid: one is acquired support, zero is excluded fill."},
    {"id": "measurements-csv", "name": "Object measurements (CSV)", "extension": "csv",
     "mediaType": "text/csv", "targets": ["plane", "volume"], "requiresAnalysis": True,
     "description": "Current scalar object measurements with source identity, selection, calibration, units and analysis revisions."},
    {"id": "overlay-png", "name": "Display overlay (PNG)", "extension": "png",
     "mediaType": "image/png", "targets": ["plane"], "requiresAnalysis": True,
     "description": "A bounded display image with saved-label boundaries and transparent unsupported samples. Never a scientific label raster."},
]
ANNOTATION_FORMATS = [
    {"id": "geometry-json", "name": "Annotation geometry (JSON)", "extension": "json",
     "mediaType": "application/json",
     "description": "Exact saved geometry in local pixel-edge coordinates, source selection, history and current calibration."},
    {"id": "measurements-csv", "name": "Annotation measurements (CSV)", "extension": "csv",
     "mediaType": "text/csv",
     "description": "Current calibrated geometry and source-intensity statistics for one saved annotation."},
    {"id": "profile-csv", "name": "Intensity profile samples (CSV)", "extension": "csv",
     "mediaType": "text/csv",
     "description": "Line or polyline sample coordinates, arc distances and intensities; missing samples remain empty and explicitly invalid."},
]
LINEAGE_FORMATS = [
    {"id": "graph-json", "name": "Lineage graph (JSON)", "extension": "json", "mediaType": "application/json",
     "description": "Exact observations, links, recorded divisions, track summaries and correction history."},
    {"id": "observations-csv", "name": "Lineage observations (CSV)", "extension": "csv", "mediaType": "text/csv",
     "description": "One row per observed object, with track/lineage identity, source coordinates, calibration and label provenance."},
    {"id": "tracks-csv", "name": "Track summaries (CSV)", "extension": "csv", "mediaType": "text/csv",
     "description": "One row per lineage segment, with parent/daughter segments, observed span, path length and speed."},
    {"id": "edges-csv", "name": "Lineage links (CSV)", "extension": "csv", "mediaType": "text/csv",
     "description": "Continuation and division links with endpoint identities, gaps, displacement and recorded decision reasons."},
]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS)}


def annotation_catalogue():
    return {"formats": copy.deepcopy(ANNOTATION_FORMATS)}


def lineage_catalogue():
    return {"formats": copy.deepcopy(LINEAGE_FORMATS)}


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    return [
        _op("image.export.catalogue", "Describe built-in scientific image and display export formats.",
            _object(), project=False),
        _op("image.export", "Retain and publish a selected image export without overwriting existing files.",
            _object({
                "imageId": _ID, "format": {"type": "string", "enum": [item["id"] for item in FORMATS]},
                "target": {"type": "string", "enum": ["plane", "volume"], "default": "plane"},
                "sourceParameters": _object({
                    "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                    "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]},
                }),
                "timeIndex": {"type": "integer", "minimum": 0, "default": 0},
                "channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0},
                "destination": _STRING,
                "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 2048},
            }, ["imageId", "format", "destination"]), True),
        _op("annotation.export.catalogue", "Describe saved-annotation geometry, measurement and profile exports.",
            _object(), project=False),
        _op("annotation.export", "Retain and publish exact saved annotation geometry or current measurements without overwriting files.",
            _object({
                "imageId": _ID, "annotationId": _ID,
                "format": {"type": "string", "enum": [item["id"] for item in ANNOTATION_FORMATS]},
                "destination": _STRING,
                "measurementChannel": {"type": "integer", "minimum": 0, "maximum": 31},
                "profileSamples": {"type": "integer", "minimum": 2, "maximum": 4096},
            }, ["imageId", "annotationId", "format", "destination"]), True),
        _op("lineage.export.catalogue", "Describe lineage graph, observation, track and link export formats.",
            _object(), project=False),
        _op("lineage.export", "Retain and publish a current lineage graph or scientific trajectory table without overwriting files.",
            _object({"imageId": _ID, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                     "format": {"type": "string", "enum": [item["id"] for item in LINEAGE_FORMATS]},
                     "destination": _STRING}, ["imageId", "channel", "format", "destination"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _source_pixels(store, image, selection):
    """Reuse the bounded decoder, retaining native pixel dtype during selection."""
    import _workbench_imaging as imaging
    import _workbench_volume as volume
    np, = imaging.require("numpy")
    path = store.verify_artifact(image["sourcePath"], image["sourceHash"])
    metadata = imaging.inspect_source(path)
    if any(metadata[key] != image[key] for key in ("width", "height", "channels", "zCount", "timeCount")):
        fail("source-changed", "Source geometry differs from the imported image.")
    target = selection["target"]
    if target == "volume":
        time_index, channel = selection["timeIndex"], selection["channel"]
        volume.selection(image, time_index, channel)
    else:
        if metadata["timeCount"] > 1:
            fail("unsupported-time-selection", "Use a volume export with explicit timeIndex for a multi-time source.")
        time_index, channel = 0, selection["sourceParameters"]["channel"]
        if channel >= metadata["channels"]:
            fail("channel-unavailable", "The selected source channel is unavailable.")
    array, _ = imaging.load_array(path, metadata)
    axes = metadata["axes"].replace("S", "C")
    for axis, selected in (("T", time_index), ("C", channel)):
        if axis in axes:
            position = axes.index(axis)
            indexes = [slice(None)] * array.ndim
            indexes[position] = selected
            array = array[tuple(indexes)]
            axes = axes[:position] + axes[position + 1:]
    if target == "plane" and "Z" in axes:
        position = axes.index("Z")
        mode = selection["sourceParameters"]["zProjection"]
        if mode == "middle":
            array = np.take(array, array.shape[position] // 2, axis=position)
        elif mode == "mean":
            array = array.mean(axis=position, dtype=np.float64)
        else:
            array = array.max(axis=position)
        axes = axes[:position] + axes[position + 1:]
    if target == "volume" and axes == "YX":
        array = array[None, ...]
        axes = "ZYX"
    expected = "YX" if target == "plane" else "ZYX"
    if axes != expected:
        fail("unsupported-axes", "Selected source cannot be represented by this export's spatial axes.")
    if not np.isfinite(array).all():
        fail("invalid-pixels", "Scientific exports require finite source samples.")
    return array, metadata


def _select(store, image, arguments, definition):
    import _workbench_core as core
    import _workbench_volume as volume
    target = arguments.get("target", "plane")
    if target not in definition["targets"]:
        fail("unsupported-export-target", "This format is unavailable for the selected target.")
    if definition["id"] != "overlay-png" and "maxSize" in arguments:
        fail("invalid-arguments", "maxSize is a display-overlay setting; scientific exports always keep full resolution.")
    analysis = None
    if target == "volume":
        if "sourceParameters" in arguments:
            fail("invalid-arguments", "Volume exports select timeIndex and channel, without a plane projection.")
        selection = {"target": target, "timeIndex": arguments.get("timeIndex", 0), "channel": arguments.get("channel", 0)}
        volume.selection(image, selection["timeIndex"], selection["channel"])
        if definition["requiresAnalysis"]:
            analysis = volume.current_frame(store, image, selection["timeIndex"], selection["channel"], verify=False)
    else:
        if "timeIndex" in arguments or "channel" in arguments:
            fail("invalid-arguments", "Plane exports select channel and projection through sourceParameters.")
        saved = image.get("analysis")
        defaults = {"channel": 0, "zProjection": "max", **image.get("preferredSourceParameters", {})}
        if saved:
            defaults.update({key: saved["parameters"][key] for key in ("channel", "zProjection")})
        supplied = arguments.get("sourceParameters", {})
        if definition["requiresAnalysis"]:
            analysis = core._current_analysis(store, image, verify_files=False)
            if any(value != analysis["parameters"][key] for key, value in supplied.items()):
                fail("source-selection-mismatch", "Saved labels, measurements and overlays must use their analysis channel and Z projection.")
        selected = {key: {**defaults, **supplied}[key] for key in ("channel", "zProjection")}
        selection = {"target": target, "sourceParameters": selected}
    raw, metadata = _source_pixels(store, image, selection)
    labels = None
    if analysis is not None:
        labels = (core._labels(store, image, analysis) if target == "plane"
                  else volume.read_labels(store, image, analysis))
        if labels.shape != raw.shape:
            fail("invalid-labels", "The saved mask and selected source dimensions differ.")
    return selection, raw, metadata, analysis, labels


def _provenance(document, image, selection, raw, metadata, analysis, valid, definition, revision, request_id, actor):
    from _workbench_assays import processing_provenance
    from _workbench_core import ENGINE_VERSION
    from _workbench_store import utc_now
    import _workbench_support as support
    import _workbench_volume as volume
    result = {
        "schemaVersion": 1, "exportId": str(uuid.uuid4()), "format": definition["id"],
        "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
        "createdAt": utc_now(), "requestId": request_id, "actor": copy.deepcopy(actor), "engineVersion": ENGINE_VERSION,
        "imageId": image["id"], "imageName": image["name"], "selection": selection,
        "source": {"sha256": image["sourceHash"], "dtype": metadata["dtype"],
                   "axes": metadata["axes"], "shape": metadata["shape"]},
        "selectedShape": list(raw.shape), "selectedDtype": str(raw.dtype),
        "axes": "YX" if raw.ndim == 2 else "ZYX",
        "voxelSizeUm": volume.calibration(image), "pxPerUm": image["pxPerUm"],
        "timeStepSeconds": image.get("timeStepSeconds"),
        "coordinateSpace": "pixel-edges" if raw.ndim == 2 else "voxel-edges",
        "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
        "processing": processing_provenance(document, image),
        "validSupport": support.summary(image, valid, raw.shape),
        "displayOnly": definition["id"] == "overlay-png",
        "notes": ["Image coordinates are local pixel/voxel edges; the first sample centre is 0.5.",
                  "Zero-valued labels indicate background; source fill values must be interpreted with the valid-support mask."],
    }
    if raw.ndim == 2 and metadata["zCount"] > 1:
        projection = selection["sourceParameters"]["zProjection"]
        result["projection"] = {"method": projection, "sourcePlanes": metadata["zCount"]}
        if projection == "mean":
            result["notes"].append("Mean Z projection is exported as float64 to preserve fractional values without integer rounding.")
    for key in ("sourceRegion", "variantOf", "variantRootId"):
        if key in image:
            result[key] = copy.deepcopy(image[key])
    if analysis:
        result["analysis"] = {key: copy.deepcopy(analysis[key]) for key in
                              ("labelsHash", "analysisRevision", "measurementRevision", "inputFingerprint",
                               "parameters", "engineVersion", "model") if key in analysis}
    return result


def _ome(array, provenance):
    from _workbench_imaging import require
    from _workbench_store import canonical
    tifffile, = require("tifffile")
    metadata = {"axes": provenance["axes"], "Name": provenance["imageName"],
                "Description": canonical(provenance)}
    for axis in "xyz":
        value = provenance["voxelSizeUm"].get(axis)
        if value is not None and (axis != "z" or array.ndim == 3):
            metadata["PhysicalSize" + axis.upper()] = value
            metadata["PhysicalSize" + axis.upper() + "Unit"] = "µm"
    if provenance.get("timeStepSeconds") is not None:
        metadata.update({"TimeIncrement": provenance["timeStepSeconds"], "TimeIncrementUnit": "s"})
    encoded = io.BytesIO()
    try:
        tifffile.imwrite(encoded, array, ome=True, photometric="minisblack", metadata=metadata)
    except (ValueError, TypeError) as exc:
        fail("unsupported-export-dtype", "This source dtype cannot be represented unchanged in OME-TIFF: " + str(exc)[:300])
    return encoded.getvalue()


def _overlay(raw, labels, valid, max_size, provenance):
    from _workbench_imaging import require
    require("numpy", "PIL")
    import numpy as np
    from PIL import Image
    samples = raw if valid is None else raw[valid]
    low, high = float(samples.min()), float(samples.max())
    values = raw.astype(np.float64, copy=False)
    if not math.isfinite(high - low):
        fail("display-range-too-large", "The finite source range exceeds display arithmetic; select an explicit normalized image.")
    scaled = (np.zeros(raw.shape, np.uint8) if high <= low else
              np.rint(np.clip((values - low) / (high - low), 0, 1) * 255).astype(np.uint8))
    view = Image.fromarray(scaled)
    view.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    rgb = view.convert("RGB")
    interior = np.zeros(labels.shape, dtype=bool)
    interior[1:-1, 1:-1] = (
        (labels[1:-1, 1:-1] == labels[:-2, 1:-1]) & (labels[1:-1, 1:-1] == labels[2:, 1:-1]) &
        (labels[1:-1, 1:-1] == labels[1:-1, :-2]) & (labels[1:-1, 1:-1] == labels[1:-1, 2:]))
    boundary = Image.fromarray(((labels > 0) & ~interior).astype(np.uint8) * 255)
    if boundary.size != rgb.size:
        boundary = boundary.resize(rgb.size, Image.Resampling.BOX)
    rgb.paste((63, 220, 190), (0, 0), boundary)
    if valid is not None:
        alpha = Image.fromarray(valid.astype(np.uint8) * 255)
        if alpha.size != rgb.size:
            alpha = alpha.resize(rgb.size, Image.Resampling.NEAREST)
        rgb.putalpha(alpha)
    provenance["display"] = {
        "width": rgb.width, "height": rgb.height, "maxSize": max_size, "displayRange": [low, high],
        "downsampled": list(raw.shape) != [rgb.height, rgb.width], "unsupportedSamples": "transparent",
        "intensityResampling": "Lanczos", "boundaryResampling": "area coverage",
    }
    provenance["notes"].append("PNG is a normalized display overlay; use uint32 label OME-TIFF for scientific masks.")
    return rgb


def _csv_safe(value):
    if isinstance(value, str) and (value.startswith(("\t", "\r", "\n")) or value.lstrip().startswith(("=", "+", "-", "@"))):
        return "'" + value
    return value


def _csv(image, analysis, provenance, provenance_hash):
    columns = [
        "export_id", "image_id", "image_name", "source_sha256", "labels_sha256", "provenance_sha256",
        "target", "time_index", "channel", "z_projection", "label_id",
        "centroid_x_px", "centroid_y_px", "centroid_z_px",
        "centroid_x_um", "centroid_y_um", "centroid_z_um", "area_px", "area_um2",
        "volume_voxels", "volume_um3", "equivalent_diameter_um", "mean_intensity",
        "voxel_size_x_um", "voxel_size_y_um", "voxel_size_z_um", "time_step_seconds", "px_per_um",
        "analysis_revision", "measurement_revision", "coordinate_space", "intensity_units",
        "valid_sample_count", "invalid_sample_count", "source_region_x", "source_region_y",
    ]
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    selected = provenance["selection"]
    plane = selected["target"] == "plane"
    scale = provenance["voxelSizeUm"]
    region = image.get("sourceRegion", {})
    for cell in analysis["cells"]:
        coordinates = [cell.get(key) for key in ("cx", "cy", "cz")]
        physical = [value * scale[axis] if value is not None and scale.get(axis) is not None else None
                    for axis, value in zip("xyz", coordinates)]
        row = [
            provenance["exportId"], image["id"], image["name"], image["sourceHash"],
            analysis["labelsHash"], provenance_hash, selected["target"],
            0 if plane else selected["timeIndex"],
            selected["sourceParameters"]["channel"] if plane else selected["channel"],
            selected["sourceParameters"]["zProjection"] if plane else None, cell["labelId"],
            *coordinates, *physical, cell.get("areaPx"), cell.get("areaUm2"),
            cell.get("voxelCount"), cell.get("volumeUm3"),
            cell.get("diameterUm") if plane else cell.get("equivalentDiameterUm"), cell["meanIntensity"],
            scale.get("x"), scale.get("y"), None if plane else scale.get("z"),
            provenance["timeStepSeconds"], image["pxPerUm"], analysis["analysisRevision"],
            analysis["measurementRevision"], provenance["coordinateSpace"], provenance["intensityUnits"],
            provenance["validSupport"]["validVoxelCount"], provenance["validSupport"]["invalidPixelCount"],
            region.get("x"), region.get("y"),
        ]
        if any(type(value) in (int, float) and not math.isfinite(value) for value in row):
            fail("invalid-measurements", "Saved measurements contain a non-finite scalar; recompute before exporting.")
        writer.writerow([_csv_safe(value) for value in row])
    return output.getvalue().encode("utf-8")


def artifact_references(document):
    references = {}
    for item in document.get("imageExports", []):
        for prefix in ("file", "provenance", "source", "labels", "support", "annotation", "graph", "report"):
            if prefix + "Path" in item:
                references[item[prefix + "Path"]] = item[prefix + "Hash"]
        for frame in item.get("frameReferences", []):
            references[frame["labelsPath"]] = frame["labelsHash"]
        for reference in item.get("inputReferences", []):
            references[reference["path"]] = reference["hash"]
    return references


def describe(item):
    result = {key: copy.deepcopy(value) for key, value in item.items() if not key.endswith("Path")}
    if "frameReferences" in result:
        result["frameReferences"] = [{key: value for key, value in frame.items() if not key.endswith("Path")}
                                     for frame in result["frameReferences"]]
    if "inputReferences" in result:
        result["inputReferences"] = [{"sha256": reference["hash"]} for reference in result["inputReferences"]]
    return result


def _destination(arguments, definition):
    from _workbench_schema import absolute_path
    destination = absolute_path(arguments["destination"], "destination")
    suffixes = (".tif", ".tiff") if definition["mediaType"] == "image/tiff" else ("." + definition["extension"],)
    if destination.suffix.lower() not in suffixes:
        fail("invalid-path", "The export destination extension must match its selected format.")
    if not destination.parent.is_dir():
        fail("invalid-path", "The export destination parent directory must already exist.")
    if destination.exists() or destination.is_symlink():
        fail("destination-exists", "Scientific exports never overwrite an existing file or link.")
    return destination


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_core import _image
    from _workbench_imaging import require
    from _workbench_store import canonical
    import _workbench_support as support
    np, = require("numpy")
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    image = _image(document, arguments["imageId"])
    selection, raw, metadata, analysis, labels = _select(store, image, arguments, definition)
    valid = support.load(store, image, raw.shape, selection.get("sourceParameters"))
    provenance = _provenance(document, image, selection, raw, metadata, analysis, valid,
                             definition, revision, request_id, actor)
    format_id = definition["id"]
    view = None
    if format_id == "overlay-png":
        view = _overlay(raw, labels, valid, arguments.get("maxSize", 2048), provenance)
        provenance["exportedDtype"] = "uint8-display"
    elif format_id == "labels-ome-tiff":
        pixels = np.asarray(labels, dtype=np.uint32)
        provenance["exportedDtype"] = "uint32"
    elif format_id == "support-ome-tiff":
        pixels = np.ones(raw.shape, np.uint8) if valid is None else valid.astype(np.uint8)
        provenance["exportedDtype"] = "uint8"
    elif format_id == "source-ome-tiff":
        pixels = raw
        provenance["exportedDtype"] = str(pixels.dtype)
    else:
        provenance["exportedDtype"] = "scalar-csv"
    provenance_path, provenance_hash = store.put_bytes((canonical(provenance) + "\n").encode(), ".export-provenance.json")
    if format_id == "measurements-csv":
        contents = _csv(image, analysis, provenance, provenance_hash)
    elif view is not None:
        from PIL.PngImagePlugin import PngInfo
        metadata_png = PngInfo()
        metadata_png.add_text("CellCounter provenance", canonical(provenance))
        encoded = io.BytesIO()
        view.save(encoded, format="PNG", pnginfo=metadata_png)
        contents = encoded.getvalue()
    else:
        contents = _ome(pixels, provenance)
    if len(contents) > MAX_EXPORT_BYTES:
        fail("export-too-large", "The selected image export exceeds the 256 MiB output budget.")
    file_path, checksum = store.put_bytes(contents, ".image-export." + definition["extension"])
    item = {
        "exportId": provenance["exportId"], "imageId": image["id"], "format": format_id,
        "target": selection["target"], "selection": selection, "createdAt": provenance["createdAt"],
        "revision": revision, "filePath": file_path, "fileHash": checksum,
        "provenancePath": provenance_path, "provenanceHash": provenance_hash,
        "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
        "destination": str(destination), "mediaType": definition["mediaType"], "bytes": len(contents),
    }
    if analysis:
        item.update({"labelsPath": analysis["labelsPath"], "labelsHash": analysis["labelsHash"],
                     "analysisRevision": analysis["analysisRevision"], "measurementRevision": analysis["measurementRevision"]})
    if support.descriptor(image):
        item.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {
        "exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
        "format": format_id, "mediaType": definition["mediaType"], "bytes": len(contents),
        "imageId": image["id"], "target": selection["target"], "selection": selection,
        "provenance": provenance, "provenanceSha256": provenance_hash,
    }, publish, temporary, publication


def _stage_publication(contents, destination, checksum):
    from _workbench_store import sync_directory
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".cellcounter-export-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        def cleanup():
            try:
                if os.path.samefile(destination, temporary):
                    destination.unlink()
                    sync_directory(destination.parent)
            except FileNotFoundError:
                pass
        def publish():
            try:
                os.link(temporary, destination)
            except FileExistsError:
                fail("destination-exists", "Scientific exports never overwrite an existing destination.")
            try:
                sync_directory(destination.parent)
            except OSError:
                cleanup()
                raise
            return cleanup
        return publish, temporary, {"destination": str(destination), "sha256": checksum}
    except Exception:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise


def _annotation_csv(image, annotation, measurement, provenance, provenance_hash, profile_only):
    selected = measurement["selection"]
    plane = annotation["target"] == "plane"
    columns = [
        "export_id", "image_id", "image_name", "annotation_id", "annotation_name", "annotation_notes",
        "geometry_type", "geometry_revision", "source_revision", "source_sha256",
        "annotation_sha256", "provenance_sha256", "target", "time_index", "measurement_channel",
        "z_projection", "slice_orientation", "slice_index", "horizontal_axis", "vertical_axis",
        "coordinate_space", "pixel_spacing_u_um", "pixel_spacing_v_um", "intensity_units",
    ]
    common = [
        provenance["exportId"], image["id"], image["name"], annotation["id"], annotation["name"], annotation["notes"],
        annotation["geometry"]["type"], annotation["geometryRevision"], measurement["sourceRevision"],
        measurement["sourceHash"], provenance["annotationSha256"], provenance_hash, annotation["target"],
        0 if plane else selected["timeIndex"], measurement["measurementChannel"],
        selected["sourceParameters"]["zProjection"] if plane else None,
        None if plane else selected["plane"], None if plane else selected["index"],
        *measurement["axes"], "pixel-edges", measurement["pixelSpacingUm"]["u"], measurement["pixelSpacingUm"]["v"],
        measurement["intensity"]["units"],
    ]
    profile = measurement["profile"]
    if profile_only:
        columns += ["sample_index", "coordinate_u_px", "coordinate_v_px", "arc_distance_px",
                    "arc_distance_um", "intensity", "valid", "interpolation"]
        rows = (common + [index, *coordinates, profile["positionsPx"][index], profile["positionsUm"][index],
                          value, 0 if value is None else 1, profile["interpolation"]]
                for index, (coordinates, value) in enumerate(zip(profile["coordinates"], profile["values"])))
    else:
        columns += [
            "length_px", "perimeter_px", "area_px2", "length_um", "perimeter_um", "area_um2",
            "valid_samples", "missing_samples", "mean_intensity", "minimum_intensity", "maximum_intensity",
            "population_sd_intensity", "sum_intensity", "sampling", "profile_samples",
            "source_valid_pixels", "source_invalid_pixels", "source_support_fraction",
        ]
        geometry, intensity, valid = measurement["geometry"], measurement["intensity"], measurement["validSupport"]
        rows = [common + [
            *[geometry[key] for key in ("lengthPx", "perimeterPx", "areaPx2", "lengthUm", "perimeterUm", "areaUm2")],
            *[intensity[key] for key in ("validSamples", "missingSamples", "mean", "min", "max", "sd", "sum", "sampling")],
            profile["sampleCount"] if profile else None,
            valid["validPixelCount"], valid["invalidPixelCount"], valid["fraction"],
        ]]
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    for row in rows:
        if any(type(value) in (int, float) and not math.isfinite(value) for value in row):
            fail("invalid-measurements", "Annotation measurements contain a non-finite scalar.")
        writer.writerow([_csv_safe(value) for value in row])
    return output.getvalue().encode("utf-8")


def prepare_annotation_export(store, document, arguments, revision, request_id, actor):
    from _workbench_core import _image
    from _workbench_assays import processing_provenance
    from _workbench_store import canonical, utc_now
    import _workbench_annotations as annotations
    import _workbench_support as support
    import _workbench_volume as volume
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in ANNOTATION_FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    format_id = definition["id"]
    if format_id == "geometry-json" and ("measurementChannel" in arguments or "profileSamples" in arguments):
        fail("invalid-arguments", "Geometry exports do not accept measurement settings.")
    image = _image(document, arguments["imageId"])
    record = annotations._record(document, image, arguments["annotationId"])
    value = annotations._read(store, record)
    annotation = annotations.describe(image, record, full=True, value=value)
    if annotation["deleted"]:
        fail("annotation-deleted", "Restore a deleted annotation before exporting it.")
    if not annotation["sourceCurrent"]:
        fail("annotation-source-changed", "The saved annotation source or valid support changed.")
    if format_id == "profile-csv" and annotation["geometry"]["type"] not in ("line", "polyline"):
        fail("unsupported-export-target", "Intensity profile exports require a line or polyline.")
    snapshot = annotations._snapshot(record)
    measurement = None
    if format_id == "geometry-json":
        store.verify_artifact(image["sourcePath"], image["sourceHash"])
        if support.descriptor(image):
            store.verify_artifact(support.descriptor(image)["path"], support.descriptor(image)["hash"])
    else:
        measured = annotations.measure(store, document, image, {
            "annotationId": annotation["id"],
            **{key: arguments[key] for key in ("measurementChannel", "profileSamples") if key in arguments},
        }, include_preview=False)
        annotation, measurement = measured["annotation"], measured["measurement"]
    provenance = {
        "schemaVersion": 1, "exportId": str(uuid.uuid4()), "format": format_id,
        "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
        "createdAt": utc_now(), "requestId": request_id, "actor": copy.deepcopy(actor),
        "engineVersion": annotations.ENGINE_VERSION, "imageId": image["id"], "imageName": image["name"],
        "annotationId": annotation["id"], "annotationSha256": snapshot["hash"],
        "geometryRevision": annotation["geometryRevision"], "target": annotation["target"],
        "selection": copy.deepcopy(annotation["selection"]), "coordinateSpace": "pixel-edges",
        "source": {"sha256": image["sourceHash"], **{key: image[key] for key in
                   ("width", "height", "channels", "zCount", "timeCount")}},
        "voxelSizeUm": volume.calibration(image), "timeStepSeconds": image.get("timeStepSeconds"),
        "processing": processing_provenance(document, image), "validSupport": support.fingerprint(image),
        "notes": [
            "Coordinates use local image pixel edges; the first acquired sample centre is 0.5.",
            "Slice orientations specify the horizontal and vertical source axes; slice indices and CSV sample indices are zero-based.",
            "Physical calibration is captured at export time. Unavailable physical values remain null in JSON and empty in CSV.",
            "Geometry JSON uses CellCounter's local image coordinates, without a geographic coordinate reference system.",
            "CSV strings that could be interpreted as spreadsheet formulas are prefixed with an apostrophe.",
        ],
    }
    if "sourceRegion" in image:
        provenance["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    if measurement is not None:
        provenance["measurement"] = {key: copy.deepcopy(item) for key, item in measurement.items() if key != "profile"}
        profile = measurement["profile"]
        provenance["profile"] = ({"sampleCount": profile["sampleCount"], "interpolation": profile["interpolation"]}
                                 if profile else None)
        provenance["notes"].extend(measurement["notes"])
        provenance["notes"].append("Missing profile intensities are empty; valid=0 distinguishes them from measured zero intensity.")
    provenance_path, provenance_hash = store.put_bytes(
        (canonical(provenance) + "\n").encode("utf-8"), ".annotation-export-provenance.json")
    if format_id == "geometry-json":
        contents = (canonical({"schemaVersion": 1, "format": "cellcounter-annotation",
                               "annotation": annotation, "provenance": provenance,
                               "provenanceSha256": provenance_hash}) + "\n").encode("utf-8")
    else:
        contents = _annotation_csv(image, annotation, measurement, provenance, provenance_hash, format_id == "profile-csv")
    if len(contents) > MAX_EXPORT_BYTES:
        fail("export-too-large", "The annotation export exceeds the 256 MiB output budget.")
    file_path, checksum = store.put_bytes(contents, ".annotation-export." + definition["extension"])
    item = {
        "exportId": provenance["exportId"], "kind": "annotation", "imageId": image["id"],
        "annotationId": annotation["id"], "geometryRevision": annotation["geometryRevision"],
        "format": format_id, "target": annotation["target"], "selection": copy.deepcopy(annotation["selection"]),
        "createdAt": provenance["createdAt"], "revision": revision,
        "filePath": file_path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
        "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
        "annotationPath": snapshot["path"], "annotationHash": snapshot["hash"],
        "destination": str(destination), "mediaType": definition["mediaType"], "bytes": len(contents),
    }
    if support.descriptor(image):
        item.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {
        "exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
        "format": format_id, "mediaType": definition["mediaType"], "bytes": len(contents),
        "imageId": image["id"], "annotationId": annotation["id"], "geometryRevision": annotation["geometryRevision"],
        "provenance": provenance, "provenanceSha256": provenance_hash,
    }, publish, temporary, publication


def _lineage_csv(image, graph, tracks, provenance, provenance_hash, format_id):
    common_columns = ["export_id", "image_id", "image_name", "source_sha256", "graph_sha256",
                      "provenance_sha256", "graph_revision", "channel", "coordinate_space",
                      "voxel_size_x_um", "voxel_size_y_um", "voxel_size_z_um", "time_step_seconds"]
    scale, step = graph["voxelSizeUm"], graph.get("timeStepSeconds")
    common = [provenance["exportId"], image["id"], image["name"], image["sourceHash"], provenance["graphSha256"],
              provenance_hash, provenance["graphRevision"], graph["channel"], "voxel-edges",
              *[scale.get(axis) for axis in "xyz"], step]
    by_node = {node["id"]: node for node in graph["nodes"]}
    track_by_node = {node["id"]: track for track in tracks for node in track["observations"]}
    frames = {frame["timeIndex"]: frame for frame in graph["frameReferences"]}
    columns = list(common_columns)
    if format_id == "observations-csv":
        columns += ["node_id", "lineage_id", "track_id", "parent_track_id", "time_index", "time_seconds",
                    "label_id", "labels_sha256", "analysis_revision", "measurement_revision",
                    "centroid_x_px", "centroid_y_px", "centroid_z_px",
                    "centroid_x_um", "centroid_y_um", "centroid_z_um",
                    "volume_voxels", "volume_um3", "mean_intensity", "intensity_units"]
        def rows():
            for node in sorted(graph["nodes"], key=lambda item: (item["timeIndex"], item["labelId"])):
                track, frame = track_by_node[node["id"]], frames[node["timeIndex"]]
                coordinates = [node[key] for key in ("cx", "cy", "cz")]
                physical = [coordinate * scale[axis] if scale.get(axis) is not None else None
                            for coordinate, axis in zip(coordinates, "xyz")]
                yield common + [
                    node["id"], track["lineageId"], track["id"], track["parentTrackId"],
                    node["timeIndex"], node["timeIndex"] * step if step is not None else None,
                    node["labelId"], frame["labelsHash"], frame["analysisRevision"], frame["measurementRevision"],
                    *coordinates, *physical, node["voxelCount"], node["volumeUm3"], node["meanIntensity"],
                    provenance["intensityUnits"],
                ]
    elif format_id == "tracks-csv":
        columns += ["lineage_id", "track_id", "parent_track_id", "daughter_track_1", "daughter_track_2",
                    "observation_count", "start_time_index", "end_time_index", "elapsed_frames", "elapsed_seconds",
                    "path_length_voxels", "path_length_um", "mean_speed_um_per_second", "mean_volume_um3"]
        def rows():
            for track in tracks:
                daughters = (track["daughterTrackIds"] + [None, None])[:2]
                yield common + [track["lineageId"], track["id"], track["parentTrackId"], *daughters,
                                *[track["summary"][key] for key in
                                  ("observationCount", "startTimeIndex", "endTimeIndex", "elapsedFrames", "elapsedSeconds",
                                   "pathLengthVoxels", "pathLengthUm", "meanSpeedUmPerSecond", "meanVolumeUm3")]]
    else:
        columns += ["lineage_id", "source_track_id", "target_track_id", "source_node_id", "target_node_id",
                    "source_time_index", "source_label_id", "target_time_index", "target_label_id",
                    "kind", "division_id", "elapsed_frames", "unobserved_frames", "elapsed_seconds",
                    "displacement_voxels", "displacement_um", "speed_um_per_second", "decision_reason", "decision_at"]
        divisions = {event["id"]: event for event in graph["divisions"]}
        def rows():
            for edge in graph["edges"]:
                first, second = by_node[edge["sourceNodeId"]], by_node[edge["targetNodeId"]]
                elapsed = second["timeIndex"] - first["timeIndex"]
                seconds = elapsed * step if step is not None else None
                delta = [second[key] - first[key] for key in ("cx", "cy", "cz")]
                physical = (math.sqrt(sum((difference * scale[axis]) ** 2 for difference, axis in zip(delta, "xyz")))
                            if all(scale.get(axis) is not None for axis in "xyz") else None)
                event = divisions.get(edge.get("divisionId"), {}) if edge["kind"] == "division" else edge.get("decision", {})
                yield common + [
                    track_by_node[first["id"]]["lineageId"], track_by_node[first["id"]]["id"],
                    track_by_node[second["id"]]["id"], first["id"], second["id"],
                    first["timeIndex"], first["labelId"], second["timeIndex"], second["labelId"],
                    edge["kind"], edge.get("divisionId"), elapsed, elapsed - 1, seconds,
                    math.sqrt(sum(value * value for value in delta)), physical,
                    physical / seconds if physical is not None and seconds is not None and seconds > 0 else None,
                    event.get("reason"), event.get("at"),
                ]
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(columns)
    for row in rows():
        if any(type(value) in (int, float) and not math.isfinite(value) for value in row):
            fail("invalid-measurements", "The lineage graph contains a non-finite exported measurement.")
        writer.writerow([_csv_safe(value) for value in row])
    return output.getvalue().encode("utf-8")


def prepare_lineage_export(store, document, arguments, revision, request_id, actor):
    from _workbench_core import _image
    from _workbench_assays import processing_provenance
    from _workbench_store import canonical, utc_now
    import _workbench_lineages as lineages
    import _workbench_support as support
    import _workbench_volume as volume
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in LINEAGE_FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    image = _image(document, arguments["imageId"])
    volume.selection(image, 0, arguments["channel"])
    record, graph = lineages.current_graph(store, image, arguments["channel"])
    snapshot = lineages.snapshot_for(record)
    tracks, lineage_groups, summary = lineages.graph_measurements(graph)
    support_value = support.descriptor(image)
    if support_value:
        store.verify_artifact(support_value["path"], support_value["hash"])
    provenance = {
        "schemaVersion": 1, "exportId": str(uuid.uuid4()), "format": definition["id"],
        "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
        "createdAt": utc_now(), "requestId": request_id, "actor": copy.deepcopy(actor),
        "imageId": image["id"], "imageName": image["name"], "sourceHash": image["sourceHash"],
        "graphSha256": snapshot["graphHash"], "graphRevision": snapshot["revision"], "snapshotId": snapshot["id"],
        "channel": graph["channel"], "timeIndices": graph["timeIndices"],
        "voxelSizeUm": graph["voxelSizeUm"], "timeStepSeconds": graph.get("timeStepSeconds"),
        "coordinateSpace": "voxel-edges", "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
        "processing": processing_provenance(document, image),
        "frameReferences": [{key: copy.deepcopy(value) for key, value in frame.items() if not key.endswith("Path")}
                            for frame in graph["frameReferences"]],
        "inputFingerprint": graph["inputFingerprint"], "baseTrackingFingerprint": graph["baseTrackingFingerprint"],
        "validSupport": {key: copy.deepcopy(value) for key, value in support_value.items() if key != "path"} if support_value else None,
        "summary": summary,
        "notes": list(summary["notes"]) + [
            "Coordinates refer to local source voxel edges; the first voxel centre is 0.5.",
            "Time indices are zero-based. Calibrated time is relative to acquisition frame zero.",
            "Unknown calibration remains null in JSON and empty in CSV.",
            "CSV strings that could be interpreted as spreadsheet formulas are prefixed with an apostrophe.",
        ],
    }
    if "sourceRegion" in image:
        provenance["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    provenance_path, provenance_hash = store.put_bytes(
        (canonical(provenance) + "\n").encode("utf-8"), ".lineage-export-provenance.json")
    if definition["id"] == "graph-json":
        exported_graph = {key: copy.deepcopy(value) for key, value in graph.items()
                          if key not in ("sourcePath", "frameReferences", "validSupport", "trackSummaries", "lineageSummaries", "summary")}
        exported_graph.update({
            "frameReferences": provenance["frameReferences"], "validSupport": provenance["validSupport"],
            "tracks": [{key: value for key, value in track.items() if key != "observations"} for track in tracks],
            "lineages": lineage_groups, "summary": summary,
            "history": [{key: event[key] for key in ("id", "revision", "operation", "actor", "at", "reason")}
                        for event in record["snapshots"]],
        })
        contents = (canonical({"schemaVersion": 1, "format": "cellcounter-lineage", "graph": exported_graph,
                               "provenance": provenance, "provenanceSha256": provenance_hash}) + "\n").encode("utf-8")
    else:
        contents = _lineage_csv(image, graph, tracks, provenance, provenance_hash, definition["id"])
    if len(contents) > MAX_EXPORT_BYTES:
        fail("export-too-large", "The lineage export exceeds the 256 MiB output budget.")
    file_path, checksum = store.put_bytes(contents, ".lineage-export." + definition["extension"])
    item = {
        "exportId": provenance["exportId"], "kind": "lineage", "imageId": image["id"], "channel": graph["channel"],
        "graphRevision": snapshot["revision"], "snapshotId": snapshot["id"], "format": definition["id"],
        "target": "volume", "selection": {"channel": graph["channel"], "timeIndices": graph["timeIndices"]},
        "createdAt": provenance["createdAt"], "revision": revision,
        "filePath": file_path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
        "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
        "graphPath": snapshot["graphPath"], "graphHash": snapshot["graphHash"],
        "frameReferences": copy.deepcopy(snapshot["frameReferences"]),
        "destination": str(destination), "mediaType": definition["mediaType"], "bytes": len(contents),
    }
    if support_value:
        item.update({"supportPath": support_value["path"], "supportHash": support_value["hash"]})
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {
        "exportId": item["exportId"], "destination": str(destination), "sha256": checksum,
        "format": definition["id"], "mediaType": definition["mediaType"], "bytes": len(contents),
        "imageId": image["id"], "channel": graph["channel"], "graphRevision": snapshot["revision"],
        "provenance": provenance, "provenanceSha256": provenance_hash,
    }, publish, temporary, publication
