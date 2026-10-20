"""Retained multi-channel display exports through the common publication journal."""
from __future__ import annotations

import copy
import io
import uuid


FORMATS = [
    {
        "id": "composite-png",
        "name": "Multi-channel display (PNG)",
        "extension": "png",
        "mediaType": "image/png",
        "description": (
            "A color display up to 2048 pixels per side, with transparent unsupported samples "
            "and embedded channel, intensity-window and source provenance. Scientific measurements are unchanged."
        ),
    },
]


def catalogue():
    return {"formats": copy.deepcopy(FORMATS)}


def operations():
    from _workbench_schema import _object, _op, _STRING
    import _workbench_composite as composite

    schema = copy.deepcopy(composite.argument_schema())
    schema["properties"].update({
        "format": {"type": "string", "enum": [item["id"] for item in FORMATS]},
        "destination": _STRING,
    })
    schema["required"] = [*schema.get("required", []), "format", "destination"]
    return [
        _op(
            "image.composite.export.catalogue",
            "Describe multi-channel display export formats.",
            _object(),
            project=False,
        ),
        _op(
            "image.composite.export",
            "Retain and publish a multi-channel display with exact rendering settings and source provenance.",
            schema,
            True,
        ),
    ]


def prepare_export(store, document, arguments, revision, request_id, actor):
    from _workbench_core import _image
    from _workbench_exports import _destination, _stage_publication, MAX_EXPORTS, MAX_EXPORT_BYTES, fail
    from _workbench_store import canonical, utc_now
    from _workbench_assays import processing_provenance
    from _workbench_packages import runtime_versions
    import _workbench_composite as composite
    import _workbench_support as support
    import _workbench_volume as volume

    if len(document.get("imageExports", [])) >= MAX_EXPORTS:
        fail("export-limit", "A project retains at most 1,000 built-in scientific exports.")
    definition = next(item for item in FORMATS if item["id"] == arguments["format"])
    destination = _destination(arguments, definition)
    image = _image(document, arguments["imageId"])
    rendering_arguments = {
        key: copy.deepcopy(value) for key, value in arguments.items()
        if key not in ("format", "destination")
    }
    view, display = composite.render(store, image, rendering_arguments, document=document)
    from PIL.PngImagePlugin import PngInfo

    provenance = {
        "schemaVersion": 1,
        "engineVersion": display["engineVersion"],
        "exportId": str(uuid.uuid4()),
        "format": definition["id"],
        "projectId": document["id"],
        "sourceRevision": document["revision"],
        "exportRevision": revision,
        "createdAt": utc_now(),
        "requestId": request_id,
        "actor": copy.deepcopy(actor),
        "imageId": image["id"],
        "imageName": image["name"],
        "source": {
            "sha256": image["sourceHash"],
            "axes": image["axes"],
            "shape": copy.deepcopy(image["shape"]),
            "dtype": image["dtype"],
        },
        "voxelSizeUm": volume.calibration(image),
        "timeStepSeconds": image.get("timeStepSeconds"),
        "intensityUnits": "processed-source" if image.get("derivation") else "raw-source",
        "processing": processing_provenance(document, image),
        "displayOnly": True,
        "exportedDtype": "uint8-display",
        "displayRequest": rendering_arguments,
        "display": display,
        "runtimeDependencies": runtime_versions(),
        "notes": [
            "This PNG is a color display; source intensities and scientific measurements are unchanged.",
            "The display records effective channel windows, colors, opacity and gamma; color mixtures are clipped to the display range.",
            "Transparent samples are outside acquired support and must not be interpreted as measured zero intensity.",
            "Pixel dimensions describe the bounded display. Use source exports for native-resolution scientific pixels.",
        ],
    }
    for key in ("sourceRegion", "variantOf", "variantRootId"):
        if key in image:
            provenance[key] = copy.deepcopy(image[key])
    support_value = support.descriptor(image)
    if support_value:
        provenance["sourceSupport"] = {
            key: copy.deepcopy(value) for key, value in support_value.items()
            if key in ("shape", "dtype", "policy", "validPixelCount", "invalidPixelCount")
        }
        provenance["sourceSupport"]["sha256"] = support_value["hash"]

    provenance_path, provenance_hash = store.put_bytes(
        (canonical(provenance) + "\n").encode("utf-8"), ".composite-provenance.json"
    )
    metadata = PngInfo()
    metadata.add_text("CellCounter provenance", canonical(provenance))
    metadata.add_text("CellCounter provenance SHA256", provenance_hash)
    encoded = io.BytesIO()
    view.save(encoded, format="PNG", pnginfo=metadata)
    contents = encoded.getvalue()
    if len(contents) > MAX_EXPORT_BYTES:
        fail("export-too-large", "The multi-channel display exceeds the 256 MiB output budget.")
    file_path, checksum = store.put_bytes(contents, ".composite-export.png")
    selection = copy.deepcopy(display["selection"])
    item = {
        "exportId": provenance["exportId"],
        "kind": "composite",
        "imageId": image["id"],
        "format": definition["id"],
        "target": selection["target"],
        "selection": selection,
        "channels": copy.deepcopy(display["channels"]),
        "displayOnly": True,
        "createdAt": provenance["createdAt"],
        "revision": revision,
        "filePath": file_path,
        "fileHash": checksum,
        "provenancePath": provenance_path,
        "provenanceHash": provenance_hash,
        "sourcePath": image["sourcePath"],
        "sourceHash": image["sourceHash"],
        "destination": str(destination),
        "mediaType": definition["mediaType"],
        "bytes": len(contents),
    }
    if support_value:
        item.update({"supportPath": support_value["path"], "supportHash": support_value["hash"]})
    document.setdefault("imageExports", []).append(item)
    publish, temporary, publication = _stage_publication(contents, destination, checksum)
    return {
        "exportId": item["exportId"],
        "destination": str(destination),
        "sha256": checksum,
        "format": definition["id"],
        "mediaType": definition["mediaType"],
        "bytes": len(contents),
        "imageId": image["id"],
        "target": selection["target"],
        "selection": selection,
        "provenance": provenance,
        "provenanceSha256": provenance_hash,
    }, publish, temporary, publication
