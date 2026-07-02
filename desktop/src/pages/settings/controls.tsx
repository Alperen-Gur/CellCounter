/**
 * pages/settings/controls.tsx — small presentational controls shared by the
 * Settings sections (feat-settings).
 *
 * These are pure, headless-ish widgets (a labelled row, a toggle switch, a
 * numeric field with a live text buffer, a slider, a segmented picker). They own
 * no app state — every value/handler is passed in by the section, which reads /
 * writes the FROZEN zustand store. Styling lives in `settings.css`.
 */

import {
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

// ---------------------------------------------------------------------------
// SetRow — label + description on the left, control on the right (Swift SetRow)
// ---------------------------------------------------------------------------

export function SetRow({
  label,
  desc,
  children,
}: {
  label: string;
  desc?: string;
  children: ReactNode;
}) {
  return (
    <div className="cc-set__row">
      <div className="cc-set__row-text">
        <span className="cc-set__row-label">{label}</span>
        {desc && <span className="cc-set__row-desc">{desc}</span>}
      </div>
      <div className="cc-set__row-control">{children}</div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Toggle — port of the Swift CustomToggle
// ---------------------------------------------------------------------------

export function Toggle({
  on,
  onChange,
  label,
}: {
  on: boolean;
  onChange(v: boolean): void;
  label?: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className={"cc-set__toggle" + (on ? " cc-set__toggle--on" : "")}
      onClick={() => onChange(!on)}
    >
      <span className="cc-set__toggle-knob" aria-hidden="true" />
    </button>
  );
}

// ---------------------------------------------------------------------------
// NumberField — text-buffered numeric input (lets the user clear / type "5.")
// ---------------------------------------------------------------------------

export function NumberField({
  value,
  onCommit,
  unit,
  wide = false,
  min,
  ariaLabel,
}: {
  value: number;
  /** Called with a finite parsed number when the field is edited. */
  onCommit(v: number): void;
  unit?: string;
  wide?: boolean;
  min?: number;
  ariaLabel?: string;
}) {
  const [text, setText] = useState<string>(() => formatNum(value));
  const focused = useRef(false);

  // Sync down from the store when we are NOT actively editing, so external
  // changes (e.g. applying a preset) reflect without stomping the user's typing.
  useEffect(() => {
    if (!focused.current) setText(formatNum(value));
  }, [value]);

  return (
    <>
      <input
        className={"cc-set__num" + (wide ? " cc-set__num--wide" : "")}
        type="text"
        inputMode="decimal"
        aria-label={ariaLabel}
        value={text}
        onFocus={() => {
          focused.current = true;
        }}
        onBlur={() => {
          focused.current = false;
          setText(formatNum(value));
        }}
        onChange={(e) => {
          const raw = e.target.value;
          setText(raw);
          if (raw.trim() === "") return;
          const parsed = Number(raw);
          if (!Number.isFinite(parsed)) return;
          if (min !== undefined && parsed < min) return;
          onCommit(parsed);
        }}
      />
      {unit && <span className="cc-set__unit">{unit}</span>}
    </>
  );
}

export function formatNum(v: number): string {
  if (!Number.isFinite(v)) return "0";
  return String(Math.round(v * 1000) / 1000);
}

// ---------------------------------------------------------------------------
// SliderField — range input + a monospace read-out (Swift Slider + label)
// ---------------------------------------------------------------------------

export function SliderField({
  value,
  min,
  max,
  step = 1,
  onChange,
  format,
  ariaLabel,
}: {
  value: number;
  min: number;
  max: number;
  step?: number;
  onChange(v: number): void;
  /** Render the trailing read-out (e.g. `${v} px`). */
  format(v: number): string;
  ariaLabel?: string;
}) {
  return (
    <>
      <input
        className="cc-set__slider"
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        aria-label={ariaLabel}
        onChange={(e) => onChange(Number(e.target.value))}
      />
      <span className="cc-set__slider-val">{format(value)}</span>
    </>
  );
}

// ---------------------------------------------------------------------------
// SegmentedPicker — a compact button group (channels cyto / nuclei)
// ---------------------------------------------------------------------------

export function SegmentedPicker<T extends string | number>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange(v: T): void;
  ariaLabel?: string;
}) {
  return (
    <div className="cc-set__seg" role="group" aria-label={ariaLabel}>
      {options.map((opt) => (
        <button
          key={String(opt.value)}
          type="button"
          className={
            "cc-set__seg-btn" +
            (opt.value === value ? " cc-set__seg-btn--active" : "")
          }
          aria-pressed={opt.value === value}
          onClick={() => onChange(opt.value)}
        >
          {opt.label}
        </button>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Select — a native <select> styled to the token palette
// ---------------------------------------------------------------------------

export function Select<T extends string | number>({
  value,
  options,
  onChange,
  ariaLabel,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange(v: T): void;
  ariaLabel?: string;
}) {
  return (
    <select
      className="cc-set__select"
      aria-label={ariaLabel}
      value={String(value)}
      onChange={(e) => {
        const raw = e.target.value;
        const match = options.find((o) => String(o.value) === raw);
        if (match) onChange(match.value);
      }}
    >
      {options.map((opt) => (
        <option key={String(opt.value)} value={String(opt.value)}>
          {opt.label}
        </option>
      ))}
    </select>
  );
}

// ---------------------------------------------------------------------------
// ConfirmDialog — a small destructive-action confirmation (Swift NSAlert)
// ---------------------------------------------------------------------------

export function ConfirmDialog({
  title,
  body,
  confirmLabel,
  onConfirm,
  onCancel,
}: {
  title: string;
  body: string;
  confirmLabel: string;
  onConfirm(): void;
  onCancel(): void;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onCancel();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);

  return (
    <div
      className="cc-set__confirm-backdrop"
      role="alertdialog"
      aria-modal="true"
      aria-label={title}
      onPointerDown={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div className="cc-set__confirm">
        <div className="cc-set__confirm-title">{title}</div>
        <div className="cc-set__confirm-body">{body}</div>
        <div className="cc-set__confirm-actions">
          <button
            type="button"
            className="cc-set__confirm-btn"
            onClick={onCancel}
          >
            Cancel
          </button>
          <button
            type="button"
            className="cc-set__confirm-btn cc-set__confirm-btn--danger"
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
