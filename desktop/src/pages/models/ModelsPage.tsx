/**
 * pages/models/ModelsPage.tsx — the Models tab (feature task `feat-models`).
 *
 * Catalog UI (ARCHITECTURE.md §4, `/models`):
 *   • Two catalog entries are runnable — Cellpose `cp-cyto3` and Cellpose-SAM
 *     `cpsam` — each installed, probed, and activated independently (the Rust
 *     side keeps them in separate venvs, so installing one never touches the
 *     other's status). Every other catalog entry renders "coming soon" and is
 *     non-activatable.
 *   • The Install button calls the kernel-env `env_install` command (passing
 *     the card's own `modelId`) and streams its `uv sync` progress lines live
 *     (via the `env://install/log` event); we never re-implement the uv
 *     bootstrap here.
 *   • Availability from `env_availability` + the transport's `availability`
 *     (`detection_availability`) — both probed with that card's own `modelId`
 *     — gates the Run flow: the card shows Installed / Not installed and the
 *     Activate action is disabled until that model is runnable.
 *   • Activating sets `store.activeModelId` (the FROZEN store slice); we only
 *     consume the setter, never change the slice shape.
 *
 * This page owns ONLY `pages/models/`. It talks to kernel-env / kernel-transport
 * through `useModelInstall`, reads/writes the active model via the store, and
 * imports domain vocabulary from kernel-types — nothing else.
 */

import { useAppStore } from "../../kernel/store/store";
import { Icon, type IconName } from "../../components/Icon";
import { MODEL_CATALOG, type ModelCatalogEntry } from "./catalog";
import { useModelInstall, type UseModelInstall } from "./useModelInstall";
import "./models.css";

export default function ModelsPage() {
  const activeModelId = useAppStore((s) => s.activeModelId);
  const setActiveModelId = useAppStore((s) => s.setActiveModelId);

  return (
    <div className="cc-models">
      <div className="cc-models__intro">
        <h1 className="cc-models__title">Models</h1>
        <p className="cc-models__subtitle">
          CellCounter ships with Cellpose <strong>cyto3</strong> for general
          cytoplasm segmentation and <strong>Cellpose-SAM</strong> for large or
          irregular cells. Install a model once — it runs locally through the
          bundled Python sidecar. Additional models are on the way.
        </p>
      </div>

      <section className="cc-models__section" aria-label="Model catalog">
        <div className="cc-models__section-head">
          <span className="cc-models__section-title">Catalog</span>
        </div>
        <ul className="cc-models__list">
          {MODEL_CATALOG.map((model) =>
            model.available ? (
              <RunnableModelCard
                key={model.id}
                model={model}
                isActive={model.id === activeModelId}
                onActivate={() => setActiveModelId(model.id)}
              />
            ) : (
              <ComingSoonCard key={model.id} model={model} />
            ),
          )}
        </ul>
      </section>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Runnable model card — installs / probes / activates ITS OWN model id
// ---------------------------------------------------------------------------

interface RunnableModelCardProps {
  model: ModelCatalogEntry;
  isActive: boolean;
  onActivate: () => void;
}

function RunnableModelCard({
  model,
  isActive,
  onActivate,
}: RunnableModelCardProps) {
  // One hook instance per runnable card: cyto3 and cpsam each drive their own
  // install/availability lifecycle against their own venv (kernel-env routes
  // `cpsam` to a separate `cellpose>=4` venv), so installing one never
  // reports on — or blocks — the other.
  const install = useModelInstall(model.id);
  const { availability, uv, probing, phase, logLines, error } = install;

  const installing = phase === "installing";
  const installed = availability?.installed === true;
  const runnable = installed; // the Run flow gates on this
  // The install IS `uv sync`, so surface a missing uv toolchain on the button
  // itself instead of letting the user click into a raw spawn error.
  const uvMissing = uv != null && !uv.installed;

  const cardClass =
    "cc-model-card" + (isActive ? " cc-model-card--active" : "");

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
        <AvailabilityPill probing={probing} installed={installed} />
        <span className="cc-model-card__meta">
          {model.backend} · {model.sizeLabel}
        </span>
      </div>

      <p className="cc-model-card__body">{model.description}</p>

      <div className="cc-model-card__actions">
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
      </div>

      <div className="cc-model-card__status">
        <InstallStatus
          modelName={model.name}
          installing={installing}
          phase={phase}
          error={error}
          availabilityReason={
            !installed && !installing ? availability?.reason : undefined
          }
          logLines={logLines}
        />
      </div>
    </li>
  );
}

// ---------------------------------------------------------------------------
// Coming-soon card — static, no install/availability probe
// ---------------------------------------------------------------------------

function ComingSoonCard({ model }: { model: ModelCatalogEntry }) {
  return (
    <li className="cc-model-card cc-model-card--soon">
      <div className="cc-model-card__glyph" aria-hidden="true">
        <Icon name={model.glyph as IconName} size={22} />
      </div>

      <div className="cc-model-card__head">
        <span className="cc-model-card__name">{model.name}</span>
        <span className="cc-pill cc-pill--soon">
          <Icon name="clock" size={12} />
          Coming soon
        </span>
        <span className="cc-model-card__meta">
          {model.backend} · {model.sizeLabel}
        </span>
      </div>

      <p className="cc-model-card__body">{model.description}</p>

      <div className="cc-model-card__actions">
        <button
          type="button"
          className="cc-btn cc-models__btn"
          disabled
          title="This model is not available yet."
        >
          Unavailable
        </button>
      </div>
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
  /** Model display name, for the "install complete" message. */
  modelName: string;
  installing: boolean;
  phase: UseModelInstall["phase"];
  error?: string;
  availabilityReason?: string;
  logLines: string[];
}

function InstallStatus({
  modelName,
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
          Install complete — {modelName} is ready to run.
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
