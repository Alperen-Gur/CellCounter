import type { StatisticalFactor, StatisticalRow } from "./statisticsProtocol";
import type { Specimen, ExperimentalDesign } from "./protocol";

export interface ExperimentSlot {
  key: string; name: string; condition: string; role: Specimen["role"]; values: Record<string, string | number>;
  subjectKey?: string; blockKey?: string; wellRow?: number; wellColumn?: number;
}
export interface ExperimentLayoutDefinition { name: string; factors: StatisticalFactor[]; slots: ExperimentSlot[]; plate?: { rows: number; columns: number }; notes?: string }
export interface ExperimentLayoutSummary { id: string; version: number; latestVersion: number; name: string; hash: string; slotCount: number; createdAt: string; revision: number }
export interface ExperimentLayout extends Omit<ExperimentLayoutSummary, "slotCount" | "latestVersion"> { latestVersion?: number; definition: ExperimentLayoutDefinition }
export interface ExperimentApplicationSummary { id: string; instanceName: string; experiment: string; specimenCount: number; imageCount: number; createdAt: string; revision: number; layoutRef: { id: string; version: number; hash: string; name: string } }
export interface ExperimentApplicationPlan {
  id: string; layoutRef: ExperimentApplicationSummary["layoutRef"]; instanceName: string; experiment: string;
  newSpecimens: Specimen[]; newPlate: ExperimentalDesign["plates"][number] | null;
  assignments: ExperimentalDesign["assignments"]; replacedAssignments: ExperimentalDesign["assignments"];
  statisticsRows: StatisticalRow[]; factors: StatisticalFactor[];
  subjectMapping: { key: string; id: string; reused: boolean }[]; blockMapping: { key: string; id: string; reused: boolean }[];
  sourceMembers: { imageId: string; sourceHash: string; sourcePath: string }[]; notes: string[];
}
export interface ExperimentApplication extends ExperimentApplicationPlan { createdAt: string; revision: number; hash: string }
export interface AcquisitionSessionSummary { id: string; version: number; latestVersion: number; name: string; instrument: string; imageCount: number; startedAt?: string; endedAt?: string; hash: string; createdAt: string; revision: number }
export interface AcquisitionSession extends Omit<AcquisitionSessionSummary, "imageCount" | "latestVersion"> { operator?: string; notes?: string; members: { imageId: string; sourceHash: string; sourcePath: string }[] }
export interface ExperimentExclusion { id: string; target: "image" | "specimen"; targetId: string; excluded: boolean; reason: string; at: string; revision: number; actor?: { kind: string; name: string } }
export type EffectiveExperimentExclusions = { image: Record<string, ExperimentExclusion>; specimen: Record<string, ExperimentExclusion> };
export interface ExperimentRecordActions {
  run: (action: () => Promise<void>) => Promise<void>;
  mutate: <T>(operation: string, args: Record<string, unknown>, accepted: (result: T) => void) => Promise<void>;
}
