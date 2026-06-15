export class RateLimitError extends Error {
  constructor() {
    super("RATE_LIMITED");
  }
}

interface Bucket {
  count: number;
  resetAt: number;
}

export class RateLimitService {
  private buckets = new Map<string, Bucket>();

  constructor(private readonly enabled: boolean) {}

  check(key: string, limit: number, windowMs: number): void {
    if (!this.enabled) return;
    const now = Date.now();
    const existing = this.buckets.get(key);
    if (!existing || existing.resetAt <= now) {
      this.buckets.set(key, { count: 1, resetAt: now + windowMs });
      return;
    }
    existing.count += 1;
    if (existing.count > limit) {
      throw new RateLimitError();
    }
  }
}
