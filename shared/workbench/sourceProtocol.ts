export interface LargeSource {
  id: string; name: string; sourceHash: string; sourceBytes: number;
  width: number; height: number; channels: number; dtype: string;
  access: "memmap" | "segments" | "unsupported"; tiled: boolean;
  seriesIndex: number; seriesCount: number; pageCount: number;
  voxelSizeUm: { x: number | null; y: number | null; z: number | null };
  limits: { roiPixels: number; segmentBytes: number; sourceBytes: number };
  limitations: string[];
}
export interface SourceOverview {
  sourceId: string; pageIndex: number; channel: number; dataUrl: string;
  width: number; height: number; previewWidth: number; previewHeight: number;
  scale: { x: number; y: number }; coordinateSpace: string;
}
