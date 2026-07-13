// Tiny in-process read-through cache with per-key TTL. Used for the LIVE dynamic-fee read
// (MASTER_SPEC §8: "Live dynamic fee is read-through cached with TTL ≤ block time (~100ms →
// use ~1s practical)"). Deliberately dependency-free and single-flight so that a burst of API
// requests collapses to ONE on-chain read per key per TTL window.

export class TtlCache<V> {
  private readonly ttlMs: number;
  private readonly store = new Map<string, { value: V; expiresAt: number }>();
  private readonly inflight = new Map<string, Promise<V>>();

  constructor(ttlMs: number) {
    this.ttlMs = ttlMs;
  }

  /**
   * Return the cached value if fresh; otherwise call `loader` once (single-flight) and cache it.
   * Concurrent callers for the same key share the same in-flight promise.
   */
  async get(key: string, loader: () => Promise<V>): Promise<V> {
    const now = Date.now();
    const hit = this.store.get(key);
    if (hit && hit.expiresAt > now) return hit.value;

    const existing = this.inflight.get(key);
    if (existing) return existing;

    const p = (async () => {
      try {
        const value = await loader();
        this.store.set(key, { value, expiresAt: Date.now() + this.ttlMs });
        return value;
      } finally {
        this.inflight.delete(key);
      }
    })();
    this.inflight.set(key, p);
    return p;
  }

  /** Best-effort fetch that never throws: returns `fallback` if the loader rejects. */
  async getOr(key: string, loader: () => Promise<V>, fallback: V): Promise<V> {
    try {
      return await this.get(key, loader);
    } catch {
      return fallback;
    }
  }
}
