"""Authored model cards and reversible future-selection defaults.

Cards are immutable evidence snapshots, not certifications. A default never
grants executable trust and never changes saved analyses or workflow versions.
"""
from __future__ import annotations

import copy
import hashlib
import re
import uuid

MAX_CARDS = 1000
MAX_EVENTS = 1000


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def operations():
    from _workbench_schema import _object, _op, _ID
    text = lambda size: {"type": "string", "maxLength": size}
    return [
        _op("model.card.save", "Retain an immutable authored model card with exact model and evaluation identities.",
            _object({"modelId": _ID, "intendedUse": text(4000), "limitations": text(8000), "notes": text(4000),
                     "evaluationIds": {"type": "array", "maxItems": 100, "items": _ID}},
                    ["modelId", "intendedUse", "limitations"]), True),
        _op("model.card.get", "Read an authored model card version and its current identity status.",
            _object({"modelId": _ID, "version": {"type": "integer", "minimum": 1}}, ["modelId"])),
        _op("model.card.list", "Read the latest compact authored card for each registered model.", _object()),
        _op("model.activation.set", "Set or clear the future model-selection default without enabling code or changing past outputs.",
            _object({"modelId": {"type": ["string", "null"], "minLength": 1, "maxLength": 200},
                     "reason": {"type": "string", "minLength": 1, "maxLength": 2000}}, ["modelId", "reason"]), True),
        _op("model.activation.get", "Read the future-selection default and its reversible decision history.", _object()),
    ]


def _records(document, model_id):
    return [row for row in document.get("modelCards", []) if row["modelId"] == model_id]


def _binding_current(document, binding):
    from _workbench_models import prediction_binding
    model = next((row for row in document.get("models", []) if row["id"] == binding.get("modelId")), None)
    return model is not None and prediction_binding(model) == binding


def describe(document, card, compact=False):
    result = copy.deepcopy(card)
    result["inputsCurrent"] = _binding_current(document, card["modelBinding"])
    result["latestVersion"] = max(row["version"] for row in _records(document, card["modelId"]))
    if compact:
        return {key: result[key] for key in ("id", "modelId", "version", "name", "hash", "createdAt", "createdRevision", "inputsCurrent", "latestVersion")}
    return result


def activation(document):
    records = document.get("modelActivations", [])
    if not records:
        return {"modelId": None, "available": False, "bindingCurrent": True}
    last = records[-1]
    identity = last["modelId"]
    model = next((row for row in document.get("models", []) if row["id"] == identity), None)
    current = identity is None or _binding_current(document, last["modelBinding"])
    return {"modelId": identity, "available": bool(model and model.get("enabled") and current),
            "bindingCurrent": current, "reason": last["reason"], "eventId": last["id"],
            "at": last["createdAt"], "modelBinding": copy.deepcopy(last.get("modelBinding")),
            "notes": ["This is a future-selection preference, not authorization to execute.",
                      "A disabled or rebound model must be explicitly trusted and selected again; no fallback model is substituted."]}


def execute(store, document, operation, args, revision, actor):
    from _workbench_models import _model, prediction_binding
    from _workbench_store import utc_now
    if operation == "model.activation.get":
        return {"activation": activation(document), "history": copy.deepcopy(list(document.get("modelActivations", [])))}
    if operation == "model.activation.set":
        if len(document.get("modelActivations", [])) >= MAX_EVENTS:
            _fail("model-activation-limit", "This project has reached its 1,000 retained default-selection decisions.")
        reason = args["reason"].strip()
        if not reason: _fail("reason-required", "Record a reason for changing the future default.")
        model = _model(document, args["modelId"]) if args["modelId"] is not None else None
        if model and not model.get("enabled"):
            _fail("model-disabled", "Explicitly enable this trusted model before selecting it as a future default.")
        record = {"id": str(uuid.uuid4()), "modelId": args["modelId"], "reason": reason,
                  "modelBinding": prediction_binding(model) if model else None,
                  "createdAt": utc_now(), "createdRevision": revision, "actor": copy.deepcopy(actor)}
        record["hash"] = _digest(record)
        document.setdefault("modelActivations", []).append(record)
        return {"activation": activation(document)}
    if operation == "model.card.list":
        latest = {}
        for row in document.get("modelCards", []): latest[row["modelId"]] = row
        return {"cards": [describe(document, row, compact=True) for row in latest.values()]}
    model = _model(document, args["modelId"])
    records = _records(document, model["id"])
    if operation == "model.card.get":
        card = next((row for row in records if row["version"] == args["version"]), None) if "version" in args else records[-1] if records else None
        if "version" in args and card is None: _fail("model-card-not-found", "This model has no retained card with that version.")
        return {"card": describe(document, card) if card else None, "cards": [describe(document, row, compact=True) for row in records]}
    if operation != "model.card.save": _fail("unknown-operation", "Unsupported model card operation.")
    if len(document.get("modelCards", [])) >= MAX_CARDS:
        _fail("model-card-limit", "This project has reached its 1,000 immutable model-card versions.")
    selected = args.get("evaluationIds", [])
    if len(set(selected)) != len(selected): _fail("duplicate-evaluation", "Choose each retained evaluation once.")
    references = []
    for dataset in document.get("adaptationDatasets", []):
        for evaluation in dataset.get("evaluations", []):
            if evaluation["id"] not in selected: continue
            roles = [role for role in ("baseline", "candidate") if evaluation.get("choices", {}).get(role, {}).get("modelId") == model["id"]]
            if not roles: _fail("evaluation-model-mismatch", "A selected comparison did not evaluate this registered model.")
            for role in roles:
                references.append({"evaluationId": evaluation["id"], "datasetId": dataset["id"],
                                   "datasetFingerprint": dataset["fingerprint"], "role": role,
                                   "binding": copy.deepcopy(evaluation["bindings"][role])})
    if set(selected) != {row["evaluationId"] for row in references}:
        _fail("evaluation-not-found", "A selected comparison is not retained in this project.")
    record = {"id": str(uuid.uuid4()), "modelId": model["id"], "name": model["name"], "version": len(records) + 1,
              "intendedUse": args["intendedUse"], "limitations": args["limitations"], "notes": args.get("notes", ""),
              "evaluations": references, "modelBinding": prediction_binding(model), "training": copy.deepcopy(model.get("training")),
              "createdAt": utc_now(), "createdRevision": revision, "actor": copy.deepcopy(actor)}
    record["hash"] = _digest(record)
    document.setdefault("modelCards", []).append(record)
    return {"card": describe(document, record)}


def artifact_references(document):
    # Card/evaluation identities refer to registered models and frozen datasets;
    # their owning modules retain the actual artifacts.
    return {}


def validate_document(document):
    from _workbench_indexed import RecordList
    for key, maximum in (("modelCards", MAX_CARDS), ("modelActivations", MAX_EVENTS)):
        records = document.get(key, [])
        if not isinstance(records, (list, RecordList)) or len(records) > maximum:
            _fail("invalid-package", "Retained model-card or default-selection history exceeds its bound.")
        seen = set()
        for record in records:
            if not isinstance(record, dict) or not isinstance(record.get("id"), str) or record["id"] in seen:
                _fail("invalid-package", "A model-card or activation identity is invalid or duplicated.")
            seen.add(record["id"])
            if not isinstance(record.get("hash"), str) or not re.fullmatch("[0-9a-f]{64}", record["hash"]) or _digest({k: v for k, v in record.items() if k != "hash"}) != record["hash"]:
                _fail("invalid-package", "A model-card or activation record failed its immutable identity check.")
            if key == "modelCards":
                if type(record.get("version")) is not int or record["version"] < 1 or not isinstance(record.get("modelBinding"), dict):
                    _fail("invalid-package", "A model-card version or binding is invalid.")
                for field, limit in (("intendedUse", 4000), ("limitations", 8000), ("notes", 4000)):
                    if not isinstance(record.get(field), str) or len(record[field]) > limit:
                        _fail("invalid-package", "A model-card authored field exceeds its bound.")
