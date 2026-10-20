"""Explicit-time scratch-wound series over one common acquired source region.

A series is one repeated-measure observation. No image-order time inference,
registration, mask replacement or biological-replicate multiplication occurs.
"""
from __future__ import annotations

import copy
import csv
import hashlib
import io
import json
import math
import uuid

ENGINE_VERSION = "assay-series-1"
LIMITS = {"frames": 128, "pixelsPerFrame": 4_000_000, "totalPixels": 64_000_000,
          "runs": 1000, "reportBytes": 16 * 1024 ** 2}
FORMATS = [
    {"id": "results-json", "name": "Scratch-wound series and provenance", "extension": "json",
     "mediaType": "application/json", "description": "Every observation, explicit timestamp, common support, baseline and descriptive rate calculation."},
    {"id": "observations-csv", "name": "Scratch-wound observations", "extension": "csv",
     "mediaType": "text/csv", "description": "Ordered measured and missing observations; unknown measurements remain empty, with retained provenance."},
]
NOTES = [
    "The same field and spatial alignment are assumed explicitly; this operation does not register images or infer timestamps from file order.",
    "Every measured frame uses the same intersection of acquired support on the selected source grid. Unsupported fill is never measured as a wound.",
    "Gap areas are low-texture image estimates. Area change per second is not cell migration speed.",
    "Missing observations and unknown timestamps are retained. Fits and intervals identify exactly which known-time measured observations were used.",
    "This is one repeated-measure series, not one biological replicate per frame. Biological interpretation requires one coherent, nonexcluded specimen assignment.",
    "Normalized closure is (baseline gap area - current gap area) / baseline gap area; negative values are retained. Missing or zero baseline leaves normalized closure unknown.",
]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def definition_schema():
    from _workbench_schema import _object, _ID
    from _workbench_assays_specialist import catalog
    integer = {"type": "integer", "minimum": 0, "maximum": 1000000000}
    region = _object({key: {**integer, "minimum": 1 if key in ("width", "height") else 0}
                      for key in ("x", "y", "width", "height")}, ["x", "y", "width", "height"])
    selection = _object({"channel": {"type": "integer", "minimum": 0, "maximum": 31},
                         "zProjection": {"type": "string", "enum": ["max", "mean", "middle"]}}, ["channel", "zProjection"])
    frame = _object({"imageId": _ID, "sourceParameters": selection, "timeIndex": integer,
                     "timeSeconds": {"type": ["number", "null"], "minimum": -1e12, "maximum": 1e12}, "region": region,
                     "missingReason": {"type": "string", "minLength": 1, "maxLength": 1000}}, ["timeSeconds"])
    return _object({"assay": {"type": "string", "enum": ["scratch_wound"]},
                    "name": {"type": "string", "minLength": 1, "maxLength": 200},
                    "frames": {"type": "array", "items": frame, "minItems": 2, "maxItems": LIMITS["frames"]},
                    "baselineIndex": {"type": "integer", "minimum": 0, "maximum": LIMITS["frames"] - 1},
                    "parameters": next(item["parameters"] for item in catalog() if item["id"] == "scratch_wound")},
                   ["assay", "frames", "baselineIndex"])


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING
    base = definition_schema()
    fingerprint = {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    run_schema = copy.deepcopy(base); run_schema["properties"]["previewFingerprint"] = fingerprint
    run_schema["required"].append("previewFingerprint")
    return [
        _op("assay.series.catalogue", "Describe explicit-time scratch-wound series and common acquired-support limits.", _object(), project=False),
        _op("assay.series.preview", "Calculate a common-support scratch-wound series without saving it.", base),
        _op("assay.series.run", "Retain a reviewed series with exact sources, explicit timestamps and baseline.", run_schema, True),
        _op("assay.series.results", "Read saved series and source/assignment currentness.", _object({"runId": _ID})),
        _op("assay.series.recompute.preview", "Preview the same series definition against current sources and calibration.", _object({"runId": _ID}, ["runId"])),
        _op("assay.series.recompute.run", "Append a reviewed replacement series without rewriting prior results.",
            _object({"runId": _ID, "previewFingerprint": fingerprint}, ["runId", "previewFingerprint"]), True),
        _op("assay.series.export.catalogue", "Describe retained scratch-wound series export formats.", _object(), project=False),
        _op("assay.series.export", "Publish all retained series observations and their exact provenance.",
            _object({"runId": _ID, "format": {"type": "string", "enum": [row["id"] for row in FORMATS]},
                     "destination": _STRING}, ["runId", "format", "destination"]), True),
    ]


def normalize(arguments):
    from _workbench_schema import validate_value
    from _workbench_plugins import validate_parameters
    value = copy.deepcopy({key: item for key, item in arguments.items() if key != "previewFingerprint"})
    validate_value(value, definition_schema(), "series")
    value.setdefault("name", "Scratch-wound time series")
    value["parameters"] = validate_parameters({"parameters": definition_schema()["properties"]["parameters"]}, value.get("parameters"))
    if value["parameters"]["textureWindowPx"] % 2 != 1:
        fail("invalid-arguments", "Texture-window size must be an odd number of source pixels.")
    if value["baselineIndex"] >= len(value["frames"]):
        fail("invalid-baseline", "Choose a baseline observation from this series.")
    previous = None
    for frame in value["frames"]:
        time = frame["timeSeconds"]
        if time is not None:
            if previous is not None and time <= previous:
                fail("invalid-times", "Known timestamps must increase strictly in the explicit observation order.")
            previous = time
        if "imageId" in frame:
            if "missingReason" in frame or "sourceParameters" not in frame:
                fail("invalid-observation", "A measured observation needs sourceParameters and cannot also have missingReason.")
        elif "missingReason" not in frame or any(key in frame for key in ("sourceParameters", "timeIndex", "region")):
            fail("invalid-observation", "A missing observation needs missingReason and cannot specify an acquisition selection.")
    if not any("imageId" in frame for frame in value["frames"]):
        fail("missing-observations", "Select at least one acquired observation; missing records alone cannot define common support.")
    return value


def _specimen(document, image_ids):
    from _workbench_experiment_layouts import effective_exclusions
    design = document.get("experimentalDesign", {})
    assignments = {item["imageId"]: item["specimenId"] for item in design.get("assignments", [])}
    specimens = {item["id"]: item for item in design.get("specimens", [])}
    excluded = effective_exclusions(document)
    rows = [{"imageId": image_id, "specimenId": assignments.get(image_id),
             "imageExclusion": excluded["image"].get(image_id),
             "specimenExclusion": excluded["specimen"].get(assignments.get(image_id))}
            for image_id in sorted(set(image_ids))]
    ids = {row["specimenId"] for row in rows}
    coherent = len(ids) == 1 and None not in ids and next(iter(ids)) in specimens
    eligible = coherent and not any(row["imageExclusion"] or row["specimenExclusion"] for row in rows)
    return {"status": "coherent" if eligible else "excluded" if coherent else "unassigned" if ids == {None} else "mixed-or-incomplete",
            "inferentiallyEligible": bool(eligible), "biologicalN": 1 if eligible else None,
            "specimen": copy.deepcopy(specimens[next(iter(ids))]) if coherent else None,
            "assignments": rows, "note": "Repeated observations are not independent biological replicates."}


def _fit(frames, key, *, minimum_index=0):
    points = [row for row in frames if row["index"] >= minimum_index and row["timeSeconds"] is not None and row.get(key) is not None]
    omitted = [{"index": row["index"], "reason": "before-baseline" if row["index"] < minimum_index else
                "unknown-time" if row["timeSeconds"] is None else "missing-measurement"}
               for row in frames if row not in points]
    result = {"usedIndices": [row["index"] for row in points], "omitted": omitted,
              "slopePerSecond": None, "intercept": None, "timeOriginSeconds": points[0]["timeSeconds"] if points else None,
              "rSquared": None, "intervals": []}
    if len(points) < 2:
        return result
    origin = points[0]["timeSeconds"]
    xs = [row["timeSeconds"] - origin for row in points]; ys = [row[key] for row in points]
    xm, ym = math.fsum(xs) / len(xs), math.fsum(ys) / len(ys)
    sxx = math.fsum((x - xm) ** 2 for x in xs)
    if sxx <= 0 or not math.isfinite(sxx):
        fail("invalid-times", "Timestamp spacing cannot support a finite descriptive fit; use accurately resolved seconds.")
    slope = math.fsum((x - xm) * (y - ym) for x, y in zip(xs, ys)) / sxx
    intercept = ym - slope * xm
    if not math.isfinite(slope) or not math.isfinite(intercept):
        fail("invalid-times", "Timestamp spacing is too small for a finite descriptive rate; use accurately resolved seconds.")
    residual = math.fsum((y - (intercept + slope * x)) ** 2 for x, y in zip(xs, ys))
    total = math.fsum((y - ym) ** 2 for y in ys)
    result.update({"slopePerSecond": slope, "intercept": intercept,
                   "rSquared": max(0., 1. - residual / total) if total else None})
    for left, right in zip(points, points[1:]):
        dt = right["timeSeconds"] - left["timeSeconds"]
        rate = (right[key] - left[key]) / dt
        if not math.isfinite(rate):
            fail("invalid-times", "An interval is too short for a finite rate; correct its timestamp precision before calculating the series.")
        result["intervals"].append({"fromIndex": left["index"], "toIndex": right["index"], "elapsedSeconds": dt,
                                    "change": right[key] - left[key], "ratePerSecond": rate,
                                    "spansOmittedObservations": right["index"] != left["index"] + 1})
    return result


def calculate(store, document, arguments):
    import numpy as np
    import _workbench_imaging as imaging
    import _workbench_support as support
    from _workbench_indexed import image_index
    from _workbench_assays import _fingerprint, source_provenance
    from _workbench_assay_summary import _Context
    from _workbench_assays_specialist import compute
    from _workbench_volume import calibration
    value = normalize(arguments)
    images = image_index(document)
    resolved, dependencies, rows = [], [], []
    common = None; signature = None; total_pixels = 0; identities = set(); verified = {}
    for index, frame in enumerate(value["frames"]):
        row = {"index": index, "timeSeconds": frame["timeSeconds"], "status": "missing", "gapAreaPx": None,
               "gapAreaUm2": None, "gapFractionPct": None, "closureFraction": None, "gapAreaChangePx": None,
               "gapAreaChangeUm2": None, "missingReason": frame.get("missingReason")}
        rows.append(row)
        if "imageId" not in frame:
            continue
        image = images.get(frame["imageId"])
        if image is None:
            fail("image-not-found", "A selected scratch-wound acquisition no longer exists.")
        selected = frame["sourceParameters"]
        time = frame.get("timeIndex")
        if time is None and image.get("timeCount", 1) != 1:
            fail("time-required", "Every time-series source requires an explicit timeIndex; timestamps are separately declared in seconds.")
        time = 0 if time is None else time
        if time >= image.get("timeCount", 1) or selected["channel"] >= image["channels"]:
            fail("selection-out-of-range", "An observation's source channel or time index is outside its acquisition.")
        region = frame.get("region", {"x": 0, "y": 0, "width": image["width"], "height": image["height"]})
        x, y, width, height = [region[key] for key in ("x", "y", "width", "height")]
        if x + width > image["width"] or y + height > image["height"] or width * height > LIMITS["pixelsPerFrame"]:
            fail("series-region-limit", "Choose a source-bounded region of at most 4 million pixels for every observation.")
        total_pixels += width * height
        if total_pixels > LIMITS["totalPixels"]:
            fail("series-limit", "This series exceeds 64 million selected pixels. Use a smaller common region or fewer observations.")
        identity = digest({"source": image["sourceHash"], "time": time, "selection": selected, "region": region})
        if identity in identities:
            fail("duplicate-observation", "The same source bytes, time, channel/projection and region occur more than once; variants are not extra time points.")
        identities.add(identity)
        scale = calibration(image)
        provenance = source_provenance(document, image, {"parameters": selected}, {"target": "plane"})
        provenance["selection"].update({"timeIndex": time, "region": copy.deepcopy(region)})
        current_signature = {"width": image["width"], "height": image["height"], "region": region,
                             "spacing": [scale[axis] for axis in "yx"], "selection": selected,
                             "processing": _Context.frozen_processing_identity(provenance["processing"])}
        if signature is not None and signature != current_signature:
            fail("series-grid-mismatch", "Measured frames need the same XY grid, region, XY calibration, channel/projection and processing recipe. Register or prepare comparable acquisitions explicitly.")
        signature = current_signature
        key = (image["sourcePath"], image["sourceHash"])
        if key not in verified:
            verified[key] = store.verify_artifact(*key)
        valid = support.load(store, image, (image["height"], image["width"]), selected)
        region_mask = np.ones((height, width), dtype=bool) if valid is None else valid[y:y + height, x:x + width]
        common = region_mask.copy() if common is None else (common & region_mask)
        dependency = {"imageId": image["id"], "target": "plane", "rawSourceOnly": True,
                      "sourceParameters": copy.deepcopy(selected), "timeIndex": time, "region": copy.deepcopy(region),
                      "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"], "sourceProvenance": provenance}
        dependency["fingerprint"] = _fingerprint(image, dependency)
        if support.descriptor(image):
            dependency.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
        dependencies.append(dependency)
        frame["timeIndex"] = time; frame["region"] = copy.deepcopy(region)
        row.update({"imageId": image["id"], "name": image["name"], "sourceHash": image["sourceHash"],
                    "sourceParameters": copy.deepcopy(selected), "timeIndex": time, "region": copy.deepcopy(region),
                    "acquiredSamples": int(region_mask.sum()), "selectedSamples": width * height,
                    "unsupportedSamples": width * height - int(region_mask.sum())})
        resolved.append((index, image, verified[key], region, selected, time))
    crop = support.rectangular_crop(common)
    common_count = int(common.sum())
    common_region = {"x": signature["region"]["x"] + crop[1].start, "y": signature["region"]["y"] + crop[0].start,
                     "width": crop[1].stop - crop[1].start, "height": crop[0].stop - crop[0].start}
    spacing = signature["spacing"]
    common_info = {"shape": list(common.shape), "samples": common_count, "selectedSamples": int(common.size),
                   "fraction": common_count / common.size, "sourceRegion": common_region,
                   "sha256": hashlib.sha256(np.asarray(common, dtype=np.uint8).tobytes()).hexdigest(),
                   "areaUm2": common_count * math.prod(spacing) if all(item is not None for item in spacing) else None,
                   "policy": "intersection-of-all-measured-frames; rectangular-supported-filter-boundary"}
    last_path = None; array = None; metadata = None
    for index, image, path, region, selected, time in resolved:
        if path != last_path:
            # Release the preceding decoded source before allocating the next.
            array = None
            metadata = imaging.inspect_source(path)
            array = imaging.load_array(path, metadata)
            last_path = path
        raw = imaging.plane_from_array(array, metadata, selected, time_index=time)
        y, x = common_region["y"], common_region["x"]
        cropped = raw[y:y + common_region["height"], x:x + common_region["width"]]
        result = compute("scratch_wound", value["parameters"], raw=cropped, spacing=spacing)
        rows[index].update(result["summary"])
        rows[index].update({"status": "measured", "missingReason": None, "commonSamples": common_count,
                            "excludedAcquiredSamples": rows[index]["acquiredSamples"] - common_count,
                            "measuredFractionOfRequestedROI": common_count / rows[index]["selectedSamples"],
                            "measuredSourceRegion": copy.deepcopy(common_region),
                            "message": result.get("message")})
        if result.get("gapBoundsPx"):
            a, b, c, d = result["gapBoundsPx"]
            rows[index]["gapBoundsPx"] = [a + x, b + y, c + x, d + y]
        del raw, cropped
    baseline_row = rows[value["baselineIndex"]]
    baseline = {"index": value["baselineIndex"], "status": "missing" if baseline_row["gapAreaPx"] is None else
                "zero" if baseline_row["gapAreaPx"] == 0 else "available", "gapAreaPx": baseline_row["gapAreaPx"],
                "gapAreaUm2": baseline_row["gapAreaUm2"], "timeSeconds": baseline_row["timeSeconds"]}
    for row in rows:
        if row["gapAreaPx"] is not None and baseline["gapAreaPx"] is not None:
            row["gapAreaChangePx"] = row["gapAreaPx"] - baseline["gapAreaPx"]
            if baseline["gapAreaUm2"] is not None:
                row["gapAreaChangeUm2"] = row["gapAreaUm2"] - baseline["gapAreaUm2"]
            if baseline["gapAreaPx"] > 0:
                row["closureFraction"] = (baseline["gapAreaPx"] - row["gapAreaPx"]) / baseline["gapAreaPx"]
    rates = {"gapAreaPx": _fit(rows, "gapAreaPx"), "gapAreaUm2": _fit(rows, "gapAreaUm2"),
             "closureFraction": _fit(rows, "closureFraction", minimum_index=value["baselineIndex"]),
             "units": {"gapAreaPx": "px2/s", "gapAreaUm2": "um2/s", "closureFraction": "1/s"},
             "method": "ordinary least squares of known-time measured points; closure fit uses baseline and later observations"}
    specimen = _specimen(document, [row["imageId"] for row in dependencies])
    output = {"assay": "scratch_wound", "name": value["name"], "parameters": value["parameters"],
              "baselineIndex": value["baselineIndex"], "frames": rows, "commonSupport": common_info,
              "baseline": baseline, "rates": rates, "specimen": specimen, "dependencies": dependencies,
              "intensityUnits": provenance["processing"]["intensityUnits"], "engineVersion": ENGINE_VERSION,
              "inputFingerprint": digest({"dependencies": dependencies, "specimen": specimen}), "notes": copy.deepcopy(NOTES)}
    output["previewFingerprint"] = digest({"projectId": document["id"], "revision": document["revision"],
                                          "definition": value, "inputFingerprint": output["inputFingerprint"],
                                          "commonSupport": common_info, "engineVersion": ENGINE_VERSION})
    return value, output


def current(document, run):
    from _workbench_assays import _current
    return (_current(document, run) and _specimen(document, [item["imageId"] for item in run["dependencies"]]) == run["specimen"])


def describe(document, run):
    return {key: copy.deepcopy(value) for key, value in run.items() if key not in ("outputPath", "dependencies", "arguments")} | {
        "outputsCurrent": current(document, run), "imageIds": list(dict.fromkeys(item["imageId"] for item in run["dependencies"]))}


def _find(document, identifier):
    result = next((row for row in document.get("assaySeriesRuns", []) if row["runId"] == identifier), None)
    if result is None:
        fail("series-not-found", "The selected scratch-wound series does not exist.")
    return result


def read_output(store, run):
    path = store.verify_artifact(run["outputPath"], run["outputHash"])
    if path.stat().st_size > LIMITS["reportBytes"]:
        fail("series-limit", "The retained series report exceeds its read limit.")
    return json.loads(path.read_text(encoding="utf-8"))


def execute(store, document, operation, arguments, revision, actor=None, *, calculated=None):
    from _workbench_store import canonical, utc_now
    if operation == "assay.series.catalogue":
        return {"definitionSchema": definition_schema(), "limits": LIMITS, "notes": NOTES}
    if operation == "assay.series.export.catalogue":
        return {"formats": FORMATS}
    if operation == "assay.series.results":
        if "runId" in arguments:
            run = _find(document, arguments["runId"])
            return {"run": describe(document, run), "output": read_output(store, run)}
        return {"runs": [describe(document, run) for run in document.get("assaySeriesRuns", [])], "limits": LIMITS}
    previous = _find(document, arguments["runId"]) if operation.startswith("assay.series.recompute.") else None
    value, output = calculated if calculated is not None else calculate(store, document, previous["arguments"] if previous else arguments)
    if operation.endswith(".preview"):
        return {"preview": output}
    if arguments.get("previewFingerprint") != output["previewFingerprint"]:
        fail("preview-changed", "Sources, settings, assignments or project revision changed. Preview the series again before saving.")
    if len(document.get("assaySeriesRuns", [])) >= LIMITS["runs"]:
        fail("series-limit", "This project already retains 1,000 scratch-wound series runs.")
    encoded = canonical(output).encode()
    if len(encoded) > LIMITS["reportBytes"]:
        fail("series-limit", "The complete series provenance exceeds 16 MiB.")
    path, checksum = store.put_bytes(encoded, ".assay-series.json")
    run = {"runId": str(uuid.uuid4()), "name": value["name"], "assay": "scratch_wound", "engineVersion": ENGINE_VERSION,
           "arguments": value, "parameters": value["parameters"], "frameCount": len(value["frames"]),
           "measuredCount": sum(row["status"] == "measured" for row in output["frames"]),
           "baselineIndex": value["baselineIndex"], "dependencies": output["dependencies"],
           "specimen": output["specimen"], "inputFingerprint": output["inputFingerprint"],
           "createdAt": utc_now(), "revision": revision, "actor": copy.deepcopy(actor),
           "outputPath": path, "outputHash": checksum, "reexecution": {"operation": "assay.series.run", "arguments": copy.deepcopy(value)}}
    if previous:
        run["predecessorRunId"] = previous["runId"]
    document.setdefault("assaySeriesRuns", []).append(run)
    return {"run": describe(document, run), "output": output}


def artifact_references(document):
    refs = {}
    for run in document.get("assaySeriesRuns", []):
        refs[run["outputPath"]] = run["outputHash"]
        for item in run["dependencies"]:
            for prefix in ("source", "support"):
                if prefix + "Path" in item:
                    refs[item[prefix + "Path"]] = item[prefix + "Hash"]
    return refs


def validate_document(document):
    from _workbench_indexed import image_index
    images = image_index(document)
    runs = document.get("assaySeriesRuns", [])
    from _workbench_indexed import RecordList
    if not isinstance(runs, (list, RecordList)) or len(runs) > LIMITS["runs"]:
        fail("invalid-series-package", "Series records exceed the retained limit.")
    identifiers = set()
    for run in runs:
        if not isinstance(run, dict) or not isinstance(run.get("runId"), str) or run["runId"] in identifiers:
            fail("invalid-series-package", "Series identifiers must be unique.")
        identifiers.add(run["runId"])
        value = normalize(run.get("arguments", {}))
        dependencies = run.get("dependencies")
        measured = [frame for frame in value["frames"] if "imageId" in frame]
        if not isinstance(dependencies, list) or len(dependencies) != len(measured):
            fail("invalid-series-package", "Series dependencies do not match the explicit observations.")
        for frame, dependency in zip(measured, dependencies):
            if (not isinstance(dependency, dict) or dependency.get("imageId") != frame["imageId"] or frame["imageId"] not in images or
                    dependency.get("sourceParameters") != frame["sourceParameters"] or dependency.get("timeIndex") != frame.get("timeIndex") or
                    dependency.get("region") != frame.get("region") or dependency.get("rawSourceOnly") is not True):
                fail("invalid-series-package", "A retained series selection or source dependency is inconsistent.")
        for key in ("outputHash", "inputFingerprint"):
            value_hash = run.get(key)
            if not isinstance(value_hash, str) or len(value_hash) != 64 or any(c not in "0123456789abcdef" for c in value_hash):
                fail("invalid-series-package", "A retained series hash is malformed.")
        if not isinstance(run.get("outputPath"), str) or not isinstance(run.get("specimen"), dict):
            fail("invalid-series-package", "A retained series is missing its report or specimen binding.")


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_exports import _destination, _stage_publication, _csv_safe, MAX_EXPORTS
    from _workbench_store import canonical, utc_now
    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "This project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    run = _find(document, arguments["runId"]); output = read_output(store, run)
    provenance = {"schemaVersion": 1, "engineVersion": ENGINE_VERSION, "exportId": str(uuid.uuid4()),
                  "projectId": document["id"], "sourceRevision": document["revision"], "exportRevision": revision,
                  "runId": run["runId"], "outputHash": run["outputHash"], "inputFingerprint": run["inputFingerprint"],
                  "outputsCurrent": current(document, run), "format": definition["id"], "createdAt": utc_now(),
                  "requestId": request_id, "actor": copy.deepcopy(actor), "notes": NOTES}
    provenance_path, provenance_hash = store.put_bytes(canonical(provenance).encode(), ".assay-series-provenance.json")
    if definition["id"] == "results-json":
        contents = canonical({"schemaVersion": 1, "format": "cellcounter-assay-series", "run": describe(document, run),
                              "output": output, "provenance": provenance, "provenanceSha256": provenance_hash}).encode()
    else:
        stream = io.StringIO(newline=""); writer = csv.writer(stream)
        fields = ["index", "timeSeconds", "status", "imageId", "name", "sourceHash", "timeIndex", "gapAreaPx", "gapAreaUm2",
                  "gapFractionPct", "closureFraction", "gapAreaChangePx", "gapAreaChangeUm2", "acquiredSamples", "commonSamples", "missingReason"]
        writer.writerow(["runId", *fields, "selection_json", "common_support_json", "provenance_sha256"])
        for row in output["frames"]:
            values = [run["runId"], *[row.get(key) for key in fields],
                      canonical({key: row.get(key) for key in ("sourceParameters", "region")}), canonical(output["commonSupport"]), provenance_hash]
            writer.writerow([_csv_safe(item) for item in values])
        contents = stream.getvalue().encode()
    if len(contents) > LIMITS["reportBytes"]:
        fail("series-limit", "The exported series report exceeds 16 MiB.")
    path, checksum = store.put_bytes(contents, ".assay-series-export." + definition["extension"])
    references = artifact_references({"assaySeriesRuns": [run]})
    item = {"exportId": provenance["exportId"], "kind": "assay-series", "runId": run["runId"],
            "createdAt": provenance["createdAt"], "revision": revision, "destination": str(destination),
            "filePath": path, "fileHash": checksum, "provenancePath": provenance_path, "provenanceHash": provenance_hash,
            "reportPath": run["outputPath"], "reportHash": run["outputHash"], "bytes": len(contents), "mediaType": definition["mediaType"],
            "inputReferences": [{"path": key, "hash": value} for key, value in sorted(references.items())]}
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {"exportId": item["exportId"], "destination": str(destination), "sha256": checksum, "format": definition["id"],
            "mediaType": definition["mediaType"], "bytes": len(contents), "runId": run["runId"], "provenance": provenance}, publish, temporary, publication
