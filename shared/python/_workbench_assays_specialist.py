"""Canonical units, limits and source selection for shared specialist kernels."""
from __future__ import annotations

import math

RAW_ASSAYS = frozenset({"confluence_threshold", "scratch_wound", "spheroids"})
MASK_ASSAYS = frozenset({"confluence", "colonies", "neurite_outgrowth"})


def catalog():
    from _workbench_assays import _field as f
    threshold = {"method": f("string", "otsu", enum=["otsu", "manual"]),
                 "threshold": f("number", 128, title="Manual threshold (source intensity)"),
                 "polarity": f("string", "bright", enum=["bright", "dark"]),
                 "smoothSigmaPx": f("number", 1., minimum=0, maximum=20, title="Gaussian smoothing (pixels)")}
    definitions = [
        ("confluence", "Confluence from saved masks", {}, True, []),
        ("confluence_threshold", "Confluence from source intensity", {**threshold,
         "minimumAreaPx": f("integer", 0, minimum=0, maximum=4000000, title="Remove objects / fill holes smaller than (pixels²)")}, False, []),
        ("scratch_wound", "Scratch-wound gap area", {
         "textureWindowPx": f("integer", 11, minimum=3, maximum=101, title="Texture window (odd pixel count)"),
         "minimumGapAreaPx": f("integer", 200, minimum=1, maximum=4000000, title="Minimum gap area (pixels²)"),
         "smoothSigmaPx": f("number", 1., minimum=0, maximum=20, title="Gaussian smoothing (pixels)"),
         "flatRegionRatio": f("number", .25, minimum=0, maximum=1, title="Low / high texture ratio gate")}, False, []),
        ("spheroids", "Spheroid / organoid projected shape", {**threshold,
         "polarity": f("string", "dark", enum=["bright", "dark"]),
         "minimumAreaPx": f("integer", 500, minimum=1, maximum=4000000, title="Minimum projected area (pixels²)"),
         "minimumCircularity": f("number", 0., minimum=0, maximum=1),
         "maximumObjects": f("integer", 100, minimum=1, maximum=1000)}, False, []),
        ("colonies", "Colony grouping and centroid distances", {
         "dilationRadiusPx": f("integer", 4, minimum=0, maximum=128, title="Grouping dilation radius (source pixels)"),
         "minimumCells": f("integer", 3, minimum=1, maximum=100000, title="Minimum cells per colony")}, True, []),
        ("neurite_outgrowth", "Neurite length and soma attribution", {
         "somaImageId": f("string", maxLength=256, title="Image with exact soma masks")}, True, ["somaImageId"]),
    ]
    return [{"id": key, "name": name, "dimensions": [2], "requiresAnalysis": masks,
             "imageReferenceArguments": references,
             "parameters": {"type": "object", "properties": fields, "additionalProperties": False, "required": references},
             "notes": (["Uses selected source intensity without requiring or changing saved segmentation."] if not masks else []) +
                      ["Unknown physical calibration remains unknown; source-pixel measurements are retained."]}
            for key, name, fields, masks, references in definitions]


def _check(result):
    from _workbench_assays import fail
    if not result.get("ok", True) or str(result.get("message", "")).startswith("Neurite analysis failed"):
        fail("assay-unavailable", result.get("message") or "The specialist assay could not be calculated.")
    return result


def _area_summary(result, mapping, scale):
    summary = {}
    for old, new in mapping.items():
        value = result.get(old)
        summary[new + "Px"] = value
        summary[new + "Um2"] = value * scale if value is not None and scale is not None else None
    return summary


def compute(kind, params, *, labels=None, raw=None, soma=None, spacing=None, valid=None):
    import numpy as np
    import _workbench_assays_area as area
    import _workbench_support as support
    from _workbench_assays import fail
    shape = labels.shape if labels is not None else raw.shape
    if len(shape) != 2 or math.prod(shape) > 4_000_000:
        fail("assay-limit", "Specialist 2D assays support up to 4 million source pixels; extract an exact region first.")
    calibrated = spacing is not None and all(value is not None for value in spacing)
    area_scale = math.prod(spacing) if calibrated else None
    isotropic = calibrated and math.isclose(spacing[0], spacing[1], rel_tol=1e-9)
    notes = ["Physical values are null when required calibration is unknown."]
    if kind == "colonies":
        import _workbench_colony as colony
        return colony.measure(labels, dilation_radius_px=params["dilationRadiusPx"], minimum_cells=params["minimumCells"],
                              spacing_yx=spacing if calibrated else None, valid_support=valid)
    if kind == "neurite_outgrowth":
        import _workbench_neurite as neurite
        if soma is None or soma.shape != labels.shape:
            fail("soma-mask-required", "Select exact soma masks on the same source grid and projection.")
        # Unit-spacing is a pixel-coordinate calculation, never a guessed µm calibration.
        result = _check(neurite.analyze(labels != 0, soma, 1., spacing_yx=spacing if calibrated else (1., 1.)))
        unit = "um" if calibrated else "px"
        rows = [{"somaLabelId": int(cell["soma_id"]), "length": cell["total_length_um"], "lengthUnit": unit,
                 "primaryProcessCount": cell["n_primary_processes"], "branchPixelCount": cell["n_branch_points"],
                 "skeletonPixelCount": cell["skeleton_px_count"]} for cell in result["cells"]]
        summary = {"somaCount": result["n_cells"], "lengthUnit": unit,
                   "totalSkeletonLength": result["total_skeleton_length_um"],
                   "meanAttributedLength": result["mean_neurite_length_um"],
                   "attributedLength": result.get("attributed_length_um", 0.),
                   "somaInteriorLength": result["soma_skeleton_length_um"],
                   "unattributedLength": result["unattributed_length_um"],
                   "unattributedComponentLength": result["unattributed_component_length_um"]}
        return {"measurements": rows, "summary": summary, "units": {key: unit for key in summary if "Length" in key},
                "notes": notes + [result["caveat"],
                    "Length sums horizontal, vertical and diagonal skeleton edges. Attribution uses nearest soma pixels in physical coordinates when both XY spacings are known, otherwise source pixels.",
                    "Branch counts count skeleton pixels with at least three neighbours, not distinct anatomical junctions. A one-pixel soma margin is excluded from process components.",
                    "Only exact saved soma masks are used; no footprint is invented from a centroid."]}
    if kind == "confluence":
        result = _check(area.confluence(mask=labels, px_per_um=1., valid_support=valid))
        summary = _area_summary(result, {"covered_area_um2": "coveredArea", "uncovered_area_um2": "uncoveredArea", "total_area_um2": "observedArea"}, area_scale)
        return {"summary": {**summary, "coveragePct": result["coverage_pct"]}, "notes": notes + ["Coverage is exact saved foreground divided by acquired support area; labels are not changed."]}
    # Texture/threshold filtering has a finite boundary. Do not treat synthetic
    # registration fill or arbitrary holes as acquired optical texture.
    region = support.rectangular_crop(valid) if valid is not None else (slice(0, shape[0]), slice(0, shape[1]))
    source = raw[region]
    crop = {"x": region[1].start, "y": region[0].start, "width": region[1].stop - region[1].start, "height": region[0].stop - region[0].start}
    if kind == "scratch_wound":
        if params["textureWindowPx"] % 2 != 1:
            fail("invalid-arguments", "Choose an odd texture-window size in source pixels.")
        result = _check(area.scratch_wound(source, px_per_um=1., texture_window_px=params["textureWindowPx"],
                     min_gap_size_um2=params["minimumGapAreaPx"], smooth_sigma_px=params["smoothSigmaPx"], flat_region_ratio=params["flatRegionRatio"]))
        bounds = result["wound_bbox_px"]
        if bounds: bounds = [bounds[0] + crop["x"], bounds[1] + crop["y"], bounds[2] + crop["x"], bounds[3] + crop["y"]]
        summary = _area_summary(result, {"gap_area_um2": "gapArea", "total_area_um2": "observedArea"}, area_scale)
        return {"summary": {**summary, "gapFractionPct": result["gap_fraction_pct"]}, "gapBoundsPx": bounds,
                "supportCrop": crop, "message": result.get("message"), "notes": notes + [
                    "Gap area is the largest low-texture connected region after smoothing and the texture-ratio gate; this is an image-derived estimate, not a saved cell mask.",
                    "Only acquired rectangular support is filtered; edges of that rectangle define the filtering boundary."]}
    controls = {"threshold_method": "fixed" if params["method"] == "manual" else "otsu", "fixed_threshold": params["threshold"],
                "invert": params["polarity"] == "dark", "smooth_sigma_px": params["smoothSigmaPx"]}
    if kind == "confluence_threshold":
        result = _check(area.confluence(image=source, px_per_um=1., min_object_size_um2=params["minimumAreaPx"], **controls))
        summary = _area_summary(result, {"covered_area_um2": "coveredArea", "uncovered_area_um2": "uncoveredArea", "total_area_um2": "observedArea"}, area_scale)
        return {"summary": {**summary, "coveragePct": result["coverage_pct"]}, "threshold": result["threshold_value"],
                "supportCrop": crop, "notes": notes + ["Threshold coverage is a source-intensity estimate; it neither changes nor claims exact instance masks."]}
    result = _check(area.spheroids(source, px_per_um=1., min_object_area_um2=params["minimumAreaPx"],
                    min_circularity=params["minimumCircularity"], max_objects=params["maximumObjects"], **controls))
    rows = []
    for cell in result["objects"]:
        row = {"objectIndex": cell["label"], "areaPx": cell["area_um2"],
               "areaUm2": cell["area_um2"] * area_scale if calibrated else None,
               "circularityPx": cell["circularity"], "cx": cell["centroid_x_px"] + crop["x"] + .5,
               "cy": cell["centroid_y_px"] + crop["y"] + .5,
               "boundsPx": [cell["bbox_px"][0] + crop["x"], cell["bbox_px"][1] + crop["y"], cell["bbox_px"][2] + crop["x"], cell["bbox_px"][3] + crop["y"]]}
        for old, name in (("equivalent_diameter_um", "equivalentDiameter"), ("perimeter_um", "perimeter"), ("major_axis_um", "majorAxis"), ("minor_axis_um", "minorAxis")):
            row[name + "Px"] = cell[old]
            row[name + "Um"] = (2 * math.sqrt(row["areaUm2"] / math.pi) if name == "equivalentDiameter" and calibrated
                                else cell[old] * spacing[0] if isotropic else None)
        rows.append(row)
    return {"measurements": rows, "summary": {"objectCount": result.get("total_count", result["count"]), "returnedObjects": len(rows)},
            "truncated": result.get("truncated", False), "supportCrop": crop,
            "notes": notes + ["Projected objects use intensity thresholding, filled holes and size/circularity filters; they do not replace saved masks or measure 3D organoid volume.",
            "Area and area-equivalent diameter support anisotropic calibration; perimeter and fitted axes in µm require isotropic XY spacing. Pixel-edge centroids are sample indices plus 0.5."]}
