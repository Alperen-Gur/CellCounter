"""Registered exact local model inference and durable Cellpose 3 training."""
from __future__ import annotations

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

MAX_MODELS = 128
MAX_TRAINING_JOBS = 100
MAX_TRAINING_BYTES = 256 * 1024 ** 2
MAX_LOG_BYTES = 4 * 1024 ** 2
MAX_CELLPOSE4_CHECKPOINT_BYTES = 2 * 1024 ** 3
MAX_ENVIRONMENT_RECORDS = 100


def inference_schema(backend=None):
    from _workbench_schema import _object
    import _workbench_model_adapters as adapters
    if backend in adapters.BACKENDS:
        return adapters.inference_schema(backend)
    common = {
        "flowThreshold": {"type": "number", "minimum": 0, "maximum": 10, "default": .4,
                          "title": "Flow error threshold"},
        "cellprobThreshold": {"type": "number", "minimum": -20, "maximum": 20, "default": 0,
                              "title": "Cell probability threshold"},
        "minSize": {"type": "integer", "minimum": 1, "maximum": 16000000, "default": 15,
                    "title": "Minimum object area (pixels)"},
        "device": {"type": "string", "enum": ["auto", "cpu"], "default": "auto",
                   "title": "Execution device", "description": "Auto selects available CUDA, MPS, then CPU."},
    }
    diameter = {"type": "number", "exclusiveMinimum": 0, "maximum": 4096}
    cp3 = {"diameterPx": {**diameter, "default": 30, "title": "Cell diameter (pixels)",
                         "description": "Explicit Cellpose 3 segmentation diameter; no automatic size predictor."}}
    cp4 = {"rescaleDiameterPx": {**diameter, "title": "Optional rescale diameter (pixels)",
                                "description": "Omit to retain native scale. This is a resize hint, not an estimated diameter."}}
    if backend not in (None, "cellpose3", "cellpose4"):
        fail("unsupported-model-backend", "Choose the cellpose3 or cellpose4 inference adapter.")
    fields = {**common, **(cp3 if backend == "cellpose3" else cp4 if backend == "cellpose4" else {**cp3, **cp4})}
    if backend is None:
        for name in adapters.BACKENDS:
            fields.update(adapters.inference_schema(name)["properties"])
    return _object(fields)


def catalog():
    import _workbench_model_adapters as adapters
    return {"defaultBackend": "cellpose3", "backends": [{
        "id": backend, "name": "Cellpose 3" if backend == "cellpose3" else "Cellpose 4 / Cellpose-SAM",
        "dimensions": [2], "supportsTraining": backend == "cellpose3",
        "inferenceSchema": inference_schema(backend),
        "maxCheckpointBytes": 512 * 1024 ** 2 if backend == "cellpose3" else MAX_CELLPOSE4_CHECKPOINT_BYTES,
        "notes": (["Requires an explicitly registered local Cellpose 3.x interpreter and exact checkpoint."]
                  if backend == "cellpose3" else [
                      "Requires an explicitly registered local Cellpose 4.x interpreter and exact checkpoint.",
                      "One selected grayscale source plane is supplied; the Cellpose 3 channels control is not passed.",
                      "Omitting rescaleDiameterPx preserves native input scale; no size prediction is performed.",
                      "Shared fine-tuning is currently available for Cellpose 3 only.",
                  ]) + ["The runtime does not install packages or download substitute weights.",
                        "Inference is bounded to 16 million source pixels and 64 million rescaled pixels."],
    } for backend in ("cellpose3", "cellpose4")] + adapters.catalog()}


def parameter_schema_hash(backend):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(inference_schema(backend)).encode()).hexdigest()


def inference_parameters(backend, values=None):
    from _workbench_plugins import validate_parameters
    return validate_parameters({"parameters": inference_schema(backend)}, values)


def schema_for_model(model):
    import _workbench_model_adapters as adapters
    return (adapters.inference_schema(model["backend"], model["registrationConfig"])
            if model["backend"] in adapters.BACKENDS else inference_schema(model["backend"]))


def model_schema_hash(model):
    from _workbench_store import canonical
    return hashlib.sha256(canonical(schema_for_model(model)).encode()).hexdigest()


def parameters_for_model(model, values=None):
    from _workbench_plugins import validate_parameters
    params = validate_parameters({"parameters": schema_for_model(model)}, values)
    if model["backend"] == "stardist2d":
        if params["lowerPercentile"] >= params["upperPercentile"]:
            fail("invalid-model-parameters", "The lower normalization percentile must be smaller than the upper percentile.")
        if any(key in params and not 0 < params[key] < 1 for key in ("probThreshold", "nmsThreshold")):
            fail("invalid-model-parameters", "StarDist probability and NMS thresholds must be strictly between zero and one.")
    return params


def binding_fields(model):
    """Additional immutable identities; legacy Cellpose bindings stay unchanged."""
    return {key: copy.deepcopy(model[key]) for key in ("artifactSetHash", "registrationConfigHash") if key in model}


def validate_model_artifacts(document):
    from _workbench_model_adapters import validate_model_artifacts as validate
    validate(document)


def operations():
    from _workbench_schema import _object, _op, _ID, _STRING, _PARAMETERS
    import _workbench_model_adapters as adapters
    positive = {"type": "number", "exclusiveMinimum": 0}
    device = {"type": "string", "enum": ["auto", "cpu"]}
    result = [
        _op("model.catalog", "Discover backend-specific local model controls, dimensional support and training availability.",
            _object(), project=False),
        _op("model.register", "Register exact local weights, required configuration and a trusted interpreter without downloads or execution.",
            _object({"name": {"type": "string", "maxLength": 200}, "backend": {"type": "string", "enum": ["cellpose3", "cellpose4", *adapters.BACKENDS]},
                     "pythonPath": _STRING, "checkpointPath": _STRING, "configPath": _STRING, "thresholdsPath": _STRING,
                     "registrationConfig": adapters.registration_schema()}, ["name", "backend", "pythonPath", "checkpointPath"]), True),
        _op("model.configure", "Rebind a registered local interpreter or explicitly enable or disable a trusted model.",
            _object({"modelId": _ID, "pythonPath": _STRING, "enabled": {"type": "boolean"}}, ["modelId"]), True),
        _op("model.list", "List registered immutable model checkpoints and their local interpreter bindings.", _object()),
        _op("model.probe", "Probe the registered interpreter's backend version and inference API without downloading models.",
            _object({"modelId": _ID}, ["modelId"])),
        _op("model.environment.capture", "Explicitly capture the trusted interpreter's observed Python and package metadata and bind subsequent execution to it.",
            _object({"modelId": _ID}, ["modelId"]), True),
        _op("model.environment.get", "Read an immutable observed model environment and its retained capture history without executing the interpreter.",
            _object({"modelId": _ID, "environmentId": _ID}, ["modelId"])),
        _op("model.run", "Run registered local inference with backend-specific controls and save exact source-grid labels.",
            _object({"modelId": _ID, "imageId": _ID, "parameters": inference_schema(), "sourceParameters": _PARAMETERS},
                    ["modelId", "imageId"]), True),
        _op("adaptation.train.start", "Start local Cellpose 3 training on an immutable specimen-disjoint adaptation dataset.",
            _object({
                "datasetId": _ID, "modelId": _ID, "name": {"type": "string", "maxLength": 200},
                "epochs": {"type": "integer", "minimum": 6, "maximum": 2000},
                "learningRate": {**positive, "maximum": 1},
                "batchSize": {"type": "integer", "minimum": 1, "maximum": 32},
                "augment": {"type": "boolean"}, "earlyStop": {"type": "boolean"},
                "seed": {"type": "integer", "minimum": 0, "maximum": 4294967295},
                "device": device,
                "timeoutSeconds": {"type": "integer", "minimum": 60, "maximum": 86400},
            }, ["datasetId", "modelId", "name", "epochs", "learningRate", "batchSize"]), True),
        _op("adaptation.train.list", "Read saved training jobs and measured progress.", _object()),
        _op("adaptation.train.status", "Read one training job, its actual measured progress and completion state.",
            _object({"jobId": _ID}, ["jobId"])),
        _op("adaptation.train.cancel", "Request cancellation at the next Cellpose logging or evaluation boundary.",
            _object({"jobId": _ID}, ["jobId"]), True),
        _op("adaptation.train.collect", "Validate and retain a finished local checkpoint and held-out report.",
            _object({"jobId": _ID}, ["jobId"]), True),
    ]
    for entry in result:
        if entry["name"] in ("model.probe", "model.run", "adaptation.train.start", "model.environment.capture"):
            entry["usesExecutableCode"] = True
        if entry["name"] in ("model.register", "model.configure"):
            entry["installsExecutableCode"] = True
    return result


def fail(code, message, details=None):
    from _workbench_schema import WorkbenchError
    raise WorkbenchError(code, message, details)


def _model(document, model_id):
    value = next((item for item in document.get("models", []) if item["id"] == model_id), None)
    if value is None:
        fail("model-not-found", "The registered model does not exist.")
    return value


def _job(document, job_id):
    value = next((item for item in document.get("trainingJobs", []) if item["id"] == job_id), None)
    if value is None:
        fail("training-job-not-found", "The selected training job does not exist.")
    return value


def _python(value):
    from _workbench_schema import absolute_path
    from _workbench_store import file_hash
    # Preserve the venv launcher path: resolving its symlink changes which
    # environment Python selects even if executable bytes remain identical.
    absolute_path(value, "pythonPath")
    lexical = Path(value).expanduser()
    if not lexical.is_file() or not os.access(lexical, os.X_OK) or lexical.stat().st_size > 128 * 1024 ** 2:
        fail("invalid-interpreter", "Choose an existing executable local Python interpreter.")
    return str(lexical), file_hash(lexical)


def describe(model):
    descriptor = next(item for item in catalog()["backends"] if item["id"] == model["backend"])
    active = active_environment(model)
    return {**{key: copy.deepcopy(value) for key, value in model.items() if key not in ("checkpointPath", "environments")},
            "activeEnvironmentId": active["id"] if active else None,
            "activeEnvironmentHash": active["hash"] if active else None,
            "environmentCount": len(model.get("environments", [])),
            "environmentStatus": "captured" if active else "binding-changed" if model.get("environments") else "unrecorded",
            **{key: copy.deepcopy(descriptor[key]) for key in
               ("supportsTraining", "dimensions", "notes", "maxCheckpointBytes")},
            "inferenceSchema": schema_for_model(model),
            "inferenceSchemaHash": model_schema_hash(model)}


def active_environment(model):
    identifier = model.get("activeEnvironmentId")
    if identifier is None:
        return None
    record = next((item for item in model.get("environments", []) if item["id"] == identifier), None)
    if record is None:
        fail("model-environment-missing", "The active model environment record is unavailable.")
    if any(record.get(key) != model.get(key) for key in ("pythonPath", "pythonHash")):
        return None
    return record


def active_environment_hash(model):
    record = active_environment(model)
    return record["hash"] if record else None


def _retain_environment(store, inventory):
    import _workbench_environment as environments
    from _workbench_store import canonical
    try:
        inventory = environments.validate(inventory)
    except ValueError as exc:
        fail("invalid-environment-record", str(exc))
    path, checksum = store.put_bytes((canonical(inventory) + "\n").encode("utf-8"), ".model-environment.json")
    return {"hash": inventory["hash"], "inventoryPath": path, "inventoryHash": checksum,
            "summary": environments.summary(inventory)}


def _environment_inventory(store, record):
    import _workbench_environment as environments
    path = store.verify_artifact(record["inventoryPath"], record["inventoryHash"])
    inventory = _read_json(path, 2 * 1024 ** 2)
    try:
        inventory = environments.validate(inventory)
    except ValueError as exc:
        fail("invalid-environment-record", str(exc))
    if inventory["hash"] != record["hash"] or environments.summary(inventory) != record["summary"]:
        fail("environment-record-changed", "The observed environment no longer matches its immutable capture record.")
    return inventory


def _environment_descriptor(record):
    return {key: copy.deepcopy(value) for key, value in record.items() if key not in ("inventoryPath", "inventoryHash")}


def _environment_get(store, model, environment_id=None):
    import _workbench_environment as environments
    records = model.get("environments", [])
    active = active_environment(model)
    selected = next((item for item in records if item["id"] == environment_id), None) if environment_id else (active or (records[-1] if records else None))
    if environment_id and selected is None:
        fail("environment-not-found", "That observed environment is not retained for this model.")
    return {"modelId": model["id"], "activeEnvironmentId": active["id"] if active else None,
            "environments": [_environment_descriptor(record) for record in records],
            "environment": {**_environment_descriptor(selected), "inventory": _environment_inventory(store, selected)} if selected else None,
            "notes": environments.notes()}


def _capture_environment(store, model, revision, actor):
    from _workbench_store import utc_now
    import _workbench_environment as environments
    if len(model.get("environments", [])) >= MAX_ENVIRONMENT_RECORDS:
        fail("environment-history-limit", "A model supports at most 100 immutable observed environment captures.")
    observed = _invoke(store, model, {"mode": "environment"})
    retained = _retain_environment(store, observed.get("environment"))
    record = {**retained, "id": str(uuid.uuid4()), "pythonPath": model["pythonPath"], "pythonHash": model["pythonHash"],
              "capturedAt": utc_now(), "capturedRevision": revision, "actor": copy.deepcopy(actor)}
    model.setdefault("environments", []).append(record)
    model["activeEnvironmentId"] = record["id"]
    return {"model": describe(model), "environment": {**_environment_descriptor(record), "inventory": observed["environment"]},
            "notes": environments.notes()}


def _verified(store, model):
    if not model.get("enabled"):
        fail("model-disabled", "Explicitly enable this trusted checkpoint and interpreter before execution.")
    path, digest = _python(model["pythonPath"])
    if digest != model["pythonHash"]:
        fail("interpreter-changed", "The registered Python executable changed. Rebind it explicitly.")
    checkpoint = store.verify_artifact(model["checkpointPath"], model["checkpointHash"])
    if model.get("modelArtifacts"):
        validate_model_artifacts({"models": [model]})
        for artifact in model["modelArtifacts"]:
            artifact_path = checkpoint if artifact["role"] == "checkpoint" else store.verify_artifact(artifact["path"], artifact["hash"])
            if artifact_path.stat().st_size != artifact["bytes"]:
                fail("model-artifact-changed", "A retained model artifact no longer has its recorded byte size.")
    return path, checkpoint


def artifact_references(document):
    result = {}
    for model in document.get("models", []):
        result[model["checkpointPath"]] = model["checkpointHash"]
        for artifact in model.get("modelArtifacts", []):
            result[artifact["path"]] = artifact["hash"]
        for environment in model.get("environments", []):
            result[environment["inventoryPath"]] = environment["inventoryHash"]
    for job in document.get("trainingJobs", []):
        if job.get("reportPath"):
            result[job["reportPath"]] = job["reportHash"]
        for prediction in job.get("predictions", []):
            result[prediction["labelsPath"]] = prediction["labelsHash"]
        for key in ("environment", "observedEnvironment"):
            if job.get(key):
                result[job[key]["inventoryPath"]] = job[key]["inventoryHash"]
    for image in document.get("images", []):
        versions = ([image["analysis"]] if image.get("analysis") else []) + image.get("undoStack", [])
        for analysis in versions:
            environment = analysis.get("model", {}).get("environment")
            if environment:
                result[environment["inventoryPath"]] = environment["inventoryHash"]
    return result


def _worker(backend="cellpose3"):
    return Path(__file__).with_name("_workbench_cellpose_worker.py" if backend in ("cellpose3", "cellpose4") else "_workbench_specialist_worker.py")


def _environment():
    return {key: value for key, value in os.environ.items() if key in
            ("PATH", "HOME", "USERPROFILE", "SYSTEMROOT", "WINDIR", "APPDATA", "LOCALAPPDATA",
             "TEMP", "TMP", "TMPDIR", "LANG", "LC_ALL", "CUDA_VISIBLE_DEVICES")}


def _read_json(path, maximum=4 * 1024 ** 2):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > maximum:
        fail("invalid-model-output", "The model runtime did not provide a bounded regular result.")
    try:
        value = json.loads(path.read_text())
        json.dumps(value, allow_nan=False)
        return value
    except (ValueError, UnicodeError, RecursionError):
        fail("invalid-model-output", "The model runtime returned invalid JSON.")


def _invoke(store, model, request, prepare=None, consume=None):
    from _workbench_store import canonical
    if request["mode"] == "environment":
        if not model.get("enabled"):
            fail("model-disabled", "Explicitly enable the trusted interpreter before capturing its environment.")
        interpreter, python_hash = _python(model["pythonPath"])
        if python_hash != model["pythonHash"]:
            fail("interpreter-changed", "The registered Python executable changed. Rebind it explicitly before capturing its environment.")
        checkpoint = store.artifact_path(model["checkpointPath"])
    else:
        interpreter, checkpoint = _verified(store, model)
    with tempfile.TemporaryDirectory(prefix="cellcounter-model-") as temporary:
        directory = Path(temporary)
        request = {**request, "backend": model["backend"],
                   "checkpointPath": str(checkpoint), "checkpointHash": model["checkpointHash"]}
        if model.get("modelArtifacts"):
            request.update({"registrationConfig": copy.deepcopy(model["registrationConfig"]),
                            "modelArtifacts": [{**item, "path": str(store.artifact_path(item["path"]))} for item in model["modelArtifacts"]]})
        captured = active_environment(model)
        if captured is not None and request["mode"] != "environment":
            _environment_inventory(store, captured)
            request["expectedEnvironmentHash"] = captured["hash"]
        if prepare:
            request.update(prepare(directory))
        path = directory / "request.json"
        path.write_text(canonical(request))
        with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
            process = subprocess.Popen([interpreter, "-I", str(_worker(model["backend"])), "--request", str(path),
                                        "--output", str(directory)], stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr, env=_environment(), start_new_session=os.name != "nt")
            started = time.monotonic()
            while process.poll() is None:
                if (time.monotonic() - started > (60 if request["mode"] in ("probe", "environment") else 300)
                        or stdout.tell() + stderr.tell() > MAX_LOG_BYTES):
                    process.kill()
                    process.wait()
                    fail("model-runtime-limit", "The model runtime exceeded its bounded time or log budget.")
                time.sleep(.05)
            if process.returncode:
                status = _read_json(directory / "status.json") if (directory / "status.json").exists() else {}
                if status.get("error", {}).get("code") == "model-environment-changed":
                    error = status["error"]
                    fail("model-environment-changed", error.get("message", "The interpreter's observed environment changed after capture."),
                         error.get("details"))
                fail("model-runtime-error", status.get("error", {}).get("message", "The registered runtime failed."),
                     {"exitCode": process.returncode})
        result = _read_json(directory / "result.json")
        return consume(directory, result) if consume else result


def _directory(store, job):
    root = store.root / "training" / job["id"]
    if (not root.is_dir() or root.is_symlink() or root.parent.is_symlink()
            or root.resolve().parent.parent != store.root):
        fail("training-artifacts-missing", "Local training files are unavailable. Restored jobs must be started again explicitly.")
    return root


def describe_job(store, job):
    result = {key: copy.deepcopy(value) for key, value in job.items()
              if key not in ("request", "reportPath", "reportHash", "predictions")}
    if job["status"] in ("collected", "interrupted"):
        return result
    try:
        directory = _directory(store, job)
        status_path = directory / "status.json"
        if status_path.exists():
            result.update(_read_json(status_path))
        elif (directory / "cancel.requested").exists():
            result["status"] = "cancelling"
        elif (directory / ".launched").exists():
            result["status"] = "starting"
        if (directory / "cancel.requested").exists() and result["status"] in ("queued", "starting", "running"):
            result["status"] = "cancelling"
        heartbeat = directory / ".heartbeat"
        if result["status"] in ("running", "starting", "cancelling") and heartbeat.exists():
            if time.time() - heartbeat.stat().st_mtime > 120:
                result.update({"status": "interrupted", "error": {
                    "code": "training-worker-lost", "message": "The training worker stopped updating its heartbeat. Start a new job explicitly."}})
    except Exception as exc:
        result.update({"status": "interrupted", "error": {"code": "training-artifacts-missing", "message": str(exc)}})
    return result


def _register(store, document, args, revision):
    from _workbench_schema import absolute_path
    from _workbench_store import utc_now
    import _workbench_model_adapters as adapters
    if len(document.get("models", [])) >= MAX_MODELS:
        fail("model-limit", "A project supports at most 128 registered checkpoints.")
    interpreter, python_hash = _python(args["pythonPath"])
    checkpoint = absolute_path(args["checkpointPath"], "checkpointPath")
    maximum = MAX_CELLPOSE4_CHECKPOINT_BYTES if args["backend"] in ("cellpose4", "micro-sam") else 512 * 1024 ** 2
    if not checkpoint.is_file() or checkpoint.is_symlink() or not 1024 <= checkpoint.stat().st_size <= maximum:
        fail("invalid-checkpoint", "Choose an existing checkpoint between 1 KiB and the selected backend's size limit.",
             {"maxCheckpointBytes": maximum, "backend": args["backend"]})
    # import_file is streaming and content addressed; checkpoint deserialization
    # happens only during explicit execution in the registered environment.
    specialist = args["backend"] in adapters.BACKENDS
    suffix = {"cellpose3": ".cp3", "cellpose4": ".cp4", "omnipose": ".omnipose", "micro-sam": ".microsam"}.get(args["backend"])
    if args["backend"] == "stardist2d":
        suffix = ".stardist.weights.h5" if checkpoint.name.endswith(".weights.h5") else ".stardist.h5"
    if not specialist and any(args.get(key) for key in ("configPath", "thresholdsPath", "registrationConfig")):
        fail("unexpected-model-config", "Cellpose registration uses the exact checkpoint directly; extra specialist configuration is not accepted.")
    reference, digest, size = store.import_file(str(checkpoint), artifact_suffix=suffix)
    model = {"id": str(uuid.uuid4()), "name": args["name"], "backend": args["backend"],
             "pythonPath": interpreter, "pythonHash": python_hash,
             "checkpointPath": reference, "checkpointHash": digest, "checkpointBytes": size, "enabled": True,
             "createdAt": utc_now(), "registeredRevision": revision}
    if specialist:
        model.update(adapters.register_extras(store, args, {"role": "checkpoint", "path": reference, "hash": digest, "bytes": size,
            "filename": "weights.weights.h5" if suffix == ".stardist.weights.h5" else "weights.h5" if args["backend"] == "stardist2d" else "checkpoint.pt"}))
    document.setdefault("models", []).append(model)
    return {"model": describe(model)}


def _start(store, document, args, revision):
    from _workbench_adaptation import _dataset
    from _workbench_store import utc_now, canonical
    if len(document.get("trainingJobs", [])) >= MAX_TRAINING_JOBS:
        fail("training-limit", "A project supports at most 100 saved training jobs.")
    model = _model(document, args["modelId"])
    if model["backend"] != "cellpose3":
        fail("unsupported-training-backend", "Shared fine-tuning currently supports Cellpose 3 only. Register a Cellpose 3 checkpoint and interpreter to train; Cellpose 4 remains available for inference.")
    interpreter, checkpoint = _verified(store, model)
    dataset = _dataset(document, args["datasetId"])
    if dataset["dimension"] != 2:
        fail("unsupported-training-dimension", "The Cellpose 3 training adapter requires frozen 2D raw planes.")
    total = sum(sample["shape"][0] * sample["shape"][1] * 8 for sample in dataset["samples"])
    if total > MAX_TRAINING_BYTES:
        fail("training-limit", "Training inputs exceed the 256 MiB raw-plane and label budget.")
    for job in document.get("trainingJobs", []):
        if describe_job(store, job)["status"] in ("queued", "starting", "running", "cancelling"):
            fail("training-already-running", "Complete or cancel the current local training job before starting another.")
    samples = []
    for sample in dataset["samples"]:
        sample = copy.deepcopy(sample)
        for kind in ("raw", "labels"):
            sample[kind + "Path"] = str(store.verify_artifact(sample[kind + "Path"], sample[kind + "Hash"]))
        samples.append(sample)
    params = {"augment": True, "earlyStop": True, "seed": 42, "device": "auto", "timeoutSeconds": 21600,
              **{key: value for key, value in args.items() if key not in ("datasetId", "modelId", "name")}}
    job_id = str(uuid.uuid4())
    parent = store.root / "training"
    if parent.is_symlink():
        fail("project-corrupt", "Training directory cannot be a symbolic link.")
    parent.mkdir(exist_ok=True)
    directory = parent / job_id
    directory.mkdir()
    request = {"mode": "train", "backend": "cellpose3", "parameters": params, "samples": samples,
               "checkpointPath": str(checkpoint), "checkpointHash": model["checkpointHash"],
               "datasetFingerprint": dataset["fingerprint"]}
    environment = active_environment(model)
    if environment is not None:
        _environment_inventory(store, environment)
        request["expectedEnvironmentHash"] = environment["hash"]
    (directory / "request.json").write_text(canonical(request))
    job = {"id": job_id, "name": args["name"], "status": "queued", "datasetId": dataset["id"],
           "datasetFingerprint": dataset["fingerprint"], "modelId": model["id"],
           "baseCheckpointHash": model["checkpointHash"], "pythonPath": interpreter, "pythonHash": model["pythonHash"],
           "parameters": params, "createdAt": utc_now(), "createdRevision": revision,
           "requestHash": hashlib.sha256(canonical(request).encode()).hexdigest()}
    if environment is not None:
        job["environment"] = {key: copy.deepcopy(environment[key]) for key in ("hash", "inventoryPath", "inventoryHash", "summary")}
    document.setdefault("trainingJobs", []).append(job)
    return {"job": describe_job(store, job)}


def launch(store, job):
    """Called only after the queued job is durably committed."""
    from _workbench_store import canonical
    directory = _directory(store, job)
    if (directory / ".launched").exists() or (directory / "cancel.requested").exists():
        return
    request = _read_json(directory / "request.json", 16 * 1024 ** 2)
    if hashlib.sha256(canonical(request).encode()).hexdigest() != job["requestHash"]:
        fail("training-input-changed", "The staged training request changed before launch.")
    interpreter, digest = _python(job["pythonPath"])
    if digest != job["pythonHash"]:
        fail("interpreter-changed", "The registered interpreter changed before training launch.")
    try:
        with (directory / ".launched").open("x") as claim:
            claim.write(job["requestHash"])
    except FileExistsError:
        return
    try:
        with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
            process = subprocess.Popen([interpreter, "-I", str(_worker()), "--request", str(directory / "request.json"),
                                        "--output", str(directory)], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                       env=_environment(), start_new_session=os.name != "nt")
        (directory / "process.json").write_text(canonical({"pid": process.pid, "jobId": job["id"]}))
    except OSError as exc:
        from _workbench_cellpose_worker import _write
        _write(directory / "status.json", {"status": "failed",
                                         "error": {"code": "training-launch-failed", "message": str(exc)}})


def _collect(store, document, job, revision):
    import _workbench_plugins as plugins
    from _workbench_adaptation import _dataset
    from _workbench_store import canonical, utc_now
    if job["status"] == "collected":
        return {"job": describe_job(store, job), "model": describe(_model(document, job["resultModelId"]))}
    if describe_job(store, job)["status"] != "completed":
        fail("training-not-complete", "Only a successfully completed job can be collected.")
    dataset = _dataset(document, job["datasetId"])
    if dataset["fingerprint"] != job["datasetFingerprint"]:
        fail("training-input-changed", "The frozen training dataset changed.")
    directory = _directory(store, job)
    report = _read_json(directory / "result.json")
    if report.get("environment"):
        job["observedEnvironment"] = _retain_environment(store, report["environment"])
        if job.get("environment") and job["environment"]["hash"] != job["observedEnvironment"]["hash"]:
            fail("model-environment-changed", "The training output does not match its frozen observed environment.")
        report = {**report, "environment": job["observedEnvironment"]}
    if (report.get("schemaVersion") != 1 or report.get("datasetFingerprint") != dataset["fingerprint"]
            or report.get("checkpointValidated") is not True):
        fail("invalid-training-output", "The completed report does not match this frozen dataset.")
    from _workbench_store import file_hash
    if file_hash(directory / "checkpoint.cp3") != report.get("checkpointHash"):
        fail("training-output-changed", "The trained checkpoint no longer matches its held-out report.")
    result = _register(store, document, {"name": job["name"], "backend": "cellpose3",
                                      "pythonPath": job["pythonPath"],
                                      "checkpointPath": str(directory / "checkpoint.cp3")}, revision)
    model = _model(document, result["model"]["id"])
    model["training"] = {"jobId": job["id"], "datasetId": dataset["id"],
                         "datasetFingerprint": dataset["fingerprint"],
                         "baseCheckpointHash": job["baseCheckpointHash"], "cellposeVersion": report["cellposeVersion"]}
    predictions = []
    test_samples = {sample["imageId"]: sample for sample in dataset["samples"] if sample["partition"] == "test"}
    if set(test_samples) != {item["imageId"] for item in report["images"]}:
        fail("invalid-training-output", "The report must contain every held-out test image exactly once.")
    for index, item in enumerate(report["images"]):
        if item.get("predictionFile") != f"prediction-{index}.npy":
            fail("invalid-training-output", "Test prediction paths do not match the worker's bounded output layout.")
        path = directory / item["predictionFile"]
        if file_hash(path) != item["predictionHash"]:
            fail("training-output-changed", "A retained test prediction changed.")
        labels = plugins._read_output_labels(path, test_samples[item["imageId"]]["shape"])
        encoded = io.BytesIO()
        import numpy as np
        np.save(encoded, labels, allow_pickle=False)
        reference, digest = store.put_bytes(encoded.getvalue(), ".training-prediction.npy")
        predictions.append({"imageId": item["imageId"], "labelsPath": reference, "labelsHash": digest})
    report_ref, report_hash = store.put_bytes((canonical(report) + "\n").encode(), ".training-report.json")
    job.update({"status": "collected", "resultModelId": model["id"], "metrics": report["metrics"],
                "reportPath": report_ref, "reportHash": report_hash, "predictions": predictions,
                "collectedAt": utc_now(), "collectedRevision": revision})
    return {"job": describe_job(store, job), "model": describe(model)}


def input_channels(model, parameters, primary_channel):
    """Ordered acquired channel identities for direct and frozen-dataset inputs."""
    channels = [primary_channel] + [parameters[key] for key in ("additionalChannel1", "additionalChannel2") if key in parameters]
    if any(type(channel) is not int or channel < 0 for channel in channels) or len(set(channels)) != len(channels):
        fail("duplicate-model-channels", "Select distinct acquired channel indices for every model input; grayscale replication is not performed.")
    expected = (model.get("registrationConfig", {}).get("inputChannels", 1) if model["backend"] == "stardist2d" else
                model.get("registrationConfig", {}).get("nChannels", 1) if model["backend"] == "omnipose" else 1)
    if len(channels) != expected:
        fail("model-input-channels", "The acquired input channels do not match the registered model configuration.")
    return channels


def prediction_binding(model):
    return {"modelId": model["id"], "backend": model["backend"], "checkpointHash": model["checkpointHash"],
            "pythonHash": model["pythonHash"], "inferenceSchemaHash": model_schema_hash(model),
            **binding_fields(model), "environmentHash": active_environment_hash(model)}


def predict(store, document, model_id, raw, parameters=None):
    """One exact predictor for direct analysis, workflows and immutable held-out pixels.

    The caller supplies acquired planes, with support already cropped. This
    helper never reconstructs channels from a live acquisition.
    """
    import numpy as np
    import _workbench_plugins as plugins
    from _workbench_imaging import MAX_PIXELS
    model = _model(document, model_id)
    params = parameters_for_model(model, parameters)
    array = np.asarray(raw)
    count = (model.get("registrationConfig", {}).get("inputChannels", 1) if model["backend"] == "stardist2d" else
             model.get("registrationConfig", {}).get("nChannels", 1) if model["backend"] == "omnipose" else 1)
    if (array.ndim != (2 if count == 1 else 3) or (count > 1 and array.shape[-1] != count)
            or any(size < 1 for size in array.shape) or array.shape[0] * array.shape[1] > MAX_PIXELS
            or array.dtype.kind not in "uif" or not np.isfinite(array).all()):
        fail("model-input-shape", "Supply finite exact acquired source planes matching the registered channel count and pixel budget.")
    def prepare(directory):
        np.save(directory / "pixels.npy", array, allow_pickle=False)
        return {"rawPath": str(directory / "pixels.npy")}
    def consume(directory, result):
        return plugins._read_output_labels(directory / "labels.npy", array.shape[:2]), result
    labels, details = _invoke(store, model, {"mode": "infer", "parameters": params}, prepare, consume)
    if "environment" in details:
        details = {**details, "environment": _retain_environment(store, details["environment"])}
        expected = active_environment_hash(model)
        if expected is not None and details["environment"]["hash"] != expected:
            fail("model-environment-changed", "The inference output does not match the captured observed environment.")
    provenance = {**details, **prediction_binding(model), "parameters": params,
                  "registrationConfig": copy.deepcopy(model.get("registrationConfig")), "inputShape": list(array.shape)}
    return labels, provenance


def execute(store, document, operation, args, revision, actor=None):
    if operation == "model.register":
        return _register(store, document, args, revision)
    if operation == "model.list":
        return {"models": [describe(item) for item in document.get("models", [])]}
    if operation == "adaptation.train.start":
        return _start(store, document, args, revision)
    if operation == "adaptation.train.list":
        return {"jobs": [describe_job(store, item) for item in document.get("trainingJobs", [])]}
    if operation.startswith("adaptation.train."):
        job = _job(document, args["jobId"])
        if operation == "adaptation.train.status":
            return {"job": describe_job(store, job)}
        if operation == "adaptation.train.cancel":
            if describe_job(store, job)["status"] not in ("queued", "starting", "running", "cancelling"):
                fail("invalid-training-state", "Only an active training job can be cancelled.")
            # This is a cancellation intent. The core publishes the marker only
            # after committing it against the caller's expected revision.
            job["cancelRequested"] = True
            return {"job": {**describe_job(store, job), "status": "cancelling"}}
        return _collect(store, document, job, revision)
    model = _model(document, args["modelId"])
    if operation == "model.environment.get":
        return _environment_get(store, model, args.get("environmentId"))
    if operation == "model.environment.capture":
        return _capture_environment(store, model, revision, actor or {"kind": "api", "name": "Unspecified client"})
    if operation == "model.configure":
        if "pythonPath" not in args and "enabled" not in args:
            fail("invalid-arguments", "Provide a local interpreter binding or explicit enabled state.")
        if "pythonPath" in args:
            model["pythonPath"], model["pythonHash"] = _python(args["pythonPath"])
            model.pop("activeEnvironmentId", None)
        if "enabled" in args:
            model["enabled"] = args["enabled"]
        return {"model": describe(model)}
    if operation == "model.probe":
        from _workbench_schema import WorkbenchError
        try:
            return {"modelId": model["id"], "backend": model["backend"],
                    "inferenceSchema": schema_for_model(model),
                    **_invoke(store, model, {"mode": "probe"})}
        except WorkbenchError as exc:
            return {"modelId": model["id"], "backend": model["backend"], "available": False,
                    "error": {"code": exc.code, "message": exc.message}}
    if operation != "model.run":
        fail("unknown-operation", "Unknown model operation.")
    params = parameters_for_model(model, args.get("parameters"))
    from _workbench_core import _image, _source, _set_analysis
    from _workbench_schema import analysis_parameters
    import _workbench_plugins as plugins
    import _workbench_support as support
    import numpy as np
    image = _image(document, args["imageId"])
    source_parameters = analysis_parameters({"parameters": {
        **image.get("preferredSourceParameters", {}), **args.get("sourceParameters", {})}})
    channels = input_channels(model, params, source_parameters["channel"])
    if len(channels) > 1:
        from _workbench_imaging import load_array, plane_from_array
        source_path = store.verify_artifact(image["sourcePath"], image["sourceHash"])
        array, metadata = load_array(source_path)
        planes = [plane_from_array(array, metadata, {**source_parameters, "channel": channel}) for channel in channels]
        raw = planes[0]
        if raw.shape != (image["height"], image["width"]):
            fail("source-changed", "Source dimensions differ from the imported acquisition.")
    else:
        raw = _source(store, image, source_parameters)
        planes = [raw]
    valid = support.load(store, image, raw.shape, source_parameters)
    for channel in channels[1:]:
        additional_valid = support.load(store, image, raw.shape, {**source_parameters, "channel": channel})
        if (valid is None) != (additional_valid is None) or (valid is not None and not np.array_equal(valid, additional_valid)):
            fail("model-support-mismatch", "All acquired model channels must have the same valid support. Extract compatible source regions first.")
    region = support.rectangular_crop(valid) if valid is not None else (slice(0, raw.shape[0]), slice(0, raw.shape[1]))
    inference_raw = raw[region] if len(planes) == 1 else np.stack([plane[region] for plane in planes], axis=-1)
    cropped, details = predict(store, document, model["id"], inference_raw, params)
    labels = np.zeros(raw.shape, dtype=np.uint32)
    labels[region] = cropped
    measured = _set_analysis(store, image, labels, raw, source_parameters, revision)
    provenance = {"modelId": model["id"], "backend": model["backend"], "checkpointHash": model["checkpointHash"],
                  "pythonHash": model["pythonHash"], "parameters": params, **details,
                  "sourceHash": image["sourceHash"], "retainedLabelsHash": image["analysis"]["labelsHash"],
                  "inferenceSchemaHash": model_schema_hash(model), **binding_fields(model),
                  "registrationConfig": copy.deepcopy(model.get("registrationConfig")), "sourceChannels": channels,
                  "sourceSelection": {key: source_parameters[key] for key in ("channel", "zProjection")},
                  "sourceProcessing": copy.deepcopy(image.get("derivation")),
                  "validSupport": support.fingerprint(image),
                  "inferenceRegion": {"x": region[1].start, "y": region[0].start,
                                      "width": region[1].stop - region[1].start,
                                      "height": region[0].stop - region[0].start}}
    image["analysis"]["model"] = provenance
    measured["model"] = provenance
    return {"model": describe(model), "analysis": measured}


def after_commit(store, document, operation, args, result):
    if operation not in ("adaptation.train.start", "adaptation.train.cancel"):
        return
    from _workbench_cellpose_worker import _write
    job = _job(document, result["job"]["id"])
    if job["status"] in ("collected", "interrupted"):
        return
    directory = None
    try:
        directory = _directory(store, job)
        if operation == "adaptation.train.start":
            launch(store, job)
        else:
            (directory / "cancel.requested").touch(exist_ok=True)
            if not (directory / ".launched").exists():
                _write(directory / "status.json", {"status": "cancelled"})
    except Exception as exc:
        # The queued/cancelled intent has already committed. Report launch
        # failure through job status rather than falsely returning a failed
        # mutation that has actually persisted.
        if directory is not None:
            _write(directory / "status.json", {"status": "failed",
                "error": {"code": "training-launch-failed", "message": str(exc)[:2000]}})


def validate_environment_records(document):
    """Validate retained metadata structure without invoking a registered runtime."""
    import re
    identities = set()
    for model in document.get("models", []):
        records = model.get("environments", [])
        if not isinstance(records, list) or len(records) > MAX_ENVIRONMENT_RECORDS:
            fail("invalid-package", "A model's environment capture history exceeds 100 records.")
        for record in records:
            if (not isinstance(record, dict) or not isinstance(record.get("id"), str) or record["id"] in identities or
                    not isinstance(record.get("hash"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["hash"]) or
                    not isinstance(record.get("inventoryHash"), str) or not re.fullmatch(r"[0-9a-f]{64}", record["inventoryHash"]) or
                    record.get("inventoryPath") != f"artifacts/{record['inventoryHash']}.model-environment.json" or
                    not isinstance(record.get("summary"), dict) or record["summary"].get("hash") != record["hash"] or
                    type(record["summary"].get("packageCount")) is not int or not 0 <= record["summary"]["packageCount"] <= 4096 or
                    not isinstance(record.get("pythonPath"), str) or not isinstance(record.get("pythonHash"), str) or
                    not re.fullmatch(r"[0-9a-f]{64}", record["pythonHash"]) or
                    type(record.get("capturedRevision")) is not int or record["capturedRevision"] < 0):
                fail("invalid-package", "A retained model environment capture has inconsistent metadata.")
            identities.add(record["id"])
        if model.get("activeEnvironmentId"):
            active_environment(model)


def environment_bindings(document):
    """Small references only, for cross-checking inventories inside packages."""
    records = [record for model in document.get("models", []) for record in model.get("environments", [])]
    for image in document.get("images", []):
        analyses = ([image["analysis"]] if image.get("analysis") else []) + image.get("undoStack", [])
        records.extend(analysis["model"]["environment"] for analysis in analyses if analysis.get("model", {}).get("environment"))
    for job in document.get("trainingJobs", []):
        records.extend(job[key] for key in ("environment", "observedEnvironment") if job.get(key))
    records.extend(run["environment"] for run in document.get("pluginRuns", []) if run.get("environment"))
    records.extend(image["readerOrigin"]["environment"] for image in document.get("images", [])
                   if image.get("readerOrigin", {}).get("environment"))
    for dataset in document.get("adaptationDatasets", []):
        for evaluation in dataset.get("evaluations", []):
            for image in evaluation.get("images", []):
                provenance = image.get("provenance", {})
                records.extend(provenance[key]["environment"] for key in ("baseline", "candidate")
                               if provenance.get(key, {}).get("environment"))
    return [{key: copy.deepcopy(record[key]) for key in ("inventoryPath", "hash", "summary")} for record in records]


def validate_environment_content(document, path, inventory):
    """Relate a verified inventory file to model capture/provenance metadata."""
    import _workbench_environment as environments
    for record in environment_bindings(document):
        if record["inventoryPath"] == path and (record["hash"] != inventory["hash"] or record["summary"] != environments.summary(inventory)):
            fail("invalid-package", "A retained environment inventory differs from its capture or analysis metadata.")
