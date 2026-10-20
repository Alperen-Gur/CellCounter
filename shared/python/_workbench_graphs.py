"""Bounded workflow DAGs using the same canonical scientific operations as linear jobs."""
from __future__ import annotations

from _workbench_indexed import image_capacity

from _workbench_indexed import image_index

import copy
import re
import uuid

MAX_NODES = 32
MAX_BRANCHES = 8
MAX_CHECKPOINTS = 5000
SOURCE = "$source"
SEGMENTATION = frozenset(("analysis", "volume-analysis", "plugin-segmentation", "model-segmentation"))
SCIENCE = SEGMENTATION | {"preprocessing", "measurements", "plugin-measurement", "assay", "review", "mask-merge"}


def parents(node):
    return list(node["inputs"]) if "inputs" in node else [node["input"]] + [node[key] for key in ("nuclearInput", "somaInput") if node.get(key)]


def raw_assay(node):
    if node["type"] != "assay": return False
    from _workbench_workflows import _assay_definition
    return _assay_definition(node["assay"]).get("requiresAnalysis", True) is False


def accepted_inputs(node):
    kind = node["type"]
    if kind == "summary": return {"analyzed", "raw-measured"}
    if raw_assay(node): return {"raw", "raw-measured", "analyzed"}
    return {"raw"} if kind == "preprocessing" or kind in SEGMENTATION else {"summary"} if kind == "export" else {"analyzed"}


def output_kind(node, incoming):
    kind = node["type"]
    if kind == "preprocessing": return "raw"
    if kind in ("summary", "export"): return kind
    if raw_assay(node) and incoming != "analyzed": return "raw-measured"
    return "analyzed"


def paired_port(node):
    return {"nuclear_cytoplasmic": ("nuclearInput", "nuclearImageId"),
            "neurite_outgrowth": ("somaInput", "somaImageId")}.get(node.get("assay")) if node["type"] == "assay" else None


def fail(code, message, node_id=None, **details):
    from _workbench_schema import WorkbenchError
    if node_id is not None:
        details["nodeId"] = node_id
    raise WorkbenchError(code, message, details or None)


def digest(value):
    from _workbench_workflows import _digest
    return _digest(value)


def limits():
    return {"nodes": MAX_NODES, "segmentationBranches": MAX_BRANCHES,
            "nodeCheckpoints": MAX_CHECKPOINTS, "projectImages": 1000}


def notes():
    return [
        "Each segmentation node creates an independent image identity. Original acquisitions and other branches' masks are never overwritten.",
        "Branches are technical alternatives of the same acquisition/time, not additional biological replicates. Summaries keep branches separate.",
        "Preprocessing shares immutable outputs with downstream branches; processed selections become channel 0, max projection or local volume time 0.",
        "N:C and neurite assays consume explicit cell/nuclear or neurite/soma branches. Mask union/intersection creates new connected-component identities on the same source grid and valid support; arbitrary merges and conditional execution are unsupported.",
        "Raw-intensity assays may consume source/preprocessed pixels directly; raw-only branches report no object count and cannot feed mask measurement/review nodes.",
        "Review gates pause the existing worker. Agent recommendations remain distinct from self-declared human decisions and never silently approve a human-required gate.",
        "A changed source or completed branch blocks further checkpoints. Corrected continuation creates a new job using exact corrected masks and still-current ancestors; historical checkpoints remain unchanged.",
        "Graph jobs use ordinary job.advance and job.worker.start; nodeId parameter sweeps and portable whole-graph tasks use the same checkpoints.",
    ]


def schemas():
    from _workbench_schema import _object, _ID
    from _workbench_workflows import operations as linear_operations
    step = copy.deepcopy(linear_operations()[0]["inputSchema"]["properties"]["steps"]["items"])
    step["properties"]["type"]["enum"] += ["review", "mask-merge"]
    step["properties"].update({
        "sourceChannel": {"type": "integer", "minimum": 0, "maximum": 31},
        "nuclearInput": {"type": "string", "minLength": 1, "maxLength": 64},
        "somaInput": {"type": "string", "minLength": 1, "maxLength": 64},
        "prompt": {"type": "string", "minLength": 1, "maxLength": 2000},
        "requireHuman": {"type": "boolean", "default": True},
        "mode": {"type": "string", "enum": ["union", "intersection"]},
        "connectivity": {"type": "string", "enum": ["faces", "full"], "default": "faces"},
        "id": {"type": "string", "minLength": 1, "maxLength": 64},
        "name": {"type": "string", "minLength": 1, "maxLength": 100},
        "input": {"type": "string", "minLength": 1, "maxLength": 64},
        "inputs": {"type": "array", "items": {"type": "string", "minLength": 1, "maxLength": 64},
                   "minItems": 1, "maxItems": MAX_NODES},
    })
    step["required"] = ["id", "type"]
    graph = _object({
        "schemaVersion": {"type": "integer", "enum": [1]},
        "target": {"type": "string", "enum": ["plane", "volume"]},
        "sourceParameters": _object({"channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0},
                                      "zProjection": {"type": "string", "enum": ["max", "mean", "middle"], "default": "max"}}),
        "channel": {"type": "integer", "minimum": 0, "maximum": 31, "default": 0},
        "nodes": {"type": "array", "items": step, "minItems": 2, "maxItems": MAX_NODES},
    }, ["schemaVersion", "target", "nodes"])
    return step, graph


def operations():
    from _workbench_schema import _object, _op, _ID
    _, graph = schemas()
    from _workbench_graph_controls import operations as control_operations
    return [
        *control_operations(),
        _op("workflow.graph.catalogue", "Describe supported DAG nodes, input bindings and bounded execution semantics.", _object(), project=False),
        _op("workflow.graph.preview", "Validate and normalize a workflow DAG and optionally budget selected source/time checkpoints without executing science.",
            _object({"graph": graph, "imageIds": {"type": "array", "items": _ID, "minItems": 1, "maxItems": 1000},
                     "timeIndices": {"type": "array", "items": {"type": "integer", "minimum": 0}, "minItems": 1, "maxItems": 1000}}, ["graph"])),
        _op("workflow.graph.save", "Save a versioned executable DAG with explicit immutable branch dependencies.",
            _object({"workflowId": _ID, "name": {"type": "string", "minLength": 1, "maxLength": 200}, "graph": graph}, ["name", "graph"]), True),
        _op("job.graph.node.preview", "Preview one built-in graph node against its retained current input without creating branch outputs.",
            _object({"jobId": _ID, "nodeId": {"type": "string", "minLength": 1, "maxLength": 64},
                     "checkpointIndex": {"type": "integer", "minimum": 0, "maximum": MAX_CHECKPOINTS - 1},
                     "cellLimit": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 200},
                     "maxSize": {"type": "integer", "minimum": 64, "maximum": 2048, "default": 768}},
                    ["jobId", "nodeId", "checkpointIndex"])),
    ]


def catalogue():
    from _workbench_schema import _PARAMETERS
    from _workbench_volume import parameter_schema
    step, graph = schemas()
    fields = {
        "preprocessing": {"recipe", "engineVersion"}, "analysis": {"parameters"},
        "volume-analysis": {"parameters"}, "model-segmentation": {"modelId", "modelParameters"},
        "plugin-segmentation": {"pluginId", "pluginParameters"}, "plugin-measurement": {"pluginId", "pluginParameters"},
        "assay": {"assay", "assayParameters", "nuclearInput", "somaInput"}, "review": {"prompt", "requireHuman"},
        "mask-merge": {"mode", "connectivity"}, "measurements": set(), "summary": set(), "export": {"destination"},
    }
    definitions = []
    for kind in step["properties"]["type"]["enum"]:
        incoming = ["raw"] if kind == "preprocessing" or kind in SEGMENTATION else ["summary"] if kind == "export" else ["analyzed"]
        outgoing = "raw" if kind == "preprocessing" else kind if kind in ("summary", "export") else "analyzed"
        if kind == "assay": incoming, outgoing = ["raw", "raw-measured", "analyzed"], "input-dependent"
        if kind == "summary": incoming = ["analyzed", "raw-measured"]
        selected = fields[kind] | {"id", "name", "type", "inputs" if kind in ("summary", "mask-merge") else "input"}
        if kind in SEGMENTATION: selected.add("sourceChannel")
        schema = {**copy.deepcopy(step), "properties": {key: copy.deepcopy(value) for key, value in step["properties"].items() if key in selected}}
        schema["properties"]["type"] = {"type": "string", "enum": [kind]}
        schema["required"] += ["inputs" if kind in ("summary", "mask-merge") else "input"]
        if kind == "mask-merge":
            schema["properties"]["inputs"].update({"minItems": 2, "maxItems": 2})
            schema["required"].append("mode")
        if kind == "analysis":
            parameters = copy.deepcopy(_PARAMETERS)
            for key in ("channel", "zProjection"):
                parameters["properties"].pop(key)
            schema["properties"]["parameters"] = parameters
        elif kind == "volume-analysis":
            schema["properties"]["parameters"] = parameter_schema()
        definitions.append({"type": kind, "name": kind.replace("-", " ").title(), "inputKinds": incoming,
                            "outputKind": outgoing, "schema": schema,
                            "previewSupported": kind in ("preprocessing", "analysis", "volume-analysis", "assay", "measurements")})
    from _workbench_assays import catalog
    return {"nodeTypes": definitions, "graphSchema": graph, "limits": limits(), "notes": notes(),
            "assayPorts": [{"assay": item["id"], "requiresAnalysis": item.get("requiresAnalysis", True),
                            "pairedPort": {"nuclear_cytoplasmic": "nuclearInput", "neurite_outgrowth": "somaInput"}.get(item["id"])}
                           for item in catalog()]}


def step_of(node):
    return {key: copy.deepcopy(value) for key, value in node.items() if key not in ("id", "name", "input", "inputs", "nuclearInput", "somaInput", "sourceChannel")}


def _selection(graph):
    return ({"target": "volume", "channel": graph["channel"]} if graph["target"] == "volume" else
            {"target": "plane", **graph["sourceParameters"]})


def _inherit(step, selected, node_id):
    """Bind selectors to the edge; callers may retain matching normalized fields."""
    from _workbench_schema import analysis_parameters
    kind = step["type"]
    target = selected["target"]
    if kind == "analysis":
        if target != "plane":
            fail("invalid-graph", "Use volume-analysis for a volume graph.", node_id)
        supplied = step.setdefault("parameters", {})
        for key in ("channel", "zProjection"):
            if key in supplied and supplied[key] != selected[key]:
                fail("graph-selector-mismatch", "Node selectors must match its input binding; edit the graph source selection instead.", node_id)
            supplied[key] = selected[key]
    elif kind in ("model-segmentation", "plugin-segmentation"):
        if kind == "model-segmentation" and target != "plane":
            fail("unsupported-graph-node", "Registered workflow model adapters currently support plane inference only.", node_id)
        if kind == "plugin-segmentation":
            if step.get("target", target) != target:
                fail("graph-selector-mismatch", "A plugin node inherits graph dimensionality.", node_id)
            step["target"] = target
        if target == "plane":
            supplied = step.get("sourceParameters", {})
            if any(key in supplied and supplied[key] != selected[key] for key in ("channel", "zProjection")):
                fail("graph-selector-mismatch", "Node source selectors must match the inherited input binding.", node_id)
            step["sourceParameters"] = analysis_parameters({"parameters": {**supplied, "channel": selected["channel"], "zProjection": selected["zProjection"]}})
        else:
            if step.get("channel", selected["channel"]) != selected["channel"]:
                fail("graph-selector-mismatch", "A volume node inherits its source channel.", node_id)
            step["channel"] = selected["channel"]
    elif kind == "volume-analysis":
        if target != "volume":
            fail("invalid-graph", "Use analysis for a plane graph.", node_id)
        if step.get("channel", selected["channel"]) != selected["channel"]:
            fail("graph-selector-mismatch", "A volume node inherits its source channel.", node_id)
        step["channel"] = selected["channel"]
    return step


def normalize(document, value):
    import _workbench_workflows as workflows
    from _workbench_schema import validate_value, WorkbenchError, absolute_path
    from _workbench_preprocessing import normalize_recipe, ENGINE_VERSION
    validate_value(value, schemas()[1], "graph")
    graph = copy.deepcopy(value)
    if graph["target"] == "plane":
        if "channel" in graph:
            fail("invalid-graph", "Plane graphs select a channel through sourceParameters.")
        graph["sourceParameters"] = {"channel": 0, "zProjection": "max", **graph.get("sourceParameters", {})}
    else:
        if "sourceParameters" in graph:
            fail("invalid-graph", "Volume graphs use channel and job timeIndices, without a projection.")
        graph["channel"] = graph.get("channel", 0)
    nodes = graph["nodes"]
    if len({item["id"] for item in nodes}) != len(nodes):
        fail("invalid-graph", "Every node requires a unique ID.")
    by_id = {item["id"]: item for item in nodes}
    for node in nodes:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", node["id"]):
            fail("invalid-graph", "Node IDs must begin with a letter and contain only letters, digits, underscores or hyphens.", node["id"])
        if node["type"] in ("summary", "mask-merge"):
            if "input" in node or not node.get("inputs") or len(set(node["inputs"])) != len(node["inputs"]):
                fail("invalid-graph", "Summary requires distinct inputs and no single input field.", node["id"])
        elif "inputs" in node or not node.get("input"):
            fail("invalid-graph", "This node requires exactly one input.", node["id"])
        if node["type"] == "mask-merge" and len(node["inputs"]) != 2:
            fail("invalid-graph", "Mask merge requires exactly two distinct analyzed inputs.", node["id"])
        port = paired_port(node)
        for key in ("nuclearInput", "somaInput"):
            if node.get(key) and (port is None or key != port[0]):
                fail("invalid-graph", "The paired input port does not belong to this assay.", node["id"])
        if "sourceChannel" in node and node["type"] not in SEGMENTATION:
            fail("invalid-graph", "sourceChannel belongs only to a segmentation node.", node["id"])
        for dependency in parents(node):
            if dependency != SOURCE and dependency not in by_id:
                fail("invalid-graph", "A node input does not exist.", node["id"], input=dependency)
    summaries = [node for node in nodes if node["type"] == "summary"]
    exports = [node for node in nodes if node["type"] == "export"]
    segments = [node for node in nodes if node["type"] in SEGMENTATION]
    if len(summaries) != 1 or len(exports) > 1 or len(segments) > MAX_BRANCHES or not (segments or any(raw_assay(node) for node in nodes)):
        fail("invalid-graph", "Use one summary, zero or one export, at most eight segmentation branches, and at least one segmentation or raw assay node.")
    pending = dict(by_id)
    ordered, outputs = [], {SOURCE: {"outputKind": "raw", "selection": _selection(graph), "processed": False}}
    while pending:
        # Stable independent of caller node array order.
        available = sorted(identifier for identifier, node in pending.items()
                           if all(parent in outputs for parent in parents(node)))
        if not available:
            fail("graph-cycle", "The graph contains a cycle or a dependency that cannot be scheduled.", sorted(pending)[0])
        identifier = available[0]
        node = pending.pop(identifier)
        kind, raw = node["type"], step_of(node)
        incoming = [outputs[parent] for parent in parents(node)]
        selected = copy.deepcopy(incoming[0]["selection"])
        if kind in SEGMENTATION and "sourceChannel" in node:
            if incoming[0]["processed"] and node["sourceChannel"] != 0:
                fail("graph-selector-mismatch", "A processed acquisition contains only channel 0.", identifier)
            selected["channel"] = node["sourceChannel"]
        expected = accepted_inputs(node)
        if any(item["outputKind"] not in expected for item in incoming):
            fail("invalid-graph-port", "This node requires compatible inputs: " + ", ".join(sorted(expected)) + ".", identifier)
        try:
            if kind == "preprocessing":
                if set(raw) - {"type", "recipe", "engineVersion"} or "recipe" not in raw:
                    fail("invalid-graph", "Preprocessing accepts only its recipe and engineVersion.", identifier)
                if raw.get("engineVersion", ENGINE_VERSION) != ENGINE_VERSION:
                    fail("preprocessing-changed", "Save this recipe using the current preprocessing engine.", identifier)
                raw = {"type": kind, "recipe": normalize_recipe(raw["recipe"], 3 if graph["target"] == "volume" else 2), "engineVersion": ENGINE_VERSION}
                selected = ({"target": "volume", "timeIndex": 0, "channel": 0} if graph["target"] == "volume" else
                            {"target": "plane", "channel": 0, "zProjection": "max"})
            elif kind in SEGMENTATION:
                raw = _inherit(raw, selected, identifier)
                raw = workflows._validated_steps([raw, {"type": "measurements"}, {"type": "summary"}], document)[0]
                if kind == "model-segmentation" and incoming[0]["processed"] and any(key.startswith("additionalChannel") for key in raw["modelParameters"]):
                    fail("incompatible-preprocessing-model", "A processed graph acquisition contains one channel; use the original multichannel source for this model.", identifier)
            elif kind == "review":
                if set(raw) - {"type", "prompt", "requireHuman"}:
                    fail("invalid-graph", "Review accepts only a prompt and human-decision policy.", identifier)
                raw = {"type": kind, "prompt": raw.get("prompt", "Review the exact saved mask before continuing."), "requireHuman": raw.get("requireHuman", True)}
            elif kind == "mask-merge":
                if set(raw) - {"type", "mode", "connectivity"} or raw.get("mode") not in ("union", "intersection"):
                    fail("invalid-graph", "Mask merge needs a declared union/intersection mode and connectivity.", identifier)
                if any(item["selection"].get(key) != selected.get(key) for item in incoming for key in ("target", "timeIndex", "zProjection")):
                    fail("invalid-graph-port", "Mask merge inputs must share projection/time and dimensionality.", identifier)
                raw = {"type": kind, "mode": raw["mode"], "connectivity": raw.get("connectivity", "faces")}
            elif kind in ("assay", "plugin-measurement"):
                paired = paired_port(node)
                if paired:
                    if graph["target"] != "plane" or not node.get(paired[0]) or node[paired[0]] == node["input"]:
                        fail("invalid-graph-port", "This assay requires distinct analyzed primary and paired plane branches.", identifier)
                    if paired[1] in raw.get("assayParameters", {}):
                        fail("invalid-graph-reference", "Use " + paired[0] + " instead of a hardcoded image ID.", identifier)
                    raw.setdefault("assayParameters", {})[paired[1]] = "$graph-bound-reference"
                synthetic = _inherit({"type": "volume-analysis" if graph["target"] == "volume" else "analysis"}, selected, identifier)
                raw = workflows._validated_steps([synthetic, raw, {"type": "measurements"}, {"type": "summary"}], document)[1]
                if kind == "assay":
                    if paired:
                        raw["assayParameters"].pop(paired[1])
                    if incoming[0]["processed"]:
                        if raw["assay"] in ("colocalization", "live_dead"):
                            fail("incompatible-preprocessing-assay", "A processed branch retains one channel; multichannel assays require an unprocessed source branch.", identifier)
                        for key, item in raw["assayParameters"].items():
                            if (key == "channel" or key.endswith("_channel") or key.startswith("channel_")) and item != 0:
                                fail("incompatible-preprocessing-assay", "Processed branch assays must select channel 0.", identifier)
            elif kind == "export":
                if set(raw) - {"type", "destination"} or node["input"] != summaries[0]["id"]:
                    fail("invalid-graph", "Export consumes the single summary and accepts only a destination.", identifier)
                if "destination" in raw:
                    raw["destination"] = str(absolute_path(raw["destination"], "destination"))
                    if not raw["destination"].lower().endswith(".zip"):
                        fail("invalid-path", "Complete-project export requires a .zip destination.", identifier)
            elif set(raw) != {"type"}:
                fail("invalid-graph", "Measurements and summary do not accept scientific parameter fields.", identifier)
        except WorkbenchError as exc:
            details = dict(exc.details) if isinstance(exc.details, dict) else {}
            details.setdefault("nodeId", identifier)
            raise WorkbenchError(exc.code, str(exc), details)
        normalized = {"id": identifier, **({"name": node["name"]} if "name" in node else {}),
                      **({"inputs": list(node["inputs"])} if kind in ("summary", "mask-merge") else {"input": node["input"]}),
                      **{key: node[key] for key in ("nuclearInput", "somaInput") if node.get(key)},
                      **({"sourceChannel": node["sourceChannel"]} if "sourceChannel" in node else {}), **raw}
        ordered.append(normalized)
        outputs[identifier] = {"outputKind": output_kind(node, incoming[0]["outputKind"]),
                               "selection": selected, "processed": kind == "preprocessing" or incoming[0]["processed"]}
    summary_id = summaries[0]["id"]
    reachable = set()
    def visit(identifier):
        if identifier == SOURCE or identifier in reachable:
            return
        reachable.add(identifier)
        node = by_id[identifier]
        for parent in parents(node):
            visit(parent)
    visit(summary_id)
    missing = sorted(node["id"] for node in nodes if node["type"] != "export" and node["id"] not in reachable)
    if missing:
        fail("unused-graph-node", "Every scientific branch must contribute to the summary; connect its terminal node explicitly.", missing[0])
    graph["nodes"] = ordered
    return graph, [{"nodeId": node["id"], **outputs[node["id"]]} for node in ordered]


def scientific_nodes(workflow):
    return [node for node in workflow["graph"]["nodes"] if node["type"] in SCIENCE]


def _sources(document, graph, arguments):
    from _workbench_workflows import _image
    from _workbench_preprocessing import _source_fingerprint
    from _workbench_volume import selection, dimensions, MAX_VOLUME_VOXELS
    from math import prod
    identifiers = arguments["imageIds"]
    if len(identifiers) != len(set(identifiers)):
        fail("invalid-arguments", "Select each acquisition once.")
    if graph["target"] == "plane" and "timeIndices" in arguments:
        fail("invalid-arguments", "Plane graphs do not take timeIndices.")
    checkpoints = []
    node_count = sum(node["type"] in SCIENCE for node in graph["nodes"])
    maximum_sources = MAX_CHECKPOINTS // node_count
    for image_id in identifiers:
        image = _image(document, image_id)
        for node in graph["nodes"]:
            if node.get("sourceChannel", 0) >= image["channels"]:
                fail("invalid-source-selection", "A branch sourceChannel is unavailable in this acquisition.", node["id"], imageId=image_id)
        if graph["target"] == "plane":
            if image.get("timeCount", 1) != 1 or graph["sourceParameters"]["channel"] >= image["channels"]:
                fail("invalid-source-selection", "Plane graph inputs need one time point and an available source channel.", imageId=image_id)
            selected = [{"target": "plane", **graph["sourceParameters"]}]
        else:
            times = arguments.get("timeIndices", range(image.get("timeCount", 1)))
            if len(times) + len(checkpoints) > maximum_sources:
                fail("graph-job-too-large", "Selected sources and times exceed the graph's 5,000 node-checkpoint bound.")
            if "timeIndices" in arguments and len(set(times)) != len(times):
                fail("invalid-arguments", "timeIndices must be distinct.")
            if prod(dimensions(image)) > MAX_VOLUME_VOXELS:
                fail("volume-too-large", "A selected volume exceeds the canonical full-resolution volume limit. Extract a bounded region before running this graph.", imageId=image_id)
            selected = []
            for time in sorted(times):
                selection(image, time, graph["channel"])
                selected.append({"target": "volume", "timeIndex": time, "channel": graph["channel"]})
        for item in selected:
            if len(checkpoints) >= maximum_sources:
                fail("graph-job-too-large", "Selected sources exceed the graph's 5,000 node-checkpoint bound.")
            checkpoints.append({"imageId": image_id, **({"timeIndex": item["timeIndex"]} if "timeIndex" in item else {}),
                                "sourceSelection": item, "sourceFingerprint": _source_fingerprint(image, item), "status": "pending"})
    return checkpoints


def preview(document, arguments):
    graph, outputs = normalize(document, arguments["graph"])
    result = {"graph": graph, "order": [node["id"] for node in graph["nodes"]], "nodeOutputs": outputs,
              "limits": limits(), "notes": notes()}
    if "timeIndices" in arguments and "imageIds" not in arguments:
        fail("invalid-arguments", "Select imageIds when budgeting timeIndices.")
    if "imageIds" in arguments:
        sources = _sources(document, graph, arguments)
        nodes = [node for node in graph["nodes"] if node["type"] in SCIENCE]
        new_images = len(sources) * sum(node["type"] in ("preprocessing", "mask-merge") or node["type"] in SEGMENTATION for node in nodes)
        units = len(sources) * len(nodes)
        if units > MAX_CHECKPOINTS:
            fail("graph-job-too-large", "A graph job supports at most 5,000 scientific node checkpoints.")
        if len(document["images"]) + new_images > image_capacity(document):
            fail("project-too-large", "The graph's independent processing/segmentation outputs would exceed 1,000 project images.")
        for kind, field in (("assay", "assayRuns"), ("plugin", "pluginRuns")):
            count = sum(node["type"] == "assay" if kind == "assay" else node["type"].startswith("plugin-") for node in nodes) * len(sources)
            if len(document.get(field, [])) + count > 1000:
                fail("graph-result-limit", "The graph would exceed the project's retained assay/plugin result limit.")
        result["plan"] = {"sourceCount": len(arguments["imageIds"]), "checkpointCount": len(sources),
                          "nodeCheckpointCount": units, "newImageCount": new_images,
                          "segmentationBranchCount": sum(node["type"] in SEGMENTATION for node in nodes)}
    return result


def save(document, arguments):
    from _workbench_store import utc_now
    from _workbench_workflows import get_workflow
    graph, _ = normalize(document, arguments["graph"])
    versions = document.setdefault("workflows", [])
    if len(versions) >= 1000:
        fail("project-too-large", "A project supports at most 1,000 saved workflow versions.")
    previous = get_workflow(document, arguments["workflowId"]) if arguments.get("workflowId") else None
    workflow = {"id": previous["id"] if previous else str(uuid.uuid4()), "name": arguments["name"],
                "version": previous["version"] + 1 if previous else 1, "kind": "dag", "execution": "dag",
                "graph": graph, "steps": [step_of(node) for node in graph["nodes"]],
                "createdAt": utc_now(), "createdRevision": document["revision"] + 1}
    versions.append(workflow)
    return {"workflow": copy.deepcopy(workflow)}


def create_job(document, workflow, arguments):
    from _workbench_store import utc_now
    from _workbench_schema import absolute_path
    workflow = copy.deepcopy(workflow)
    budget = preview(document, {"graph": workflow["graph"], **{key: arguments[key] for key in ("imageIds", "timeIndices") if key in arguments}})
    if budget["graph"] != workflow["graph"]:
        fail("workflow-changed", "The saved graph no longer matches this runtime. Save a new graph version before running it.")
    export = next((node for node in workflow["graph"]["nodes"] if node["type"] == "export"), None)
    if "exportDestination" in arguments:
        if export is None:
            fail("invalid-graph", "This graph has no export node.")
        export["destination"] = str(absolute_path(arguments["exportDestination"], "exportDestination"))
    if export:
        if not export.get("destination"):
            fail("export-destination-required", "Supply a fresh exportDestination for this graph job.", export["id"])
        destination = absolute_path(export["destination"], "destination")
        if destination.suffix.lower() != ".zip" or not destination.parent.is_dir() or destination.exists():
            fail("invalid-path", "Graph export needs a new .zip file in an existing directory.", export["id"])
    workflow["steps"] = [step_of(node) for node in workflow["graph"]["nodes"]]
    checkpoints = _sources(document, workflow["graph"], arguments)
    for checkpoint in checkpoints:
        checkpoint["nodes"] = [{"nodeId": node["id"], "status": "pending"} for node in scientific_nodes(workflow)]
    now = utc_now()
    job = {"id": str(uuid.uuid4()), "kind": "dag", "name": workflow["name"], "workflow": workflow,
           "definitionHash": digest(workflow), "imageIds": list(arguments["imageIds"]), "checkpoints": checkpoints,
           "createdAt": now, "updatedAt": now, "createdRevision": document["revision"] + 1, "status": "pending"}
    document.setdefault("jobs", []).append(job)
    return {"job": describe(job, document)}


def next_unit(job):
    if job["status"] in ("completed", "cancelled"):
        return None
    nodes = scientific_nodes(job["workflow"])
    for checkpoint_index, checkpoint in enumerate(job["checkpoints"]):
        for node_index, saved in enumerate(checkpoint["nodes"]):
            if saved["status"] != "completed":
                node = nodes[node_index]
                return {"type": "graph-node", "nodeId": node["id"], "nodeType": node["type"],
                        "checkpointIndex": checkpoint_index, "nodeIndex": node_index,
                        **({"requiresReview": True, "nextAction": "job.graph.review.get"} if saved["status"] == "awaiting-review" else {}),
                        "imageId": checkpoint["imageId"], **({"timeIndex": checkpoint["timeIndex"]} if "timeIndex" in checkpoint else {})}
    for kind in ("summary", "export"):
        node = next((item for item in job["workflow"]["graph"]["nodes"] if item["type"] == kind), None)
        if node and kind not in job:
            return {"type": kind, "nodeId": node["id"]}
    return None


def progress(job):
    complete = sum(node["status"] == "completed" for item in job["checkpoints"] for node in item["nodes"])
    final = sum(node["type"] in ("summary", "export") for node in job["workflow"]["graph"]["nodes"])
    return {"completed": complete + int("summary" in job) + int("export" in job),
            "total": len(job["checkpoints"]) * len(scientific_nodes(job["workflow"])) + final}


def binding(image, selected, analyzed):
    from _workbench_preprocessing import _source_fingerprint
    import _workbench_support as support
    from _workbench_workflows import image_fingerprint
    from _workbench_volume import current_frame, input_fingerprint
    result = {"imageId": image["id"], "selection": copy.deepcopy(selected), "sourcePath": image["sourcePath"],
              "sourceHash": image["sourceHash"], "sourceFingerprint": _source_fingerprint(image, selected),
              "derivationHash": digest(image.get("derivation")), "analyzed": analyzed}
    if support.descriptor(image):
        result.update({"supportPath": support.descriptor(image)["path"], "supportHash": support.descriptor(image)["hash"]})
    if analyzed:
        if selected["target"] == "volume":
            analysis = current_frame(None, image, selected["timeIndex"], selected["channel"], verify=False)
            result["analysisFingerprint"] = input_fingerprint(image, selected["timeIndex"], selected["channel"])
        else:
            from _workbench_core import _current_analysis
            analysis = _current_analysis(None, image, verify_files=False)
            result["analysisFingerprint"] = image_fingerprint(image)
        result.update({"labelsPath": analysis["labelsPath"], "labelsHash": analysis["labelsHash"]})
    return result


def _stale(document, job):
    from _workbench_preprocessing import _source_fingerprint
    from _workbench_plugins import checkpoint_outputs_current
    from _workbench_workflows import assay_outputs_current
    images = image_index(document)
    from _workbench_indexed import collection_index
    plugin_runs = collection_index(document, "pluginRuns")
    assay_runs = collection_index(document, "assayRuns")
    stale_images, stale_nodes = set(), []
    cache = {}
    for index, checkpoint in enumerate(job["checkpoints"]):
        source = images.get(checkpoint["imageId"])
        if source is None or _source_fingerprint(source, checkpoint["sourceSelection"]) != checkpoint["sourceFingerprint"]:
            stale_images.add(checkpoint["imageId"])
        for node in checkpoint["nodes"]:
            if node["status"] not in ("completed", "awaiting-review"):
                continue
            current = True
            bindings = ([node["review"]["inputBinding"]] if node["status"] == "awaiting-review" else [node["inputBinding"], node["outputBinding"]])
            bindings += node.get("secondaryInputBindings", [])
            for saved in bindings:
                key = (saved["imageId"], digest(saved["selection"]), saved["analyzed"])
                if key not in cache:
                    image = images.get(saved["imageId"])
                    try:
                        cache[key] = binding(image, saved["selection"], saved["analyzed"]) if image else None
                    except Exception:
                        cache[key] = None
                if cache[key] != saved:
                    current = False
                    stale_images.add(saved["imageId"])
            if not checkpoint_outputs_current(document, node, plugin_runs) or not assay_outputs_current(document, node, assay_runs):
                current = False
            if not current:
                stale_nodes.append({"checkpointIndex": index, "nodeId": node["nodeId"], "imageId": checkpoint["imageId"]})
    return sorted(stale_images), stale_nodes


def check_inputs(document, job):
    images, nodes = _stale(document, job)
    if images or nodes:
        fail("stale-job-input", "A graph source, branch mask, calibration, support or retained result changed. Completed branches remain intact; create a new job for the changed inputs.",
             nodes[0]["nodeId"] if nodes else None, imageIds=images, staleNodes=nodes)


def describe(job, document, compact=False, current_project_fingerprint=None):
    from _workbench_workflows import project_fingerprint
    result = {key: copy.deepcopy(value) for key, value in job.items()
              if not compact or key not in ("checkpoints", "summary", "export")}
    stale_images, stale_nodes = _stale(document, job)
    result.update({"nextUnit": next_unit(job), "progress": progress(job), "staleImageIds": stale_images,
                   "staleNodeIds": stale_nodes, "staleReferenceImageIds": [],
                   "workingImageIds": list(dict.fromkeys(node["outputBinding"]["imageId"] for checkpoint in job["checkpoints"]
                       for node in checkpoint["nodes"] if node.get("outputBinding", {}).get("analyzed")))})
    export_fingerprint = job.get("export", {}).get("projectInputFingerprint")
    result["exportInputsCurrent"] = export_fingerprint is None or export_fingerprint == (current_project_fingerprint or project_fingerprint(document))
    result["outputsCurrent"] = not stale_images and not stale_nodes and result["exportInputsCurrent"]
    result["nodeProgress"] = [{"nodeId": node["id"], "type": node["type"],
        "completed": sum(saved["status"] == "completed" for checkpoint in job["checkpoints"] for saved in checkpoint["nodes"] if saved["nodeId"] == node["id"])
            if node["type"] in SCIENCE else int(node["type"] in job),
        "total": len(job["checkpoints"]) if node["type"] in SCIENCE else 1} for node in job["workflow"]["graph"]["nodes"]]
    from _workbench_graph_controls import pending_review
    result["pendingReview"] = pending_review(document, job)
    result["notes"] = notes()
    return result


def advance_node(store, document, job, unit, revision):
    import _workbench_core as core
    import _workbench_workflows as workflows
    import _workbench_variants as variants
    from _workbench_store import utc_now
    checkpoint = job["checkpoints"][unit["checkpointIndex"]]
    saved = checkpoint["nodes"][unit["nodeIndex"]]
    node = scientific_nodes(job["workflow"])[unit["nodeIndex"]]
    if node["id"] != unit["nodeId"] or saved["nodeId"] != node["id"] or saved["status"] not in ("pending", "awaiting-review"):
        fail("graph-checkpoint-integrity", "The next graph node does not match its durable checkpoint.", node["id"])
    first_input = parents(node)[0]
    if first_input == SOURCE:
        image = workflows._image(document, checkpoint["imageId"])
        incoming = binding(image, checkpoint["sourceSelection"], False)
    else:
        previous = next(item for item in checkpoint["nodes"] if item["nodeId"] == first_input)
        if previous["status"] != "completed":
            fail("graph-dependency-pending", "The node's input has not completed.", node["id"])
        incoming = copy.deepcopy(previous["outputBinding"])
        image = workflows._image(document, incoming["imageId"])
    secondary = []
    for parent_id in parents(node)[1:]:
        other = next(item for item in checkpoint["nodes"] if item["nodeId"] == parent_id)
        if other["status"] != "completed":
            fail("graph-dependency-pending", "The paired mask input has not completed.", node["id"])
        secondary.append(copy.deepcopy(other["outputBinding"]))
    selected = copy.deepcopy(incoming["selection"])
    if node["type"] in SEGMENTATION and "sourceChannel" in node:
        selected["channel"] = node["sourceChannel"]
    step = step_of(node)
    retained = {}
    if node["type"] == "review":
        from _workbench_graph_controls import enter_review
        enter_review(job, checkpoint, node, saved, incoming, revision)
        return
    if node["type"] == "mask-merge":
        from _workbench_graph_controls import merge_masks
        image, retained = merge_masks(store, document, node, incoming, secondary[0], revision,
            {"image": core._image, "current_analysis": core._current_analysis, "labels": core._labels, "source": core._source, "set_analysis": core._set_analysis})
    elif node["type"] == "preprocessing":
        temporary_checkpoint = {"imageId": image["id"], "sourceSelection": selected}
        image, retained = workflows.execute_preprocessing_step(store, document, step, temporary_checkpoint, revision,
                                                               {"image": core._image, "source": core._source})
        selected = temporary_checkpoint["workingSelection"]
        image["workflowBranch"] = {"jobId": job["id"], "nodeId": node["id"], "sourceImageId": checkpoint["imageId"],
                                   "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"])}
    else:
        if node["type"] in SEGMENTATION:
            created = variants.execute(store, document, {"imageId": image["id"],
                "name": (image["name"][:95] + " · " + node.get("name", node["id"]))[:200], "copyAnalysis": False}, revision,
                {"image": core._image, "current_analysis": core._current_analysis})
            image = workflows._image(document, created["imageId"])
            image["workflowBranch"] = {"jobId": job["id"], "nodeId": node["id"], "sourceImageId": checkpoint["imageId"],
                                       "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"])}
        port = paired_port(node)
        if port:
            from _workbench_graph_controls import paired_images
            paired_images(document, incoming, secondary[0])
            step["assayParameters"][port[1]] = secondary[0]["imageId"]
        if node["type"] == "measurements":
            if selected["target"] == "volume":
                from _workbench_volume import current_frame
                analysis = current_frame(store, image, selected["timeIndex"], selected["channel"])
            else:
                analysis = core._current_analysis(store, image)
            retained = {"cellCount": len(analysis["cells"]), "analysisRevision": analysis["analysisRevision"],
                        "measurementRevision": analysis["measurementRevision"]}
        else:
            execution = {"imageId": image["id"], "sourceSelection": selected, **({key: selected[key] for key in ("timeIndex", "channel")} if selected["target"] == "volume" else {})}
            retained = core._execute_scientific_step(store, document, step, execution, revision)
    if node["type"] == "mask-merge":
        image["workflowBranch"] = {"jobId": job["id"], "nodeId": node["id"], "sourceImageId": checkpoint["imageId"], "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"])}
    if secondary:
        saved["secondaryInputBindings"] = secondary
    saved.update({"status": "completed", "inputBinding": incoming,
                  "outputBinding": binding(image, selected, node["type"] != "preprocessing" and not (raw_assay(node) and not incoming["analyzed"])),
                  "stepResults": [{"type": node["type"], "nodeId": node["id"], "completedRevision": revision, **retained}],
                  "completedRevision": revision, "completedAt": utc_now()})
    checkpoint["status"] = "completed" if all(item["status"] == "completed" for item in checkpoint["nodes"]) else "running"


def summarize(store, document, job):
    import _workbench_core as core
    import _workbench_workflows as workflows
    import _workbench_volume as volume
    node = next(item for item in job["workflow"]["graph"]["nodes"] if item["type"] == "summary")
    branches = []
    for node_id in node["inputs"]:
        records = []
        for checkpoint in job["checkpoints"]:
            saved = next(item for item in checkpoint["nodes"] if item["nodeId"] == node_id)
            bound = saved["outputBinding"]
            image = workflows._image(document, bound["imageId"])
            if not bound["analyzed"]:
                summary = {"sourceRevision": document["revision"], "imageCount": 1, "cellCount": None,
                           "objectsAvailable": False, "aggregation": "source-intensity-assay; no segmentation was performed"}
            elif bound["selection"]["target"] == "volume":
                selected = bound["selection"]
                frame = volume.current_frame(store, image, selected["timeIndex"], selected["channel"])
                summary = volume.summary({**document, "images": [{**image, "volumeFrames": [frame]}]})
            else:
                core._current_analysis(store, image)
                summary = core._summary({**document, "images": [image]})
            related = [item for item in checkpoint["nodes"] if item.get("outputBinding", {}).get("imageId") == image["id"]]
            records.append({"sourceImageId": checkpoint["imageId"], "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"]),
                            "imageId": image["id"], "selection": copy.deepcopy(bound["selection"]), "summary": summary,
                            "stepResults": [copy.deepcopy(result) for item in related for result in item.get("stepResults", [])]})
        definition = next(item for item in job["workflow"]["graph"]["nodes"] if item["id"] == node_id)
        branches.append({"nodeId": node_id, "nodeName": definition.get("name", node_id), "records": records})
    return {"kind": "dag", "scope": "separate-technical-branches", "branches": branches,
            "sourceImageIds": list(job["imageIds"]), "notes": notes()}


def artifact_references(document):
    references = {}
    for job in document.get("jobs", []):
        if job.get("kind") != "dag":
            continue
        for checkpoint in job["checkpoints"]:
            for node in checkpoint["nodes"]:
                bindings = [node.get("inputBinding", {}), node.get("outputBinding", {}), node.get("review", {}).get("inputBinding", {})]
                bindings += node.get("secondaryInputBindings", [])
                bindings += [node.get("correctionOrigin", {}).get(key, {}) for key in ("correctedInputBinding", "previousOutputBinding")]
                for value in bindings:
                    for prefix in ("source", "labels", "support"):
                        if prefix + "Path" in value:
                            references[value[prefix + "Path"]] = value[prefix + "Hash"]
    return references


def _validate_retained_graph(workflow, schema):
    from _workbench_schema import validate_value
    graph = workflow["graph"]
    validate_value(graph, schema, "workflow.graph")
    if workflow["steps"] != [step_of(node) for node in graph["nodes"]]:
        fail("invalid-package", "A graph's compatibility step view differs from its retained nodes.")
    if (graph["target"] == "plane" and ("channel" in graph or "sourceParameters" not in graph) or
            graph["target"] == "volume" and ("sourceParameters" in graph or "channel" not in graph)):
        fail("invalid-package", "Retained graph source selectors are not normalized.")
    outputs = {SOURCE: {"kind": "raw", "selection": _selection(graph)}}
    by_id, summary_nodes, export_nodes = {}, [], []
    for node in graph["nodes"]:
        identifier, kind = node["id"], node["type"]
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", identifier) or identifier in by_id:
            fail("invalid-package", "Retained graph node identities are invalid or duplicated.", identifier)
        if kind in ("summary", "mask-merge"):
            if "input" in node or not node.get("inputs") or len(set(node["inputs"])) != len(node["inputs"]):
                fail("invalid-package", "Retained graph summary inputs are inconsistent.", identifier)
            if kind == "summary": summary_nodes.append(identifier)
            if kind == "mask-merge" and (len(node["inputs"]) != 2 or node.get("mode") not in ("union", "intersection")):
                fail("invalid-package", "Retained mask merge ports/mode are unsupported.", identifier)
            dependencies = node["inputs"]
        else:
            if "inputs" in node or not node.get("input"):
                fail("invalid-package", "A retained graph node must have exactly one input.", identifier)
            dependencies = parents(node)
        expected = accepted_inputs(node)
        if any(parent not in outputs or outputs[parent]["kind"] not in expected for parent in dependencies):
            fail("invalid-package", "Retained graph nodes must be acyclic, ordered and connected to compatible ports.", identifier)
        selected = copy.deepcopy(outputs[dependencies[0]]["selection"])
        if kind in SEGMENTATION:
            if "sourceChannel" in node: selected["channel"] = node["sourceChannel"]
            _inherit(step_of(node), selected, identifier)
        if kind == "preprocessing":
            selected = ({"target": "volume", "timeIndex": 0, "channel": 0} if graph["target"] == "volume" else
                        {"target": "plane", "channel": 0, "zProjection": "max"})
        port = paired_port(node)
        if port:
            if graph["target"] != "plane" or not node.get(port[0]) or port[1] in node.get("assayParameters", {}):
                fail("invalid-package", "The retained assay requires its explicit paired branch port.", identifier)
        if any(node.get(key) and (port is None or key != port[0]) for key in ("nuclearInput", "somaInput")):
            fail("invalid-package", "A retained paired input is not supported by this assay.", identifier)
        if kind == "export":
            export_nodes.append(identifier)
        by_id[identifier] = node
        outputs[identifier] = {"kind": output_kind(node, outputs[dependencies[0]]["kind"]),
                               "selection": selected}
    if len(summary_nodes) != 1 or len(export_nodes) > 1 or sum(node["type"] in SEGMENTATION for node in graph["nodes"]) > MAX_BRANCHES or not any(node["type"] in SEGMENTATION or raw_assay(node) for node in graph["nodes"]):
        fail("invalid-package", "Retained graph terminal or segmentation-node counts are unsupported.")
    reachable, pending = set(), [summary_nodes[0]]
    while pending:
        identifier = pending.pop()
        if identifier == SOURCE or identifier in reachable:
            continue
        reachable.add(identifier)
        node = by_id[identifier]
        pending.extend(parents(node))
    if any(node["type"] != "export" and node["id"] not in reachable for node in graph["nodes"]):
        fail("invalid-package", "Every retained scientific branch must contribute to its summary.")


def validate_document(document):
    schema = schemas()[1]
    for workflow in document.get("workflows", []):
        if workflow.get("kind") == "dag":
            _validate_retained_graph(workflow, schema)
    for job in document.get("jobs", []):
        if job.get("kind") != "dag":
            continue
        workflow = job["workflow"]
        _validate_retained_graph(workflow, schema)
        if job["definitionHash"] != digest(workflow):
            fail("invalid-package", "A retained graph job's immutable definition changed.")
        expected = [node["id"] for node in scientific_nodes(workflow)]
        if len(job["checkpoints"]) * len(expected) > MAX_CHECKPOINTS:
            fail("invalid-package", "A graph job exceeds its checkpoint budget.")
        for checkpoint in job["checkpoints"]:
            if [node["nodeId"] for node in checkpoint["nodes"]] != expected:
                fail("invalid-package", "Graph node checkpoint identities differ from their definition.")
            if any(node["status"] not in ("pending", "completed", "awaiting-review") for node in checkpoint["nodes"]):
                fail("invalid-package", "Unsupported graph node checkpoint state.")
            completed = {}
            definitions = {node["id"]: node for node in scientific_nodes(workflow)}
            for saved in checkpoint["nodes"]:
                if saved.get("review"):
                    review = saved["review"]
                    if review.get("inputFingerprint") != digest(review.get("inputBinding")) or any(
                            record.get("inputFingerprint") != review["inputFingerprint"] for record in review.get("recommendations", []) + review.get("decisions", [])):
                        fail("invalid-package", "A retained graph review no longer matches its exact input fingerprint.")
                    if definitions[saved["nodeId"]]["type"] != "review" or (saved["status"] == "completed" and
                            (not review.get("decisions") or review["decisions"][-1].get("decision") != "approve")):
                        fail("invalid-package", "A completed review gate requires its retained approval decision.")
                if saved["status"] in ("pending", "awaiting-review"):
                    if any(key in saved for key in ("inputBinding", "outputBinding", "stepResults")):
                        fail("invalid-package", "A pending graph checkpoint cannot contain completed outputs.")
                    if saved["status"] == "awaiting-review":
                        node = definitions[saved["nodeId"]]
                        review = saved.get("review", {})
                        if node["type"] != "review" or review.get("inputFingerprint") != digest(review.get("inputBinding")):
                            fail("invalid-package", "A review gate lacks exact retained input evidence.")
                    continue
                node = definitions[saved["nodeId"]]
                incoming, outgoing = saved["inputBinding"], saved["outputBinding"]
                first_input = parents(node)[0]
                if first_input == SOURCE:
                    if incoming["imageId"] != checkpoint["imageId"] or incoming["selection"] != checkpoint["sourceSelection"] or incoming["analyzed"]:
                        fail("invalid-package", "A graph source checkpoint binding is inconsistent.", node["id"])
                elif first_input not in completed or incoming != completed[first_input]:
                    fail("invalid-package", "A graph edge no longer refers to its exact retained parent output.", node["id"])
                if node["type"] in SEGMENTATION | {"mask-merge"} and (outgoing["imageId"] == incoming["imageId"] or not outgoing["analyzed"]):
                    fail("invalid-package", "Segmentation branches require independent analyzed output identities.", node["id"])
                if node["type"] == "preprocessing" and (outgoing["imageId"] == incoming["imageId"] or outgoing["analyzed"]):
                    fail("invalid-package", "Processing branches require new raw output identities.", node["id"])
                if node["type"] not in SEGMENTATION | {"mask-merge", "preprocessing"} and outgoing != incoming:
                    fail("invalid-package", "Measurement graph nodes cannot change their input image or mask binding.", node["id"])
                if saved.get("secondaryInputBindings", []) != [completed.get(parent) for parent in parents(node)[1:]]:
                    fail("invalid-package", "Paired graph ports differ from retained ancestor outputs.", node["id"])
                completed[node["id"]] = outgoing


def preview_node(store, document, arguments):
    """Read-only delegation to the same preview operations available to every host."""
    import _workbench_core as core
    import _workbench_workflows as workflows
    from _workbench_schema import WorkbenchError
    job = workflows.get_job(document, arguments["jobId"])
    if job.get("kind") != "dag":
        fail("invalid-graph-job", "Choose a branching workflow job for node previews.")
    index, node_id = arguments["checkpointIndex"], arguments["nodeId"]
    if index >= len(job["checkpoints"]):
        fail("graph-checkpoint-not-found", "The selected source/time checkpoint does not exist.", node_id, checkpointIndex=index)
    node = next((item for item in scientific_nodes(job["workflow"]) if item["id"] == node_id), None)
    if node is None or node["type"] not in ("analysis", "volume-analysis", "preprocessing", "assay", "measurements"):
        fail("unsupported-graph-preview", "This node has no read-only scientific preview. Models and plugins require an explicit execution checkpoint.", node_id)
    try:
        check_inputs(document, job)
    except WorkbenchError as exc:
        details = dict(exc.details) if isinstance(exc.details, dict) else {}
        details.update({"nodeId": node_id, "checkpointIndex": index})
        raise WorkbenchError(exc.code, str(exc), details)
    checkpoint = job["checkpoints"][index]
    if node["input"] == SOURCE:
        incoming = binding(workflows._image(document, checkpoint["imageId"]), checkpoint["sourceSelection"], False)
    else:
        parent = next(item for item in checkpoint["nodes"] if item["nodeId"] == node["input"])
        if parent["status"] != "completed":
            fail("graph-dependency-pending", "Run the upstream node before previewing this retained input.", node_id,
                 checkpointIndex=index, dependencyNodeId=node["input"])
        incoming = copy.deepcopy(parent["outputBinding"])
    selected, kind = copy.deepcopy(incoming["selection"]), node["type"]
    if kind in SEGMENTATION and "sourceChannel" in node: selected["channel"] = node["sourceChannel"]
    args = {"imageId": incoming["imageId"]}
    if kind in ("analysis", "volume-analysis"):
        operation = "analysis.preview" if kind == "analysis" else "volume.analysis.preview"
        args.update({"parameters": node["parameters"], "maxSize": arguments.get("maxSize", 768),
                     "cellLimit": arguments.get("cellLimit", 200)})
        if kind == "volume-analysis":
            args.update({key: selected[key] for key in ("timeIndex", "channel")})
    elif kind == "preprocessing":
        operation = "preprocessing.preview"
        args.update({"recipe": node["recipe"], "target": selected["target"], "maxSize": arguments.get("maxSize", 768)})
        if selected["target"] == "volume":
            args.update({key: selected[key] for key in ("timeIndex", "channel")})
        else:
            args["sourceParameters"] = {key: selected[key] for key in ("channel", "zProjection")}
    elif kind == "assay":
        operation = "assay.preview"
        args.update({"assay": node["assay"], "parameters": copy.deepcopy(node["assayParameters"]), "target": selected["target"]})
        port = paired_port(node)
        if port:
            nuclear = next(item for item in checkpoint["nodes"] if item["nodeId"] == node[port[0]])
            if nuclear["status"] != "completed":
                fail("graph-dependency-pending", "Run the paired branch before previewing this assay.", node_id)
            from _workbench_graph_controls import paired_images
            paired_images(document, incoming, nuclear["outputBinding"])
            args["parameters"][port[1]] = nuclear["outputBinding"]["imageId"]
        if selected["target"] == "volume":
            args.update({key: selected[key] for key in ("timeIndex", "channel")})
        elif raw_assay(node):
            args["sourceParameters"] = {key: selected[key] for key in ("channel", "zProjection")}
    else:
        operation = "measurements.page"
        args.update({"target": selected["target"], "limit": arguments.get("cellLimit", 200), "includeContours": False})
        if selected["target"] == "volume":
            args.update({key: selected[key] for key in ("timeIndex", "channel")})
    try:
        response = core._execute({"schemaVersion": 1, "operation": operation, "requestId": str(uuid.uuid4()),
                                  "projectPath": str(store.root), "expectedRevision": document["revision"], "arguments": args})
    except WorkbenchError as exc:
        details = dict(exc.details) if isinstance(exc.details, dict) else {}
        details.update({"nodeId": node_id, "checkpointIndex": index})
        raise WorkbenchError(exc.code, str(exc), details)
    return {"nodeId": node_id, "checkpointIndex": index, "sourceImageId": checkpoint["imageId"],
            "sourceSelection": copy.deepcopy(checkpoint["sourceSelection"]), "inputBinding": incoming,
            "inputsCurrent": True, "dependencyReasons": [], "operation": operation,
            "mode": "retained-measurements" if kind == "measurements" else "fresh-calculation",
            "preview": response["result"], "notes": [
                "This read-only preview does not complete a checkpoint or replace a retained branch output."]}
