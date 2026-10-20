/** Fixed headless adapter protocol; scientific algorithms stay in shared/microscopy. */
import type { Calibration, Coordinate, ResourceLimits, WorkspaceAxis, ZarrPlaneSelection } from "../microscopy/types";
export const ENGINE_VERSION = "microscopy-worker-1";
export const NODE_VERSION = "24.22.0";
export const WORKER_LIMITS = Object.freeze({ requestBytes: 8 * 1024 ** 2, jsonBytes: 32 * 1024 ** 2,
  inputBytes: 256 * 1024 ** 2, outputBytes: 256 * 1024 ** 2, responseBytes: 16 * 1024 ** 2,
  inputFiles: 1024, readFiles: 65536, stores: 32, planes: 256, animationFrames: 3600 });
export type WorkerOperation = "catalogue" | "workspace.create" | "workspace.import" | "workspace.validate" |
  "workspace.positions" | "workspace.export" | "workspace.compose" | "workspace.replay" | "semantic.render" |
  "lineage.validate" | "lineage.build" | "zarr.inspect" | "zarr.plane" | "animation.gif";
export interface InputFile { id: string; path: string; sha256: string; bytes: number }
export interface StoreGrant { id: string; name: string; root: string; metadataSha256?: string }
/** position identifies the exact acquired plane; no reuse across another T/Z/C position. */
export interface PlaneInput { layerId: string; inputId: string; width: number; height: number; calibration?: Calibration; position?: Record<string, number>; supportInput?: string }
export interface ZarrBinding { layerId: string; storeId: string; selection?: ZarrPlaneSelection; axisMapping?: Record<string, string> }
export interface WorkerRequest {
  schemaVersion: 1; requestId: string; operation: WorkerOperation; arguments: Record<string, unknown>;
  inputs: InputFile[]; stores?: StoreGrant[]; outputDirectory: string; limits?: Partial<ResourceLimits>;
}
export interface OutputFile { id: string; path: string; sha256: string; bytes: number; kind: string; dtype?: string; shape?: number[] }
export interface ReadRecord { storeId: string; path: string; sha256: string | null; bytes: number; missing?: true }
export type WorkerResponse = { schemaVersion: 1; requestId: string; operation: string; engineVersion: string; nodeVersion: string } &
  ({ ok: true; result: Record<string, unknown>; outputs: OutputFile[]; readSet: ReadRecord[] } |
   { ok: false; error: { code: string; message: string }; outputs: []; readSet: ReadRecord[] });
export interface WorkspaceArguments { workspaceInput: string; planes?: PlaneInput[]; zarrBindings?: ZarrBinding[] }
export interface CreateArguments { name: string; axes?: WorkspaceAxis[] }
export interface ComposeArguments extends WorkspaceArguments { position?: Record<string, number>; width?: number; height?: number; origin?: Coordinate; center?: Coordinate; zoom?: number }
export interface RuntimeManifest {
  schemaVersion: 1; engineVersion: string; nodeVersion: string; entrypoint: string;
  node: { path: string; sha256: string; bytes: number; archiveSha256: string; platform: string };
  files: { path: string; sha256: string; bytes: number }[];
}
