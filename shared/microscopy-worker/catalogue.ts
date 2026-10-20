import { DEFAULT_LIMITS } from "../microscopy/types";
import { ENGINE_VERSION, NODE_VERSION, WORKER_LIMITS } from "./protocol";
type Schema = Record<string, unknown>;
const string = { type: "string", minLength: 1, maxLength: 1024 };
const integer = { type: "integer", minimum: 0 };
const finite = { type: "number" };
const object = (properties: Record<string, Schema>, required: string[] = []) => ({ type: "object", properties, required, additionalProperties: false });
const position = { type: "object", maxProperties: 16, additionalProperties: integer };
const coordinate = object({ x: finite, y: finite, z: finite }, ["x", "y"]);
const calibration = object({ x: { type: "number", exclusiveMinimum: 0 }, y: { type: "number", exclusiveMinimum: 0 }, unit: string }, ["x", "y", "unit"]);
const selection = object({ level: integer, t: integer, z: integer, c: integer, indices: position });
const planes = { type: "array", maxItems: 256, items: object({ layerId: string, inputId: string, supportInput: string, width: { ...integer, minimum: 1 }, height: { ...integer, minimum: 1 }, calibration, position }, ["layerId", "inputId", "width", "height"]) };
const zarrBindings = { type: "array", maxItems: 256, items: object({ layerId: string, storeId: string, selection,
  axisMapping: { type: "object", maxProperties: 16, additionalProperties: string } }, ["layerId", "storeId"]) };
const workspace = { workspaceInput: string, planes, zarrBindings };
const axis = object({ id: string, name: string, kind: { type: "string", enum: ["x", "y", "z", "time", "channel", "other"] }, length: { ...integer, minimum: 1 }, scale: { type: "number", exclusiveMinimum: 0 }, unit: string, calibrated: { type: "boolean" } }, ["id", "name", "kind", "length", "scale", "calibrated"]);
export const OPERATION_SCHEMAS: Record<string, Schema> = {
  catalogue: object({}),
  "workspace.create": object({ name: string, axes: { type: "array", maxItems: 16, items: axis } }, ["name"]),
  "workspace.import": object({ inputId: string }, ["inputId"]),
  "workspace.validate": object({ workspaceInput: string }, ["workspaceInput"]),
  "workspace.positions": object({ workspaceInput: string, workflowId: string, planId: string }, ["workspaceInput"]),
  "workspace.export": object(workspace, ["workspaceInput"]),
  "workspace.compose": object({ ...workspace, position, width: { ...integer, minimum: 1 }, height: { ...integer, minimum: 1 }, origin: coordinate, center: coordinate, zoom: { type: "number", exclusiveMinimum: 0, maximum: 64 } }, ["workspaceInput"]),
  "workspace.replay": object({ ...workspace, workflowId: string }, ["workspaceInput", "workflowId"]),
  "semantic.render": object({ workspaceInput: string, layerId: string, position, calibration }, ["workspaceInput", "layerId"]),
  "lineage.validate": object({ inputId: string }, ["inputId"]),
  "lineage.build": object({ inputId: string, maxDistance: { type: "number", exclusiveMinimum: 0 }, calibration,
    maxDistanceEvaluations: { ...integer, minimum: 1, maximum: 10000000 } }, ["inputId", "maxDistance"]),
  "zarr.inspect": object({ storeId: string }, ["storeId"]),
  "zarr.plane": object({ storeId: string, selection }, ["storeId"]),
  "animation.gif": object({ ...workspace, planId: string, width: { ...integer, minimum: 1 }, height: { ...integer, minimum: 1 } }, ["workspaceInput", "planId", "width", "height"]),
};
export function catalogue() {
  return { engineVersion: ENGINE_VERSION, nodeVersion: NODE_VERSION, operations: Object.entries(OPERATION_SCHEMAS).map(([name, argumentSchema]) => ({ name, argumentSchema })),
    limits: { ...WORKER_LIMITS, ...DEFAULT_LIMITS },
    zarr: { storage: "local-directory", format: "Zarr v2", metadata: "OME-NGFF 0.4", codecs: ["uncompressed", "zlib", "gzip"], unsupported: ["Zarr v3 / OME-NGFF 0.5", "Blosc", "filters", "sharding", "remote stores"] },
    notes: ["Float32 planes retain only values supported exactly by the existing workspace engine; source/instance-label authority remains in the canonical project.",
      "Semantic class rasters are uint16 and never imply instance IDs or segmentation approval.",
      "Composition and GIF are presentation outputs. Display transforms do not alter acquired pixels or canonical masks.",
      "Directory grants permit safe local Zarr reads only. Returned file read sets must be rechecked by the canonical parent before publishing provenance."] };
}
