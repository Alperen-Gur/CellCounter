"""Experimental organization and descriptive, equally weighted replicate summaries.

Images and objects are observations within a biological specimen. They are never
counted as independent biological replicates.
"""
from __future__ import annotations

from _workbench_indexed import image_index

import copy
import hashlib
import json
import statistics
import uuid

def operations():
    def obj(properties=None, required=()):
        return {"type": "object", "properties": properties or {},
                "required": list(required), "additionalProperties": False}

    text = {"type": "string", "minLength": 1, "maxLength": 200}
    ids = {"type": "array", "items": text, "minItems": 1, "maxItems": 1000}
    number = {"type": "integer", "minimum": 1, "maximum": 100}
    schemas = [
        ("experiment.get", "Read specimens, plates and image assignments.", obj(), False),
        ("specimen.set", "Create or update a biological specimen and its experiment and condition.",
         obj({"specimenId": text, "name": text, "experiment": text, "condition": text,
              "role": {"type": "string", "enum": ["control", "treatment", "other"]}},
             ["name", "experiment", "condition", "role"]), True),
        ("plate.set", "Create or update a plate layout without invalidating assigned wells.",
         obj({"plateId": text, "name": text, "rows": number, "columns": number},
             ["name", "rows", "columns"]), True),
        ("image.assign", "Assign images to one biological specimen and optionally a plate well.",
         obj({"imageIds": ids, "specimenId": text, "plateId": text,
              "wellRow": number, "wellColumn": number, "field": text},
             ["imageIds", "specimenId"]), True),
        ("image.unassign", "Remove experimental assignments without deleting images or analyses.",
         obj({"imageIds": ids}, ["imageIds"]), True),
        ("experiment.summary", "Summarize complete biological specimens with equal weight per specimen.",
         obj(), False),
    ]
    return [{"name": name, "description": description, "inputSchema": schema,
             "mutating": mutating, "requiresProject": True}
            for name, description, schema, mutating in schemas]


def describe(document):
    design = document.get("experimentalDesign", {})
    return {key: copy.deepcopy(design.get(key, []))
            for key in ("specimens", "plates", "assignments")}


def _find(items, identifier, entity):
    from _workbench_schema import WorkbenchError
    from _workbench_indexed import RecordList
    if isinstance(items, RecordList):
        value = items.find(identifier)
        if value is not None: return value
        raise WorkbenchError(f"{entity}-not-found", f"The selected {entity} is not part of this project.")
    for item in items:
        if item["id"] == identifier:
            return item
    raise WorkbenchError(f"{entity}-not-found", f"The selected {entity} is not part of this project.")


def apply(document, operation, arguments):
    from _workbench_schema import WorkbenchError
    design = describe(document)
    specimens, plates, assignments = (design[key] for key in ("specimens", "plates", "assignments"))
    if operation == "specimen.set":
        identifier = arguments.get("specimenId")
        if identifier:
            _find(specimens, identifier, "specimen")
        value = {key: arguments[key].strip() for key in ("name", "experiment", "condition", "role")}
        value["id"] = identifier or str(uuid.uuid4())
        for existing in specimens:
            if existing["id"] == value["id"]:
                continue
            if (existing["experiment"].casefold(), existing["name"].casefold()) == (
                    value["experiment"].casefold(), value["name"].casefold()):
                raise WorkbenchError("duplicate-specimen", "A specimen with this name already exists in this experiment.")
            if (existing["experiment"], existing["condition"]) == (value["experiment"], value["condition"]):
                if existing["role"] != value["role"]:
                    raise WorkbenchError("condition-role-conflict", "All specimens in the same condition must have the same control/treatment role.")
        design["specimens"] = [item for item in specimens if item["id"] != value["id"]] + [value]
        if len(design["specimens"]) > 1000:
            raise WorkbenchError("design-too-large", "A project supports up to 1,000 biological specimens.")
    elif operation == "plate.set":
        identifier = arguments.get("plateId")
        if identifier:
            _find(plates, identifier, "plate")
        value = {key: arguments[key] for key in ("name", "rows", "columns")}
        value["name"] = value["name"].strip()
        value["id"] = identifier or str(uuid.uuid4())
        if any(item["name"].casefold() == value["name"].casefold() and item["id"] != value["id"] for item in plates):
            raise WorkbenchError("duplicate-plate", "A plate with this name already exists.")
        if any(item.get("plateId") == value["id"] and (
                item["wellRow"] > value["rows"] or item["wellColumn"] > value["columns"]) for item in assignments):
            raise WorkbenchError("assigned-well-outside-plate", "The new plate size would exclude an assigned well.")
        design["plates"] = [item for item in plates if item["id"] != value["id"]] + [value]
        if len(design["plates"]) > 100:
            raise WorkbenchError("design-too-large", "A project supports up to 100 plates.")
    elif operation in ("image.assign", "image.unassign"):
        identifiers = set(arguments["imageIds"])
        images = image_index(document)
        if any(identifier not in images for identifier in identifiers):
            raise WorkbenchError("image-not-found", "Every assigned image must belong to this project.")
        from _workbench_indexed import RecordList
        if isinstance(assignments, RecordList):
            for identifier in identifiers: assignments.remove_identity(identifier)
        else: design["assignments"] = [item for item in assignments if item["imageId"] not in identifiers]
        if operation == "image.assign":
            _find(specimens, arguments["specimenId"], "specimen")
            value = {key: arguments[key] for key in (
                "specimenId", "plateId", "wellRow", "wellColumn", "field") if key in arguments}
            well_keys = {"plateId", "wellRow", "wellColumn"}
            supplied = well_keys.intersection(value)
            if supplied and supplied != well_keys:
                raise WorkbenchError("incomplete-well", "A well requires a plate, row and column together.")
            if supplied:
                plate = _find(plates, value["plateId"], "plate")
                if value["wellRow"] > plate["rows"] or value["wellColumn"] > plate["columns"]:
                    raise WorkbenchError("well-outside-plate", "The selected well is outside the plate.")
                for assignment in design["assignments"]:
                    if all(assignment.get(key) == value[key] for key in well_keys):
                        if assignment["specimenId"] != value["specimenId"]:
                            raise WorkbenchError("well-specimen-conflict", "A well cannot belong to two biological specimens.")
            if "field" in value:
                value["field"] = value["field"].strip()
            design["assignments"].extend(
                {"imageId": identifier, **value} for identifier in sorted(identifiers))
        value = {"imageIds": sorted(identifiers)}
    else:
        raise WorkbenchError("unknown-operation", "Unknown experiment operation.")
    document["experimentalDesign"] = design
    if len(design["assignments"]) > 1000:
        # The mutation remains usable in a large library without returning all
        # memberships. Complete, revision-bound membership is paged separately.
        selected = set(arguments.get("imageIds", []))
        from _workbench_indexed import RecordList
        rows = design["assignments"]
        affected = [row for identifier in sorted(selected) if (row := rows.find(identifier)) is not None] if isinstance(rows, RecordList) else [row for row in rows if row["imageId"] in selected]
        return {**value, "design": {"specimens": copy.deepcopy(design["specimens"]), "plates": copy.deepcopy(design["plates"]), "assignments": affected},
                "designPartial": True, "assignmentCount": len(rows)}
    return {**value, "design": copy.deepcopy(design), "designPartial": False, "assignmentCount": len(design["assignments"])}


def _mean(values):
    return statistics.fmean(values) if values else None


def summarize(document):
    design = describe(document)
    images = image_index(document)
    assignment_map = {item["imageId"]: item["specimenId"] for item in design["assignments"]}
    from _workbench_experiment_layouts import effective_exclusions
    policy = effective_exclusions(document)
    rows = []
    for specimen in design["specimens"]:
        assigned = [image for identifier, image in images.items()
                    if assignment_map.get(identifier) == specimen["id"]]
        excluded_fields = [image["id"] for image in assigned if image["id"] in policy["image"]]
        assigned = [image for image in assigned if image["id"] not in policy["image"]]
        included = specimen["id"] not in policy["specimen"]
        analyzed = [image for image in assigned if image.get("analysis")]
        from _workbench_volume import xy_calibrated
        calibrated = [image for image in analyzed if xy_calibrated(image)]
        counts = [len(image["analysis"]["cells"]) for image in analyzed]
        cells = [cell for image in analyzed for cell in image["analysis"]["cells"]]
        physical_cells = [cell for image in calibrated for cell in image["analysis"]["cells"]]
        complete = bool(assigned) and len(assigned) == len(analyzed)
        physical_complete = complete and len(calibrated) == len(analyzed)
        rows.append({
            **specimen, "included": included, "exclusionReason": policy["specimen"].get(specimen["id"], {}).get("reason"),
            "excludedImageIds": excluded_fields, "fieldExclusions": [policy["image"][identifier] for identifier in excluded_fields], "imageCount": len(assigned), "analyzedImageCount": len(analyzed),
            "calibratedImageCount": len(calibrated), "complete": complete,
            "physicalComplete": physical_complete, "objectCount": len(cells),
            "meanObjectsPerImage": _mean(counts),
            "meanObjectAreaPx": _mean([cell["areaPx"] for cell in cells]),
            "meanObjectAreaUm2": _mean([cell["areaUm2"] for cell in physical_cells]) if physical_complete else None,
            "meanObjectIntensity": _mean([cell["meanIntensity"] for cell in cells]),
        })
    groups = []
    keys = sorted({(row["experiment"], row["condition"]) for row in rows})
    for experiment, condition in keys:
        members = [row for row in rows if (row["experiment"], row["condition"]) == (experiment, condition)]
        complete = [row for row in members if row["complete"] and row["included"]]
        counts = [row["meanObjectsPerImage"] for row in complete]
        physical = [row["meanObjectAreaUm2"] for row in complete if row["meanObjectAreaUm2"] is not None]
        groups.append({
            "experiment": experiment, "condition": condition, "role": members[0]["role"],
            "specimenCount": len(members), "biologicalN": len(complete),
            "excludedIncompleteSpecimens": sum(row["included"] and not row["complete"] for row in members),
            "excludedByPolicySpecimens": sum(not row["included"] for row in members),
            "meanObjectsPerImage": _mean(counts),
            "sdObjectsPerImage": statistics.stdev(counts) if len(counts) >= 2 else None,
            "meanObjectAreaUm2": _mean(physical), "physicalBiologicalN": len(physical),
            "specimenIds": [row["id"] for row in members],
        })
    fingerprint_source = {
        "design": design, "exclusions": policy,
        "images": [{"id": image["id"], "inputFingerprint": image.get("analysis", {}).get("inputFingerprint")}
                   for image in document["images"]],
    }
    fingerprint = hashlib.sha256(json.dumps(
        fingerprint_source, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()
    return {
        "projectId": document["id"], "sourceRevision": document["revision"],
        "inputFingerprint": fingerprint, "specimens": rows, "conditions": groups, "effectiveExclusions": policy,
        "unassignedImageCount": len(set(images) - set(assignment_map)),
        "aggregation": "equal-weight-complete-biological-specimens",
        "notes": [
            "Biological n counts complete specimens, not images or objects.",
            "Incomplete specimens and explicitly excluded specimens are listed but excluded from condition aggregates.",
            "Reasoned field exclusions remove only those fields from specimen inputs; archive visibility never implies exclusion.",
            "Physical specimen metrics require every assigned image to be analyzed and calibrated.",
            "Counts per image are descriptive and are not normalized for field area or sampling design.",
        ],
    }
