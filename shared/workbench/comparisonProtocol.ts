export interface MaskComparison {
  left: { imageId: string; name: string; analysisRevision: number; parameters: Record<string, unknown> };
  right: { imageId: string; name: string; analysisRevision: number; parameters: Record<string, unknown> };
  target: "plane" | "volume";
  selection: Record<string, unknown>;
  metrics: {
    leftObjects: number; rightObjects: number; matchedObjects: number;
    unmatchedLeft: number; unmatchedRight: number; instanceF1: number; instanceJaccard: number;
    foregroundDice: number; foregroundJaccard: number;
    foregroundLeft: number; foregroundRight: number; foregroundBoth: number;
  };
  pairs: { leftLabelId: number; rightLabelId: number; iou: number }[];
  unmatchedLeftLabelIds: number[];
  unmatchedRightLabelIds: number[];
  truncated: boolean;
  notes: string[];
  dataUrl: string;
  overlayDataUrl: string;
  width: number; height: number; previewWidth: number; previewHeight: number;
  plane?: "xy" | "xz" | "yz"; index?: number; sliceCount?: number;
}
