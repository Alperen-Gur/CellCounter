"""Guided annotation, immutable specimen splits and paired held-out evaluation."""
from __future__ import annotations

import copy
import hashlib
import io
import uuid

MAX_SAMPLES = 200
MAX_FROZEN_BYTES = 512 * 1024 ** 2
MAX_DATASETS = 100
MAX_EVALUATIONS = 100


def operations():
    from _workbench_schema import _object, _ID, _op
    from _workbench_plugins import parameter_values_schema
    ids = {"type": "array", "items": _ID, "minItems": 1, "maxItems": MAX_SAMPLES}
    model = _object({"pluginId": _ID, "modelId": _ID, "parameters": parameter_values_schema()})
    return [
        _op("adaptation.reference.set", "Approve or revoke the current 2D mask as an explicitly reviewed reference.",
            _object({"imageId": _ID, "approved": {"type": "boolean"},
                     "note": {"type": "string", "maxLength": 2000}}, ["imageId", "approved"]), True),
        _op("adaptation.suggest", "Suggest representative and heuristic difficult images, excluding held-out specimens.",
            _object({"imageIds": ids, "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                     "excludedSpecimenIds": {"type": "array", "items": _ID, "maxItems": MAX_SAMPLES}})),
        _op("adaptation.dataset.create", "Freeze approved raw planes and exact references with explicit specimen-disjoint splits.",
            _object({"name": {"type": "string", "maxLength": 200}, "imageIds": ids,
                     "validationSpecimenIds": ids, "testSpecimenIds": ids,
                     "inputChannels": {"type": "array", "minItems": 1, "maxItems": 3, "uniqueItems": True,
                                       "items": {"type": "integer", "minimum": 0, "maximum": 65535}}},
                    ["name", "imageIds", "validationSpecimenIds", "testSpecimenIds"]), True),
        _op("adaptation.dataset.list", "List immutable adaptation datasets and evaluation summaries.", _object()),
        _op("adaptation.dataset.get", "Inspect dataset samples, specimen partitions and reference freshness.",
            _object({"datasetId": _ID}, ["datasetId"])),
        _op("adaptation.evaluate.preview", "Check exact frozen channel compatibility and model identities without executing inference.",
            _object({"datasetId": _ID, "baseline": model, "candidate": model}, ["datasetId", "baseline", "candidate"])),
        {**_op("adaptation.evaluate", "Run two enabled segmenters on the same frozen held-out specimens; never changes analysis masks.",
            _object({"datasetId": _ID, "baseline": model, "candidate": model,
                     "previewFingerprint": {"type": "string", "pattern": "^[0-9a-f]{64}$"}},
                    ["datasetId", "baseline", "candidate"]), True), "usesExecutableCode": True},
    ]


def fail(code, message):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message)


def _digest(value):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def _image(document, image_id):
    from _workbench_core import _image
    return _image(document, image_id)


def _assignment(document, image_id):
    from _workbench_indexed import RecordList
    design = document.get("experimentalDesign", {})
    rows = design.get("assignments", [])
    assignment = rows.find(image_id) if isinstance(rows, RecordList) else next((item for item in rows if item["imageId"] == image_id), None)
    if not assignment: return None
    rows = design.get("specimens", [])
    return rows.find(assignment["specimenId"]) if isinstance(rows, RecordList) else next((item for item in rows if item["id"] == assignment["specimenId"]), None)


def _reference_current(image):
    reference = image.get("adaptationReference")
    analysis = image.get("analysis")
    return bool(reference and reference["approved"] and analysis and
                reference["inputFingerprint"] == analysis["inputFingerprint"])


def _approve(store, document, args, actor):
    from _workbench_core import _current_analysis
    from _workbench_store import utc_now
    image = _image(document, args["imageId"])
    analysis = _current_analysis(store, image)
    reference = {"approved": args["approved"], "inputFingerprint": analysis["inputFingerprint"],
                 "labelsPath": analysis["labelsPath"], "labelsHash": analysis["labelsHash"],
                 "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
                 "parameters": copy.deepcopy(analysis["parameters"]), "reviewer": copy.deepcopy(actor),
                 "note": args.get("note"), "at": utc_now()}
    image["adaptationReference"] = reference
    return {"imageId": image["id"], "reference": copy.deepcopy(reference), "current": _reference_current(image)}


def _suggest(store, document, args):
    import numpy as np
    from _workbench_core import _source
    from _workbench_schema import analysis_parameters
    chosen = args.get("imageIds", [item["id"] for item in document["images"]])
    if len(chosen) > MAX_SAMPLES:
        fail("selection-too-large", "Choose at most 200 candidate images.")
    if len(chosen) != len(set(chosen)):
        fail("invalid-selection", "Candidate images must be distinct.")
    excluded = set(args.get("excludedSpecimenIds", []))
    held_out_sources = set()
    # Once a test split is frozen, its specimens remain outside annotation
    # recommendations. Their explicit dataset references can still be inspected.
    for dataset in document.get("adaptationDatasets", []):
        excluded.update(sample["specimenId"] for sample in dataset["samples"] if sample["partition"] == "test")
        held_out_sources.update(sample["sourceHash"] for sample in dataset["samples"] if sample["partition"] == "test")
    rows, features = [], []
    skipped = []
    for image_id in chosen:
        image = _image(document, image_id)
        specimen = _assignment(document, image_id)
        reason = ("held-out-specimen" if (specimen and specimen["id"] in excluded) or image["sourceHash"] in held_out_sources else
                  "time-series-requires-volume-adaptation" if image.get("timeCount", 1) > 1 else None)
        if reason:
            skipped.append({"imageId": image_id, "reason": reason})
            continue
        params = image.get("analysis", {}).get("parameters") or analysis_parameters({})
        raw = _source(store, image, params)
        # Bounded, deterministic source sampling: suggestions do not segment or
        # pretend the heuristic is a calibrated model uncertainty estimate.
        sample = raw[::max(1, raw.shape[0] // 128), ::max(1, raw.shape[1] // 128)].astype(float)
        low, median, high = np.percentile(sample, [10, 50, 90])
        contrast = float(high - low)
        spread = float(np.std(sample))
        analysis = image.get("analysis")
        cells = analysis["cells"] if analysis else []
        areas = np.array([cell["areaPx"] for cell in cells], dtype=float)
        variation = float(areas.std() / areas.mean()) if len(areas) and areas.mean() else 0.
        difficulty = float(1 / (1 + contrast / max(abs(float(median)), 1.)) + min(variation, 4) / 4)
        rows.append({"imageId": image_id, "name": image["name"], "specimenId": specimen["id"] if specimen else None,
                     "referenceCurrent": _reference_current(image), "difficultyScore": difficulty,
                     "reason": "Low relative contrast and heterogeneous object sizes are annotation heuristics."})
        features.append([float(median), contrast, spread, len(cells) / max(1, raw.size), variation])
    if not rows:
        return {"suggestions": [], "skipped": skipped, "method": "deterministic-diversity-and-heuristic-difficulty"}
    matrix = np.asarray(features, dtype=float)
    scale = matrix.std(axis=0)
    scale[scale == 0] = 1
    matrix = (matrix - matrix.mean(axis=0)) / scale
    selected = []
    remaining = set(range(len(rows)))
    target = min(args.get("limit", 12), len(rows))
    while remaining and len(selected) < target:
        if not selected or len(selected) % 2 == 0:
            index = min(remaining, key=lambda i: (-rows[i]["difficultyScore"], rows[i]["imageId"]))
            strategy = "heuristic-difficulty"
        else:
            index = min(remaining, key=lambda i: (
                -min(float(np.sum((matrix[i] - matrix[j]) ** 2)) for j in selected), rows[i]["imageId"]))
            strategy = "feature-diversity"
        selected.append(index)
        remaining.remove(index)
        rows[index]["selectionReason"] = strategy
    return {"suggestions": [rows[index] for index in selected], "skipped": skipped,
            "method": "deterministic-diversity-and-heuristic-difficulty",
            "notes": ["Scores are heuristics, not probabilities of segmentation error.",
                      "Frozen test specimens are excluded; image candidates remain distinct from biological replicates."]}


def _encoded(array):
    import numpy as np
    output = io.BytesIO()
    np.save(output, array, allow_pickle=False)
    return output.getvalue()


def _create_dataset(store, document, args, revision):
    import numpy as np
    from _workbench_core import _current_analysis, _labels, _source
    from _workbench_store import utc_now
    selected = args["imageIds"]
    if len(document.get("adaptationDatasets", [])) >= MAX_DATASETS:
        fail("dataset-limit", "At most 100 frozen datasets are retained in one project.")
    requested_channels = args.get("inputChannels")
    if requested_channels is not None and (not 1 <= len(requested_channels) <= 3 or len(set(requested_channels)) != len(requested_channels)):
        fail("invalid-input-channels", "Choose one to three distinct acquired channel indices.")
    validation, test = set(args["validationSpecimenIds"]), set(args["testSpecimenIds"])
    if len(selected) != len(set(selected)) or validation & test:
        fail("split-overlap", "Images must be distinct and validation/test specimens must not overlap.")
    pending, seen_sources, represented = [], set(), set()
    for image_id in selected:
        image = _image(document, image_id)
        analysis = _current_analysis(store, image)
        if not _reference_current(image):
            fail("reference-required", "Every selected image needs approval of its current mask.")
        if requested_channels is not None and (analysis["parameters"]["channel"] not in requested_channels or any(type(channel) is not int or not 0 <= channel < image["channels"] for channel in requested_channels)):
            fail("incompatible-input-channels", "Every sample must acquire the selected channels, including the channel of its approved reference mask.")
        specimen = _assignment(document, image_id)
        if not specimen:
            fail("specimen-required", "Assign every selected image to its biological specimen first.")
        if image["sourceHash"] in seen_sources:
            fail("duplicate-source", "An adaptation dataset must not repeat identical source content.")
        seen_sources.add(image["sourceHash"])
        represented.add(specimen["id"])
        partition = "test" if specimen["id"] in test else "validation" if specimen["id"] in validation else "train"
        pending.append((image, analysis, specimen, partition))
    if not (validation | test) <= represented or {item[3] for item in pending} != {"train", "validation", "test"}:
        fail("invalid-split", "Choose represented validation and test specimens, leaving at least one training specimen.")
    # Existing held-out specimens cannot enter a subsequent training or
    # validation split without making the claimed holdout invalid.
    previous_test = {sample["specimenId"] for dataset in document.get("adaptationDatasets", [])
                     for sample in dataset["samples"] if sample["partition"] == "test"}
    previous_sources = {sample["sourceHash"] for dataset in document.get("adaptationDatasets", [])
                        for sample in dataset["samples"] if sample["partition"] == "test"}
    if any((specimen["id"] in previous_test or image["sourceHash"] in previous_sources) and partition != "test"
           for image, _, specimen, partition in pending):
        fail("held-out-leakage", "A previously held-out specimen cannot be moved into training or validation.")
    samples, frozen_bytes = [], 0
    for image, analysis, specimen, partition in pending:
        import _workbench_support as support
        raw = _source(store, image, analysis["parameters"])
        labels = np.asarray(_labels(store, image), dtype=np.uint32)
        valid = support.load(store, image, raw.shape, analysis["parameters"])
        region = support.rectangular_crop(valid) if valid is not None else (slice(0, raw.shape[0]), slice(0, raw.shape[1]))
        raw = raw[region]
        labels = labels[region]
        frozen_bytes += raw.nbytes + labels.nbytes
        if frozen_bytes > MAX_FROZEN_BYTES:
            fail("dataset-byte-limit", "Frozen input planes and references exceed 512 MiB. Select fewer or smaller reference regions.")
        raw_path, raw_hash = store.put_bytes(_encoded(raw), ".adaptation.npy")
        labels_path, labels_hash = store.put_bytes(_encoded(labels), ".adaptation-labels.npy")
        sample = {
            "imageId": image["id"], "name": image["name"], "specimenId": specimen["id"],
            "specimen": copy.deepcopy(specimen), "partition": partition,
            "sourcePath": image["sourcePath"], "sourceHash": image["sourceHash"],
            "rawPath": raw_path, "rawHash": raw_hash, "labelsPath": labels_path,
            "labelsHash": labels_hash, "shape": list(labels.shape),
            "sourceLabelsPath": analysis["labelsPath"], "sourceLabelsHash": analysis["labelsHash"],
            "supportRegion": {"x": region[1].start, "y": region[0].start,
                              "width": region[1].stop - region[1].start, "height": region[0].stop - region[0].start},
            "rawSupportComplete": True,
            "parameters": copy.deepcopy(analysis["parameters"]),
            "inputFingerprint": analysis["inputFingerprint"], "reference": copy.deepcopy(image["adaptationReference"]),
        }
        if support.descriptor(image):
            sample.update({"supportPath": support.descriptor(image)["path"],
                           "supportHash": support.descriptor(image)["hash"],
                           "supportFingerprint": support.fingerprint(image)})
        if requested_channels is not None:
            channels = []
            for channel in requested_channels:
                selection = {**analysis["parameters"], "channel": channel}
                if channel == analysis["parameters"]["channel"]:
                    reference, digest = raw_path, raw_hash
                else:
                    acquired = _source(store, image, selection)
                    acquired_valid = support.load(store, image, acquired.shape, selection)
                    if (valid is None) != (acquired_valid is None) or (valid is not None and not np.array_equal(valid, acquired_valid)):
                        fail("dataset-support-mismatch", "All frozen acquired channels must have identical source-grid support.")
                    acquired = acquired[region]
                    if acquired.shape != labels.shape:
                        fail("dataset-channel-grid", "All frozen acquired channels must match the exact reference grid.")
                    frozen_bytes += acquired.nbytes
                    if frozen_bytes > MAX_FROZEN_BYTES:
                        fail("dataset-byte-limit", "Frozen input planes and references exceed 512 MiB. Select fewer or smaller reference regions.")
                    reference, digest = store.put_bytes(_encoded(acquired), ".adaptation.npy")
                channels.append({"channel": channel, "rawPath": reference, "rawHash": digest,
                                 "shape": list(labels.shape), "sourceSelection": {"channel": channel, "zProjection": selection["zProjection"]}})
            sample["inputChannels"] = channels
        samples.append(sample)
    dataset = {"id": str(uuid.uuid4()), "name": args["name"], "createdAt": utc_now(),
               "sourceRevision": document["revision"], "createdRevision": revision, "samples": samples,
               "dimension": 2, "split": "explicit-specimen-disjoint", "evaluations": [], "frozenBytes": frozen_bytes}
    if requested_channels is not None: dataset["inputChannels"] = list(requested_channels)
    dataset["fingerprint"] = _digest({key: value for key, value in dataset.items() if key != "evaluations"})
    document.setdefault("adaptationDatasets", []).append(dataset)
    return {"dataset": describe(document, dataset)}


def _dataset(document, dataset_id):
    dataset = next((item for item in document.get("adaptationDatasets", []) if item["id"] == dataset_id), None)
    if dataset is None:
        fail("dataset-not-found", "The selected adaptation dataset does not exist.")
    expected = _digest({key: value for key, value in dataset.items() if key not in ("evaluations", "fingerprint")})
    if expected != dataset["fingerprint"]:
        fail("dataset-changed", "The immutable adaptation dataset failed its fingerprint check.")
    import _workbench_support as support
    for sample in dataset["samples"]:
        image = _image(document, sample["imageId"])
        if (support.descriptor(image) and sample["sourceHash"] == image["sourceHash"]
                and not sample.get("rawSupportComplete")):
            fail("legacy-unsupported-dataset", "This frozen dataset predates support exclusion. Create a new supported dataset before evaluation or training.")
    return dataset


def describe(document, dataset, detail=True):
    result = copy.deepcopy(dataset)
    for sample in result["samples"]:
        image = _image(document, sample["imageId"])
        sample["currentReference"] = bool(_reference_current(image) and
                                          sample["inputFingerprint"] == image["analysis"]["inputFingerprint"])
    result["counts"] = {part: sum(sample["partition"] == part for sample in dataset["samples"])
                        for part in ("train", "validation", "test")}
    if not detail:
        result["samples"] = [{key: sample[key] for key in
                               ("imageId", "name", "specimenId", "partition", "currentReference")} | {
                                   "availableChannels": [item["channel"] for item in _frozen_channels(sample)]}
                              for sample in result["samples"]]
        result["evaluations"] = [{key: value for key, value in evaluation.items() if key not in ("images", "compatibility")}
                                 for evaluation in result["evaluations"]]
    return result


def _load_array(store, sample, path_key, hash_key):
    import numpy as np
    path = store.verify_artifact(sample[path_key], sample[hash_key])
    array = np.load(path, mmap_mode="r", allow_pickle=False)
    if list(array.shape) != sample["shape"] or array.ndim != 2 or array.size > imaging.MAX_PIXELS:
        fail("invalid-dataset", "Frozen sample dimensions do not match their manifest.")
    if path_key == "labelsPath" and array.dtype != np.uint32:
        fail("invalid-dataset", "Frozen references must be uint32 instance labels.")
    if not np.isfinite(array).all():
        fail("invalid-dataset", "Frozen samples must contain finite values.")
    return array


def _frozen_channels(sample):
    return sample.get("inputChannels", [{"channel": sample["parameters"]["channel"], "rawPath": sample["rawPath"],
                                        "rawHash": sample["rawHash"], "shape": sample["shape"],
                                        "sourceSelection": {key: sample["parameters"][key] for key in ("channel", "zProjection")}}])


def evaluation_preview(store, document, args):
    import _workbench_plugins as plugins
    import _workbench_models as models
    from _workbench_schema import WorkbenchError
    dataset = _dataset(document, args["datasetId"])
    tests = [sample for sample in dataset["samples"] if sample["partition"] == "test"]
    choices, bindings, blockers, rows = {}, {}, [], []
    for role in ("baseline", "candidate"):
        value = args[role]
        try:
            if ("modelId" in value) == ("pluginId" in value):
                fail("evaluation-choice", "Choose exactly one registered model or segmentation plugin per comparison role.")
            if "modelId" in value:
                record = models._model(document, value["modelId"])
                params = models.parameters_for_model(record, value.get("parameters"))
                if not record.get("enabled"): fail("model-disabled", "Explicitly enable the trusted registered model before comparison.")
                choices[role] = {"modelId": record["id"], "parameters": params}
                bindings[role] = models.prediction_binding(record)
            else:
                record = plugins._record(document, value["pluginId"])
                if not record.get("enabled"): fail("plugin-disabled", "Explicitly enable the trusted segmentation plugin before comparison.")
                if record["manifest"]["kind"] != "segmentation" or 2 not in record["manifest"]["supportedDimensions"]:
                    fail("unsupported-plugin-kind", "Frozen plane evaluation requires a two-dimensional segmentation plugin.")
                choices[role] = {"pluginId": value["pluginId"], "parameters": plugins.validate_parameters(record["manifest"], value.get("parameters"))}
                import _workbench_runtimes as runtimes
                bindings[role] = {"pluginId": value["pluginId"], "packageHash": record["packageHash"],
                                  "runtime": runtimes.identity(runtimes.resolve(package_hash=record["packageHash"]))}
        except WorkbenchError as error:
            blockers.append({"code": error.code, "message": error.message, "role": role})
    for sample in tests:
        available = [item["channel"] for item in _frozen_channels(sample)]
        row = {"imageId": sample["imageId"], "name": sample["name"], "specimenId": sample["specimenId"],
               "primaryChannel": sample["parameters"]["channel"], "availableChannels": available, "requiredChannels": {}}
        for role, value in choices.items():
            try:
                required = (models.input_channels(models._model(document, value["modelId"]), value["parameters"], row["primaryChannel"])
                            if "modelId" in value else [row["primaryChannel"]])
                row["requiredChannels"][role] = required
                if not set(required) <= set(available):
                    blockers.append({"code": "frozen-channel-missing", "message": "Create a new dataset with these explicit acquired input channels; existing frozen samples are never extended from live acquisitions.",
                                     "role": role, "imageId": sample["imageId"], "requiredChannels": required, "availableChannels": available})
            except WorkbenchError as error:
                blockers.append({"code": error.code, "message": error.message, "role": role, "imageId": sample["imageId"]})
        rows.append(row)
    if len(dataset.get("evaluations", [])) >= MAX_EVALUATIONS:
        blockers.append({"code": "evaluation-limit", "message": "This immutable dataset has reached its 100 retained comparison limit."})
    result = {"ready": not blockers, "blockers": blockers, "datasetId": dataset["id"], "datasetFingerprint": dataset["fingerprint"],
              "choices": choices, "bindings": bindings, "samples": rows, "biologicalTestN": len({sample["specimenId"] for sample in tests}),
              "notes": ["Compatibility reads metadata only; it does not execute or probe either interpreter.",
                        "Only exact frozen acquired planes are compared. Extra channels are never read from mutable project sources.",
                        "External model training history cannot be established; repeated held-out evaluation can influence model selection."]}
    result["previewFingerprint"] = _digest({"projectId": document["id"], "revision": document["revision"], **result})
    return result


def _evaluate(store, document, args, revision):
    import _workbench_plugins as plugins
    from _workbench_metrics import evaluate_masks, aggregate_metrics
    from _workbench_store import utc_now
    import _workbench_models as models
    import numpy as np
    preview = evaluation_preview(store, document, args)
    if not preview["ready"]:
        from _workbench_schema import WorkbenchError
        raise WorkbenchError("evaluation-incompatible", "Resolve frozen input compatibility before running this comparison.", {"blockers": preview["blockers"]})
    if args.get("previewFingerprint", preview["previewFingerprint"]) != preview["previewFingerprint"]:
        fail("preview-changed", "The comparison inputs or project changed. Preview compatibility again before execution.")
    dataset = _dataset(document, args["datasetId"])
    samples = [sample for sample in dataset["samples"] if sample["partition"] == "test"]
    per_image = []
    for sample in samples:
        raw = _load_array(store, sample, "rawPath", "rawHash")
        truth = _load_array(store, sample, "labelsPath", "labelsHash")
        reports, provenances, artifacts = {}, {}, {}
        for role in ("baseline", "candidate"):
            choice = preview["choices"][role]
            if "modelId" in choice:
                required = models.input_channels(models._model(document, choice["modelId"]), choice["parameters"], sample["parameters"]["channel"])
                frozen = {item["channel"]: item for item in _frozen_channels(sample)}
                planes = [_load_array(store, frozen[channel], "rawPath", "rawHash") for channel in required]
                pixels = planes[0] if len(planes) == 1 else np.stack(planes, axis=-1)
                prediction, provenance = models.predict(store, document, choice["modelId"], pixels, choice["parameters"])
                provenance["frozenInputChannels"] = [copy.deepcopy(frozen[channel]) for channel in required]
            else:
                prediction, provenance = plugins.predict(store, document, choice["pluginId"], raw, choice.get("parameters", {}))
            reports[role] = evaluate_masks([prediction], [truth], allow_empty_reference=True)
            provenances[role] = provenance
            labels_path, labels_hash = store.put_bytes(_encoded(prediction), ".prediction.npy")
            artifacts[role] = {"labelsPath": labels_path, "labelsHash": labels_hash}
        per_image.append({"imageId": sample["imageId"], "specimenId": sample["specimenId"],
                          **reports, "provenance": provenances, "predictions": artifacts})
    first = aggregate_metrics([item["baseline"] for item in per_image])
    second = aggregate_metrics([item["candidate"] for item in per_image])
    result = {"id": str(uuid.uuid4()), "datasetId": dataset["id"], "datasetFingerprint": dataset["fingerprint"],
              "createdAt": utc_now(), "revision": revision, "baseline": first, "candidate": second,
              "choices": copy.deepcopy(preview["choices"]), "bindings": copy.deepcopy(preview["bindings"]),
              "compatibility": preview, "inputSource": "immutable-dataset-artifacts",
              "delta": {key: second[key] - first[key] for key in ("ap50", "f1", "precision", "recall", "meanDiamError")},
              "images": per_image, "biologicalTestN": len({sample["specimenId"] for sample in samples}),
              "evaluationNumber": len(dataset["evaluations"]) + 1,
              "notes": ["Paired descriptive metrics on frozen held-out references; no statistical superiority claim.",
                        "The application cannot establish the training history of externally supplied models or plugins.",
                        "Repeated test-set inspection can influence later model selection; evaluation count is retained."]}
    dataset["evaluations"].append(result)
    return {"evaluation": result}


def artifact_references(document):
    references = {}
    for image in document["images"]:
        reference = image.get("adaptationReference")
        if reference:
            references.update({reference["sourcePath"]: reference["sourceHash"], reference["labelsPath"]: reference["labelsHash"]})
    for dataset in document.get("adaptationDatasets", []):
        for sample in dataset["samples"]:
            for prefix in ("source", "raw", "labels", "sourceLabels", "support"):
                if prefix + "Path" in sample:
                    references[sample[prefix + "Path"]] = sample[prefix + "Hash"]
            for channel in sample.get("inputChannels", []): references[channel["rawPath"]] = channel["rawHash"]
        for evaluation in dataset.get("evaluations", []):
            for image in evaluation["images"]:
                for prediction in image["predictions"].values():
                    references[prediction["labelsPath"]] = prediction["labelsHash"]
                for provenance in image.get("provenance", {}).values():
                    if provenance.get("environment"):
                        environment = provenance["environment"]
                        references[environment["inventoryPath"]] = environment["inventoryHash"]
    return references


def validate_document(document):
    """Validate additive frozen channel identities without executing a model."""
    import re
    from _workbench_indexed import RecordList
    datasets = document.get("adaptationDatasets", [])
    if not isinstance(datasets, (list, RecordList)) or len(datasets) > MAX_DATASETS:
        fail("invalid-package", "Frozen dataset collection exceeds its supported bound.")
    for dataset in datasets:
        if not isinstance(dataset, dict) or not isinstance(dataset.get("samples"), list) or not 1 <= len(dataset["samples"]) <= MAX_SAMPLES:
            fail("invalid-package", "Frozen dataset sample identities are invalid.")
        if _digest({key: value for key, value in dataset.items() if key not in ("evaluations", "fingerprint")}) != dataset.get("fingerprint"):
            fail("invalid-package", "A frozen dataset fingerprint does not match its immutable content.")
        if not isinstance(dataset.get("evaluations", []), list) or len(dataset.get("evaluations", [])) > MAX_EVALUATIONS:
            fail("invalid-package", "Retained evaluations exceed the dataset limit.")
        for sample in dataset["samples"]:
            channels = _frozen_channels(sample)
            if not isinstance(channels, list) or not 1 <= len(channels) <= 3:
                fail("invalid-package", "Frozen channel definitions exceed their supported bound.")
            seen = set()
            for channel in channels:
                index = channel.get("channel")
                if type(index) is not int or not 0 <= index <= 65535 or index in seen or channel.get("shape") != sample["shape"]:
                    fail("invalid-package", "Frozen channels require distinct indices and the reference's exact shape.")
                seen.add(index)
                digest = channel.get("rawHash")
                if not isinstance(digest, str) or not re.fullmatch("[0-9a-f]{64}", digest) or channel.get("rawPath") != "artifacts/" + digest + ".adaptation.npy":
                    fail("invalid-package", "A frozen channel artifact identity is invalid.")
                if channel.get("sourceSelection") != {"channel": index, "zProjection": sample["parameters"]["zProjection"]}:
                    fail("invalid-package", "Frozen channel selection does not match the reference projection.")
            primary = next((row for row in channels if row["channel"] == sample["parameters"]["channel"]), None)
            if primary is None or primary["rawPath"] != sample["rawPath"] or primary["rawHash"] != sample["rawHash"]:
                fail("invalid-package", "Frozen primary channel must retain the original immutable raw sample.")


def execute(store, document, operation, args, revision, actor):
    if operation == "adaptation.reference.set":
        return _approve(store, document, args, actor)
    if operation == "adaptation.suggest":
        return _suggest(store, document, args)
    if operation == "adaptation.dataset.create":
        return _create_dataset(store, document, args, revision)
    if operation == "adaptation.dataset.list":
        return {"datasets": [describe(document, dataset, detail=False) for dataset in document.get("adaptationDatasets", [])]}
    if operation == "adaptation.dataset.get":
        return {"dataset": describe(document, _dataset(document, args["datasetId"]))}
    if operation == "adaptation.evaluate.preview":
        return {"preview": evaluation_preview(store, document, args)}
    if operation == "adaptation.evaluate":
        return _evaluate(store, document, args, revision)
    fail("unknown-operation", "Unsupported adaptation operation.")


# Loaded after catalogue functions to allow direct imports during schema setup.
import _workbench_imaging as imaging
