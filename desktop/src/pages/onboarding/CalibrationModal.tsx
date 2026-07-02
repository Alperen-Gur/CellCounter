/**
 * pages/onboarding/CalibrationModal.tsx — the calibration sheet.
 *
 * Port of `CalibrationSheet` in `CalibrationSheet.swift`. Three tabs:
 *
 *   1. "Enter scale"        — type px/µm directly.
 *   2. "Draw on scale bar"  — drag a line across the image's printed scale bar,
 *                             enter the bar's real length in µm; px/µm is derived
 *                             from (drawn px length) / (real µm).
 *   3. "Use preset"         — pick a saved px/µm preset (persisted presets first,
 *                             else the BUILTIN_PRESETS ladder); save the current
 *                             value as a new preset inline.
 *
 * On save it writes `store.pxPerUm` (via the frozen zustand setter) and records a
 * calibration note. The live `objectiveLabel(pxPerUm)` from kernel-calibration is
 * shown so the user sees "10× objective" / "custom scale" as they type.
 *
 * Kernel used: `objectiveLabel`, `BUILTIN_PRESETS` (kernel-calibration);
 * `store.setPxPerUm` / `store.setCalibrationNote` (kernel-store);
 * `PersistencePort` calibration-preset CRUD (kernel-persistence).
 *
 * Coordinate note: the draw-on-scale-bar math converts view-space drag distance
 * to SOURCE-PIXEL distance using the aspect-fit scale, exactly like the Swift
 * `updateLineLengthFromPoints`.
 */

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { convertFileSrc } from "@tauri-apps/api/core";

import {
  BUILTIN_PRESETS,
  objectiveLabel,
} from "../../kernel/calibration/calibration";
import { getPort } from "../../kernel/persistence";
import type { CalibrationPresetDTO } from "../../kernel/persistence";
import { useAppStore } from "../../kernel/store/store";

type CalibTab = "direct" | "drawline" | "preset";

/** convertFileSrc, guarded so a plain browser preview never throws. */
function safeConvert(path: string): string | undefined {
  try {
    return convertFileSrc(path);
  } catch {
    return undefined;
  }
}

/** A minimal uuid for new preset rows (crypto.randomUUID when available). */
function newId(): string {
  try {
    return crypto.randomUUID();
  } catch {
    return "preset-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
  }
}

export interface CalibrationModalProps {
  /** Absolute source path of the current image (draw-on-scale-bar tab). */
  imagePath?: string;
  onClose(): void;
}

export function CalibrationModal({ imagePath, onClose }: CalibrationModalProps) {
  const pxPerUm = useAppStore((s) => s.pxPerUm);
  const setPxPerUm = useAppStore((s) => s.setPxPerUm);
  const setCalibrationNote = useAppStore((s) => s.setCalibrationNote);

  const [tab, setTab] = useState<CalibTab>("direct");

  // Direct tab value — seeded from the current calibration (Swift: current>0?…:5.2).
  const [val, setVal] = useState<number>(pxPerUm > 0 ? pxPerUm : 5.2);

  // Draw-on-scale-bar tab state.
  const [lineLengthPx, setLineLengthPx] = useState<number>(312);
  const [refUm, setRefUm] = useState<number>(100);
  const derivedVal = refUm > 0 ? lineLengthPx / refUm : 0;

  // Preset tab state.
  const [presets, setPresets] = useState<CalibrationPresetDTO[]>([]);
  const [selectedPreset, setSelectedPreset] = useState<string>(
    "Olympus IX73 — 20×",
  );
  const [addingNew, setAddingNew] = useState(false);
  const [newPresetName, setNewPresetName] = useState("");

  // The value that would be saved from the active tab.
  const saveVal = useMemo(() => {
    switch (tab) {
      case "direct":
        return val;
      case "drawline":
        return derivedVal;
      case "preset": {
        const rows =
          presets.length > 0
            ? presets.map((p) => ({ name: p.name, px: p.pxPerUm }))
            : BUILTIN_PRESETS.map((p) => ({ name: p.name, px: p.pxPerUm }));
        return rows.find((r) => r.name === selectedPreset)?.px ?? val;
      }
      default:
        return val;
    }
  }, [tab, val, derivedVal, presets, selectedPreset]);

  const saveDisabled = saveVal <= 0;

  // Load persisted presets on open (Swift CalibPresetTab.refresh on appear).
  const refreshPresets = useCallback(async () => {
    try {
      const rows = await getPort().calibrationPresets();
      setPresets(rows);
    } catch {
      // No port (preview) — fall back to built-ins, handled at render.
      setPresets([]);
    }
  }, []);

  useEffect(() => {
    void refreshPresets();
  }, [refreshPresets]);

  const commit = useCallback(() => {
    // Guard against zero/negative px/µm to prevent divide-by-zero downstream
    // (Swift B4-4). Persist through the frozen store setter.
    if (saveVal <= 0) return;
    setPxPerUm(saveVal);
    setCalibrationNote(
      `Scale set to ${saveVal.toFixed(2)} px/µm (${objectiveLabel(saveVal)}).`,
    );
    onClose();
  }, [saveVal, setPxPerUm, setCalibrationNote, onClose]);

  const commitNewPreset = useCallback(async () => {
    const trimmed = newPresetName.trim();
    if (trimmed.length === 0 || saveVal <= 0) return;
    const preset: CalibrationPresetDTO = {
      id: newId(),
      name: trimmed,
      pxPerUm: tab === "direct" ? val : saveVal,
      isDefault: false,
    };
    try {
      await getPort().upsertCalibrationPreset(preset);
      await refreshPresets();
    } catch {
      // Preview build with no port: keep the row locally so the UI still updates.
      setPresets((prev) => [...prev, preset]);
    }
    setAddingNew(false);
    setNewPresetName("");
    setSelectedPreset(trimmed);
  }, [newPresetName, saveVal, tab, val, refreshPresets]);

  const deletePreset = useCallback(
    async (id: string) => {
      try {
        await getPort().deleteCalibrationPreset(id);
        await refreshPresets();
      } catch {
        setPresets((prev) => prev.filter((p) => p.id !== id));
      }
    },
    [refreshPresets],
  );

  // Enter → save when valid, Escape → close (Swift onKeyPress parity).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing =
        target &&
        (target.tagName === "INPUT" || target.tagName === "TEXTAREA");
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
        return;
      }
      if (e.key === "Enter" && !typing) {
        e.preventDefault();
        if (!saveDisabled) commit();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [saveDisabled, commit, onClose]);

  return (
    <div
      className="cc-cal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="Calibrate scale"
      onPointerDown={(e) => {
        // Backdrop click closes (Swift onTapGesture on the overlay).
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="cc-cal-sheet">
        <header className="cc-cal-head">
          <div className="cc-cal-head__text">
            <h2 className="cc-cal-head__title">Calibrate scale</h2>
            <p className="cc-cal-head__sub">
              Tells CellCounter how many pixels make a micrometer. Without this,
              sizes are wrong.
            </p>
          </div>
          <button
            type="button"
            className="cc-cal-head__close"
            onClick={onClose}
            aria-label="Close"
          >
            ✕
          </button>
        </header>

        <div className="cc-cal-tabs" role="tablist">
          <TabButton
            label="Enter scale"
            active={tab === "direct"}
            onClick={() => setTab("direct")}
          />
          <TabButton
            label="Draw on scale bar"
            active={tab === "drawline"}
            onClick={() => setTab("drawline")}
          />
          <TabButton
            label="Use preset"
            active={tab === "preset"}
            onClick={() => setTab("preset")}
          />
        </div>

        <div className="cc-cal-body">
          {tab === "direct" && (
            <DirectTab val={val} onChange={setVal} />
          )}
          {tab === "drawline" && (
            <DrawlineTab
              imagePath={imagePath}
              lineLengthPx={lineLengthPx}
              refUm={refUm}
              derivedVal={derivedVal}
              onLineLength={setLineLengthPx}
              onRefUm={setRefUm}
            />
          )}
          {tab === "preset" && (
            <PresetTab
              presets={presets}
              selected={selectedPreset}
              currentVal={saveVal}
              addingNew={addingNew}
              newPresetName={newPresetName}
              onSelect={(name, px) => {
                setSelectedPreset(name);
                setVal(px);
              }}
              onStartAdd={() => {
                setNewPresetName("");
                setAddingNew(true);
              }}
              onCancelAdd={() => {
                setAddingNew(false);
                setNewPresetName("");
              }}
              onNewNameChange={setNewPresetName}
              onCommitAdd={() => void commitNewPreset()}
              onDelete={(id) => void deletePreset(id)}
            />
          )}
        </div>

        <div className="cc-cal-preview-line">
          <span className="cc-cal-preview-line__eq">=</span>
          <span className="cc-cal-preview-line__val">
            {saveVal.toFixed(2)} px / µm
          </span>
          <span className="cc-cal-preview-line__obj">
            {objectiveLabel(saveVal)}
          </span>
        </div>

        <footer className="cc-cal-foot">
          <button type="button" className="cc-cal-btn" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className="cc-cal-btn cc-cal-btn--primary"
            onClick={commit}
            disabled={saveDisabled}
          >
            Save calibration
          </button>
        </footer>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Tab button
// ---------------------------------------------------------------------------

function TabButton({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick(): void;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      className={"cc-cal-tab" + (active ? " cc-cal-tab--active" : "")}
      onClick={onClick}
    >
      {label}
    </button>
  );
}

// ---------------------------------------------------------------------------
// Direct tab
// ---------------------------------------------------------------------------

function DirectTab({
  val,
  onChange,
}: {
  val: number;
  onChange(v: number): void;
}) {
  return (
    <div className="cc-cal-direct">
      <NumberBox value={val} unit="px / µm" onChange={onChange} big />
      <p className="cc-cal-hint">
        For our 20× objective on the IX73, this is typically{" "}
        <code>5.2</code>. Check your microscope's manual or run the slide-ruler
        calibration once.
      </p>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Draw-on-scale-bar tab
// ---------------------------------------------------------------------------

function DrawlineTab({
  imagePath,
  lineLengthPx,
  refUm,
  derivedVal,
  onLineLength,
  onRefUm,
}: {
  imagePath?: string;
  lineLengthPx: number;
  refUm: number;
  derivedVal: number;
  onLineLength(v: number): void;
  onRefUm(v: number): void;
}) {
  const src = useMemo(
    () => (imagePath ? safeConvert(imagePath) : undefined),
    [imagePath],
  );

  const areaRef = useRef<HTMLDivElement | null>(null);
  const imgRef = useRef<HTMLImageElement | null>(null);
  const [imgNatural, setImgNatural] = useState<{ w: number; h: number } | null>(
    null,
  );
  // Drag endpoints in view (area-local) px.
  const [start, setStart] = useState<{ x: number; y: number } | null>(null);
  const [end, setEnd] = useState<{ x: number; y: number } | null>(null);

  /**
   * Aspect-fit scale (view-px per source-px) used to convert the drawn view
   * distance to a SOURCE-PIXEL distance — mirrors the Swift `.aspectRatio(.fit)`
   * math in `updateLineLengthFromPoints`.
   */
  const updateFromPoints = useCallback(
    (a: { x: number; y: number }, b: { x: number; y: number }) => {
      const area = areaRef.current;
      if (!area || !imgNatural) return;
      const rect = area.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      if (imgNatural.w <= 0 || imgNatural.h <= 0) return;
      const scaleX = rect.width / imgNatural.w;
      const scaleY = rect.height / imgNatural.h;
      const fitScale = Math.min(scaleX, scaleY);
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const viewDist = Math.hypot(dx, dy);
      const pixelDist = viewDist / fitScale;
      if (pixelDist > 1) onLineLength(pixelDist);
    },
    [imgNatural, onLineLength],
  );

  const localPoint = useCallback((e: ReactPointerEvent) => {
    const area = areaRef.current;
    if (!area) return { x: 0, y: 0 };
    const rect = area.getBoundingClientRect();
    return { x: e.clientX - rect.left, y: e.clientY - rect.top };
  }, []);

  const onPointerDown = useCallback(
    (e: ReactPointerEvent) => {
      if (!src) return;
      e.preventDefault();
      (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
      const p = localPoint(e);
      setStart(p);
      setEnd(p);
    },
    [src, localPoint],
  );

  const onPointerMove = useCallback(
    (e: ReactPointerEvent) => {
      if (!src || start === null) return;
      const p = localPoint(e);
      setEnd(p);
      updateFromPoints(start, p);
    },
    [src, start, localPoint, updateFromPoints],
  );

  const onPointerUp = useCallback(
    (e: ReactPointerEvent) => {
      if (!src || start === null) return;
      const p = localPoint(e);
      setEnd(p);
      updateFromPoints(start, p);
    },
    [src, start, localPoint, updateFromPoints],
  );

  const mid =
    start && end ? { x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 } : null;

  return (
    <div className="cc-cal-draw">
      <div
        ref={areaRef}
        className="cc-cal-draw__area"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        style={{ cursor: src ? "crosshair" : "default" }}
      >
        {src ? (
          <>
            <img
              ref={imgRef}
              className="cc-cal-draw__img"
              src={src}
              alt=""
              draggable={false}
              onLoad={(e) => {
                const el = e.currentTarget;
                setImgNatural({
                  w: el.naturalWidth,
                  h: el.naturalHeight,
                });
              }}
            />
            {start === null && (
              <div className="cc-cal-draw__hint">
                Drag across the scale bar to measure it
              </div>
            )}
            {start && end && (
              <svg className="cc-cal-draw__overlay" aria-hidden="true">
                <line
                  x1={start.x}
                  y1={start.y}
                  x2={end.x}
                  y2={end.y}
                  stroke="var(--cc-accent)"
                  strokeWidth={2.5}
                  strokeLinecap="round"
                />
                <circle cx={start.x} cy={start.y} r={4} fill="var(--cc-accent)" />
                <circle cx={end.x} cy={end.y} r={4} fill="var(--cc-accent)" />
                {mid && (
                  <text
                    x={mid.x}
                    y={mid.y - 12}
                    textAnchor="middle"
                    fontSize={10}
                    fontFamily="var(--cc-font-mono)"
                    fill="var(--cc-accent)"
                  >
                    {Math.round(lineLengthPx)} px
                  </text>
                )}
              </svg>
            )}
          </>
        ) : (
          <div className="cc-cal-draw__empty">
            Open an image to draw on its scale bar.
          </div>
        )}
      </div>

      <div className="cc-cal-draw__inputs">
        <NumberBox
          value={lineLengthPx}
          unit="px (line)"
          onChange={onLineLength}
        />
        <NumberBox value={refUm} unit="µm (real)" onChange={onRefUm} />
      </div>

      <div className="cc-cal-draw__derived">
        <span className="cc-cal-preview-line__eq">=</span>
        <span className="cc-cal-preview-line__val">
          {derivedVal.toFixed(2)} px / µm
        </span>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Preset tab
// ---------------------------------------------------------------------------

function PresetTab({
  presets,
  selected,
  currentVal,
  addingNew,
  newPresetName,
  onSelect,
  onStartAdd,
  onCancelAdd,
  onNewNameChange,
  onCommitAdd,
  onDelete,
}: {
  presets: CalibrationPresetDTO[];
  selected: string;
  currentVal: number;
  addingNew: boolean;
  newPresetName: string;
  onSelect(name: string, px: number): void;
  onStartAdd(): void;
  onCancelAdd(): void;
  onNewNameChange(v: string): void;
  onCommitAdd(): void;
  onDelete(id: string): void;
}) {
  // SwiftData is the source of truth: persisted presets first; the BUILTIN_PRESETS
  // ladder is a fallback only when the store is empty (legacy / all-deleted), so
  // we never duplicate the seeded rows (Swift CalibPresetTab comment).
  const rows =
    presets.length > 0
      ? presets.map((p) => ({
          id: p.id,
          name: p.name,
          px: p.pxPerUm,
          deletable: true,
        }))
      : BUILTIN_PRESETS.map((p) => ({
          id: p.name,
          name: p.name,
          px: p.pxPerUm,
          deletable: false,
        }));

  return (
    <div className="cc-cal-presets">
      <div className="cc-cal-presets__list">
        {rows.map((row, idx) => (
          <div key={row.id}>
            <button
              type="button"
              className={
                "cc-cal-preset-row" +
                (selected === row.name ? " cc-cal-preset-row--sel" : "")
              }
              onClick={() => onSelect(row.name, row.px)}
            >
              <span className="cc-cal-preset-row__text">
                <span className="cc-cal-preset-row__name">{row.name}</span>
                <span className="cc-cal-preset-row__px">
                  {row.px.toFixed(1)} px / µm
                </span>
              </span>
              {row.deletable && (
                <span
                  className="cc-cal-preset-row__del"
                  role="button"
                  tabIndex={0}
                  aria-label={`Delete preset ${row.name}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    onDelete(row.id);
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      e.stopPropagation();
                      onDelete(row.id);
                    }
                  }}
                >
                  🗑
                </span>
              )}
              {selected === row.name && (
                <span className="cc-cal-preset-row__check" aria-hidden="true">
                  ✓
                </span>
              )}
            </button>
            {idx < rows.length - 1 && <div className="cc-cal-preset-div" />}
          </div>
        ))}
      </div>

      {addingNew ? (
        <div className="cc-cal-presets__add">
          <input
            className="cc-cal-input"
            type="text"
            placeholder='Preset name (e.g. "IX73 — 20×")'
            value={newPresetName}
            autoFocus
            onChange={(e) => onNewNameChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                onCommitAdd();
              }
            }}
          />
          <span className="cc-cal-presets__addval">
            {currentVal.toFixed(2)} px/µm
          </span>
          <button type="button" className="cc-cal-btn" onClick={onCancelAdd}>
            Cancel
          </button>
          <button
            type="button"
            className="cc-cal-btn cc-cal-btn--primary"
            onClick={onCommitAdd}
            disabled={newPresetName.trim().length === 0 || currentVal <= 0}
          >
            Save
          </button>
        </div>
      ) : (
        <button
          type="button"
          className="cc-cal-presets__addbtn"
          onClick={onStartAdd}
          disabled={currentVal <= 0}
        >
          + Save current value as new preset…
        </button>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Numeric input box (shared)
// ---------------------------------------------------------------------------

function NumberBox({
  value,
  unit,
  onChange,
  big = false,
}: {
  value: number;
  unit: string;
  onChange(v: number): void;
  big?: boolean;
}) {
  // Keep a text buffer so the user can clear the field / type "5." mid-edit
  // without React snapping it back to a number.
  const [text, setText] = useState<string>(() => formatNum(value));
  const focusedRef = useRef(false);

  useEffect(() => {
    if (!focusedRef.current) setText(formatNum(value));
  }, [value]);

  return (
    <div className={"cc-cal-numbox" + (big ? " cc-cal-numbox--big" : "")}>
      <input
        className="cc-cal-numbox__input"
        type="text"
        inputMode="decimal"
        value={text}
        onFocus={() => {
          focusedRef.current = true;
        }}
        onBlur={() => {
          focusedRef.current = false;
          setText(formatNum(value));
        }}
        onChange={(e) => {
          const raw = e.target.value;
          setText(raw);
          const parsed = Number(raw);
          if (raw.trim() !== "" && Number.isFinite(parsed)) {
            onChange(parsed);
          }
        }}
      />
      <span className="cc-cal-numbox__unit">{unit}</span>
    </div>
  );
}

function formatNum(v: number): string {
  if (!Number.isFinite(v)) return "0";
  // Drop trailing zeros but keep up to 2 decimals (matches the sheet's display).
  return String(Math.round(v * 100) / 100);
}
