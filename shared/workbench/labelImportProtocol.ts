export interface LabelImportPreview {
  imageId: string;
  target: "plane" | "volume";
  selection: Record<string, unknown>;
  source: { name: string; sha256: string; bytes: number; format: string; dtype: string; shape: number[] };
  summary: {
    labelCount: number; foregroundSampleCount: number; maxLabelId: number;
    validSupport: Record<string, unknown>;
  };
  previewFingerprint: string;
  dataUrl?: string;
  overlayDataUrl?: string;
  previewIndex?: number;
}
