/** Portable local microscopy workspace. Coordinates are pixel-edge coordinates.
 * Physical calibration is explicit: missing calibration is never treated as µm. */
export type AxisKind = 'x' | 'y' | 'z' | 'time' | 'channel' | 'other';
export interface WorkspaceAxis { id: string; name: string; kind: AxisKind; length: number; scale: number; unit?: string; calibrated: boolean }
export interface Calibration { x: number; y: number; unit: string }
export interface ImagePlane { width: number; height: number; values: Float32Array; calibration?: Calibration; support?: Uint8Array }
export interface Coordinate { x: number; y: number; z?: number }
export interface AffineTransform { a: number; b: number; c: number; d: number; tx: number; ty: number }
export type BlendMode = 'normal' | 'additive' | 'multiply' | 'screen' | 'difference';
export type LayerKind = 'image' | 'labels' | 'points' | 'shapes' | 'tracks' | 'surface';
export interface SourceIdentity { id: string; name: string; kind: 'local' | 'zarr' | 'generated'; relativePath?: string; sha256?: string; metadataSha256?: string; byteLength?: number }
export interface LayerSource { identity: SourceIdentity; arrayPath?: string; level?: number; channel?: number; operation?: string }
export interface WorkspacePoint { id: string; coordinate: Coordinate; position: Record<string, number>; label?: string; features?: Record<string, number> }
export interface WorkspaceShape { id: string; kind: 'polygon' | 'rectangle' | 'ellipse' | 'line'; vertices: Coordinate[]; position: Record<string, number>; label?: string }
export interface WorkspaceTrack { id: string; name: string; vertices: { frame: number; coordinate: Coordinate }[] }
export interface WorkspaceSurface { vertices: Coordinate[]; triangles: [number, number, number][] }
export interface WorkspaceLayer {
  id: string; name: string; kind: LayerKind; source: LayerSource; axisIDs: string[];
  visible: boolean; opacity: number; blendMode: BlendMode; transform: AffineTransform;
  display: { min: number; max: number; gamma: number; color: [number, number, number] };
  points?: WorkspacePoint[]; shapes?: WorkspaceShape[]; tracks?: WorkspaceTrack[]; surface?: WorkspaceSurface;
}
export interface LineageNode { id: string; frame: number; coordinate: Coordinate; label?: string; sourceCellID?: string; features?: Record<string, number> }
export type LineageEdgeKind = 'continuation' | 'gap' | 'division' | 'merge';
export interface LineageEdge { id: string; parentID: string; childID: string; kind: LineageEdgeKind }
export interface LineageGraph { nodes: LineageNode[]; edges: LineageEdge[] }
export interface LabelClass { value: number; name: string; colorHex: string }
export interface PaintStroke { id: string; classValue: number; radius: number; points: Coordinate[]; position: Record<string, number>; erases: boolean }
export interface PaintDocument { width: number; height: number; classes: LabelClass[]; strokes: PaintStroke[] }
export type WorkflowStep =
  | { type: 'visibility'; layerID: string; visible: boolean }
  | { type: 'opacity'; layerID: string; opacity: number }
  | { type: 'translate'; layerID: string; x: number; y: number }
  | { type: 'position'; axisID: string; index: number }
  | { type: 'register'; referenceID: string; movingID: string; maxShift: number }
  | { type: 'stitch'; layerIDs: string[]; columns: number; overlap: number; outputName: string };
export interface WorkspaceWorkflow { id: string; name: string; createdAt: string; steps: WorkflowStep[] }
export interface AnimationKeyframe { id: string; timeSeconds: number; position: Record<string, number>; zoom: number; center: Coordinate; visibleLayerIDs: string[] }
export interface AnimationPlan { id: string; name: string; framesPerSecond: number; easing: 'linear' | 'easeInOut'; keyframes: AnimationKeyframe[] }
export interface AnimationFrameState extends Omit<AnimationKeyframe, 'id'> { frameNumber: number }
export interface WorkspaceField { id: string; name: string; path: string; layerIDs: string[] }
export interface WorkspaceWell { id: string; row: number; column: number; label: string; path: string; fields: WorkspaceField[] }
export interface WorkspacePlate { name: string; rows: string[]; columns: string[]; wells: WorkspaceWell[] }
export interface MicroscopyWorkspace {
  schemaVersion: 1; id: string; name: string; createdAt: string; modifiedAt: string;
  axes: WorkspaceAxis[]; position: Record<string, number>; layers: WorkspaceLayer[];
  lineage: LineageGraph; paintDocuments: Record<string, PaintDocument>;
  workflows: WorkspaceWorkflow[]; animationPlans: AnimationPlan[]; plate?: WorkspacePlate;
}
/** The adapter must enforce maxBytes BEFORE reading/allocating file bytes. Never fetch remote data. */
export interface LocalByteStore { id: string; name: string; read(path: string, maxBytes?: number, signal?: AbortSignal): Promise<Uint8Array | null> }
export interface ResourceLimits { maxPixels: number; maxWorkingBytes: number; maxMetadataBytes: number; maxEncodedChunkBytes: number; maxDecodedChunkBytes: number; maxChunksPerPlane: number }
export const DEFAULT_LIMITS: Readonly<ResourceLimits> = Object.freeze({
  maxPixels: 16_000_000, maxWorkingBytes: 256 * 1024 * 1024, maxMetadataBytes: 4 * 1024 * 1024,
  maxEncodedChunkBytes: 64 * 1024 * 1024, maxDecodedChunkBytes: 64 * 1024 * 1024, maxChunksPerPlane: 65_536,
});
export interface OperationOptions { limits?: Partial<ResourceLimits>; signal?: AbortSignal; onProgress?: (fraction: number) => void }
export interface ZarrArray { path: string; fieldPath?: string; shape: number[]; chunks: number[]; dtype: string; compressor: 'zlib' | 'gzip' | null; order: 'C'; separator: '.' | '/'; fillValue: number; axes: WorkspaceAxis[]; translation: number[] }
export interface ZarrDataset { name: string; source: SourceIdentity; arrays: ZarrArray[]; plate?: WorkspacePlate; channels?: { name: string; color: [number, number, number]; min?: number; max?: number }[] }
export interface ZarrPlaneSelection { level?: number; t?: number; z?: number; c?: number; indices?: Record<string, number> }
export interface RegistrationOptions extends OperationOptions { maxShift?: number; maxSamples?: number; minOverlap?: number }
export interface RegistrationResult { transform: AffineTransform; score: number; samples: number; physicalTranslation?: { x: number; y: number; unit: string }; movingToReferenceScale: { x: number; y: number } }
export interface StitchOptions extends OperationOptions { columns: number; overlap?: number; blend?: 'average' | 'maximum'; transforms?: AffineTransform[] }
export interface StitchResult { plane: ImagePlane; origin: Coordinate; transforms: AffineTransform[]; support: Uint8Array }
