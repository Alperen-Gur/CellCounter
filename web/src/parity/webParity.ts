import capabilityData from "./capabilities.json";

export type WebParityState = "available" | "buildRequired" | "unsupported";
export type WebParityArea = "Input" | "Detection" | "Analysis" | "Editing" | "Workflow" | "Export" | "System";

export interface WebParityCapability {
  id: string;
  area: WebParityArea;
  name: string;
  state: WebParityState;
  webSurface: string;
  note: string;
  sourceEvidence: readonly string[];
}

export const WEB_PARITY_CAPABILITIES = capabilityData as readonly WebParityCapability[];

export const WEB_PARITY_AREAS: readonly WebParityArea[] = ["Input", "Detection", "Analysis", "Editing", "Workflow", "Export", "System"];

export function webParityCounts() {
  return WEB_PARITY_CAPABILITIES.reduce(
    (counts, capability) => {
      counts[capability.state] += 1;
      return counts;
    },
    { available: 0, buildRequired: 0, unsupported: 0 },
  );
}
