"""Reusable measurements over exact saved masks and raw source channels."""
from __future__ import annotations

import copy
import hashlib
import json
import math
import uuid


def _field(kind, default=None, **limits):
    return {"type": kind, **({"default": default} if default is not None else {}), **limits}


def catalog():
    channel = _field("integer", 0, minimum=0, maximum=31, title="Channel (starting at 0)")
    metric = _field("string", "mean", enum=["mean", "integrated", "median"])
    threshold = _field("number", 0, title="Manual threshold in source units")
    mode = _field("string", "manual", enum=["manual", "otsu"])
    specs = [
        ("morphology", "Shape and morphology", [2, 3], {}),
        ("surface_shape", "3D surface and shape", [3], {}),
        ("fluorescence", "Raw channel intensity", [2, 3], {"channel": channel}),
        ("spatial", "Nearest neighbours and local density", [2, 3], {
            "radius": _field("number", 50, minimum=.01, maximum=1000000),
            "units": _field("string", "voxel", enum=["voxel", "um"]),
        }),
        ("marker_positive", "Marker positivity", [2], {
            "channel": channel, "metric": metric, "threshold_mode": mode, "threshold": threshold,
        }),
        ("transfection_efficiency", "Reporter-positive cells", [2], {
            "channel": channel, "metric": metric, "threshold_mode": mode, "threshold": threshold,
        }),
        ("colocalization", "Pearson and Manders colocalization", [2], {
            "channel_a": channel, "channel_b": {**channel, "default": 1},
            "threshold_mode": mode, "threshold_a": threshold, "threshold_b": threshold,
            "threshold_scope": _field("string", "image", enum=["image", "in_cells"]),
        }),
        ("live_dead", "Live / dead classification", [2], {
            "live_channel": channel, "dead_channel": {**channel, "default": 1}, "metric": metric,
            "live_threshold_mode": mode, "dead_threshold_mode": mode,
            "live_threshold": threshold, "dead_threshold": threshold,
        }),
        ("cell_cycle", "DNA-content cell-cycle estimate", [2], {
            "dna_channel": channel, "bins": _field("integer", 64, minimum=16, maximum=256),
            "gate_width": _field("number", .15, minimum=.01, maximum=.5),
            "smoothing": _field("integer", 3, minimum=1, maximum=15),
            "percentile_cap": _field("number", 99.5, minimum=90, maximum=100),
        }),
        ("nuclear_cytoplasmic", "Nuclear : cytoplasmic intensity", [2], {
            "channel": channel, "nuclearImageId": _field("string", maxLength=256, title="Image ID with the nuclear mask"),
            "metric": _field("string", "mean", enum=["mean", "median"]),
            "min_nuclear_px": _field("integer", 4, minimum=1, maximum=16000000),
            "min_cyto_px": _field("integer", 4, minimum=1, maximum=16000000),
        }),
        ("puncta", "Puncta and foci", [2], {
            "channel": channel, "method": _field("string", "dog", enum=["dog", "log"]),
            "min_diameter_um": _field("number", .3, minimum=.001, maximum=1000),
            "max_diameter_um": _field("number", 3, minimum=.001, maximum=1000),
            "threshold": _field("number", .1, minimum=0, maximum=1),
            "overlap": _field("number", .5, minimum=0, maximum=1),
            "focus_count_threshold": _field("integer", 5, minimum=1, maximum=100000),
        }),
    ]
    from _workbench_assays_specialist import catalog as specialist_catalog
    return [{"id": key, "name": name, "dimensions": dimensions, "requiresAnalysis": True,
             "imageReferenceArguments": ["nuclearImageId"] if key == "nuclear_cytoplasmic" else [],
             "parameters": {"type": "object", "properties": fields, "additionalProperties": False,
                            "required": ["nuclearImageId"] if key == "nuclear_cytoplasmic" else []}}
            for key, name, dimensions, fields in specs] + specialist_catalog()


def operations():
    from _workbench_schema import _object, _op, _ID
    from _workbench_plugins import parameter_values_schema
    selection = {"imageId": _ID, "assay": {"type": "string", "enum": [item["id"] for item in catalog()]},
                 "target": {"type": "string", "enum": ["plane", "volume"]},
                 "timeIndex": {"type": "integer", "minimum": 0}, "channel": {"type": "integer", "minimum": 0, "maximum": 31},
                 "sourceParameters": _object({"channel": {"type": "integer", "minimum": 0, "maximum": 31},
                    "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]}}, ["channel", "zProjection"]),
                 "parameters": parameter_values_schema()}
    return [
        _op("assay.catalog", "Describe built-in measurement and assay controls.", _object(), project=False),
        _op("assay.preview", "Calculate an assay from exact masks without saving results.",
            _object(selection, ["imageId", "assay"])),
        _op("assay.run", "Save exact-input assay results and their source dependencies.",
            _object(selection, ["imageId", "assay"]), True),
        _op("assay.results", "Inspect saved assays and whether their inputs remain current.",
            _object({"imageId": _ID, "runId": _ID})),
        _op("assay.recompute", "Repeat a saved assay against current masks and calibration, retaining the old result.",
            _object({"runId": _ID}, ["runId"]), True),
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _selection(store, document, args):
    import _workbench_core as core
    import _workbench_volume as volume
    image = core._image(document, args["imageId"])
    target = args.get("target", "plane")
    if "sourceParameters" in args:
        fail("invalid-arguments", "Explicit sourceParameters apply only to source-intensity area assays; mask assays use their saved selection.")
    if target == "volume":
        if "timeIndex" not in args or "channel" not in args:
            fail("invalid-arguments", "Volume assays need the analyzed timeIndex and channel.")
        analysis = volume.current_frame(store, image, args["timeIndex"], args["channel"])
        labels = volume.read_labels(store, image, analysis)
        read = lambda channel: volume.load_source(store, image, args["timeIndex"], channel)
    else:
        if "timeIndex" in args or "channel" in args:
            fail("invalid-arguments", "Plane assays use the saved projection and parameter-selected measurement channel.")
        analysis = core._current_analysis(store, image)
        labels = core._labels(store, image)
        read = lambda channel: core._source(store, image, {**analysis["parameters"], "channel": channel})
    return image, analysis, labels, read


def _fingerprint(image, args):
    from _workbench_plugins import _state_fingerprint
    if args.get("rawSourceOnly"):
        from _workbench_volume import calibration
        import _workbench_support as support
        return _digest({"sourceHash": image["sourceHash"], "shape": image.get("shape"),
                        "selection": args["sourceParameters"], "calibration": calibration(image),
                        "support": support.fingerprint(image), "derivation": image.get("derivation"),
                        "sourceRegion": image.get("sourceRegion"),
                        **{key: copy.deepcopy(args[key]) for key in ("timeIndex", "region") if key in args}})
    return _state_fingerprint(image, args.get("target", "plane"), args.get("timeIndex"), args.get("channel"))


def _raw_compute(store, document, args, params):
    """Resolve and freeze source selection independently of saved segmentation."""
    import _workbench_core as core
    import _workbench_support as support
    from _workbench_volume import calibration
    from _workbench_assays_specialist import compute
    if args.get("target", "plane") != "plane" or "timeIndex" in args or "channel" in args:
        fail("unsupported-dimension", "Source-intensity area assays use a 2D projection. Extract a selected time/slice acquisition before this assay.")
    image = core._image(document, args["imageId"])
    selected = args.get("sourceParameters")
    if selected is None:
        saved = (image.get("analysis") or {}).get("parameters") or image.get("preferredSourceParameters") or {}
        selected = {"channel": saved.get("channel", 0), "zProjection": saved.get("zProjection", "max")}
    selected = copy.deepcopy(selected)
    args["sourceParameters"] = selected
    raw = core._source(store, image, selected)
    valid = support.load(store, image, raw.shape, selected)
    calibration_values = calibration(image)
    output = compute(args["assay"], params, raw=raw, valid=valid,
                     spacing=[calibration_values[axis] for axis in "yx"])
    output["sourceSelection"] = selected
    output["intensityUnits"] = "processed-source" if image.get("derivation") else "raw-source"
    output["validSupport"] = support.summary(image, valid, raw.shape)
    output.setdefault("notes", []).extend(output["validSupport"]["notes"])
    dependency = {"imageId": image["id"], "target": "plane", "rawSourceOnly": True,
                  "sourceParameters": selected, "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
                  "sourceProvenance": source_provenance(document, image, {"parameters": selected}, {"target": "plane"})}
    dependency["fingerprint"] = _fingerprint(image, dependency)
    if support.descriptor(image):
        dependency.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    return {"assay": args["assay"], "parameters": params, "imageId": image["id"], "target": "plane",
            "dependencies": [dependency], "inputFingerprint": _digest([dependency]), "output": output}


def _peer_labels(store, document, image, analysis, image_id, name):
    """One exact-grid compatibility path for paired soma and nuclear masks."""
    import _workbench_core as core
    import _workbench_support as support
    from _workbench_volume import calibration
    peer = core._image(document, image_id)
    peer_analysis = core._current_analysis(store, peer)
    if (peer["sourceHash"] != image["sourceHash"] or peer.get("shape") != image.get("shape") or
            peer_analysis["parameters"]["zProjection"] != analysis["parameters"]["zProjection"] or
            calibration(peer) != calibration(image) or support.fingerprint(peer) != support.fingerprint(image)):
        fail("source-mismatch", f"{name} and primary masks must use identical source bytes, grid, projection, calibration and acquired support.")
    dependency = {"imageId": peer["id"], "target": "plane", "sourcePath": peer["sourcePath"], "sourceHash": peer["sourceHash"],
                  "labelsPath": peer_analysis["labelsPath"], "labelsHash": peer_analysis["labelsHash"],
                  "sourceProvenance": source_provenance(document, peer, peer_analysis, {"target": "plane"}),
                  "fingerprint": _fingerprint(peer, {"target": "plane"})}
    if support.descriptor(peer):
        dependency.update({"supportPath": support.descriptor(peer)["path"], "supportHash": support.descriptor(peer)["hash"]})
    return core._labels(store, peer), dependency


def processing_provenance(document, image, images=None):
    """Freeze processing ancestry, including every workspace-generated parent."""
    from _workbench_indexed import image_index
    images = images if images is not None else image_index(document)
    cache, cache_sizes, active = {}, {}, set()
    copied_bytes = 0

    def walk(current, depth=0):
        nonlocal copied_bytes
        identifier = current["id"]
        if identifier in cache:
            copied_bytes += cache_sizes[identifier]
            if copied_bytes > 16 * 1024 ** 2:
                fail("processing-provenance-limit", "Expanded multi-parent processing provenance exceeds 16 MiB.")
            return copy.deepcopy(cache[identifier])
        if identifier in active or depth > 32 or len(cache) + len(active) >= 256:
            fail("invalid-processing-lineage", "Processing ancestry is cyclic or exceeds 32 levels / 256 acquisitions.")
        active.add(identifier)
        derivation = current.get("derivation")
        if not derivation:
            result = {"intensityUnits": "raw-source", "stages": [], "rootImageId": identifier,
                      "rootSourceHash": current["sourceHash"],
                      "roots": [{"imageId": identifier, "sourceHash": current["sourceHash"]}]}
        elif derivation.get("kind") == "workspace":
            from _workbench_workspace import materialized_dependencies, inspect_materialized
            parents, roots = [], []
            for binding in materialized_dependencies(current):
                parent = images.get(binding["imageId"]) if binding.get("imageId") else None
                if binding.get("sourceKind") == "zarr":
                    parents.append({"binding": copy.deepcopy(binding), "processing": None})
                    roots.append({key: copy.deepcopy(binding[key]) for key in
                                  ("sourceKind", "sourceId", "metadataHash", "arrayPath", "region", "selection", "readSetHash", "readIdentity") if key in binding})
                elif parent is None:
                    fail("missing-processing-lineage", "A workspace-generating acquisition is missing; all parent provenance is required.")
                else:
                    processing = walk(parent, depth + 1)
                    parents.append({"binding": copy.deepcopy(binding), "processing": processing})
                    roots.extend(processing["roots"])
            if not parents:
                fail("missing-processing-lineage", "The workspace-generated acquisition has no retained generating parents.")
            state = inspect_materialized(document, current)
            stage = {**copy.deepcopy(derivation), "parents": parents,
                     "parentStateAtMeasurement": {key: copy.deepcopy(state[key]) for key in
                        ("parentInputsCurrent", "staleParentImageIds", "sourceVerificationRequired")}}
            result = {"intensityUnits": "processed-source", "stages": [stage],
                      "rootImageId": None, "rootSourceHash": None, "roots": roots}
        else:
            parent = images.get(derivation.get("sourceImageId"))
            if parent is None:
                fail("missing-processing-lineage", "A preprocessing parent is missing; its full recipe cannot be recorded.")
            result = walk(parent, depth + 1)
            result["intensityUnits"] = "processed-source"
            result["stages"].append(copy.deepcopy(derivation))
        from _workbench_store import canonical
        size = len(canonical(result).encode())
        if size > 8 * 1024 ** 2:
            fail("processing-provenance-limit", "A processing provenance record exceeds 8 MiB.")
        active.remove(identifier)
        cache[identifier] = copy.deepcopy(result); cache_sizes[identifier] = size
        return result

    return walk(image)


def source_provenance(document, image, analysis, args):
    from _workbench_volume import calibration
    import _workbench_support as support
    target = args.get("target", "plane")
    selected = {"target": target}
    if target == "volume":
        selected.update({key: args[key] for key in ("timeIndex", "channel")})
    else:
        selected.update({key: analysis["parameters"][key] for key in ("channel", "zProjection")})
    result = {
        "selection": selected,
        "calibration": {"voxelSizeUm": calibration(image), "pxPerUm": image["pxPerUm"],
                        "timeStepSeconds": image.get("timeStepSeconds")},
        "processing": processing_provenance(document, image),
        "validSupport": copy.deepcopy(support.descriptor(image)),
    }
    if "sourceRegion" in image:
        result["sourceRegion"] = copy.deepcopy(image["sourceRegion"])
    return result


def _dense_labels(labels):
    import numpy as np
    ids = np.unique(labels)
    ids = ids[ids != 0]
    # Dense local IDs avoid allocating by the largest sparse uint32 label.
    dense = np.zeros(labels.shape, np.int32)
    foreground = labels != 0
    dense[foreground] = np.searchsorted(ids, labels[foreground]).astype(np.int32) + 1
    return ids, dense


def _morphology(labels, spacing):
    import numpy as np
    from skimage.measure import regionprops
    ids, dense = _dense_labels(labels)
    physical = all(value is not None for value in spacing)
    props = regionprops(dense)
    rows = []
    for region in props:
        row = {"labelId": int(ids[region.label - 1]), "extent": float(region.extent),
               "eulerNumber": int(region.euler_number), "voxelCount": int(region.area)}
        if labels.ndim == 2:
            perimeter = float(region.perimeter)
            row.update({"solidity": float(region.solidity), "eccentricity": float(region.eccentricity),
                        "majorAxisPx": float(region.axis_major_length), "minorAxisPx": float(region.axis_minor_length),
                        "orientationRadians": float(region.orientation), "perimeterPx": perimeter,
                        "circularity": float(4 * math.pi * region.area / perimeter ** 2) if perimeter else None})
            # Anisotropic physical perimeter uses scaled contour segments.
            if physical:
                from skimage.measure import find_contours
                sy, sx = spacing
                perimeter_um = 0.
                for contour in find_contours(np.pad(region.image, 1), .5):
                    delta = np.diff(contour, axis=0) * [sy, sx]
                    perimeter_um += float(np.sqrt((delta * delta).sum(axis=1)).sum())
                row["perimeterUm"] = perimeter_um
            else:
                row["perimeterUm"] = None
        rows.append(row)
    return {"measurements": rows, "summary": {"objectCount": len(rows)}, "notes": [
        "2D perimeter is a raster approximation; anisotropic physical perimeter uses scaled contour segments.",
        "Circularity uses pixel-space area and perimeter. Three-dimensional shape reports extent and Euler number.",
    ]}


def _fluorescence(labels, raw, valid_support=None):
    import numpy as np
    from scipy import ndimage as ndi
    ids, dense = _dense_labels(labels)
    indexes = np.arange(1, len(ids) + 1)
    counts = np.bincount(dense.ravel(), minlength=len(ids) + 1)[1:]
    sums = ndi.sum(raw, dense, indexes)
    minimum = ndi.minimum(raw, dense, indexes)
    maximum = ndi.maximum(raw, dense, indexes)
    background = raw[(labels == 0) if valid_support is None else ((labels == 0) & valid_support)]
    background_mean = float(background.mean()) if background.size else None
    rows = [{"labelId": int(label), "meanIntensity": float(sums[i] / counts[i]),
             "integratedIntensity": float(sums[i]), "minIntensity": float(minimum[i]),
             "maxIntensity": float(maximum[i]),
             "backgroundCorrectedMean": float(sums[i] / counts[i] - background_mean) if background_mean is not None else None}
            for i, label in enumerate(ids)]
    return {"measurements": rows, "summary": {"objectCount": len(ids), "backgroundMean": background_mean,
                                             "backgroundPixels": int(background.size)},
            "units": "raw-source intensity; integrated values are intensity sums",
            "notes": ["Background is the mean of supported unlabeled source pixels, not an inferred local or negative control."]}


def _surface_shape(labels, spacing):
    """Measure closed object surfaces without changing the scientific label grid."""
    import numpy as np
    from skimage.measure import regionprops, marching_cubes, mesh_surface_area
    ids, dense = _dense_labels(labels)
    physical = all(value is not None for value in spacing)
    metric_spacing = tuple(float(value) for value in spacing) if physical else (1., 1., 1.)
    rows = []
    visited = 0
    for region in regionprops(dense, spacing=metric_spacing):
        bbox_shape = tuple(region.bbox[i + 3] - region.bbox[i] + 2 for i in range(3))
        voxels = math.prod(bbox_shape)
        visited += voxels
        if voxels > 2_000_000 or visited > 16_000_000:
            fail("assay-limit", "Surface extraction supports 2 million voxels per padded object box and 16 million across objects.")
        mask = np.pad(region.image.astype(np.uint8), 1)
        vertices, faces, _, _ = marching_cubes(mask, level=.5, spacing=metric_spacing, allow_degenerate=False)
        area = float(mesh_surface_area(vertices, faces))
        count = int(np.count_nonzero(region.image))
        measured_volume = count * math.prod(metric_spacing)
        inertia = np.asarray(region.inertia_tensor_eigvals, dtype=float)
        diameters = sorted((2 * math.sqrt(max(0., 2.5 * (float(inertia.sum()) - 2 * value)))
                            for value in inertia), reverse=True)
        row = {
            "labelId": int(ids[region.label - 1]), "voxelCount": count,
            "surfaceArea": area, "volume": measured_volume,
            "equivalentEllipsoidDiameters": diameters,
            "sphericity": float(math.pi ** (1 / 3) * (6 * measured_volume) ** (2 / 3) / area) if area else None,
            "touchesImageBoundary": any(region.bbox[i] == 0 or region.bbox[i + 3] == labels.shape[i] for i in range(3)),
        }
        rows.append(row)
    return {"measurements": rows, "summary": {"objectCount": len(rows),
            "surfaceAreaUnits": "um2" if physical else "voxel2",
            "volumeUnits": "um3" if physical else "voxel3",
            "diameterUnits": "um" if physical else "voxel"},
            "notes": [
                "Surface uses a closed marching-cubes mesh at the label boundary, with independent axis spacing.",
                "Volume uses occupied voxel counts. Different raster estimators can give sphericity above one for small objects.",
                "Objects touching the acquisition boundary are flagged because their observed shape may be truncated.",
                "Without complete XYZ calibration, all measurements use voxel coordinates.",
            ]}


def _spatial(analysis, shape, spacing, params, valid_support=None):
    import numpy as np
    from scipy.spatial import cKDTree
    cells = analysis["cells"]
    axes = ("cx", "cy") if len(shape) == 2 else ("cx", "cy", "cz")
    coordinates = np.asarray([[cell[key] for key in axes] for cell in cells], dtype=float)
    if params["units"] == "um":
        if any(value is None for value in spacing):
            fail("calibration-required", "Physical spatial measurements require every spatial axis.")
        if coordinates.size:
            coordinates *= list(reversed(spacing))
    dimension = len(shape)
    ball = math.pi * params["radius"] ** 2 if dimension == 2 else 4 * math.pi * params["radius"] ** 3 / 3
    if not cells:
        rows = []
    else:
        tree = cKDTree(coordinates)
        counts = tree.query_ball_point(coordinates, params["radius"], return_length=True) - 1
        nearest = tree.query(coordinates, k=2)[0][:, 1] if len(cells) > 1 else [math.inf]
        rows = [{"labelId": cell["labelId"], "nearestDistance": float(nearest[i]) if math.isfinite(nearest[i]) else None,
                 "neighboursWithinRadius": int(counts[i]), "localDensity": float(counts[i] / ball)}
                for i, cell in enumerate(cells)]
        if valid_support is not None:
            factors = spacing if params["units"] == "um" else [1.] * dimension
            radii = [params["radius"] / scale for scale in factors]
            visits = 0
            for row, cell in zip(rows, cells):
                centre = [cell[key] for key in (("cy", "cx") if dimension == 2 else ("cz", "cy", "cx"))]
                start = [max(0, math.floor(value - radius - .5)) for value, radius in zip(centre, radii)]
                stop = [min(size, math.ceil(value + radius + .5)) for value, radius, size in zip(centre, radii, shape)]
                visits += math.prod(max(0, last - first) for first, last in zip(start, stop))
                if visits > 100_000_000:
                    fail("assay-limit", "Support-corrected local density exceeds 100 million neighbourhood sample visits; reduce radius.")
                region = tuple(slice(first, last) for first, last in zip(start, stop))
                grids = np.ogrid[region]
                distance2 = sum(((grid + .5 - value) * scale) ** 2
                                for grid, value, scale in zip(grids, centre, factors))
                occupied = int(np.count_nonzero(valid_support[region] & (distance2 <= params["radius"] ** 2)))
                observed = occupied * math.prod(factors)
                row.update({"localDensity": row["neighboursWithinRadius"] / observed if observed else None,
                            "observedSupportMeasure": observed, "observedSupportSamples": occupied})
    return {"measurements": rows, "summary": {"objectCount": len(cells), "radius": params["radius"],
                                             "dimension": dimension, "units": params["units"],
                                             "supportCorrected": valid_support is not None},
            "notes": ["Local-density denominators include only supported sample centres inside each neighbourhood; this is a discrete area/volume estimate."
                      if valid_support is not None else
                      "Centroid distances and local density are descriptive; neighbourhoods are not boundary-corrected."]}


def _compute(store, document, args):
    import numpy as np
    import _workbench_volume as volume
    import _workbench_core as core
    import _workbench_support as support
    from _workbench_plugins import validate_parameters
    definition = next(item for item in catalog() if item["id"] == args["assay"])
    params = validate_parameters({"parameters": definition["parameters"]}, args.get("parameters"))
    if not definition.get("requiresAnalysis", True):
        return _raw_compute(store, document, args, params)
    image, analysis, labels, read = _selection(store, document, args)
    valid = support.assert_labels(store, image, labels, analysis.get("parameters"))
    support_info = support.summary(image, valid, labels.shape)
    if labels.ndim not in definition["dimensions"]:
        fail("unsupported-dimension", "This assay is available only for the dimensions listed in assay.catalog.")
    spatial = volume.calibration(image)
    spacing = [spatial[axis] for axis in ("yx" if labels.ndim == 2 else "zyx")]
    dependencies = [{"imageId": image["id"], "fingerprint": _fingerprint(image, args),
                     "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
                     "labelsPath": analysis["labelsPath"], "labelsHash": analysis["labelsHash"],
                     "sourceProvenance": source_provenance(document, image, analysis, args),
                     "target": args.get("target", "plane"), **{key: args[key] for key in ("timeIndex", "channel") if key in args}}]
    if support.descriptor(image):
        dependencies[0]["supportPath"] = support.descriptor(image)["path"]
        dependencies[0]["supportHash"] = support.descriptor(image)["hash"]
    kind = args["assay"]
    if kind in ("confluence", "colonies", "neurite_outgrowth"):
        from _workbench_assays_specialist import compute
        soma = None
        if kind == "neurite_outgrowth":
            soma, dependency = _peer_labels(store, document, image, analysis, params["somaImageId"], "Soma")
            dependencies.append(dependency)
        output = compute(kind, params, labels=labels, soma=soma, spacing=spacing, valid=valid)
    elif kind == "morphology":
        output = _morphology(labels, spacing)
    elif kind == "surface_shape":
        output = _surface_shape(labels, spacing)
    elif kind == "fluorescence":
        output = _fluorescence(labels, read(params["channel"]), valid)
    elif kind == "spatial":
        output = _spatial(analysis, labels.shape, spacing, params, valid)
    elif kind == "puncta":
        if image.get("pxPerUm") is None:
            fail("calibration-required", "This 2D spot detector requires known isotropic XY calibration.")
        if params["max_diameter_um"] < params["min_diameter_um"]:
            fail("invalid-arguments", "Maximum spot diameter must be at least the minimum.")
        # Bound LoG scale-space allocation; use explicit limits, never silently
        # resize scientific detection data to satisfy an allocation budget.
        if labels.size > 4_000_000:
            fail("assay-limit", "Spot detection currently supports up to 4 million source pixels.")
        import _workbench_assays_puncta as puncta
        raw = read(params["channel"])
        region = support.rectangular_crop(valid) if valid is not None else (slice(0, labels.shape[0]), slice(0, labels.shape[1]))
        output = puncta.compute(raw[region], image["pxPerUm"],
                                {key: value for key, value in params.items() if key != "channel"}, label_map=labels[region])
        for spot in output.get("spots", []):
            spot["x_px"] += region[1].start
            spot["y_px"] += region[0].start
            spot["x_um"] = spot["x_px"] / image["pxPerUm"]
            spot["y_um"] = spot["y_px"] / image["pxPerUm"]
        output["supportCrop"] = {"x": region[1].start, "y": region[0].start,
                                 "width": region[1].stop - region[1].start, "height": region[0].stop - region[0].start}
        if valid is not None:
            output.setdefault("notes", []).append("Spot filtering and normalization use only the supported rectangle; its edges form the detector boundary.")
    else:
        import _workbench_assays_intensity as intensity
        channel_keys = [key for key in params if key == "channel" or key.endswith("_channel") or key in ("channel_a", "channel_b")]
        channels = sorted(set(params[key] for key in channel_keys))
        if labels.size * max(1, len(channels)) * 8 > 256 * 1024 ** 2:
            fail("assay-limit", "Selected raw channels exceed the assay allocation budget.")
        data = np.stack([read(channel) for channel in channels], axis=-1)
        call_params = dict(params)
        for key in channel_keys:
            call_params[key] = channels.index(params[key])
        if kind == "nuclear_cytoplasmic":
            call_params["nuclear_mask"], dependency = _peer_labels(store, document, image, analysis, call_params.pop("nuclearImageId"), "Nuclear")
            dependencies.append(dependency)
        if kind == "colocalization":
            call_params["valid_support"] = valid
        output = getattr(intensity, kind)(labels, data, **call_params,
                                         channel_names=[f"Source channel {channel}" for channel in channels])
        if not output.get("ok"):
            fail(output.get("error", "assay-unavailable"), output.get("message", "Assay could not be calculated."))
        output["channelMap"] = {str(index): channel for index, channel in enumerate(channels)}
    intensity_units = "processed-source" if image.get("derivation") else "raw-source"
    output["intensityUnits"] = intensity_units
    output["validSupport"] = support_info
    output.setdefault("notes", []).extend(support_info["notes"])
    if intensity_units == "processed-source":
        output.setdefault("notes", []).append("This image contains transformed intensities; consult its retained preprocessing recipe.")
        if kind == "fluorescence":
            output["units"] = "processed-source intensity; integrated values are intensity sums"
    return {"assay": kind, "parameters": params, "imageId": image["id"],
            "target": args.get("target", "plane"), "dependencies": dependencies,
            "inputFingerprint": _digest(dependencies), "output": output}


def _current(document, run):
    from _workbench_indexed import image_index
    images = image_index(document)
    return all(item["imageId"] in images and _fingerprint(images[item["imageId"]], item) == item["fingerprint"]
               for item in run["dependencies"])


def describe(document, run):
    return {**{key: copy.deepcopy(value) for key, value in run.items() if key not in ("outputPath", "dependencies")},
            "stale": not _current(document, run)}


def artifact_references(document):
    result = {}
    for run in document.get("assayRuns", []):
        result[run["outputPath"]] = run["outputHash"]
        for dependency in run["dependencies"]:
            for prefix in ("source", "labels", "support"):
                if prefix + "Path" in dependency:
                    result[dependency[prefix + "Path"]] = dependency[prefix + "Hash"]
    return result


def execute(store, document, operation, args, revision):
    from _workbench_store import canonical, utc_now
    previous = None
    if operation == "assay.catalog":
        return {"assays": catalog()}
    if operation == "assay.results":
        runs = document.get("assayRuns", [])
        if "runId" in args:
            runs = [run for run in runs if run["runId"] == args["runId"]]
            if not runs:
                fail("assay-not-found", "The selected assay run does not exist.")
        if "imageId" in args:
            runs = [run for run in runs if run["imageId"] == args["imageId"]]
        result = []
        for run in runs[-100:]:
            item = describe(document, run)
            if "runId" in args:
                path = store.verify_artifact(run["outputPath"], run["outputHash"])
                item["output"] = json.loads(path.read_text())
            result.append(item)
        return {"runs": result}
    if operation == "assay.recompute":
        previous = next((run for run in document.get("assayRuns", []) if run["runId"] == args["runId"]), None)
        if not previous:
            fail("assay-not-found", "The selected assay run does not exist.")
        args = copy.deepcopy(previous["arguments"])
    args = copy.deepcopy(args)
    result = _compute(store, document, args)
    if operation == "assay.preview":
        return result
    if len(document.get("assayRuns", [])) >= 1000:
        fail("assay-limit", "This project retains at most 1,000 assay runs.")
    encoded = canonical(result["output"]).encode()
    if len(encoded) > 16 * 1024 ** 2:
        fail("assay-limit", "The assay output exceeds the 16 MiB budget.")
    path, checksum = store.put_bytes(encoded, ".assay.json")
    run = {key: value for key, value in result.items() if key != "output"}
    run.update({"runId": str(uuid.uuid4()), "arguments": copy.deepcopy(args), "createdAt": utc_now(),
                "revision": revision, "outputPath": path, "outputHash": checksum})
    if previous is not None:
        run["replacesRunId"] = previous["runId"]
    document.setdefault("assayRuns", []).append(run)
    return {"run": describe(document, run), "output": result["output"]}
