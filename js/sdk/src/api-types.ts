// The API request and response shapes the SDK uses, written out so the published package depends
// on nothing private. tests/sdk-api-types.test.ts keeps each one identical to the API's schema.
export type EventType =
  | 'INSTALL'
  | 'OPEN'
  | 'SIGNUP'
  | 'PURCHASE'
  | 'SUBSCRIPTION'
  | 'REFUND'
  | 'CUSTOM';
/** At most 30 fields; keys up to 64 characters, strings up to 1000. */
export type EventMetadata = Record<string, string | number | boolean | null>;
export type EventInput = {
  eventId: string;
  type: EventType;
  name?: string;
  clickToken?: string;
  externalUserId?: string;
  /** Minor units (cents). Only purchases, subscriptions and refunds carry an amount. */
  amount: number;
  currency: string;
  originalEventId?: string;
  metadata: EventMetadata;
  consent: true;
  occurredAt?: string;
  installId?: string;
  attestation?: string;
};
export type InstallMatchInput = {
  installId: string;
  platform: 'ios' | 'android' | 'tvos' | 'androidtv';
  osVersion?: string;
  language?: string;
  referrer?: string;
  consent: true;
};
export type InstallMatchResult = {
  matched: boolean;
  method: 'REFERRER' | 'PROBABILISTIC' | 'VIEW_THROUGH' | 'NONE';
  clickId?: string;
  clickToken?: string;
  path?: string;
  url?: string;
  metadata?: Record<string, unknown>;
};
export type ConversionRule = {
  event: EventType;
  name?: string;
  minAmount: number;
  fineValue: number;
  coarseValue: 'low' | 'medium' | 'high';
  lockWindow: boolean;
};
