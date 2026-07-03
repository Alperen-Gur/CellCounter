/**
 * pages/models/ModelsPage.tsx — the Models tab (feature task `feat-models`).
 *
 * v1 catalog UI (ARCHITECTURE.md §4, `/models`):
 *   • Exactly one model is active in v1 — Cellpose `cyto3`. Every other catalog
 *     entry renders "coming soon" and is non-activatable (boundary: no non-cyto3
 *     runtimes in v1).
 *   • The Install button calls the kernel-env `env_install` command and streams
 *     its `uv sync` progress lines live (via the `env://install/log` event); we
 *     never re-implement the uv bootstrap here.
 *   • Availability from `env_availability` + the transport's `availability`
 *     (`detection_availability`) gates the Run flow: the card shows Installed /
 *     Not installed and the Activate action is disabled until the model is
 *     runnable.
 *   • Activating sets `store.activeModelId` (the FROZEN store slice); we only
 *     consume the setter, never change the slice shape.
 *
 * This page owns ONLY `pages/models/`. It talks to kernel-env / kernel-transport
 * through `useModelInstall`, reads/writes the active model via the store, and
 * imports domain vocabulary from kernel-types — nothing else.
 */

import { useMemo } from "react";

import { useAppStore } from "../../kernel/store/store";
import { Icon, type IconName } from "../../components/Icon";
import { MODEL_CATALOG, type ModelCatalogEntry } from "./catalog";
import { useModelInstall, type UseModelInstall } from "./useModelInstall";
import "./models.css";

export default function ModelsPage() {
  const activeModelId = useAppStore((s) => s.activeModelId);
  const setActiveModelId = useAppStore((s) => s.setActiveModelId);

  // Availability / install lifecycle is driven for the single runnable model.
  // (In v1 that is always cyto3; the coming-soon cards need no probe.)
  const runnableModelId = useMemo(
    () => MODEL_CATALOG.find((m) => m.available)?.id ?? activeModelId,
    [activeModelId],
  );
  const install = useModelInstall(runnableModelId);

  return (
    <div className="cc-models">
      <div className="cc-models__intro">
        <h1 className="cc-models__title">Models</h1>
        <p className="cc-models__subtitle">
          CellCounter v1 ships with Cellpose <strong>cyto3</strong> for general
          cytoplasm segmentation. Install it once — it runs locally through the
          bundled Python sidecar. Additional models are on the way.
        </p>
      </div>

      <section className="cc-models__section" aria-label="Model catalog">
        <div className="cc-models__section-head">
          <span className="cc-models__section-title">Catalog</span>
        </div>
        <ul className="cc-models__list">
          {MODEL_CATALOG.map((model) => (
            <ModelCard
              key={model.id}
              model={model}
              isActive={model.id === activeModelId}
              install={install}
              onActivate={() => setActiveModelId(model.id)}
            />
          ))}
        </ul>
      </section>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Model card
// ---------------------------------------------------------------------------

interface ModelCardProps {
  model: ModelCatalogEntry;
  isActive: boolean;
  install: UseModelInstall;
  onActivate: () => void;
}

function ModelCard({ model, isActive, install, onActivate }: ModelCardProps) {
  const { availability, uv, probing, phase, logLines, error } = install;

  const installing = model.available && phase === "installing";
  const installed = model.available && availability?.installed === true;
  const runnable = installed; // the Run flow gates on this
  // The install IS `uv sync`, so surface a missing uv toolchain on the button
  // itself instead of letting the user click into a raw spawn error.
  const uvMissing = uv != null && !uv.installed;

  const cardClass =
    "cc-model-card" +
    (isActive ? " cc-model-card--active" : "") +
    (model.available ? "" : " cc-model-card--soon");

  return (
    <li className={cardClass}>
      <div className="cc-model-card__glyph" aria-hidden="true">
        <Icon name={model.glyph as IconName} size={22} />
      </div>

      <div className="cc-model-card__head">
        <span className="cc-model-card__name">{model.name}</span>
        {isActive && (
          <span className="cc-pill cc-pill--active">
            <span className="cc-pill__dot" aria-hidden="true" />
            Active
          </span>
        )}
        {model.available ? (
          <AvailabilityPill
            probing={probing}
            installed={installed}
          />
        ) : (
          <span className="cc-pill cc-pill--soon">
            <Icon name="clock" size={12} />
            Coming soon
          </span>
        )}
        <span className="cc-model-card__meta">
          {model.backend} · {model.sizeLabel}
        </span>
      </div>

      <p className="cc-model-card__body">{model.description}</p>

      <div className="cc-model-card__actions">
        {model.available ? (
          <>
            <button
              type="button"
              className="cc-btn cc-models__btn"
              onClick={() => void install.install()}
              disabled={installing || uvMissing}
              title={
                uvMissing
                  ? (uv?.reason ??
                    "The uv toolchain isn't installed — install uv first.")
                  : undefined
              }
            >
              <Icon name={installed ? "refresh" : "download"} size={15} />
              {installing
                ? "Installing…"
                : installed
                  ? "Reinstall"
                  : "Install"}
            </button>
            <button
              type="button"
              className="cc-btn cc-btn--primary cc-models__btn"
              onClick={onActivate}
              disabled={isActive || !runnable}
              title={
                !runnable
                  ? "Install the model before activating it."
                  : isActive
                    ? "This model is already active."
                    : undefined
              }
            >
              {isActive && <Icon name="check" size={15} />}
              {isActive ? "Activated" : "Activate"}
            </button>
          </>
        ) : (
          // Coming-soon models are non-activatable: a single disabled control.
          <button
            type="button"
            className="cc-btn cc-models__btn"
            disabled
            title="This model is not available in v1."
          >
            Unavailable
          </button>
        )}
      </div>

      {/* Install status + streamed uv log — only for the runnable model. */}
      {model.available && (
        <div className="cc-model-card__status">
          <InstallStatus
            installing={installing}
            phase={phase}
            error={error}
            availabilityReason={
              !installed && !installing ? availability?.reason : undefined
            }
            logLines={logLines}
          />
        </div>
      )}
    </li>
  );
}

// ---------------------------------------------------------------------------
// Availability pill
// ---------------------------------------------------------------------------

function AvailabilityPill({
  probing,
  installed,
}: {
  probing: boolean;
  installed: boolean;
}) {
  if (probing && !installed) {
    return (
      <span className="cc-pill cc-pill--soon">
        <Icon name="refresh" size={12} className="cc-pill__spin" />
        Checking…
      </span>
    );
  }
  return installed ? (
    <span className="cc-pill cc-pill--installed">
      <Icon name="checkCircle" size={13} />
      Installed
    </span>
  ) : (
    <span className="cc-pill cc-pill--missing">
      <Icon name="alert" size={13} />
      Not installed
    </span>
  );
}

// ---------------------------------------------------------------------------
// Install status + log
// ---------------------------------------------------------------------------

interface InstallStatusProps {
  installing: boolean;
  phase: UseModelInstall["phase"];
  error?: string;
  availabilityReason?: string;
  logLines: string[];
}

function InstallStatus({
  installing,
  phase,
  error,
  availabilityReason,
  logLines,
}: InstallStatusProps) {
  const showLog = installing || logLines.length > 0;

  return (
    <div className="cc-install-status">
      {installing && (
        <div className="cc-install-bar" aria-hidden="true">
          <div className="cc-install-bar__fill" />
        </div>
      )}

      {phase === "error" && error && (
        <span className="cc-install-status__error" role="alert">
          <Icon name="xCircle" size={14} />
          Install failed: {error}
        </span>
      )}

      {phase === "done" && !installing && (
        <span className="cc-install-status__reason cc-install-status__reason--ok">
          <Icon name="checkCircle" size={14} />
          Install complete — cyto3 is ready to run.
        </span>
      )}

      {availabilityReason && phase !== "error" && (
        <span className="cc-install-status__reason">
          <Icon name="info" size={14} />
          {availabilityReason}
        </span>
      )}

      {showLog && (
        <pre
          className="cc-install-log"
          aria-label="Installation log"
          aria-live="polite"
        >
          {logLines.length === 0 ? (
            <span className="cc-install-log__empty">
              Starting installer… waiting for uv output.
            </span>
          ) : (
            logLines.map((line, i) => (
              <span key={i} className="cc-install-log__line">
                {line}
              </span>
            ))
          )}
        </pre>
      )}
    </div>
  );
}
