import type { AppStore } from "../../kernel/store/store";
import { MODEL_CATALOG, modelLabel } from "../models/catalog";

export const ANALYSIS_PROTOCOL_KIND = "com.cellcounter.analysis-protocol";
export const ANALYSIS_PROTOCOL_SCHEMA_VERSION = 1;

export interface AnalysisProtocol {
  schemaVersion: 1;
  kind: typeof ANALYSIS_PROTOCOL_KIND;
  id: string;
  name: string;
  notes: string;
  createdAt: string;
  appVersion: string;
  appBuild: string;
  model: { id: string; name: string; family: string };
  detection: {
    expectedDiameterUm: number;
    channelsCyto: number;
    channelsNuclei: number;
    confidenceThreshold: number;
  };
  calibration: { pxPerUm: number };
  sizeBins: { thresholdsUm: number[] };
  preprocessing: {
    backgroundSubtract: boolean;
    rollingBallRadiusPx: number;
    watershedSplit: boolean;
    watershedMinDistanceUm: number;
  };
  manualMarkerDiameterUm: number;
}

function id(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return `protocol-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  }
}

export function makeAnalysisProtocol(
  state: AppStore,
  name: string,
  notes = "",
): AnalysisProtocol {
  const model = MODEL_CATALOG.find((entry) => entry.id === state.activeModelId);
  return {
    schemaVersion: ANALYSIS_PROTOCOL_SCHEMA_VERSION,
    kind: ANALYSIS_PROTOCOL_KIND,
    id: id(),
    name: name.trim(),
    notes: notes.trim(),
    createdAt: new Date().toISOString(),
    appVersion: "1.0.8",
    appBuild: "windows",
    model: {
      id: state.activeModelId,
      name: modelLabel(state.activeModelId),
      family: model?.backend.toLowerCase().includes("stardist") ? "stardist" : "cellpose",
    },
    detection: {
      expectedDiameterUm: state.expectedDiameterUm,
      channelsCyto: state.channels[0],
      channelsNuclei: state.channels[1],
      confidenceThreshold: state.confidence,
    },
    calibration: { pxPerUm: state.pxPerUm },
    sizeBins: { thresholdsUm: state.thresholds.slice() },
    preprocessing: {
      backgroundSubtract: state.backgroundSubtract,
      rollingBallRadiusPx: state.rollingBallRadius,
      watershedSplit: state.watershedSplit,
      watershedMinDistanceUm: state.watershedMinDistanceUm,
    },
    manualMarkerDiameterUm: state.manualMarkerDiameterUm,
  };
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} is missing or malformed.`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, label: string, allowEmpty = false): string {
  if (typeof value !== "string" || (!allowEmpty && value.trim().length === 0)) {
    throw new Error(`${label} must be ${allowEmpty ? "text" : "non-empty text"}.`);
  }
  return value;
}

function number(
  value: unknown,
  label: string,
  minimum = Number.NEGATIVE_INFINITY,
  maximum = Number.POSITIVE_INFINITY,
): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new Error(`${label} is outside its supported range.`);
  }
  return value;
}

function integer(value: unknown, label: string, minimum: number, maximum: number): number {
  const parsed = number(value, label, minimum, maximum);
  if (!Number.isInteger(parsed)) throw new Error(`${label} must be a whole number.`);
  return parsed;
}

function boolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${label} must be true or false.`);
  return value;
}

export function decodeAnalysisProtocol(contents: string): AnalysisProtocol {
  let parsed: unknown;
  try {
    parsed = JSON.parse(contents);
  } catch {
    throw new Error("This file is not valid JSON.");
  }
  const root = record(parsed, "Protocol");
  if (root.kind !== ANALYSIS_PROTOCOL_KIND) {
    throw new Error("This file is not a CellCounter analysis protocol.");
  }
  const schemaVersion = number(root.schemaVersion, "Schema version", 1);
  if (schemaVersion > ANALYSIS_PROTOCOL_SCHEMA_VERSION) {
    throw new Error(
      `This protocol uses schema ${schemaVersion}; this build supports up to ${ANALYSIS_PROTOCOL_SCHEMA_VERSION}.`,
    );
  }
  if (schemaVersion !== 1) throw new Error(`Unsupported protocol schema ${schemaVersion}.`);

  const model = record(root.model, "Model");
  const detection = record(root.detection, "Detection settings");
  const calibration = record(root.calibration, "Calibration settings");
  const sizeBins = record(root.sizeBins, "Size-bin settings");
  const preprocessing = record(root.preprocessing, "Preprocessing settings");
  if (!Array.isArray(sizeBins.thresholdsUm)) {
    throw new Error("Size-bin thresholds must be an array.");
  }
  const thresholdsUm = sizeBins.thresholdsUm.map((value, index) =>
    number(value, `Threshold ${index + 1}`, 0),
  );
  if (thresholdsUm.some((value, index) => index > 0 && value <= thresholdsUm[index - 1])) {
    throw new Error("Size-bin thresholds must be strictly ascending.");
  }

  return {
    schemaVersion: 1,
    kind: ANALYSIS_PROTOCOL_KIND,
    id: string(root.id, "Protocol ID"),
    name: string(root.name, "Protocol name"),
    notes: string(root.notes ?? "", "Notes", true),
    createdAt: string(root.createdAt, "Creation date"),
    appVersion: string(root.appVersion, "App version"),
    appBuild: string(root.appBuild, "App build"),
    model: {
      id: string(model.id, "Model ID"),
      name: string(model.name, "Model name"),
      family: string(model.family, "Model family"),
    },
    detection: {
      expectedDiameterUm: number(detection.expectedDiameterUm, "Expected diameter", 0),
      channelsCyto: integer(detection.channelsCyto, "Cytoplasm channel", 0, 3),
      channelsNuclei: integer(detection.channelsNuclei, "Nuclei channel", 0, 3),
      confidenceThreshold: number(
        detection.confidenceThreshold,
        "Confidence threshold",
        0,
        1,
      ),
    },
    calibration: { pxPerUm: number(calibration.pxPerUm, "Calibration", 0.000001) },
    sizeBins: { thresholdsUm },
    preprocessing: {
      backgroundSubtract: boolean(
        preprocessing.backgroundSubtract,
        "Background subtraction",
      ),
      rollingBallRadiusPx: integer(
        preprocessing.rollingBallRadiusPx,
        "Rolling-ball radius",
        1,
        10_000,
      ),
      watershedSplit: boolean(preprocessing.watershedSplit, "Watershed split"),
      watershedMinDistanceUm: number(
        preprocessing.watershedMinDistanceUm,
        "Watershed distance",
        0.000001,
      ),
    },
    manualMarkerDiameterUm: number(root.manualMarkerDiameterUm, "Manual marker diameter", 0),
  };
}

/** Applies all settings synchronously. The model id is kept even when unknown,
 * so the backend can reject it explicitly instead of silently substituting one.
 */
export function applyAnalysisProtocol(protocol: AnalysisProtocol, state: AppStore): string | null {
  state.setThresholds(protocol.sizeBins.thresholdsUm.slice());
  state.setPxPerUm(protocol.calibration.pxPerUm);
  state.setConfidence(protocol.detection.confidenceThreshold);
  state.setExpectedDiameterUm(protocol.detection.expectedDiameterUm);
  state.setChannels([
    protocol.detection.channelsCyto,
    protocol.detection.channelsNuclei,
  ]);
  state.setBackgroundSubtract(protocol.preprocessing.backgroundSubtract);
  state.setRollingBallRadius(protocol.preprocessing.rollingBallRadiusPx);
  state.setWatershedSplit(protocol.preprocessing.watershedSplit);
  state.setWatershedMinDistanceUm(protocol.preprocessing.watershedMinDistanceUm);
  state.setManualMarkerDiameterUm(protocol.manualMarkerDiameterUm);
  state.setActiveModelId(protocol.model.id);

  if (!MODEL_CATALOG.some((entry) => entry.available && entry.id === protocol.model.id)) {
    return `This protocol requires ${protocol.model.name} (${protocol.model.id}), which is not in the three-model Windows catalog. Every other setting was applied; choose or install a supported model before analysis.`;
  }
  return null;
}

export function safeProtocolFilename(name: string): string {
  const safe = name
    .replace(/[\\/:*?"<>|\u0000-\u001f]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^[ ._]+|[ ._]+$/g, "");
  return `${safe || "analysis-protocol"}.ccproto.json`;
}
