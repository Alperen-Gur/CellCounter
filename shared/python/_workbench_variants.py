"""Independent analysis identities backed by shared immutable acquisition bytes."""
from __future__ import annotations

from _workbench_indexed import image_capacity

import copy
import uuid


def operations():
    from _workbench_schema import _object, _ID, _op
    return [_op("image.duplicate",
                "Create an independent mask variant sharing immutable source pixels and calibration; optionally copy current analyses.",
                _object({"imageId": _ID, "name": {"type": "string", "minLength": 1, "maxLength": 200},
                         "copyAnalysis": {"type": "boolean", "default": False}}, ["imageId"]), True)]


def acquisition_snapshot(source):
    fields = ("sourcePath", "sourceHash", "sourceBytes", "width", "height", "channels",
              "axes", "shape", "dtype", "zCount", "timeCount", "pxPerUm", "voxelSizeUm",
              "timeStepSeconds", "calibrationSource", "channelNames", "derivation", "readerOrigin", "sourceRegion", "validSupport")
    return {key: copy.deepcopy(source[key]) for key in fields if key in source}


def execute(store, document, arguments, revision, hooks, *, verify_source=True):
    from _workbench_schema import WorkbenchError
    from _workbench_store import utc_now
    import _workbench_volume as volume
    if len(document["images"]) >= image_capacity(document):
        raise WorkbenchError("project-too-large", "A project can retain at most 1,000 image identities.")
    source = hooks["image"](document, arguments["imageId"])
    if verify_source:
        store.verify_artifact(source["sourcePath"], source["sourceHash"])
    created = utc_now()
    # Copy only acquisition fields. Review/adaptation approvals, tracking links,
    # workflow state and plugin/assay records belong to the original identity.
    variant = acquisition_snapshot(source)
    variant.update({"id": str(uuid.uuid4()), "name": arguments.get("name", source["name"][:180] + " · variant"),
                    "importedAt": created, "undoStack": [],
                    "variantOf": source["id"], "variantRootId": source.get("variantRootId", source["id"]),
                    "variantCreatedRevision": revision, "variantSourceRevision": document["revision"]})
    preferred = copy.deepcopy(source.get("preferredSourceParameters", {}))
    if source.get("analysis"):
        preferred.update({key: source["analysis"]["parameters"][key] for key in ("channel", "zProjection")})
    variant["preferredSourceParameters"] = {"channel": 0, "zProjection": "max", **preferred}
    preferred_volume = source.get("preferredVolumeSelection")
    if preferred_volume is None and source.get("volumeFrames"):
        recent = max(source["volumeFrames"], key=lambda frame: (frame.get("analysisRevision", 0),
                                                               frame["timeIndex"], frame["channel"]))
        preferred_volume = {key: recent[key] for key in ("timeIndex", "channel")}
    variant["preferredVolumeSelection"] = copy.deepcopy(preferred_volume or {"timeIndex": 0, "channel": 0})
    if arguments.get("copyAnalysis", False):
        if source.get("analysis"):
            original = hooks["current_analysis"](store, source)
            analysis = copy.deepcopy(original)
            analysis.update({"analysisRevision": revision, "measurementRevision": revision, "createdAt": created,
                             "copiedFrom": {"imageId": source["id"], "analysisRevision": original["analysisRevision"]}})
            variant["analysis"] = analysis
        frames = []
        for original in source.get("volumeFrames", []):
            volume.current_frame(store, source, original["timeIndex"], original["channel"])
            frame = copy.deepcopy(original)
            frame.update({"analysisRevision": revision, "measurementRevision": revision, "updatedAt": created,
                          "undoStack": [], "copiedFrom": {"imageId": source["id"],
                                                          "analysisRevision": original["analysisRevision"]}})
            frames.append(frame)
        if frames:
            variant["volumeFrames"] = frames
    copied = bool(variant.get("analysis") or variant.get("volumeFrames"))
    variant["variantCopiedAnalysis"] = copied
    document["images"].append(variant)
    image = {key: copy.deepcopy(value) for key, value in variant.items()
             if key not in ("sourcePath", "analysis", "volumeFrames", "undoStack")}
    image.update({"status": "analyzed" if variant.get("analysis") else
                            "volume-analyzed" if variant.get("volumeFrames") else "imported",
                  "volumeFrameCount": len(variant.get("volumeFrames", [])),
                  "intensityUnits": "processed-source" if variant.get("derivation") else "raw-source"})
    if variant.get("analysis"):
        image.update({key: copy.deepcopy(variant["analysis"][key]) for key in
                      ("analysisRevision", "measurementRevision", "parameters", "inputFingerprint")})
        image["cellCount"] = len(variant["analysis"]["cells"])
    return {"imageId": variant["id"], "sourceImageId": source["id"], "copiedAnalysis": copied,
            "sharedSourceHash": variant["sourceHash"], "image": image}
