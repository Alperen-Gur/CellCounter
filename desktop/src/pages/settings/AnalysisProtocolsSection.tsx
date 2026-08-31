import { useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { readTextFile, writeTextFile } from "@tauri-apps/plugin-fs";

import { Icon } from "../../components/Icon";
import { useAppStore } from "../../kernel/store/store";
import { modelLabel } from "../models/catalog";
import {
  applyAnalysisProtocol,
  decodeAnalysisProtocol,
  makeAnalysisProtocol,
  safeProtocolFilename,
  type AnalysisProtocol,
} from "./analysisProtocol";

type Status =
  | { kind: "idle" }
  | { kind: "ok"; message: string }
  | { kind: "error"; message: string };

export function AnalysisProtocolsSection() {
  const [name, setName] = useState("");
  const [notes, setNotes] = useState("");
  const [loaded, setLoaded] = useState<AnalysisProtocol | null>(null);
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  const saveCurrent = async () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    const protocol = makeAnalysisProtocol(useAppStore.getState(), trimmed, notes);
    try {
      const path = await save({
        title: "Save Analysis Protocol",
        defaultPath: safeProtocolFilename(protocol.name),
        filters: [{ name: "CellCounter analysis protocol", extensions: ["json"] }],
      });
      if (!path) return;
      await writeTextFile(path, `${JSON.stringify(protocol, null, 2)}\n`);
      setStatus({ kind: "ok", message: `Saved ${protocol.name}.` });
    } catch (error) {
      setStatus({ kind: "error", message: `Could not save the protocol: ${String(error)}` });
    }
  };

  const chooseProtocol = async () => {
    setLoaded(null);
    try {
      const path = await open({
        title: "Open Analysis Protocol",
        multiple: false,
        directory: false,
        filters: [{ name: "CellCounter analysis protocol", extensions: ["json"] }],
      });
      if (!path) return;
      const protocol = decodeAnalysisProtocol(await readTextFile(path));
      setLoaded(protocol);
      setStatus({ kind: "idle" });
    } catch (error) {
      setStatus({ kind: "error", message: `Could not open the protocol: ${String(error)}` });
    }
  };

  const applyLoaded = () => {
    if (!loaded) return;
    const warning = applyAnalysisProtocol(loaded, useAppStore.getState());
    setStatus({
      kind: warning ? "error" : "ok",
      message: warning ?? `Applied ${loaded.name}.`,
    });
    setLoaded(null);
  };

  return (
    <section className="cc-set__section" aria-label="Analysis protocols">
      <div className="cc-set__heading">
        <h1 className="cc-set__title">Analysis protocols</h1>
        <p className="cc-set__subtitle">
          Save or apply a complete, versioned setup for reproducible analysis. Protocol files stay
          local unless you share them.
        </p>
      </div>

      <div className="cc-set__group-title">Save current settings</div>
      <div className="cc-set__protocol-form">
        <label className="cc-set__protocol-field">
          <span>Name</span>
          <input
            className="cc-set__text-input"
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="Keratinocyte 10× — lab standard"
          />
        </label>
        <label className="cc-set__protocol-field">
          <span>Notes (optional)</span>
          <textarea
            className="cc-set__text-input cc-set__protocol-notes"
            value={notes}
            onChange={(event) => setNotes(event.target.value)}
            placeholder="Instrument, objective, purpose, or operator notes"
          />
        </label>
        <button
          type="button"
          className="cc-set__btn cc-set__btn--primary"
          disabled={!name.trim()}
          onClick={() => void saveCurrent()}
        >
          <Icon name="download" size={15} />
          Save protocol…
        </button>
      </div>

      <div className="cc-set__group-title">Apply a protocol</div>
      <button type="button" className="cc-set__add-link" onClick={() => void chooseProtocol()}>
        <Icon name="folder" size={15} />
        Open protocol…
      </button>

      {loaded ? (
        <div className="cc-set__protocol-preview" role="dialog" aria-label="Protocol preview">
          <div className="cc-set__list-text">
            <span className="cc-set__list-name">{loaded.name}</span>
            <span className="cc-set__list-sub">
              {modelLabel(loaded.model.id)} · {loaded.calibration.pxPerUm.toPrecision(4)} px/µm · confidence{" "}
              {loaded.detection.confidenceThreshold.toFixed(2)} · bins{" "}
              {loaded.sizeBins.thresholdsUm.join(" / ")} µm
            </span>
            {loaded.notes ? <span className="cc-set__list-sub">{loaded.notes}</span> : null}
          </div>
          <div className="cc-set__list-actions">
            <button type="button" className="cc-set__btn" onClick={() => setLoaded(null)}>
              Cancel
            </button>
            <button type="button" className="cc-set__btn cc-set__btn--primary" onClick={applyLoaded}>
              Apply all settings
            </button>
          </div>
        </div>
      ) : null}

      {status.kind !== "idle" ? (
        <div
          className={`cc-set__result ${status.kind === "ok" ? "cc-set__result--ok" : "cc-set__result--err"}`}
          role={status.kind === "ok" ? "status" : "alert"}
        >
          <Icon name={status.kind === "ok" ? "checkCircle" : "alert"} size={15} />
          <span>{status.message}</span>
        </div>
      ) : null}
    </section>
  );
}
