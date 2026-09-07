export const ANALYSIS_PROTOCOL_KIND = "com.cellcounter.analysis-protocol";
export const ANALYSIS_PROTOCOL_SCHEMA_VERSION = 1;

export interface BrowserPlaneSettings {
  readonly sourceChannel: number;
  readonly projection: "first" | "max" | "mean" | "sum";
  readonly thresholdMethod: "otsu" | "triangle" | "adaptive" | "manual";
  readonly manualThreshold: number;
  readonly invert: boolean;
  readonly minimumAreaPx: number;
}
export interface AnalysisProtocolV1 {
  readonly browser?: BrowserPlaneSettings;
  readonly schemaVersion: 1;
  readonly kind: typeof ANALYSIS_PROTOCOL_KIND;
  readonly id: string;
  readonly name: string;
  readonly notes: string;
  readonly createdAt: string;
  readonly appVersion: string;
  readonly appBuild: string;
  readonly model: { readonly id: string; readonly name: string; readonly family: string };
  readonly detection: { readonly expectedDiameterUm: number; readonly channelsCyto: number; readonly channelsNuclei: number; readonly confidenceThreshold: number };
  readonly calibration: { readonly pxPerUm: number };
  readonly sizeBins: { readonly thresholdsUm: readonly number[] };
  readonly preprocessing: { readonly backgroundSubtract: boolean; readonly rollingBallRadiusPx: number; readonly watershedSplit: boolean; readonly watershedMinDistanceUm: number };
  readonly manualMarkerDiameterUm: number;
}
export class AnalysisProtocolValidationError extends Error {
  constructor(readonly issues: readonly string[]) {
    super(`Invalid CellCounter analysis protocol: ${issues.join("; ")}`);
    this.name = "AnalysisProtocolValidationError";
  }
}

function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
function finite(value: unknown): value is number { return typeof value === "number" && Number.isFinite(value); }

export function validateAnalysisProtocol(value: unknown, supportedModelIds?: readonly string[]): AnalysisProtocolV1 {
  const issues: string[] = [];
  if (!record(value)) throw new AnalysisProtocolValidationError(["document must be a JSON object"]);
  if (value.kind !== ANALYSIS_PROTOCOL_KIND) issues.push("kind is not a CellCounter analysis protocol");
  if (value.schemaVersion !== ANALYSIS_PROTOCOL_SCHEMA_VERSION) issues.push(`schemaVersion must be ${ANALYSIS_PROTOCOL_SCHEMA_VERSION}`);
  for (const key of ["id", "name", "createdAt", "appVersion", "appBuild"] as const) if (typeof value[key] !== "string" || !value[key]) issues.push(`${key} must be a non-empty string`);
  if (typeof value.notes !== "string") issues.push("notes must be a string");
  if (typeof value.createdAt === "string" && Number.isNaN(Date.parse(value.createdAt))) issues.push("createdAt must be an ISO-compatible date");
  const model = value.model;
  if (!record(model) || ["id", "name", "family"].some((key) => typeof model[key] !== "string" || !model[key])) issues.push("model must contain non-empty id, name and family strings");
  else if (supportedModelIds && !supportedModelIds.includes(model.id as string)) issues.push(`model id ${model.id as string} is not installed`);
  const detection = value.detection;
  if (!record(detection) || !finite(detection.expectedDiameterUm) || detection.expectedDiameterUm < 0 || !Number.isInteger(detection.channelsCyto) || (detection.channelsCyto as number) < 0 || !Number.isInteger(detection.channelsNuclei) || (detection.channelsNuclei as number) < 0 || !finite(detection.confidenceThreshold) || detection.confidenceThreshold < 0 || detection.confidenceThreshold > 1) issues.push("detection settings contain invalid diameter, channels or confidence threshold");
  const calibration = value.calibration;
  if (!record(calibration) || !finite(calibration.pxPerUm) || calibration.pxPerUm <= 0) issues.push("calibration.pxPerUm must be greater than zero");
  const sizeBins = value.sizeBins;
  if (!record(sizeBins) || !Array.isArray(sizeBins.thresholdsUm) || sizeBins.thresholdsUm.some((entry) => !finite(entry) || entry <= 0) || sizeBins.thresholdsUm.some((entry, index, values) => index > 0 && entry <= values[index - 1])) issues.push("sizeBins.thresholdsUm must be positive and strictly ascending");
  const preprocessing = value.preprocessing;
  if (!record(preprocessing) || typeof preprocessing.backgroundSubtract !== "boolean" || !Number.isInteger(preprocessing.rollingBallRadiusPx) || (preprocessing.rollingBallRadiusPx as number) < 0 || typeof preprocessing.watershedSplit !== "boolean" || !finite(preprocessing.watershedMinDistanceUm) || preprocessing.watershedMinDistanceUm < 0) issues.push("preprocessing settings are invalid");
  if (!finite(value.manualMarkerDiameterUm) || value.manualMarkerDiameterUm <= 0) issues.push("manualMarkerDiameterUm must be greater than zero");
  if (value.browser !== undefined) {
    const browser = value.browser;
    if (!record(browser) || !Number.isInteger(browser.sourceChannel) || (browser.sourceChannel as number) < -1 || !["first", "max", "mean", "sum"].includes(String(browser.projection)) || !["otsu", "triangle", "adaptive", "manual"].includes(String(browser.thresholdMethod)) || !finite(browser.manualThreshold) || browser.manualThreshold < 0 || browser.manualThreshold > 1 || typeof browser.invert !== "boolean" || !finite(browser.minimumAreaPx) || browser.minimumAreaPx < 1) issues.push("browser source/projection/threshold settings are invalid");
  }
  if (issues.length) throw new AnalysisProtocolValidationError(issues);
  return value as unknown as AnalysisProtocolV1;
}

export function parseAnalysisProtocol(json: string, supportedModelIds?: readonly string[]): AnalysisProtocolV1 {
  let value: unknown;
  try { value = JSON.parse(json); }
  catch { throw new AnalysisProtocolValidationError(["document is not valid JSON"]); }
  return validateAnalysisProtocol(value, supportedModelIds);
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (!record(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]));
}

export function serializeAnalysisProtocol(protocol: AnalysisProtocolV1): string {
  return `${JSON.stringify(sorted(validateAnalysisProtocol(protocol)), null, 2)}\n`;
}

export interface AppliedAnalysisSettings extends Partial<BrowserPlaneSettings> {
  readonly modelId: string;
  readonly expectedDiameterUm: number;
  readonly channels: readonly [number, number];
  readonly confidenceThreshold: number;
  readonly pxPerUm: number;
  readonly sizeThresholdsUm: readonly number[];
  readonly backgroundSubtract: boolean;
  readonly rollingBallRadiusPx: number;
  readonly watershedSplit: boolean;
  readonly watershedMinDistanceUm: number;
  readonly manualMarkerDiameterUm: number;
}

/** Applies every reproducibility-affecting field as one immutable settings snapshot. */
export function applyAnalysisProtocol(protocol: AnalysisProtocolV1, supportedModelIds?: readonly string[]): AppliedAnalysisSettings {
  const valid = validateAnalysisProtocol(protocol, supportedModelIds);
  return {
    ...valid.browser,
    modelId: valid.model.id,
    expectedDiameterUm: valid.detection.expectedDiameterUm,
    channels: [valid.detection.channelsCyto, valid.detection.channelsNuclei],
    confidenceThreshold: valid.detection.confidenceThreshold,
    pxPerUm: valid.calibration.pxPerUm,
    sizeThresholdsUm: [...valid.sizeBins.thresholdsUm],
    backgroundSubtract: valid.preprocessing.backgroundSubtract,
    rollingBallRadiusPx: valid.preprocessing.rollingBallRadiusPx,
    watershedSplit: valid.preprocessing.watershedSplit,
    watershedMinDistanceUm: valid.preprocessing.watershedMinDistanceUm,
    manualMarkerDiameterUm: valid.manualMarkerDiameterUm,
  };
}
