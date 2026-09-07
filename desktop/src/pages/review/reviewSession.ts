import type { CellDTO, ImageDTO } from "../../kernel/types";

export interface ReviewCursor { confidence: number; detectionId: string; cellId: string }
export interface ReviewItem {
  key: string;
  cell: CellDTO;
  image: ImageDTO;
  detectionId: string;
  pxPerUm: number;
  batchName: string;
  neighbors?: CellDTO[];
  contextLimited?: boolean;
}
export interface ReviewPage { items: ReviewItem[]; nextCursor: ReviewCursor | null; totalPending: number }
export interface ReviewContext { cell: CellDTO; neighbors: CellDTO[]; limited: boolean }
export type ReviewAction = "keep" | "reject" | "resize";
export interface ReviewDecisionOutcome { undoToken: string | null; undoUnavailableReason?: string | null }
export interface ReviewApi {
  page(after: ReviewCursor | null): Promise<ReviewPage>;
  decide(item: ReviewItem, action: ReviewAction, diameterUm?: number): Promise<ReviewDecisionOutcome>;
  undo(token: string): Promise<void>;
}
export interface ReviewState {
  items: ReviewItem[];
  index: number;
  visited: number;
  skipped: number;
  totalPending: number;
  loading: boolean;
  saving: boolean;
  error: string | null;
  undo: { token: string; item: ReviewItem } | null;
  restored: ReviewItem | null;
  notice: string | null;
  pageError: boolean;
}

/** One compact page in memory. Skip advances without recording a correction,
 * so skipped cells return next visit. Failed writes retain the current card;
 * failed page reads retain their cursor for an exact retry. */
export class ReviewSession {
  private api: ReviewApi;
  private listeners = new Set<() => void>();
  private generation = 0;
  private nextCursor: ReviewCursor | null = null;
  private failedPage: ReviewCursor | null | undefined;
  private state: ReviewState = {
    items: [], index: 0, visited: 0, skipped: 0, totalPending: 0,
    loading: true, saving: false, error: null, undo: null, restored: null, notice: null, pageError: false,
  };

  constructor(api: ReviewApi) { this.api = api; }
  getSnapshot = (): ReviewState => this.state;
  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  private update(patch: Partial<ReviewState>) {
    this.state = { ...this.state, ...patch };
    this.listeners.forEach((listener) => listener());
  }
  dispose() { this.generation++; }
  async start() {
    this.update({ visited: 0, skipped: 0, restored: null });
    await this.loadPage(null);
  }
  private async loadPage(after: ReviewCursor | null) {
    const generation = ++this.generation;
    this.failedPage = after;
    this.update({ items: [], index: 0, loading: true, error: null, pageError: false });
    try {
      const page = await this.api.page(after);
      if (generation !== this.generation) return;
      this.nextCursor = page.nextCursor;
      this.failedPage = undefined;
      this.update({ items: page.items, totalPending: page.totalPending, loading: false });
    } catch (error) {
      if (generation === this.generation) this.update({ loading: false, error: String(error), pageError: true });
    }
  }
  retryPage = async () => {
    if (!this.state.loading && this.failedPage !== undefined) await this.loadPage(this.failedPage);
  };
  private async advance(skipped: boolean) {
    if (this.state.restored) {
      this.update({ restored: null, visited: this.state.visited + 1, skipped: this.state.skipped + (skipped ? 1 : 0) });
      if (this.state.index >= this.state.items.length && this.failedPage !== undefined) await this.loadPage(this.failedPage);
      return;
    }
    const index = this.state.index + 1;
    this.update({ index, visited: this.state.visited + 1, skipped: this.state.skipped + (skipped ? 1 : 0) });
    if (index >= this.state.items.length) {
      if (this.nextCursor) await this.loadPage(this.nextCursor);
      else this.update({ items: [], index: 0 });
    }
  }
  skip = async () => {
    if (this.state.loading || this.state.saving || !(this.state.restored ?? this.state.items[this.state.index])) return;
    this.update({ error: null });
    await this.advance(true);
  };
  decide = async (action: ReviewAction, diameterUm?: number): Promise<boolean> => {
    const item = this.state.restored ?? this.state.items[this.state.index];
    if (!item || this.state.loading || this.state.saving) return false;
    const generation = this.generation;
    this.update({ saving: true, error: null });
    try {
      const outcome = await this.api.decide(item, action, diameterUm);
      if (generation === this.generation) this.update({
        undo: outcome.undoToken ? { token: outcome.undoToken, item } : null,
        notice: outcome.undoUnavailableReason ?? null,
      });
    } catch (error) {
      if (generation === this.generation) this.update({ saving: false, error: String(error) });
      return false;
    }
    if (generation !== this.generation) return true;
    this.update({ totalPending: Math.max(0, this.state.totalPending - 1) });
    await this.advance(false);
    this.update({ saving: false });
    return true;
  };
  undo = async (): Promise<boolean> => {
    const previous = this.state.undo;
    if (!previous || this.state.loading || this.state.saving) return false;
    const generation = this.generation;
    this.update({ saving: true, error: null, notice: null });
    try {
      await this.api.undo(previous.token);
      if (generation === this.generation) this.update({
        undo: null, restored: previous.item, saving: false, pageError: false,
        visited: Math.max(0,this.state.visited-1), totalPending: this.state.totalPending+1,
      });
      return true;
    } catch (error) {
      if (generation === this.generation) this.update({ saving: false, error: String(error) });
      return false;
    }
  };
}
