export interface ImageExportFormat {
  id: string;
  name: string;
  extension: string;
  mediaType: string;
  targets: ("plane" | "volume")[];
  requiresAnalysis: boolean;
  description: string;
}

export interface ImageExportResult {
  destination: string;
  sha256: string;
  format: string;
  mediaType: string;
  bytes: number;
  imageId: string;
  target: "plane" | "volume";
  selection: Record<string, unknown>;
  provenance: Record<string, unknown>;
}
