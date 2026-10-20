import type {
  ClaimResult,
  ClaimRetry,
  ImpressionInput,
  ImpressionResult,
  InstallMatch,
  InstallMatchRequest,
  MobileConfig,
  ReferralCode,
  ResolveResult,
  SdkOptions,
  StoreAccount,
  TrackEvent,
  TrackingResult,
} from './types';
import { resolveInstall, storedMatch, submitClaim } from './install';
import { drain, enqueue, send, transient } from './queue';
import { type Claim, type QueuedEvent, Session, storageKey } from './state';
import { call, type Transport } from './transport';
import { parseUrl } from './url';
export * from './types';
export type * from './api-types';
export { LinkRunwayError } from './transport';
export { storageKey } from './state';
export { uuid } from './id';
export { parseUrl, type ParsedUrl } from './url';
/** Sent by wrappers in the user agent, as `LinkRunwaySDK/<version> <platform>`. */
export const SDK_VERSION = '0.1.0';
export class LinkRunway {
  private readonly session: Session;
  private readonly transport: Transport;
  private flushing?: Promise<void>;
  private matching?: Promise<InstallMatch | undefined>;
  private claiming: Partial<Record<Claim, Promise<ClaimResult | undefined>>> = {};
  private attestation?: { token: string; until: number };
  constructor(options: SdkOptions) {
    const url = parseUrl(options.endpoint);
    if (url.protocol !== 'https:' && !['localhost', '127.0.0.1'].includes(url.hostname))
      throw new Error('HTTPS is required outside localhost');
    const server = options.apiKey.startsWith('lr_sk_');
    if (typeof window !== 'undefined' && server)
      throw new Error('Server secrets must never be used in a browser');
    if (options.userAgent !== undefined && !/^[\x20-\x7e]{1,200}$/.test(options.userAgent))
      throw new Error('userAgent must be 1 to 200 printable ASCII characters');
    let storage = options.storage;
    if (!storage && typeof window !== 'undefined') {
      try {
        storage = window.localStorage;
      } catch {
        /* Storage may be disabled */
      }
    }
    const key = storageKey(options.endpoint, options.apiKey);
    this.session = new Session(storage, key, options.consent, !server, options.randomUUID);
    this.transport = {
      fetch: options.fetch ?? fetch,
      endpoint: options.endpoint,
      apiKey: options.apiKey,
      retries: Math.max(0, Math.min(5, options.retries ?? 2)),
      userAgent: options.userAgent,
    };
  }
  get consent(): boolean {
    return this.session.consent;
  }
  setConsent(value: boolean) {
    this.session.setConsent(value);
    if (!value) this.attestation = undefined;
  }
  capture(url: string) {
    if (!this.session.consent) return;
    const value = parseUrl(url).param('lr_token');
    if (value && value.length <= 1500) {
      this.session.clickToken = value;
      this.session.persist();
    }
  }
  captureReferrer(referrer: string) {
    this.capture(`https://referrer.invalid/?${referrer}`);
  }
  attributionToken(): string | undefined {
    return this.session.consent ? this.session.clickToken : undefined;
  }
  /** This install's random ID; nothing without consent or with a server key. */
  installId(): string | undefined {
    return this.session.installId();
  }
  /** The stored answer of `matchInstall`, once there is one. */
  installMatch(): InstallMatch | undefined {
    return storedMatch(this.session);
  }
  async open(
    url: string,
    platform: 'ios' | 'android' | 'web' = 'web',
  ): Promise<ResolveResult | undefined> {
    if (!this.session.consent) return;
    const { epoch } = this.session;
    const result = await this.post<ResolveResult>('resolve', { url, platform, consent: true });
    if (!this.session.since(epoch)) return;
    // An untracked open recorded no click, so it leaves the current attribution as it was.
    if (!result.untracked) {
      this.session.clickToken = result.clickToken;
      this.session.persist();
    }
    return result;
  }
  /** Resolves this install's first launch once; concurrent callers share the request. */
  matchInstall(input: InstallMatchRequest): Promise<InstallMatch | undefined> {
    this.matching ??= resolveInstall(this.session, this.transport, input).finally(() => {
      this.matching = undefined;
    });
    return this.matching;
  }
  /** Forwards the raw Play install referrer so the server can verify ad-network evidence in it. */
  submitReferrerClaim(appId: string, referrer: string) {
    if (!referrer) return Promise.resolve(undefined);
    return this.claim('referrer', { appId, referrer }, {});
  }
  /** Forwards Apple's AdServices attribution token. Apple may need a few seconds to know it. */
  submitAdServicesToken(token: string, retry: ClaimRetry = {}) {
    return this.claim('appleAds', { token }, { retries: 3, delayMs: 5000, ...retry });
  }
  /** Attaches a server-issued attestation token to events until it expires. Kept in memory only. */
  setAttestation(token: string, expiresAt: string | number | Date) {
    const until = new Date(expiresAt).getTime();
    if (!token || token.length > 2000 || !Number.isFinite(until))
      throw new Error('Invalid attestation token or expiry');
    if (this.session.consent) this.attestation = { token, until };
  }
  async createReferralCode() {
    if (!this.session.consent || !this.session.clickToken)
      throw new Error('A consented attributed click is required');
    const { epoch } = this.session;
    const result = await this.post<ReferralCode>('deferred', {
      clickToken: this.session.clickToken,
      consent: true,
    });
    return this.session.since(epoch) ? result : undefined;
  }
  async claimReferralCode(code: string, claimId: string): Promise<ResolveResult | undefined> {
    if (!this.session.consent) return;
    const { epoch } = this.session;
    const result = await this.post<ResolveResult>('deferred/claim', {
      code,
      claimId,
      consent: true,
    });
    if (!this.session.since(epoch)) return;
    this.session.clickToken = result.clickToken;
    this.session.persist();
    return result;
  }
  async track(event: TrackEvent): Promise<TrackingResult> {
    const { session } = this;
    if (!session.consent) return { skipped: true };
    const payload: QueuedEvent = {
      ...event,
      occurredAt: event.occurredAt ?? new Date().toISOString(),
      clickToken: event.clickToken ?? session.clickToken,
      installId: event.installId ?? session.installId(),
    };
    const { epoch } = session;
    try {
      return await this.deliver(payload);
    } catch (error) {
      if (!session.since(epoch)) return { skipped: true };
      if (!transient(error)) throw error;
      enqueue(session, payload);
      return { queued: true };
    }
  }
  async createShare(input: { linkId: string; externalUserId?: string; channel?: string }) {
    if (!this.session.consent)
      throw new Error('Analytics consent is required to create tracked shares');
    return this.post<{ shareId: string; url: string }>('shares', input);
  }
  flush(): Promise<void> {
    if (this.flushing) return this.flushing;
    this.flushing = drain(this.session, (event) => this.deliver(event)).finally(() => {
      this.flushing = undefined;
    });
    return this.flushing;
  }
  /** Server key only: an ad impression reported by your ad server, for view-through matching. */
  recordImpression(input: ImpressionInput) {
    return this.server<ImpressionResult>('recordImpression', 'POST', 'impressions', input);
  }
  /** Server key only: binds a store account token (StoreKit `appAccountToken`) to your user. */
  bindStoreAccount(input: StoreAccount) {
    return this.server<StoreAccount>('bindStoreAccount', 'PUT', 'customers/store-account', input);
  }
  /** The conversion rules configured for one of the workspace's mobile apps. */
  async mobileConfig(appId: string): Promise<MobileConfig | undefined> {
    if (!this.session.consent) return;
    const path = `mobile/config/${encodeURIComponent(appId)}`;
    return (await call<MobileConfig>(this.transport, 'GET', path)).data;
  }
  private async server<T>(name: string, method: 'POST' | 'PUT', path: string, body: object) {
    // These calls decide revenue identity and paid reach; a key shipped in an app cannot make them.
    if (this.session.client) throw new Error(`${name} requires a server key`);
    if (!this.session.consent) return undefined;
    return (await call<T>(this.transport, method, path, { ...body, consent: true })).data;
  }
  private claim(kind: Claim, evidence: Record<string, string>, retry: ClaimRetry) {
    const { retries = 0, delayMs = 0 } = retry;
    const running = (this.claiming[kind] ??= submitClaim(
      this.session,
      this.transport,
      kind,
      evidence,
      Math.max(0, Math.min(10, retries)),
      Math.max(0, delayMs),
    ).finally(() => {
      this.claiming[kind] = undefined;
    }));
    return running;
  }
  private deliver(event: QueuedEvent) {
    const live = this.attestation && this.attestation.until > Date.now();
    const post = (path: string, body: unknown) => this.post<TrackingResult>(path, body);
    return send(this.session, post, event, live ? this.attestation!.token : undefined);
  }
  private async post<T>(path: string, body: unknown) {
    return (await call<T>(this.transport, 'POST', path, body)).data;
  }
}
