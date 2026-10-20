"""Reusable experimental layouts, acquisition metadata and explicit exclusion policy.

Layout slots create specimens, never observations; acquisition sessions describe
membership only. Neither feature turns images, fields or sessions into biological n.
"""
from __future__ import annotations

from _workbench_indexed import RecordList

from _workbench_indexed import image_index

import copy
import datetime
import hashlib
import re
import uuid

LIMITS = {"layouts": 100, "layoutVersions": 1000, "slots": 1000, "applications": 1000,
          "sessions": 1000, "sessionVersions": 4000, "exclusionEvents": 10000}
NOTES = ["One layout slot creates one biological specimen across every bound image field.",
         "Each application creates new specimen and plate identities. Subject/block reuse requires an explicit mapping; names are not matched.",
         "Layouts can be saved before images or inferentially sufficient specimens exist.",
         "Acquisition session membership never changes biological n or experimental assignments.",
         "Exclusion decisions are reasoned history, independent of archive visibility; historical reports remain unchanged."]


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def definition_schema():
    from _workbench_schema import _object, _ID
    from _workbench_statistics import definition_schema as statistical_schema
    base = statistical_schema()["properties"]
    text = {"type": "string", "minLength": 1, "maxLength": 200}
    well = {"type": "integer", "minimum": 1, "maximum": 100}
    slot = _object({"key": _ID, "name": text, "condition": text,
                    "role": {"type": "string", "enum": ["control", "treatment", "other"]},
                    "values": base["rows"]["items"]["properties"]["values"],
                    "subjectKey": _ID, "blockKey": _ID, "wellRow": well, "wellColumn": well},
                   ["key", "name", "condition", "role", "values"])
    return _object({"name": text, "factors": base["factors"],
                    "slots": {"type": "array", "items": slot, "minItems": 1, "maxItems": LIMITS["slots"]},
                    "plate": _object({"rows": well, "columns": well}, ["rows", "columns"]),
                    "notes": {"type": "string", "minLength": 0, "maxLength": 4000}},
                   ["name", "factors", "slots"])


def operations():
    from _workbench_schema import _object, _ID, _op
    from _workbench_statistics import definition_schema as statistical_schema
    text = {"type": "string", "minLength": 1, "maxLength": 200}
    notes = {"type": "string", "minLength": 0, "maxLength": 4000}
    ids = {"type": "array", "items": _ID, "maxItems": 1000}
    version = {"type": "integer", "minimum": 1, "maximum": LIMITS["sessionVersions"]}
    select = {"layoutId": _ID, "version": version}
    save = definition_schema(); save["properties"]["layoutId"] = _ID
    mapping = {"type": "array", "maxItems": 1000, "items": _object({"key": _ID, "id": _ID}, ["key", "id"])}
    apply = _object({**select, "instanceName": text, "experiment": text, "plateName": text,
                     "bindings": {"type": "array", "maxItems": 1000, "items":
                                  _object({"slotKey": _ID, "imageIds": ids, "field": text}, ["slotKey", "imageIds"])},
                     "subjectMapping": mapping, "blockMapping": mapping, "replaceAssignments": {"type": "boolean", "default": False}},
                    ["layoutId", "instanceName", "experiment", "bindings"])
    apply_run = copy.deepcopy(apply); apply_run["properties"]["previewFingerprint"] = _ID
    apply_run["required"].append("previewFingerprint")
    session = _object({"sessionId": _ID, "name": text, "instrument": text, "operator": text,
                       "startedAt": text, "endedAt": text, "imageIds": ids, "notes": notes},
                      ["name", "instrument", "imageIds"])
    return [
        _op("experiment.layout.catalogue", "Describe reusable layout slots, typed factors and explicit identity mapping.", _object(), project=False),
        _op("experiment.layout.save", "Append an immutable reusable experimental layout version, including drafts without images.", save, True),
        _op("experiment.layout.list", "List the latest layout versions.", _object()),
        _op("experiment.layout.get", "Read an exact retained layout version.", _object(select, ["layoutId"])),
        _op("experiment.layout.apply.preview", "Preview new biological specimens, optional plate and explicit assignment changes.", apply),
        _op("experiment.layout.apply.run", "Apply the exact preview as new specimen identities and retained typed factor rows.", apply_run, True),
        _op("experiment.layout.application.list", "List retained layout applications.", _object()),
        _op("experiment.layout.application.get", "Read a layout application and its assignment provenance.", _object({"applicationId": _ID}, ["applicationId"])),
        _op("experiment.layout.application.statistics", "Create a statistical definition draft from explicit layout factor and subject rows.",
            _object({"applicationId": _ID, "outcome": statistical_schema()["properties"]["outcome"], "name": text}, ["applicationId", "outcome"])),
        _op("acquisition.session.save", "Append explicit acquisition metadata and immutable source membership; does not change replicate identity.", session, True),
        _op("acquisition.session.list", "List current acquisition session versions.", _object()),
        _op("acquisition.session.get", "Read an exact acquisition session and its frozen source identities.",
            _object({"sessionId": _ID, "version": version}, ["sessionId"])),
        _op("experiment.exclusion.set", "Record or clear a reasoned specimen/field exclusion without changing archive visibility.",
            _object({"target": {"type": "string", "enum": ["specimen", "image"]}, "targetId": _ID,
                     "excluded": {"type": "boolean"}, "reason": {"type": "string", "minLength": 1, "maxLength": 2000}},
                    ["target", "targetId", "excluded", "reason"]), True),
        _op("experiment.exclusion.list", "Read effective exclusion decisions and their immutable history.", _object()),
    ]


def catalogue():
    return {"definitionSchema": definition_schema(), "limits": copy.deepcopy(LIMITS), "notes": list(NOTES)}


def normalize_definition(args):
    from _workbench_schema import validate_value
    from _workbench_statistics import normalize_definition as normalize_statistical
    value = {key: copy.deepcopy(args[key]) for key in definition_schema()["properties"] if key in args}
    validate_value(value, definition_schema())
    value["name"] = value["name"].strip(); value.setdefault("notes", "")
    normalized = normalize_statistical({"name": value["name"], "factors": value["factors"],
                                       "outcome": {"kind": "measurement", "metric": "count", "target": "plane"},
                                       "rows": [{"specimenId": slot["key"], "values": slot["values"]} for slot in value["slots"]]})
    value["factors"] = normalized["factors"]
    names, wells, roles = set(), set(), {}
    for slot in value["slots"]:
        for key in ("key", "name", "condition"):
            slot[key] = slot[key].strip()
        if slot["name"].casefold() in names:
            fail("duplicate-layout-slot", "Every slot requires a distinct specimen name within a layout.")
        names.add(slot["name"].casefold())
        if slot["condition"] in roles and roles[slot["condition"]] != slot["role"]:
            fail("condition-role-conflict", "Every slot of a condition must use the same role.")
        roles[slot["condition"]] = slot["role"]
        supplied = {key for key in ("wellRow", "wellColumn") if key in slot}
        if supplied:
            if len(supplied) != 2 or "plate" not in value:
                fail("incomplete-layout-well", "Slot wells require row, column and an explicit plate shape.")
            well = (slot["wellRow"], slot["wellColumn"])
            if well[0] > value["plate"]["rows"] or well[1] > value["plate"]["columns"] or well in wells:
                fail("invalid-layout-well", "Each slot well must be distinct and inside the declared plate.")
            wells.add(well)
    if len({slot["key"] for slot in value["slots"]}) != len(value["slots"]):
        fail("duplicate-layout-slot", "Slot keys must remain distinct after trimming whitespace.")
    return value


def _get(document, collection, identifier, version=None):
    records = [row for row in document.get(collection, []) if row["id"] == identifier and (version is None or row["version"] == version)]
    if not records:
        fail("experiment-record-not-found", "This saved layout, application or acquisition session version is unavailable.")
    return max(records, key=lambda row: row.get("version", 1))


def _latest(document, collection):
    result = {}
    for row in document.get(collection, []):
        if row["id"] not in result or row.get("version", 1) > result[row["id"]].get("version", 1):
            result[row["id"]] = row
    return list(result.values())


def _compact(document, collection, record):
    value = {key: copy.deepcopy(record[key]) for key in ("id", "version", "name", "hash", "createdAt", "revision", "layoutRef", "instanceName", "experiment", "instrument", "startedAt", "endedAt") if key in record}
    if collection in ("experimentLayouts", "acquisitionSessions"):
        value["latestVersion"] = _get(document, collection, record["id"])["version"]
    if collection == "experimentLayouts":
        value["slotCount"] = len(record["definition"]["slots"])
    if collection == "experimentApplications":
        value["specimenCount"] = len(record["newSpecimens"]); value["imageCount"] = len(record["assignments"])
    if collection == "acquisitionSessions":
        value["imageCount"] = len(record["members"])
    return value


def effective_exclusions(document):
    current = {}
    for item in document.get("experimentExclusions", []):
        current[(item["target"], item["targetId"])] = item
    return {target: {identifier: copy.deepcopy(item) for (kind, identifier), item in current.items()
                     if kind == target and item["excluded"]} for target in ("image", "specimen")}


def inspect_records(document):
    return {"experimentLayouts": [_compact(document, "experimentLayouts", row) for row in _latest(document, "experimentLayouts")],
            "experimentApplications": [_compact(document, "experimentApplications", row) for row in document.get("experimentApplications", [])],
            "acquisitionSessions": [_compact(document, "acquisitionSessions", row) for row in _latest(document, "acquisitionSessions")],
            "experimentExclusions": effective_exclusions(document)}


def _mapping(args, key, slots, application_id):
    source_key = "subjectKey" if key == "subjectMapping" else "blockKey"
    required = {slot[source_key] for slot in slots if source_key in slot}
    supplied = args.get(key, [])
    mapping = {item["key"]: item["id"] for item in supplied}
    if len(mapping) != len(supplied) or set(mapping) - required:
        fail("invalid-layout-mapping", "Subject/block mappings must use distinct declared keys.")
    if len(set(mapping.values())) != len(mapping):
        fail("ambiguous-layout-mapping", "Distinct layout subject/block keys cannot map to one identity; declare shared keys in the layout instead.")
    return {item: mapping.get(item, str(uuid.uuid5(uuid.UUID(application_id), source_key + ":" + item))) for item in sorted(required)}


def preview(document, args):
    from _workbench_experiments import apply, describe
    layout = _get(document, "experimentLayouts", args["layoutId"], args.get("version"))
    name, experiment = args["instanceName"].strip(), args["experiment"].strip()
    if any(row["instanceName"].casefold() == name.casefold() and row["experiment"].casefold() == experiment.casefold()
           for row in document.get("experimentApplications", [])):
        fail("duplicate-layout-application", "Use a new instance name; an application with this name already exists in this experiment.")
    if len(document.get("experimentApplications", [])) >= LIMITS["applications"]:
        fail("experiment-layout-limit", "This project has reached its retained layout application limit.")
    application_id = str(uuid.uuid5(uuid.NAMESPACE_URL, digest({"project": document["id"], "layout": layout["hash"], "name": name, "experiment": experiment})))
    definition = layout["definition"]; slots = {row["key"]: row for row in definition["slots"]}
    subject = _mapping(args, "subjectMapping", slots.values(), application_id)
    block = _mapping(args, "blockMapping", slots.values(), application_id)
    images = image_index(document)
    bound, binding_rows = set(), {}
    for row in args["bindings"]:
        if row["slotKey"] not in slots or row["slotKey"] in binding_rows:
            fail("invalid-layout-binding", "Each binding must identify a distinct declared slot.")
        if len(set(row["imageIds"])) != len(row["imageIds"]) or bound.intersection(row["imageIds"]) or set(row["imageIds"]) - set(images):
            fail("invalid-layout-binding", "Every bound image must exist and may appear in only one layout slot.")
        bound.update(row["imageIds"]); binding_rows[row["slotKey"]] = row
    design = describe(document)
    replaced = [row for row in design["assignments"] if row["imageId"] in bound]
    if replaced and not args.get("replaceAssignments", False):
        fail("layout-assignment-conflict", "Some selected images are assigned already. Preview with replaceAssignments:true to explicitly review their reassignment.", {"assignments": replaced})
    # Use the canonical design engine on a narrow preview copy, not a second assignment implementation.
    draft = {"images": [{"id": identifier} for identifier in images], "experimentalDesign": design}
    plate = None
    if "plate" in definition:
        plate = {"id": str(uuid.uuid5(uuid.UUID(application_id), "plate")), "name": args.get("plateName", name).strip(), **definition["plate"]}
        apply(draft, "plate.set", {key: value for key, value in plate.items() if key != "id"})
        draft["experimentalDesign"]["plates"][-1]["id"] = plate["id"]
    elif "plateName" in args:
        fail("layout-has-no-plate", "plateName requires a plate shape in the saved layout.")
    new_specimens, assignments, rows = [], [], []
    if bound:
        apply(draft, "image.unassign", {"imageIds": sorted(bound)})
    for key, slot in slots.items():
        identifier = str(uuid.uuid5(uuid.UUID(application_id), "specimen:" + key))
        specimen = {"id": identifier, "name": name + " / " + slot["name"], "experiment": experiment,
                    "condition": slot["condition"], "role": slot["role"]}
        if len(specimen["name"]) > 200:
            fail("layout-name-too-long", "The instance and slot name together must fit within 200 characters.")
        apply(draft, "specimen.set", {key: value for key, value in specimen.items() if key != "id"})
        draft["experimentalDesign"]["specimens"][-1]["id"] = identifier
        new_specimens.append(specimen)
        row = {"specimenId": identifier, "values": copy.deepcopy(slot["values"])}
        for source_key, target_key, mapping in (("subjectKey", "subjectId", subject), ("blockKey", "blockId", block)):
            if source_key in slot:
                row[target_key] = mapping[slot[source_key]]
        rows.append(row)
        binding = binding_rows.get(key)
        if not binding or not binding["imageIds"]:
            continue
        assign = {"imageIds": binding["imageIds"], "specimenId": identifier}
        if "field" in binding: assign["field"] = binding["field"]
        if "wellRow" in slot:
            assign.update({"plateId": plate["id"], "wellRow": slot["wellRow"], "wellColumn": slot["wellColumn"]})
        apply(draft, "image.assign", assign)
        assignments.extend({"imageId": image_id, **{key: value for key, value in assign.items() if key != "imageIds"}} for image_id in sorted(binding["imageIds"]))
    plan = {"id": application_id, "layoutRef": {"id": layout["id"], "version": layout["version"], "hash": layout["hash"], "name": layout["name"]},
            "instanceName": name, "experiment": experiment, "newSpecimens": new_specimens, "newPlate": plate,
            "assignments": assignments, "replacedAssignments": replaced, "statisticsRows": rows, "factors": copy.deepcopy(definition["factors"]),
            "subjectMapping": [{"key": key, "id": value, "reused": key in {row["key"] for row in args.get("subjectMapping", [])}} for key, value in subject.items()],
            "blockMapping": [{"key": key, "id": value, "reused": key in {row["key"] for row in args.get("blockMapping", [])}} for key, value in block.items()],
            "sourceMembers": [{"imageId": identifier, "sourceHash": images[identifier]["sourceHash"], "sourcePath": images[identifier]["sourcePath"]} for identifier in sorted(bound)],
            "notes": list(NOTES)}
    return {"plan": plan, "previewFingerprint": digest({"projectId": document["id"], "revision": document["revision"], "plan": plan})}, draft["experimentalDesign"]


def _timestamp(value, key):
    if value is None:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError()
        return parsed
    except (ValueError, TypeError, AttributeError):
        fail("invalid-acquisition-time", key + " must be an explicit ISO8601 timestamp with timezone; import time is not substituted.")


def execute(store, document, operation, args, revision, actor):
    from _workbench_store import utc_now
    if operation == "experiment.layout.save":
        definition = normalize_definition(args)
        records = document.setdefault("experimentLayouts", [])
        identifier = args.get("layoutId")
        if len(records) >= LIMITS["layoutVersions"] or (not identifier and len(_latest(document, "experimentLayouts")) >= LIMITS["layouts"]):
            fail("experiment-layout-limit", "The project layout/version bound has been reached.")
        version = _get(document, "experimentLayouts", identifier)["version"] + 1 if identifier else 1
        record = {"id": identifier or str(uuid.uuid4()), "version": version, "name": definition["name"], "definition": definition,
                  "createdAt": utc_now(), "revision": revision, "actor": copy.deepcopy(actor)}
        record["hash"] = digest(record); records.append(record)
        return {"layout": copy.deepcopy(record)}
    if operation == "experiment.layout.list":
        return {"layouts": inspect_records(document)["experimentLayouts"]}
    if operation == "experiment.layout.get":
        record = _get(document, "experimentLayouts", args["layoutId"], args.get("version"))
        return {"layout": {**copy.deepcopy(record), "latestVersion": _get(document, "experimentLayouts", record["id"])["version"]}}
    if operation.startswith("experiment.layout.apply."):
        result, design = preview(document, args)
        if operation.endswith("preview"): return result
        if args["previewFingerprint"] != result["previewFingerprint"]:
            fail("layout-preview-changed", "The layout, assignments or project changed. Preview the application again.")
        record = {**result["plan"], "createdAt": utc_now(), "revision": revision, "actor": copy.deepcopy(actor), "previewFingerprint": result["previewFingerprint"]}
        record["hash"] = digest(record)
        document.setdefault("experimentApplications", []).append(record); document["experimentalDesign"] = design
        return {"application": copy.deepcopy(record), "design": copy.deepcopy(design)}
    if operation == "experiment.layout.application.list":
        return {"applications": inspect_records(document)["experimentApplications"]}
    if operation.startswith("experiment.layout.application."):
        application = _get(document, "experimentApplications", args["applicationId"])
        if operation.endswith("get"): return {"application": copy.deepcopy(application)}
        from _workbench_statistics import normalize_definition
        exclusions = effective_exclusions(document)["specimen"]
        definition = normalize_definition({"name": args.get("name", application["instanceName"]), "outcome": args["outcome"],
                                           "factors": application["factors"], "rows": application["statisticsRows"], "exclusions": []})
        return {"definition": definition, "applicationId": application["id"], "effectiveSpecimenExclusions":
                [exclusions[row["specimenId"]] for row in definition["rows"] if row["specimenId"] in exclusions],
                "notes": ["This draft uses current assignments when previewed by statistics.design.preview. Global exclusions are applied separately and remain reversible."]}
    if operation == "acquisition.session.save":
        records = document.setdefault("acquisitionSessions", [])
        identifier = args.get("sessionId")
        if len(records) >= LIMITS["sessionVersions"] or (not identifier and len(_latest(document, "acquisitionSessions")) >= LIMITS["sessions"]):
            fail("acquisition-session-limit", "The project acquisition session/version bound has been reached.")
        start = _timestamp(args.get("startedAt"), "startedAt"); end = _timestamp(args.get("endedAt"), "endedAt")
        if end is not None and (start is None or end < start):
            fail("invalid-acquisition-time", "endedAt requires startedAt and must not precede it.")
        images = image_index(document)
        if len(set(args["imageIds"])) != len(args["imageIds"]) or set(args["imageIds"]) - set(images):
            fail("invalid-acquisition-members", "Session image IDs must be distinct images in this project.")
        version = _get(document, "acquisitionSessions", identifier)["version"] + 1 if identifier else 1
        record = {"id": identifier or str(uuid.uuid4()), "version": version, "createdAt": utc_now(), "revision": revision,
                  "actor": copy.deepcopy(actor), **{key: args[key].strip() for key in ("name", "instrument", "operator", "startedAt", "endedAt", "notes") if key in args},
                  "members": [{"imageId": image_id, "sourceHash": images[image_id]["sourceHash"], "sourcePath": images[image_id]["sourcePath"]} for image_id in args["imageIds"]]}
        record["hash"] = digest(record); records.append(record)
        return {"session": copy.deepcopy(record)}
    if operation == "acquisition.session.list": return {"sessions": inspect_records(document)["acquisitionSessions"]}
    if operation == "acquisition.session.get": return {"session": copy.deepcopy(_get(document, "acquisitionSessions", args["sessionId"], args.get("version")))}
    if operation == "experiment.exclusion.set":
        collection = document["images"] if args["target"] == "image" else document.get("experimentalDesign", {}).get("specimens", [])
        if not any(row["id"] == args["targetId"] for row in collection):
            fail("exclusion-target-not-found", "The excluded specimen or field must exist in this project.")
        records = document.setdefault("experimentExclusions", [])
        if len(records) >= LIMITS["exclusionEvents"]: fail("exclusion-history-limit", "The project exclusion history bound has been reached.")
        record = {"id": str(uuid.uuid4()), **copy.deepcopy(args), "at": utc_now(), "revision": revision, "actor": copy.deepcopy(actor)}
        records.append(record)
        return {"exclusion": copy.deepcopy(record), "exclusions": effective_exclusions(document)}
    if operation == "experiment.exclusion.list":
        return {"exclusions": effective_exclusions(document), "history": copy.deepcopy(document.get("experimentExclusions", []))}
    fail("unknown-operation", "Unknown layout, acquisition session or exclusion operation.")


def artifact_references(document):
    return {row["sourcePath"]: row["sourceHash"] for key, member_key in (("experimentApplications", "sourceMembers"), ("acquisitionSessions", "members"))
            for record in document.get(key, []) for row in record.get(member_key, [])}


def validate_document(document):
    from _workbench_schema import validate_value
    images = {row["id"] for row in document["images"]}
    specimens = {row["id"] for row in document.get("experimentalDesign", {}).get("specimens", [])}
    for key, maximum in (("experimentLayouts", LIMITS["layoutVersions"]), ("experimentApplications", LIMITS["applications"]),
                         ("acquisitionSessions", LIMITS["sessionVersions"]), ("experimentExclusions", LIMITS["exclusionEvents"])):
        records = document.get(key, [])
        if not isinstance(records, (list, RecordList)) or len(records) > maximum:
            fail("invalid-experiment-package", "Experimental history exceeds its declared bounds.")
        keys = set()
        for record in records:
            identity = (record["id"], record.get("version", 1))
            if identity in keys or type(identity[1]) is not int or identity[1] < 1:
                fail("invalid-experiment-package", "Experimental records require unique identities and positive versions.")
            keys.add(identity)
            if key == "experimentLayouts":
                if normalize_definition(record["definition"]) != record["definition"]:
                    fail("invalid-experiment-package", "A saved layout is not normalized.")
            if key in ("experimentApplications", "acquisitionSessions", "experimentLayouts"):
                if digest({field: value for field, value in record.items() if field != "hash"}) != record["hash"]:
                    fail("invalid-experiment-package", "A retained experimental record does not match its exact history hash.")
            if key == "experimentApplications":
                layout = _get(document, "experimentLayouts", record["layoutRef"]["id"], record["layoutRef"]["version"])
                if layout["hash"] != record["layoutRef"]["hash"] or len(record["statisticsRows"]) != len(layout["definition"]["slots"]):
                    fail("invalid-experiment-package", "A layout application no longer matches its saved definition.")
                from _workbench_statistics import normalize_definition as normalize_statistics
                normalize_statistics({"name": record["instanceName"], "factors": record["factors"], "rows": record["statisticsRows"],
                                      "outcome": {"kind": "measurement", "target": "plane", "metric": "count"}})
                if record["factors"] != layout["definition"]["factors"]:
                    fail("invalid-experiment-package", "Application factors differ from the exact layout version.")
                for slot, row in zip(layout["definition"]["slots"], record["statisticsRows"]):
                    if row["values"] != slot["values"]:
                        fail("invalid-experiment-package", "Application values differ from the exact layout slot.")
                if {row["id"] for row in record["newSpecimens"]} != {row["specimenId"] for row in record["statisticsRows"]}:
                    fail("invalid-experiment-package", "Application specimens and typed factor rows differ.")
                if any(row["id"] not in specimens for row in record["newSpecimens"]):
                    fail("invalid-experiment-package", "A layout application references missing biological specimens.")
            if key in ("experimentApplications", "acquisitionSessions"):
                members = record.get("members", record.get("sourceMembers", []))
                if not isinstance(members, (list, RecordList)) or len(members) > 1000 or len({row["imageId"] for row in members}) != len(members):
                    fail("invalid-experiment-package", "Invalid acquisition membership list.")
                for member in members:
                    if member["imageId"] not in images or not re.fullmatch(r"[0-9a-f]{64}", member["sourceHash"]):
                        fail("invalid-experiment-package", "An acquisition membership has a missing image or invalid source identity.")
            if key == "acquisitionSessions":
                session_schema = next(row["inputSchema"] for row in operations() if row["name"] == "acquisition.session.save")
                validate_value({**{field: record[field] for field in session_schema["properties"] if field in record and field != "sessionId"},
                                "imageIds": [row["imageId"] for row in record["members"]]}, session_schema)
                start = _timestamp(record.get("startedAt"), "startedAt"); end = _timestamp(record.get("endedAt"), "endedAt")
                if end is not None and (start is None or end < start): fail("invalid-experiment-package", "Invalid retained acquisition timestamps.")
            if key == "experimentExclusions":
                schema = next(row["inputSchema"] for row in operations() if row["name"] == "experiment.exclusion.set")
                validate_value({field: record[field] for field in schema["properties"]}, schema)
                if record["targetId"] not in (images if record["target"] == "image" else specimens):
                    fail("invalid-experiment-package", "A retained exclusion references a missing target.")
