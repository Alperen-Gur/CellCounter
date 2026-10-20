/** Local proof of unchanged display science across known committed revisions. */
export interface DisplayRevisionTransition {
  fromRevision: number;
  toRevision: number;
  startedAt: number;
  operation: "display.preset.save" | "display.preset.archive" | "display.preset.import.run" | "display.preset.export" | "project.observe";
  projectId: string;
  imageId: string;
  sourceHash: string;
}

export function carriesCompletedDisplay(transition: DisplayRevisionTransition | undefined,
  image: { id: string; sourceHash: string }, revision: number, previous: number | undefined,
  completedAt: number | undefined): boolean {
  return carriesDisplayRevision(transition, image, revision, previous) && completedAt !== undefined &&
    Number.isFinite(completedAt) && completedAt <= transition!.startedAt;
}

export function carriesDisplayRevision(transition: DisplayRevisionTransition | undefined,
  image: { id: string; sourceHash: string }, revision: number, previous: number | undefined): boolean {
  return !!transition && transition.toRevision === revision && transition.fromRevision === previous &&
    (transition.operation === "project.observe" ? transition.toRevision > transition.fromRevision : transition.toRevision === transition.fromRevision + 1) && transition.imageId === image.id &&
    transition.sourceHash === image.sourceHash;
}
