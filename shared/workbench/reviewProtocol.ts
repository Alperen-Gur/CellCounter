export type ReviewDecision = "accept" | "reject" | "uncertain";
export interface ReviewItem {
  id: string; code: string; unit: "image" | "cell"; status: string; reviewCount: number;
  requiredReviews: number; stale: boolean; decision?: ReviewDecision;
  ownDecision?: { decision: ReviewDecision; reason?: string; errorType?: string };
  decisions?: { reviewerId: string; decision: ReviewDecision; reason?: string; errorType?: string }[];
}
export interface ReviewSession {
  id: string; name: string; unit: "image" | "cell"; seed: number; populationSize: number;
  sampleSize: number; acceptedOnly: boolean; blinded: boolean; requiredReviews: number;
  target?: "plane" | "volume";
  reviewers: { id: string; name: string }[]; createdRevision: number;
  progress: { total: number; reviewed: number; resolved: number; accepted: number | null; rejected: number | null;
    conflicts: number | null; uncertain: number | null; stale: number; outcomesHidden?: boolean };
  items?: ReviewItem[];
}
export interface ReviewPreview {
  sessionId: string; itemId: string; code: string; dataUrl: string; overlayDataUrl: string;
  width: number; height: number; previewWidth: number; previewHeight: number;
  region: { x: number; y: number; width: number; height: number }; plane?: string; index?: number; sliceCount?: number; stale: boolean;
}
