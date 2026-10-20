import { useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { PackageInspection } from "../../../../shared/workbench/extensionProtocol";
import type { PackageRestoreResult, StorageUpgradePreview, StorageUpgradeResult } from "../../../../shared/workbench/pagingProtocol";

type Props = {
  snapshot?: ProjectSnapshot; busy: boolean; writeBlocked: boolean;
  selectedPackage?: PackageInspection; restore?: { path: string; result: PackageRestoreResult };
  running: boolean; rememberedRestorePath: string;
  run: (action: () => Promise<void>) => Promise<void>;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T>;
  upgrade: (fingerprint: string, revision: number, accepted: (value: StorageUpgradeResult) => void) => Promise<void>;
  choosePackage: () => Promise<void>; dismissPackage: () => void; startRestore: () => Promise<void>;
  reopenRestore: (path?: string) => Promise<void>; advanceRestore: (remaining: boolean) => Promise<void>;
  stopRestore: () => void; controlRestore: (operation: "cancel" | "resume") => Promise<void>;
  openCompleted: () => Promise<void>;
};
export default function WorkbenchProjectStorage(props: Props) {
  const { snapshot, selectedPackage, restore, busy, writeBlocked } = props;
  const [upgradePreview, setUpgradePreview] = useState<{ projectId: string; value: StorageUpgradePreview }>();
  const [upgradeResult, setUpgradeResult] = useState<{ projectId: string; value: StorageUpgradeResult }>();
  const [storedRecovery, setStoredRecovery] = useState<{ projectId: string; path?: string; relativePath?: string; hash?: string }>();
  const [error, setError] = useState("");
  const previewCurrent = upgradePreview?.projectId === snapshot?.project.id && upgradePreview?.value.plan.sourceRevision === snapshot?.project.revision;
  const perform = (work: () => Promise<void>) => props.run(async () => { setError(""); try { await work(); } catch (cause) { setError(String(cause)); } });
  const checkpoint = restore?.result.restore;
  return <details className="workbench-package" open={!!selectedPackage || !!checkpoint || undefined}>
    <summary>Project storage and package restoration</summary>
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}
    {snapshot ? <>
      <p>Storage format {snapshot.storage?.format ?? 1} · {snapshot.imageCount ?? snapshot.images.length} acquisitions · {snapshot.storage?.historyCount ?? "unknown"} retained history entries.</p>
      <fieldset disabled={busy || writeBlocked}><legend>Storage format</legend>
        {(snapshot.storage?.format ?? 1) === 1 ? <>
          <p>Indexed format 2 stores acquisition, measurement and history records separately. Upgrading retains a host-local copy of the original store and leaves scientific pixels and masks unchanged.</p>
          <button className="cc-btn" onClick={() => void perform(async () => setUpgradePreview({ projectId: snapshot.project.id, value: await props.read<StorageUpgradePreview>("project.storage.upgrade.preview") }))}>Preview storage upgrade</button>
          {upgradePreview?.projectId === snapshot.project.id ? <><p>{upgradePreview.value.plan.imageCount} acquisitions · {upgradePreview.value.plan.measurementRows} object measurement rows · {upgradePreview.value.plan.historyCount} history entries.</p>
            {upgradePreview.value.plan.notes.map((note, i) => <p key={i}>{note}</p>)}
            {!previewCurrent ? <p>The saved project changed. Preview the upgrade again before applying it.</p> : null}
            <button className="cc-btn" disabled={!previewCurrent} onClick={() => void props.upgrade(upgradePreview.value.previewFingerprint, upgradePreview.value.plan.sourceRevision,
              value => { setUpgradeResult({ projectId: snapshot.project.id, value }); setUpgradePreview(undefined); })}>Upgrade the previewed store</button>
          </> : null}
        </> : <p>This project already uses indexed storage. Image and measurement readers page bounded rows.</p>}
        <button className="cc-btn" onClick={() => void perform(async () => {
          const value = await props.read<{ storage: Record<string, unknown>; recoveryPath?: string; migration?: StorageUpgradeResult["migration"] }>("project.storage.inspect");
          setStoredRecovery({ projectId: snapshot.project.id, path: value.recoveryPath,
            relativePath: value.migration?.recoveryRelativePath, hash: value.migration?.recoverySha256 });
        })}>Read original-store recovery location</button>
      </fieldset>
      {upgradeResult?.projectId === snapshot.project.id ? <p className="workbench-project-path">Original store retained at {upgradeResult.value.recoveryPath}<br />SHA-256: {upgradeResult.value.migration.recoverySha256}</p> : null}
      {storedRecovery?.projectId === snapshot.project.id ? <p className="workbench-project-path">{storedRecovery.path ?? storedRecovery.relativePath ?? "No format-1 recovery copy is recorded for this project."}{storedRecovery.hash ? <><br />SHA-256: {storedRecovery.hash}</> : null}</p> : null}
    </> : null}
    <div className="workbench-actions"><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.choosePackage()}>Choose analysis package…</button>
      <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.reopenRestore()}>Open a partial restore folder…</button>
      {props.rememberedRestorePath ? <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.reopenRestore(props.rememberedRestorePath)}>Read last restore checkpoint</button> : null}</div>
    {selectedPackage ? <section aria-label="Selected analysis package"><h3>{selectedPackage.package.name}</h3>
      <p>{selectedPackage.package.imageCount} acquisitions · source revision {selectedPackage.package.sourceRevision} · package format {selectedPackage.package.format ?? 1}.</p>
      <p className="workbench-project-path">{selectedPackage.package.path}<br />SHA-256: {selectedPackage.package.sha256}</p>
      <p>{selectedPackage.package.format === 2 ? `${selectedPackage.package.shardCount ?? 0} artifact shards. Snapshot metadata was checked; exact shard and artifact bytes are verified at each restore checkpoint.`
        : `${selectedPackage.integrity?.fileCount ?? selectedPackage.package.files ?? 0} package files inspected.`}</p>
      {selectedPackage.dependencies.warnings.map((warning, index) => <p key={index}>{warning}</p>)}
      <div className="workbench-actions"><button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.startRestore()}>{selectedPackage.package.format === 2 ? "Choose new folder and start restore" : "Choose new folder and restore legacy package"}</button><button className="cc-btn" disabled={busy} onClick={props.dismissPackage}>Dismiss package</button></div>
    </section> : null}
    {checkpoint && restore ? <section aria-label="Restore checkpoint"><h3>{checkpoint.name} · {checkpoint.status}</h3>
      <p className="workbench-project-path">Destination: {restore.path}<br />Source: {checkpoint.packagePath}</p>
      <p>{checkpoint.progress.completed} / {checkpoint.progress.total} checkpoints · restore revision {checkpoint.restoreRevision} · {checkpoint.imageCount} acquisitions · {checkpoint.artifactCount} artifacts.</p>
      <progress aria-label="Package restoration" value={checkpoint.progress.completed} max={checkpoint.progress.total || 1} />
      {checkpoint.nextUnit ? <p>Next: {checkpoint.nextUnit.type === "restore-shard" ? `artifact shard ${(checkpoint.nextUnit.shardIndex ?? 0) + 1}` : "final scientific metadata publication"}.</p> : null}
      {checkpoint.notes.map((note, i) => <p key={i}>{note}</p>)}
      <div className="workbench-actions">
        <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.reopenRestore(restore.path)}>Read checkpoint</button>
        {checkpoint.status === "pending" || checkpoint.status === "running" ? <>
          <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.advanceRestore(false)}>Restore next checkpoint</button>
          <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.advanceRestore(true)}>Restore remaining while app is open</button>
          <button className="cc-btn" disabled={!props.running} onClick={props.stopRestore}>Stop after current checkpoint</button>
          <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.controlRestore("cancel")}>Cancel restore and retain partial data</button>
        </> : null}
        {checkpoint.status === "cancelled" ? <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.controlRestore("resume")}>Resume retained restore</button> : null}
        {checkpoint.status === "completed" ? <button className="cc-btn" disabled={busy || writeBlocked} onClick={() => void props.openCompleted()}>Open completed project</button> : null}
      </div><p>A partial destination is not opened as a scientific project. Closing the app stops this foreground loop; read its retained checkpoint to continue later.</p>
    </section> : null}
  </details>;
}
