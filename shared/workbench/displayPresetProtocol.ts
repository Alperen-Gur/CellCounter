import type { CompositeChannel } from "./compositeProtocol";

export type DisplayIntensityUnits = "raw-source" | "processed-source";
export interface DisplayPresetSettings {
  channels: CompositeChannel[]; maxSize: number; maxDimension: number; intensityUnits: DisplayIntensityUnits;
}
export interface DisplayPresetSummary {
  id: string; version: number; hash: string; name: string; notes: string; maxSize: number; maxDimension: number;
  intensityUnits: DisplayIntensityUnits; archived: boolean; latestVersion: number; versionCount: number;
  createdAt: string; createdRevision: number; channelCount: number; hasFixedWindows: boolean;
}
export interface DisplayPreset extends Omit<DisplayPresetSummary, "channelCount" | "hasFixedWindows"> {
  channels: CompositeChannel[]; actor: { kind: string; name: string };
}
export interface DisplayChannelMapping { source: number; target: number }
export interface DisplayPresetRef {
  id: string; version: number; hash: string; name: string; channelMapping: DisplayChannelMapping[];
}
export interface DisplayPresetResolution {
  settings: DisplayPresetSettings; presetRef: DisplayPresetRef;
  compatibility: { compatible: true; sourceIntensityUnits: DisplayIntensityUnits; targetIntensityUnits: DisplayIntensityUnits; warnings: string[] };
  notes: string[];
}
export type DisplayPresetMutation = (operation: "display.preset.save" | "display.preset.archive" | "display.preset.import.run", args: Record<string, unknown>,
  accepted: (result: { preset: DisplayPreset }) => void) => Promise<void>;
export interface DisplayPresetExportFormat {
  id: "preset-json"; name: string; extension: string; mediaType: string; description: string;
}
export interface DisplayPresetExportArguments { presetId: string; version: number; format: "preset-json" }
export interface DisplayPresetExportResult {
  destination: string; sha256: string; bytes: number; format: "preset-json"; mediaType: string;
  presetId?: string; version?: number; provenance: Record<string, unknown>;
}
export interface DisplayPresetImportPreview {
  source: { name: string; sha256: string; bytes: number; format: string };
  preset: DisplayPresetSettings & { name: string; notes: string }; origin: Record<string, unknown>;
  previewFingerprint: string; notes: string[];
}
export interface DisplayPresetFileActions {
  chooseImport: (selected: (path: string) => void) => Promise<void>;
  exportPreset: (format: DisplayPresetExportFormat, args: DisplayPresetExportArguments, name: string) => Promise<void>;
}
