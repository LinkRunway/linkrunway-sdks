import type {
  ConversionRule,
  EventInput,
  InstallMatchInput,
  InstallMatchResult,
} from './api-types';
export type TrackEvent = Omit<
  EventInput,
  'consent' | 'metadata' | 'amount' | 'currency' | 'eventId'
> & {
  eventId: string;
  metadata?: EventInput['metadata'];
  amount?: number;
  currency?: string;
};
export type StorageAdapter = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};
export type SdkOptions = {
  endpoint: string;
  apiKey: string;
  consent: boolean;
  storage?: StorageAdapter;
  fetch?: typeof fetch;
  retries?: number;
  /** Sent as the User-Agent header where the runtime allows it; never from a browser. */
  userAgent?: string;
  /** Source of the install ID. Defaults to the runtime's `crypto`; see `uuid` for the fallback. */
  randomUUID?: () => string;
};
export type TrackingResult = {
  id?: string;
  attributed?: boolean;
  duplicate?: boolean;
  skipped?: boolean;
  queued?: boolean;
};
export type ResolveResult = {
  clickId: string;
  clickToken?: string;
  path: string;
  url: string;
  metadata: Record<string, unknown>;
  /** The workspace is over its click allowance: the link still routes, the open is not recorded. */
  untracked?: boolean;
};

export type ReferralCode = { code: string; expiresAt: string };
export type InstallMatchRequest = Omit<InstallMatchInput, 'installId' | 'consent'>;
/** `cached` is true when the answer was stored by an earlier call and no request was made. */
export type InstallMatch = InstallMatchResult & { cached: boolean };
export type ClaimResult = {
  /** `pending`: the network has not processed the evidence yet; submit it again later. */
  status: 'submitted' | 'alreadySubmitted' | 'pending';
  data?: Record<string, unknown>;
};
export type ClaimRetry = { retries?: number; delayMs?: number };
export type Attestation = { attestation: string; expiresAt: string | number | Date };
export type ImpressionInput = {
  linkId: string;
  platform?: 'CTV' | 'MOBILE' | 'WEB';
  device?: string;
  /** The viewer's address as your ad server saw it. The API hashes it and never stores it. */
  ip?: string;
};
export type ImpressionResult = { id: string; createdAt: string };
export type StoreAccount = { externalUserId: string; storeAccountToken: string };
export type MobileConfig = { id: string; conversionRules: ConversionRule[] };
