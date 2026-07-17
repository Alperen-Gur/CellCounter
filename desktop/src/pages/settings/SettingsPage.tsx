/**
 * pages/settings/SettingsPage.tsx — the Settings screen (feature task
 * `feat-settings`, route `/settings`).
 *
 * Port of `Views/Settings/SettingsView.swift`. A left section rail + a scrolling
 * body of labelled rows. It owns ONLY `pages/settings/` and touches the rest of
 * the app exclusively through the two frozen kernel seams:
 *
 *   • kernel-store   — every analysis parameter is a store field; editing a row
 *                      calls the matching FROZEN setter (`setThresholds`,
 *                      `setConfidence`, …). The analysis-params slice is
 *                      persisted to localStorage by the store's `persist`
 *                      middleware, so a change survives relaunch and is picked up
 *                      by the *next* detection (Home/Results read the store when
 *                      they build `DetectionParams`). We never change slice
 *                      shapes — only consume setters (task boundary).
 *   • kernel-persistence — calibration-preset CRUD + bin-preset listing go
 *                      through `PersistencePort`; `wipeAllUserData()` performs the
 *                      destructive data reset (clears batches/images/detections,
 *                      preserves config/presets per the DDL cascade + §3.8).
 *   • kernel-types   — domain vocabulary only.
 *
 * Sections (mirroring the Swift `SettingsSection` cases we carry into v1):
 *   General        — model default, max-parallel, background-subtract +
 *                    rolling-ball radius, watershed + min-distance, confidence,
 *                    channels, GPU, manual-marker diameter.
 *   Default bins   — inline threshold editor (writes `thresholds`) + saved
 *                    bin-preset list (apply / list — see kernel gap below).
 *   Calibration    — saved px/µm presets (create / edit / delete via the port).
 *   Data & reset   — reset-all-settings (restore Swift defaults via setters) and
 *                    the destructive "Reset all data…" wipe.
 *
 * KERNEL GAP (documented, coded around): `PersistencePort` exposes `binPresets()`
 * (read) but no create/delete for bin presets — only calibration presets have
 * full CRUD. So the bin-preset list is apply-only here; threshold *values* are a
 * store param and fully editable. See the returned `kernelGaps`.
 */

import { useCallback, useEffect, useState } from "react";

import { useAppStore } from "../../kernel/store/store";
import type { AppStore } from "../../kernel/store/store";
import { getPort } from "../../kernel/persistence";
import type {
  CalibrationPresetDTO,
  BinPresetDTO,
} from "../../kernel/persistence";

import {
  SetRow,
  Toggle,
  NumberField,
  SliderField,
  SegmentedPicker,
  Select,
  ConfirmDialog,
} from "./controls";
import { binColor } from "../../kernel/theme/binColors";
import { Icon, type IconName } from "../../components/Icon";
import "./settings.css";

// ---------------------------------------------------------------------------
// Section registry
// ---------------------------------------------------------------------------

type SectionId = "general" | "bins" | "calibration" | "data";

const SECTIONS: { id: SectionId; label: string; icon: IconName }[] = [
  { id: "general", label: "General", icon: "settings" },
  { id: "bins", label: "Default bins", icon: "histogram" },
  { id: "calibration", label: "Calibration presets", icon: "calibrate" },
  { id: "data", label: "Data & reset", icon: "trash" },
];

// ---------------------------------------------------------------------------
// Analysis-params defaults (mirror AppState.init / refreshFromDefaults + §3.3).
// "Reset all settings" restores exactly these via the frozen setters.
// ---------------------------------------------------------------------------

const PARAM_DEFAULTS = {
  thresholds: [20, 30] as number[],
  pxPerUm: 2.6,
  confidence: 0.5,
  expectedDiameterUm: 0,
  activeModelId: "cp-cyto3",
  channels: [0, 0] as [number, number],
  manualMarkerDiameterUm: 20,
  backgroundSubtract: false,
  rollingBallRadius: 50,
  watershedSplit: false,
  watershedMinDistanceUm: 8,
  useGpu: true,
  maxParallel: 1,
} as const;

// Channel options: 0=gray, 1=red, 2=green, 3=blue (DetectionParams channels).
const CHANNEL_OPTIONS: { value: number; label: string }[] = [
  { value: 0, label: "Gray" },
  { value: 1, label: "R" },
  { value: 2, label: "G" },
  { value: 3, label: "B" },
];

// v1 ships cyto3 only; the "default model" select mirrors that (activeModelId).
const MODEL_OPTIONS: { value: string; label: string }[] = [
  { value: "cp-cyto3", label: "Cellpose cyto3" },
];

const PARALLEL_OPTIONS: { value: number; label: string }[] = [
  { value: 1, label: "1" },
  { value: 2, label: "2" },
  { value: 4, label: "4" },
  { value: 8, label: "8" },
];

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

export default function SettingsPage() {
  const [section, setSection] = useState<SectionId>("general");

  return (
    <div className="cc-set">
      <nav className="cc-set__rail" aria-label="Settings sections">
        {SECTIONS.map((s) => (
          <button
            key={s.id}
            type="button"
            className={
              "cc-set__rail-item" +
              (section === s.id ? " cc-set__rail-item--active" : "")
            }
            aria-current={section === s.id}
            onClick={() => setSection(s.id)}
          >
            <span className="cc-set__rail-icon" aria-hidden="true">
              <Icon name={s.icon} size={17} />
            </span>
            <span className="cc-set__rail-label">{s.label}</span>
          </button>
        ))}
      </nav>

      <div className="cc-set__body">
        {section === "general" && <GeneralSection />}
        {section === "bins" && <BinsSection />}
        {section === "calibration" && <CalibrationSection />}
        {section === "data" && <DataSection />}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Section heading
// ---------------------------------------------------------------------------

function Heading({ title, subtitle }: { title: string; subtitle: string }) {
  return (
    <div className="cc-set__heading">
      <h1 className="cc-set__title">{title}</h1>
      <p className="cc-set__subtitle">{subtitle}</p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// General — all analysis parameters
// ---------------------------------------------------------------------------

function GeneralSection() {
  // Fine-grained selectors (the codebase convention): subscribe only to the
  // analysis-params fields, so unrelated store churn (processing/session)
  // doesn't re-render this section. Setters are stable references.
  const activeModelId = useAppStore((st) => st.activeModelId);
  const maxParallel = useAppStore((st) => st.maxParallel);
  const confidence = useAppStore((st) => st.confidence);
  const expectedDiameterUm = useAppStore((st) => st.expectedDiameterUm);
  const channels = useAppStore((st) => st.channels);
  const backgroundSubtract = useAppStore((st) => st.backgroundSubtract);
  const rollingBallRadius = useAppStore((st) => st.rollingBallRadius);
  const watershedSplit = useAppStore((st) => st.watershedSplit);
  const watershedMinDistanceUm = useAppStore((st) => st.watershedMinDistanceUm);
  const manualMarkerDiameterUm = useAppStore((st) => st.manualMarkerDiameterUm);
  const useGpu = useAppStore((st) => st.useGpu);

  const setActiveModelId = useAppStore((st) => st.setActiveModelId);
  const setMaxParallel = useAppStore((st) => st.setMaxParallel);
  const setConfidence = useAppStore((st) => st.setConfidence);
  const setExpectedDiameterUm = useAppStore((st) => st.setExpectedDiameterUm);
  const setChannels = useAppStore((st) => st.setChannels);
  const setBackgroundSubtract = useAppStore((st) => st.setBackgroundSubtract);
  const setRollingBallRadius = useAppStore((st) => st.setRollingBallRadius);
  const setWatershedSplit = useAppStore((st) => st.setWatershedSplit);
  const setWatershedMinDistanceUm = useAppStore(
    (st) => st.setWatershedMinDistanceUm,
  );
  const setManualMarkerDiameterUm = useAppStore(
    (st) => st.setManualMarkerDiameterUm,
  );
  const setUseGpu = useAppStore((st) => st.setUseGpu);

  return (
    <section className="cc-set__section" aria-label="General settings">
      <Heading
        title="General"
        subtitle="Defaults applied to every new analysis. Changes take effect on the next detection."
      />

      <SetRow
        label="Default model"
        desc="The detector used for new analyses (v1 ships Cellpose cyto3)."
      >
        <Select
          value={activeModelId}
          options={MODEL_OPTIONS}
          onChange={setActiveModelId}
          ariaLabel="Default model"
        />
      </SetRow>

      <SetRow
        label="Max parallel images"
        desc="Higher uses more memory and finishes batches faster (CPU cellpose is CPU-bound)."
      >
        <Select
          value={maxParallel}
          options={PARALLEL_OPTIONS}
          onChange={setMaxParallel}
          ariaLabel="Max parallel images"
        />
      </SetRow>

      <SetRow
        label="Detection confidence"
        desc="Analysis filter — cells below this are hidden from counts, never deleted (0–1)."
      >
        <SliderField
          value={confidence}
          min={0}
          max={1}
          step={0.01}
          onChange={setConfidence}
          format={(v) => v.toFixed(2)}
          ariaLabel="Detection confidence"
        />
      </SetRow>

      <SetRow
        label="Expected cell diameter"
        desc="Segmentation size prior for new analyses (µm). 0 = Auto — derive it from the size bins; a set value decouples segmentation from the bins."
      >
        <NumberField
          value={expectedDiameterUm}
          onCommit={setExpectedDiameterUm}
          unit="µm"
          min={0}
          ariaLabel="Expected cell diameter"
        />
      </SetRow>

      <SetRow
        label="Detection channels"
        desc="Cytoplasm and nuclei source channels (0=gray, 1=R, 2=G, 3=B). Default gray/gray."
      >
        <SegmentedPicker
          value={channels[0]}
          options={CHANNEL_OPTIONS}
          onChange={(v) => setChannels([v, channels[1]])}
          ariaLabel="Cytoplasm channel"
        />
        <span className="cc-set__unit">cyto</span>
        <SegmentedPicker
          value={channels[1]}
          options={CHANNEL_OPTIONS}
          onChange={(v) => setChannels([channels[0], v])}
          ariaLabel="Nuclei channel"
        />
        <span className="cc-set__unit">nuc</span>
      </SetRow>

      <SetRow
        label="Subtract background before detection"
        desc="Rolling-ball subtraction — improves accuracy on phase-contrast images with uneven illumination."
      >
        <Toggle
          on={backgroundSubtract}
          onChange={setBackgroundSubtract}
          label="Subtract background"
        />
      </SetRow>

      <SetRow
        label="Rolling-ball radius"
        desc="Larger radius removes broader illumination gradients (10–200 px)."
      >
        <SliderField
          value={rollingBallRadius}
          min={10}
          max={200}
          step={1}
          onChange={setRollingBallRadius}
          format={(v) => `${Math.round(v)} px`}
          ariaLabel="Rolling-ball radius"
        />
      </SetRow>

      <SetRow
        label="Split touching cells"
        desc="Apply distance-transform watershed automatically on every new analysis."
      >
        <Toggle
          on={watershedSplit}
          onChange={setWatershedSplit}
          label="Split touching cells"
        />
      </SetRow>

      <SetRow
        label="Watershed min distance"
        desc="Minimum separation between cell centres (4–24 µm); smaller splits more aggressively."
      >
        <SliderField
          value={watershedMinDistanceUm}
          min={4}
          max={24}
          step={1}
          onChange={setWatershedMinDistanceUm}
          format={(v) => `${Math.round(v)} µm`}
          ariaLabel="Watershed min distance"
        />
      </SetRow>

      <SetRow
        label="Manual marker diameter"
        desc="Diameter used for manually-placed count markers and the fixed-diameter prior when no EXIF scale is present (µm)."
      >
        <NumberField
          value={manualMarkerDiameterUm}
          onCommit={setManualMarkerDiameterUm}
          unit="µm"
          min={0}
          ariaLabel="Manual marker diameter"
        />
      </SetRow>

      <SetRow
        label="Use GPU when available"
        desc="Off forces CPU torch (passes --no-gpu to the sidecar). v1 ships CPU torch."
      >
        <Toggle on={useGpu} onChange={setUseGpu} label="Use GPU" />
      </SetRow>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Default bins — inline threshold editor + saved bin presets (apply-only)
// ---------------------------------------------------------------------------

function BinsSection() {
  const thresholds = useAppStore((st) => st.thresholds);
  const setThresholds = useAppStore((st) => st.setThresholds);

  const [presets, setPresets] = useState<BinPresetDTO[]>([]);

  const refreshPresets = useCallback(async () => {
    try {
      setPresets(await getPort().binPresets());
    } catch {
      // No port (plain preview build) — leave the list empty.
      setPresets([]);
    }
  }, []);

  useEffect(() => {
    void refreshPresets();
  }, [refreshPresets]);

  const setThresholdAt = (i: number, v: number) => {
    const next = thresholds.slice();
    if (i < 0 || i >= next.length) return;
    next[i] = v;
    setThresholds(next);
  };

  const removeThresholdAt = (i: number) => {
    if (thresholds.length <= 1) return;
    const next = thresholds.slice();
    next.splice(i, 1);
    setThresholds(next);
  };

  const addThreshold = () => {
    const last = thresholds.length > 0 ? thresholds[thresholds.length - 1] : 30;
    setThresholds([...thresholds, last + 10]);
  };

  return (
    <section className="cc-set__section" aria-label="Default bin settings">
      <Heading
        title="Default bins"
        subtitle="New images start with these size thresholds (µm). Override per-image in the Results sidebar."
      />

      <div className="cc-set__thresholds">
        {thresholds.map((t, i) => (
          <div className="cc-set__threshold-row" key={i}>
            {/* swatch for the bin below this threshold (index i) */}
            <span
              className="cc-set__bin-swatch"
              style={{ background: binColor(i) }}
              aria-hidden="true"
            />
            <NumberField
              value={t}
              onCommit={(v) => setThresholdAt(i, v)}
              unit="µm"
              min={0}
              ariaLabel={`Threshold ${i + 1}`}
            />
            <button
              type="button"
              className="cc-set__btn cc-set__btn--icon"
              onClick={() => removeThresholdAt(i)}
              disabled={thresholds.length <= 1}
              aria-label={`Remove threshold ${i + 1}`}
              title={
                thresholds.length <= 1
                  ? "At least one threshold is required."
                  : "Remove threshold"
              }
            >
              <Icon name="minus" size={15} />
            </button>
          </div>
        ))}

        <button
          type="button"
          className="cc-set__add-link"
          onClick={addThreshold}
        >
          <Icon name="plus" size={15} />
          Add threshold
        </button>

        <div className="cc-set__thresholds-preview">
          {describeThresholds(thresholds)}
        </div>
      </div>

      <div className="cc-set__group-title">Saved presets</div>

      {presets.length === 0 ? (
        <div className="cc-set__empty">
          No saved bin presets. Presets are created during onboarding /
          calibration; here you can apply one to the defaults.
        </div>
      ) : (
        <div className="cc-set__list">
          {presets.map((p) => (
            <div className="cc-set__list-row" key={p.id}>
              <div className="cc-set__list-text">
                <span className="cc-set__list-name">{p.name}</span>
                <span className="cc-set__list-sub">
                  {describeThresholds(p.thresholds)}
                </span>
              </div>
              <div className="cc-set__list-actions">
                <button
                  type="button"
                  className="cc-set__btn"
                  onClick={() => setThresholds(p.thresholds.slice())}
                >
                  Apply
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

/** Human threshold summary: [20,30] → "< 20 µm · 20–30 µm · > 30 µm". */
function describeThresholds(t: number[]): string {
  if (t.length === 0) return "—";
  const sorted = t.slice().sort((a, b) => a - b);
  const parts: string[] = [`< ${fmtInt(sorted[0])} µm`];
  for (let i = 0; i < sorted.length - 1; i++) {
    parts.push(`${fmtInt(sorted[i])}–${fmtInt(sorted[i + 1])} µm`);
  }
  parts.push(`> ${fmtInt(sorted[sorted.length - 1])} µm`);
  return parts.join(" · ");
}

function fmtInt(v: number): string {
  return String(Math.round(v));
}

// ---------------------------------------------------------------------------
// Calibration presets — full CRUD through the port
// ---------------------------------------------------------------------------

function CalibrationSection() {
  const [presets, setPresets] = useState<CalibrationPresetDTO[]>([]);
  const [editing, setEditing] = useState<CalibrationPresetDTO | null>(null);
  const [showEditor, setShowEditor] = useState(false);
  const [name, setName] = useState("");
  const [pxText, setPxText] = useState("");

  const refresh = useCallback(async () => {
    try {
      setPresets(await getPort().calibrationPresets());
    } catch {
      setPresets([]);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const openNew = () => {
    setEditing(null);
    setName("");
    setPxText("");
    setShowEditor(true);
  };

  const openEdit = (p: CalibrationPresetDTO) => {
    setEditing(p);
    setName(p.name);
    setPxText(String(Math.round(p.pxPerUm * 100) / 100));
    setShowEditor(true);
  };

  const closeEditor = () => {
    setShowEditor(false);
    setEditing(null);
    setName("");
    setPxText("");
  };

  const save = useCallback(async () => {
    const trimmed = name.trim();
    const px = Number(pxText);
    if (trimmed.length === 0 || !Number.isFinite(px) || px <= 0) return;
    // Upsert preserves the existing id (edit) or mints a new one (create), and
    // keeps the `isDefault` flag on edit so we never clobber the seeded default.
    const preset: CalibrationPresetDTO = {
      id: editing?.id ?? newId(),
      name: trimmed,
      pxPerUm: px,
      isDefault: editing?.isDefault ?? false,
    };
    try {
      await getPort().upsertCalibrationPreset(preset);
      await refresh();
    } catch {
      // Preview build without a port: reflect the change locally so the UI
      // still updates (edit replaces, create appends).
      setPresets((prev) => {
        const exists = prev.some((p) => p.id === preset.id);
        return exists
          ? prev.map((p) => (p.id === preset.id ? preset : p))
          : [...prev, preset];
      });
    }
    closeEditor();
  }, [name, pxText, editing, refresh]);

  const remove = useCallback(
    async (id: string) => {
      try {
        await getPort().deleteCalibrationPreset(id);
        await refresh();
      } catch {
        setPresets((prev) => prev.filter((p) => p.id !== id));
      }
    },
    [refresh],
  );

  const saveValid = name.trim().length > 0 && Number(pxText) > 0;

  return (
    <section className="cc-set__section" aria-label="Calibration presets">
      <Heading
        title="Calibration presets"
        subtitle="Reusable scale settings — one per microscope + objective."
      />

      {presets.length === 0 && !showEditor ? (
        <div className="cc-set__empty">No calibration presets yet.</div>
      ) : (
        <div className="cc-set__list">
          {presets.map((p) => (
            <div className="cc-set__list-row" key={p.id}>
              <div className="cc-set__list-text">
                <span className="cc-set__list-name">{p.name}</span>
                <span className="cc-set__list-sub">
                  {p.pxPerUm.toFixed(1)} px / µm
                </span>
              </div>
              <div className="cc-set__list-actions">
                {p.isDefault && <span className="cc-set__badge">Default</span>}
                <button
                  type="button"
                  className="cc-set__btn"
                  onClick={() => openEdit(p)}
                >
                  Edit
                </button>
                <button
                  type="button"
                  className="cc-set__btn cc-set__btn--icon cc-set__btn--icon-danger"
                  onClick={() => void remove(p.id)}
                  aria-label={`Delete preset ${p.name}`}
                  title="Delete preset"
                >
                  <Icon name="trash" size={15} />
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {showEditor ? (
        <div className="cc-set__editor">
          <input
            className="cc-set__text-input"
            type="text"
            placeholder="Preset name (e.g. IX73 — 20×)"
            value={name}
            autoFocus
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && saveValid) {
                e.preventDefault();
                void save();
              }
            }}
          />
          <input
            className="cc-set__num cc-set__num--wide"
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            aria-label="Pixels per micrometer"
            value={pxText}
            onChange={(e) => setPxText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && saveValid) {
                e.preventDefault();
                void save();
              }
            }}
          />
          <span className="cc-set__unit">px/µm</span>
          <button
            type="button"
            className="cc-set__btn cc-set__btn--primary"
            onClick={() => void save()}
            disabled={!saveValid}
          >
            {editing ? "Save" : "Add"}
          </button>
          <button type="button" className="cc-set__btn" onClick={closeEditor}>
            Cancel
          </button>
        </div>
      ) : (
        <button
          type="button"
          className="cc-set__add-link"
          onClick={openNew}
        >
          <Icon name="plus" size={15} />
          New preset…
        </button>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Data & reset — reset settings (restore defaults) + destructive data wipe
// ---------------------------------------------------------------------------

type WipeState =
  | { kind: "idle" }
  | { kind: "working" }
  | { kind: "done" }
  | { kind: "error"; message: string };

function DataSection() {
  const [confirm, setConfirm] = useState<null | "settings" | "data">(null);
  const [wipe, setWipe] = useState<WipeState>({ kind: "idle" });

  // Reset every analysis param to its Swift default via the frozen setters.
  // (We only consume setters — never touch the slice shape.) This mirrors
  // AppState "Reset all settings"; batches/images are NOT affected here. Actions
  // are read via getState() so this section doesn't re-render on store changes.
  const resetSettings = useCallback(() => {
    applyParamDefaults(useAppStore.getState());
    setConfirm(null);
    setWipe({ kind: "idle" });
  }, []);

  // Destructive wipe: clears batches/images/detections/corrections. The DDL
  // cascade (§3.8) leaves conditions, calibration/bin presets, and the config
  // slice intact — exactly the Swift `wipeAllUserData` contract.
  const wipeData = useCallback(async () => {
    setConfirm(null);
    setWipe({ kind: "working" });
    try {
      await getPort().wipeAllUserData();
      // Clear the in-memory session pointer that now references a deleted batch,
      // then re-read the (now-empty) library counts so sidebar badges update.
      // openBatch("") also resets currentImageIdx + selectedCellIds atomically;
      // "" is falsy so every `!currentBatchId` guard reads it as "no batch"
      // (the store has no nil-setter — see kernelGaps).
      const st = useAppStore.getState();
      st.openBatch("");
      try {
        await st.refreshLibraryStats();
      } catch {
        /* counts refresh is best-effort */
      }
      setWipe({ kind: "done" });
    } catch (err) {
      setWipe({ kind: "error", message: String(err) });
    }
  }, []);

  return (
    <section className="cc-set__section" aria-label="Data and reset">
      <Heading
        title="Data & reset"
        subtitle="Restore default settings or permanently remove imported data. Everything is local to this machine."
      />

      <div className="cc-set__group-title">Reset settings</div>
      <div className="cc-set__card">
        <div className="cc-set__card-row">
          <div className="cc-set__row-text">
            <span className="cc-set__row-label">Reset all settings</span>
            <span className="cc-set__row-desc">
              Restores every analysis parameter (thresholds 20/30, px/µm 2.6,
              confidence 0.50, GPU on, …) to its default. Your images,
              detections, batches, and saved presets are not affected.
            </span>
          </div>
          <div className="cc-set__list-actions">
            <button
              type="button"
              className="cc-set__btn"
              onClick={() => setConfirm("settings")}
            >
              Reset
            </button>
          </div>
        </div>
      </div>

      <div className="cc-set__group-title cc-set__group-title--danger">
        <Icon name="alert" size={13} />
        Danger zone
      </div>
      <div className="cc-set__danger-card">
        <div className="cc-set__danger-row">
          <div className="cc-set__row-text">
            <span className="cc-set__row-label">Reset all data…</span>
            <span className="cc-set__row-desc">
              Permanently deletes all imported images, detections, batches, and
              corrections. Conditions, calibration/bin presets, and your settings
              are preserved. This cannot be undone.
            </span>
          </div>
          <div className="cc-set__list-actions">
            <button
              type="button"
              className="cc-set__btn cc-set__btn--danger"
              onClick={() => setConfirm("data")}
              disabled={wipe.kind === "working"}
            >
              {wipe.kind === "working" ? "Deleting…" : "Delete everything"}
            </button>
          </div>
        </div>

        {wipe.kind === "done" && (
          <div className="cc-set__result cc-set__result--ok" role="status">
            <Icon name="checkCircle" size={15} />
            <span>
              Data cleared. All imported images, detections, batches, and
              corrections have been removed.
            </span>
          </div>
        )}
        {wipe.kind === "error" && (
          <div className="cc-set__result cc-set__result--err" role="alert">
            <Icon name="xCircle" size={15} />
            <span>Couldn&apos;t fully reset data: {wipe.message}</span>
          </div>
        )}
      </div>

      {confirm === "settings" && (
        <ConfirmDialog
          title="Reset all settings?"
          body={
            "This restores every analysis parameter to its default value and " +
            "clears your customisations.\n\nYour batches, images, and saved " +
            "presets are not affected."
          }
          confirmLabel="Reset settings"
          onConfirm={resetSettings}
          onCancel={() => setConfirm(null)}
        />
      )}
      {confirm === "data" && (
        <ConfirmDialog
          title="Delete all imported data?"
          body={
            "This permanently removes all imported images, detections, batches, " +
            "and corrections.\n\nYour conditions, calibration presets, bin " +
            "presets, and settings are preserved.\n\nThis cannot be undone."
          }
          confirmLabel="Delete everything"
          onConfirm={() => void wipeData()}
          onCancel={() => setConfirm(null)}
        />
      )}
    </section>
  );
}

/** Restore the analysis-params slice to the Swift defaults via frozen setters. */
function applyParamDefaults(store: AppStore): void {
  store.setThresholds(PARAM_DEFAULTS.thresholds.slice());
  store.setPxPerUm(PARAM_DEFAULTS.pxPerUm);
  store.setConfidence(PARAM_DEFAULTS.confidence);
  store.setExpectedDiameterUm(PARAM_DEFAULTS.expectedDiameterUm);
  store.setActiveModelId(PARAM_DEFAULTS.activeModelId);
  store.setChannels([...PARAM_DEFAULTS.channels]);
  store.setManualMarkerDiameterUm(PARAM_DEFAULTS.manualMarkerDiameterUm);
  store.setBackgroundSubtract(PARAM_DEFAULTS.backgroundSubtract);
  store.setRollingBallRadius(PARAM_DEFAULTS.rollingBallRadius);
  store.setWatershedSplit(PARAM_DEFAULTS.watershedSplit);
  store.setWatershedMinDistanceUm(PARAM_DEFAULTS.watershedMinDistanceUm);
  store.setUseGpu(PARAM_DEFAULTS.useGpu);
  store.setMaxParallel(PARAM_DEFAULTS.maxParallel);
}

// ---------------------------------------------------------------------------
// Utils
// ---------------------------------------------------------------------------

/** A uuid for new preset rows (crypto.randomUUID when available). */
function newId(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return "preset-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }
}
