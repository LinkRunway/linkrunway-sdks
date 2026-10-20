import type { InstallMatchResult } from './api-types';
import { isUuid, uuid } from './id';
import type { StorageAdapter, TrackEvent } from './types';
import { parseUrl } from './url';
export type QueuedEvent = TrackEvent & { occurredAt: string };
/** The stored answer of a first-launch match. The click token is kept apart, as `clickToken`. */
export type StoredMatch = Omit<InstallMatchResult, 'clickToken'>;
export type Claim = 'referrer' | 'appleAds';
/** The storage entry one client uses: one per API origin and key. */
export const storageKey = (endpoint: string, apiKey: string) =>
  `linkrunway:${parseUrl(endpoint).origin}:${apiKey.slice(0, 20)}`;
const isMatch = (value: unknown): value is StoredMatch =>
  !!value && typeof (value as StoredMatch).matched === 'boolean';
/**
 * Everything the client remembers. Nothing is read, created or written while consent is off, and
 * withdrawing consent erases it from memory and from storage.
 */
export class Session {
  consent: boolean;
  clickToken?: string;
  queue: QueuedEvent[] = [];
  match?: StoredMatch;
  claims: Partial<Record<Claim, true>> = {};
  /** Advances on every withdrawal, so an answer asked for under an earlier consent is dropped. */
  epoch = 0;
  private install?: string;
  constructor(
    private readonly storage: StorageAdapter | undefined,
    private readonly key: string,
    consent: boolean,
    /** False for a server key: a backend is not an install and never gets an install ID. */
    readonly client: boolean,
    private readonly randomUUID?: () => string,
  ) {
    this.consent = consent;
    if (consent) this.load();
  }
  setConsent(value: boolean) {
    const granted = value && !this.consent;
    this.consent = value;
    // State saved under an earlier grant (a previous session) becomes usable again.
    if (granted) this.load();
    if (value) return;
    this.epoch += 1;
    this.clickToken = undefined;
    this.queue = [];
    this.install = undefined;
    this.match = undefined;
    this.claims = {};
    try {
      this.storage?.removeItem(this.key);
    } catch {
      /* Optional storage */
    }
  }
  /** This install's random ID, created and saved on first use. Not a device or advertising ID. */
  installId(): string | undefined {
    if (!this.consent || !this.client) return undefined;
    if (!this.install) {
      const supplied = this.randomUUID?.();
      const candidate = typeof supplied === 'string' ? supplied.toLowerCase() : undefined;
      this.install = isUuid(candidate) ? candidate : uuid();
      this.persist();
    }
    return this.install;
  }
  /** True while consent is on and `installId` is still this install's ID. */
  current(installId: string) {
    return this.consent && this.install === installId;
  }
  /** True while consent has stayed on since `epoch` was read. */
  since(epoch: number) {
    return this.consent && this.epoch === epoch;
  }
  persist() {
    if (!this.consent) return;
    try {
      this.storage?.setItem(
        this.key,
        JSON.stringify({
          clickToken: this.clickToken,
          queue: this.queue,
          installId: this.install,
          match: this.match,
          claims: Object.keys(this.claims).length ? this.claims : undefined,
        }),
      );
    } catch {
      /* Memory-only mode remains usable */
    }
  }
  private load() {
    let saved: Record<string, unknown> = {};
    try {
      const parsed: unknown = JSON.parse(this.storage?.getItem(this.key) ?? '{}');
      if (parsed && typeof parsed === 'object') saved = parsed as Record<string, unknown>;
    } catch {
      /* Invalid storage is discarded */
    }
    this.clickToken = typeof saved.clickToken === 'string' ? saved.clickToken : undefined;
    this.queue = Array.isArray(saved.queue) ? saved.queue.slice(-100) : [];
    this.install = isUuid(saved.installId) ? saved.installId : undefined;
    this.match = isMatch(saved.match) ? saved.match : undefined;
    const claims = (saved.claims ?? {}) as Record<string, unknown>;
    this.claims = {};
    for (const claim of ['referrer', 'appleAds'] as const)
      if (claims[claim] === true) this.claims[claim] = true;
  }
}
