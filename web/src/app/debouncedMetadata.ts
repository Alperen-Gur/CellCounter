/** Coalesces writes per record without allowing one record to replace another. */
export class DebouncedByIdWriter<T extends { readonly id: string }> {
  private readonly pending = new Map<string, T>();
  private readonly timers = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(
    private readonly delayMs: number,
    private readonly persist: (value: T) => void | Promise<void>,
  ) {}

  queue(value: T): void {
    this.pending.set(value.id, value);
    const prior = this.timers.get(value.id);
    if (prior !== undefined) clearTimeout(prior);
    this.timers.set(value.id, setTimeout(() => this.flush(value.id), this.delayMs));
  }

  flush(id: string): void {
    const timer = this.timers.get(id);
    if (timer !== undefined) clearTimeout(timer);
    this.timers.delete(id);
    const value = this.pending.get(id);
    this.pending.delete(id);
    if (value) void this.persist(value);
  }

  flushAll(): void {
    for (const id of [...this.pending.keys()]) this.flush(id);
  }
}
