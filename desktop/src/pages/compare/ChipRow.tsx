/**
 * pages/compare/ChipRow.tsx — the condition selector chips (feature `feat-compare`).
 *
 * Port of `ChipRow` in `Views/Compare/CompareView.swift`. A horizontal, scrollable
 * row of toggle chips (one per condition) with the condition's color dot. Enforces
 * the 1–4 selection rule via the parent's `onToggle` (which flashes a min hint when
 * the user tries to drop the last chip). A trailing helper caption echoes the Swift
 * `"Select 1–N conditions"` / `"Select at least one"` messaging.
 */

import type { ConditionDTO } from "../../kernel/persistence";
import { MAX_SELECTED } from "./useCompareData";

interface ChipRowProps {
  conditions: ConditionDTO[];
  selected: Set<string>;
  minHint: boolean;
  onToggle(name: string): void;
}

export function ChipRow({
  conditions,
  selected,
  minHint,
  onToggle,
}: ChipRowProps) {
  return (
    <div className="cc-compare__chiprow">
      <div className="cc-compare__chips" role="group" aria-label="Conditions">
        {conditions.map((cond) => {
          const isOn = selected.has(cond.name);
          return (
            <button
              key={cond.id}
              type="button"
              className={
                "cc-compare__chip" + (isOn ? " cc-compare__chip--on" : "")
              }
              style={
                isOn
                  ? {
                      // Tint the selected chip with the condition color.
                      borderColor: cond.color,
                      background: `color-mix(in srgb, ${cond.color} 18%, transparent)`,
                    }
                  : undefined
              }
              aria-pressed={isOn}
              onClick={() => onToggle(cond.name)}
            >
              <span
                className="cc-compare__dot"
                style={{ background: cond.color }}
                aria-hidden="true"
              />
              <span className="cc-compare__chip-label">{cond.name}</span>
            </button>
          );
        })}
      </div>

      <span
        className={
          "cc-compare__chip-hint" +
          (minHint ? " cc-compare__chip-hint--warn" : "")
        }
        role={minHint ? "status" : undefined}
      >
        {minHint
          ? "Select at least one"
          : `Select 1–${MAX_SELECTED} conditions`}
      </span>
    </div>
  );
}
