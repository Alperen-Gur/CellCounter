import { useCataloguePins } from "./WorkbenchCatalogueBrowser";
import WorkbenchImageSelector from "./WorkbenchImageSelector";
import { useState } from "react";
import type { ProjectSnapshot } from "../../../../shared/workbench/protocol";
import type { ImageCollection, LibraryActions, LibraryDuplicates, LibraryImageMetadata, SourceRepairPreview } from "../../../../shared/workbench/libraryProtocol";

type Props = { snapshot: ProjectSnapshot; imageId: string; busy: boolean; writeBlocked: boolean; actions: LibraryActions;
  read: <T>(operation: string, args?: Record<string, unknown>) => Promise<T> };
const tagsFrom = (value: string) => value.split("\n").map(tag => tag.trim()).filter(Boolean);
const cleanMetadata = (value: LibraryImageMetadata) => ({ name: value.name, notes: value.notes, tagsText: value.tags.join("\n"), channelNames: [...value.channelNames] });
type MetadataDraft = ReturnType<typeof cleanMetadata>;

export default function WorkbenchLibrary({ snapshot, imageId, busy, writeBlocked, actions, read }: Props) {
  const revision = snapshot.project.revision;
  const currentImage = snapshot.images.find(value => value.id === imageId);
  const collections = snapshot.collections ?? [];
  const [tags, setTags] = useState("");
  const [collectionFilter, setCollectionFilter] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [metadata, setMetadata] = useState<{ revision: number; image: LibraryImageMetadata }>();
  const [draft, setDraft] = useState<MetadataDraft>();
  const [collectionId, setCollectionId] = useState("");
  const [collectionName, setCollectionName] = useState("");
  const [collectionDescription, setCollectionDescription] = useState("");
  const [loadedCollection, setLoadedCollection] = useState<{ revision: number; value: ImageCollection }>();
  const [duplicates, setDuplicates] = useState<{ revision: number; value: LibraryDuplicates }>();
  const [includeArchivedDuplicates, setIncludeArchivedDuplicates] = useState(false);
  const [candidatePath, setCandidatePath] = useState("");
  const [repair, setRepair] = useState<{ revision: number; path: string; value: SourceRepairPreview }>();
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const perform = (action: () => Promise<void>) => actions.run(async () => { setError(""); try { await action(); } catch (cause) { setError(String(cause)); } });
  const dirty = !!metadata && !!draft && JSON.stringify(draft) !== JSON.stringify(cleanMetadata(metadata.image));
  const validMetadata = !!draft?.name.trim() && draft.channelNames.every(value => value.trim()) && tagsFrom(draft.tagsText).length <= 64 && new Set(tagsFrom(draft.tagsText).map(tag => tag.toLowerCase())).size === tagsFrom(draft.tagsText).length;
  const metadataCurrent = metadata?.revision === revision;
  const pinError = useCataloguePins([{ catalogue: "collections", entryId: collectionId }, { catalogue: "collections", entryId: collectionFilter }]);
  const collection = collections.find(value => value.id === collectionId);
  const collectionCurrent = loadedCollection?.value.id === collectionId && loadedCollection.revision === revision;
  const currentRepair = repair?.revision === revision && repair.path === candidatePath && repair.value.imageId === imageId ? repair.value : undefined;
  const loadMetadata = async () => {
    const value = (await read<{ image: LibraryImageMetadata }>("image.metadata.get", { imageId })).image;
    setMetadata({ revision, image: value }); setDraft(cleanMetadata(value));
  };
  const selectedKnown = selected;
  return <section className="workbench-automation"><details><summary>Image library and source repair</summary>
    <p>Names, channel labels, tags and collections organize retained acquisitions. Archiving changes visibility while preserving sources, masks, assignments and history.</p>
    {pinError ? <p className="workbench-error" role="alert">{pinError}</p> : null}
    {error ? <p className="workbench-error" role="alert">{error}</p> : null}{notice ? <p role="status">{notice}</p> : null}
    <fieldset disabled={busy}><legend>Library selection filters</legend>
      <label>Required tags (one per line; all must match)<textarea rows={2} value={tags} onChange={event => setTags(event.target.value)} /></label>
      <label>Collection<select value={collectionFilter} onChange={event => setCollectionFilter(event.target.value)}><option value="">All collections</option>{collections.map(value => <option key={value.id} value={value.id}>{value.name}{value.archived ? " · archived collection" : ""}</option>)}</select></label>
    </fieldset>
    <WorkbenchImageSelector label="Images for library actions" multiple selectedIds={selected} onChange={setSelected} disabled={busy}
      filters={{ tags: tagsFrom(tags), ...(collectionFilter ? { collectionId: collectionFilter } : {}) }}
      onOpen={writeBlocked ? undefined : id => void actions.selectImage(id)} />
    <p>{selectedKnown.length} retained images selected across pages.</p>
    <div className="workbench-actions"><button className="cc-btn" disabled={busy || !selected.length} onClick={() => setSelected([])}>Clear image selection</button>
      <button className="cc-btn" disabled={busy || writeBlocked || !selectedKnown.length} onClick={() => void actions.mutate("image.archive", { imageIds: selectedKnown, archived: true }, revision, () => setNotice("Selected images archived. Their source bytes, scientific results and assignments remain retained."))}>Archive selected images</button>
      <button className="cc-btn" disabled={busy || writeBlocked || !selectedKnown.length} onClick={() => void actions.mutate("image.archive", { imageIds: selectedKnown, archived: false }, revision, () => setNotice("Selected images restored to active library visibility."))}>Restore selected images</button></div>
    <details><summary>Selected image metadata</summary>
      <p>Current image: {currentImage?.name ?? "Choose an image"}.</p><button className="cc-btn" disabled={busy || !imageId || dirty} onClick={() => void perform(loadMetadata)}>Read selected image metadata</button>
      {dirty ? <p>Metadata draft for {metadata?.image.name} is retained. Save it or discard it before loading another image's metadata.</p> : null}
      {draft && metadata ? <><fieldset disabled={busy || writeBlocked}><legend>Editing {metadata.image.name}</legend>
        <label>Name<input value={draft.name} maxLength={200} onChange={event => setDraft({ ...draft, name: event.target.value })} /></label>
        <label>Notes<textarea rows={3} value={draft.notes} maxLength={10000} onChange={event => setDraft({ ...draft, notes: event.target.value })} /></label>
        <label>Tags (one per line, up to 64 distinct tags)<textarea rows={3} value={draft.tagsText} onChange={event => setDraft({ ...draft, tagsText: event.target.value })} /></label>
        {draft.channelNames.map((value, index) => <label key={index}>Channel {index + 1} name<input value={value} maxLength={200} onChange={event => setDraft({ ...draft, channelNames: draft.channelNames.map((name, channel) => channel === index ? event.target.value : name) })} /></label>)}
        {!metadataCurrent ? <p>The project changed after this metadata was read. Discard and reload before saving; the draft has not been overwritten.</p> : null}
        <button className="cc-btn" disabled={!dirty || !validMetadata || !metadataCurrent} onClick={() => void actions.mutate<{ image: LibraryImageMetadata }>("image.metadata.set", { imageId: metadata.image.id, name: draft.name.trim(), notes: draft.notes, tags: tagsFrom(draft.tagsText), channelNames: draft.channelNames.map(value => value.trim()) }, metadata.revision, result => { setMetadata({ revision: metadata.revision + 1, image: result.image }); setDraft(cleanMetadata(result.image)); setNotice("Image metadata saved. Indexed source channels and scientific pixels are unchanged."); })}>Save image metadata</button>
      </fieldset><button className="cc-btn" disabled={busy} onClick={() => { setDraft(undefined); setMetadata(undefined); }}>Discard metadata editor</button></> : null}
    </details>
    <details><summary>Collections</summary><fieldset disabled={busy || writeBlocked}><legend>Collection definition</legend>
      <label>Saved collection<select value={collectionId} onChange={event => setCollectionId(event.target.value)}><option value="">New collection</option>{collections.map(value => <option key={value.id} value={value.id}>{value.name}{value.archived ? " · archived" : ""}</option>)}</select></label>
      <button className="cc-btn" disabled={!collection} onClick={() => { if (collection) { setLoadedCollection({ revision, value: collection }); setCollectionName(collection.name); setCollectionDescription(collection.description); setSelected([...collection.imageIds]); } }}>Load name and member selection</button>
      <p>Loading explicitly replaces the collection draft and selected-image set. Membership does not define biological replicates.</p>
      <label>Collection name<input value={collectionName} maxLength={200} onChange={event => setCollectionName(event.target.value)} /></label><label>Description<textarea rows={2} value={collectionDescription} maxLength={2000} onChange={event => setCollectionDescription(event.target.value)} /></label>
      <p>Saving includes the {selectedKnown.length} selected images, including selections on other search pages.</p>
      <button className="cc-btn" disabled={!collectionName.trim()} onClick={() => void actions.mutate<{ collection: ImageCollection }>("collection.save", { name: collectionName.trim(), description: collectionDescription, imageIds: selectedKnown }, revision, result => { setCollectionId(result.collection.id); setLoadedCollection({ revision: revision + 1, value: result.collection }); })}>Save as new collection</button>
      <button className="cc-btn" disabled={!collectionName.trim() || !collectionCurrent} onClick={() => void actions.mutate<{ collection: ImageCollection }>("collection.save", { collectionId, name: collectionName.trim(), description: collectionDescription, imageIds: selectedKnown }, loadedCollection!.revision, result => setLoadedCollection({ revision: loadedCollection!.revision + 1, value: result.collection }))}>Update loaded collection</button>
      {collection ? <button className="cc-btn" onClick={() => void actions.mutate("collection.archive", { collectionId, archived: !collection.archived }, revision)}>{collection.archived ? "Restore collection" : "Archive collection"}</button> : null}
    </fieldset></details>
    <details><summary>Exact source duplicates</summary><label><input type="checkbox" disabled={busy} checked={includeArchivedDuplicates} onChange={event => setIncludeArchivedDuplicates(event.target.checked)} /> Include archived images</label>
      <button className="cc-btn" disabled={busy} onClick={() => void perform(async () => setDuplicates({ revision, value: await read<LibraryDuplicates>("library.duplicates", { includeArchived: includeArchivedDuplicates }) }))}>Find exact source-byte groups</button>
      {duplicates ? <><p>Read at revision {duplicates.revision}{duplicates.revision === revision ? "" : " · library has since changed"}. Identical file bytes do not establish the same acquisition or biological specimen.</p>{duplicates.value.groups.slice(0, 100).map(value => <div key={value.sourceHash}><p>{value.names.join("; ")} · {(value.bytes / 1048576).toFixed(2)} MiB per retained source</p><button className="cc-btn" disabled={busy} onClick={() => setSelected([...value.imageIds])}>Select this group without merging</button></div>)}{duplicates.value.groups.length > 100 ? <p>First 100 groups shown. Refine the source library before bulk actions.</p> : null}{duplicates.value.notes.map((note, index) => <p key={index}>{note}</p>)}</> : null}
    </details>
    <details><summary>Repair a missing or corrupt source</summary>
      <p>Repair {currentImage?.name ?? "the selected image"} only from the exact original file bytes. Different pixels must be imported as a new acquisition.</p>
      <button className="cc-btn" disabled={busy || !imageId || writeBlocked} onClick={() => void actions.chooseSource(path => { setCandidatePath(path); setRepair(undefined); })}>Choose original source file…</button>
      {candidatePath ? <p className="workbench-project-path">{candidatePath}</p> : null}
      <button className="cc-btn" disabled={busy || !imageId || !candidatePath} onClick={() => void perform(async () => setRepair({ revision, path: candidatePath, value: (await read<{ preview: SourceRepairPreview }>("image.relink.preview", { imageId, path: candidatePath })).preview }))}>Compare source identity</button>
      {repair && !currentRepair ? <p>The image, candidate or project changed. Compare source identity again before repair.</p> : null}
      {currentRepair ? <><p>Retained artifact: {currentRepair.currentArtifactStatus} · candidate {currentRepair.identityMatches ? "matches the exact saved SHA-256" : "does not match; repair is blocked"}.</p><details><summary>Source hashes and evidence</summary><p className="workbench-project-path">Saved: {currentRepair.sourceHash}<br />Candidate: {currentRepair.candidateHash}{currentRepair.displacedHash ? <><br />Displaced: {currentRepair.displacedHash}</> : null}</p>{currentRepair.notes.map((note, index) => <p key={index}>{note}</p>)}</details>
        <button className="cc-btn" disabled={busy || writeBlocked || !currentRepair.identityMatches} onClick={() => void actions.mutate("image.relink.run", { imageId, path: candidatePath, previewFingerprint: currentRepair.previewFingerprint }, revision, () => { setRepair(undefined); setNotice("Exact source identity retained; missing bytes restored when needed, with displaced corrupt evidence preserved."); })}>{currentRepair.currentArtifactStatus === "intact" ? "Record matching source location" : "Repair exact source bytes"}</button></> : null}
    </details>
  </details></section>;
}
