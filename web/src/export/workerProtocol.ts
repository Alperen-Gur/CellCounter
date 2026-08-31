import type { ExportCell, RgbaImage } from "./types";

export type ExportWorkerRequest =
  | { readonly id: string; readonly kind: "annotated-png"; readonly source: RgbaImage; readonly cells: readonly ExportCell[]; readonly options?: { readonly color?: readonly [number, number, number, number]; readonly lineWidthPx?: number; readonly minimumConfidence?: number } }
  | { readonly id: string; readonly kind: "segmentation-png"; readonly labels: Uint32Array; readonly width: number; readonly height: number };

export type ExportWorkerResponse =
  | { readonly id: string; readonly ok: true; readonly bytes: Uint8Array }
  | { readonly id: string; readonly ok: false; readonly error: string };
