import type {
  Attestation,
  InstallMatch,
  LinkRunway,
  TrackEvent,
  TrackingResult,
} from '@linkrunway/sdk';
export type Subscription = { remove(): void };
/** The part of React Native's `Linking` (or `expo-linking`) this layer uses. */
export type LinkingLike = {
  getInitialURL(): Promise<string | null>;
  addEventListener(type: 'url', handler: (event: { url: string }) => void): Subscription;
};
/** The part of React Native's `AppState` this layer uses. */
export type AppStateLike = {
  addEventListener(type: 'change', handler: (state: string) => void): Subscription;
};
/** AsyncStorage, or any key-value store wrapped to this shape (MMKV, SecureStore). */
export type AsyncStorageLike = {
  getItem(key: string): Promise<string | null | undefined> | string | null | undefined;
  setItem(key: string, value: string): Promise<unknown> | unknown;
  removeItem(key: string): Promise<unknown> | unknown;
};
export type Stage = 'storage' | 'link' | 'flush' | 'install' | 'attestation' | 'listener';
export type ReactNativeOptions = {
  /** Your link domain, for example `https://go.example.com`. */
  endpoint: string;
  /** A publishable key (`lr_pk_`). Server keys are refused. */
  apiKey: string;
  consent: boolean;
  /** Pass `Platform.OS`, or `tvos` / `androidtv` when `Platform.isTV` is set. */
  platform: 'ios' | 'android' | 'tvos' | 'androidtv';
  linking: LinkingLike;
  appState: AppStateLike;
  storage: AsyncStorageLike;
  /** Hosts whose `/l/<key>` URLs are LinkRunway links. Defaults to the endpoint's host. */
  domains?: string[];
  /** The OS release, such as `17.5` or `14`. Not the Android API level. */
  osVersion?: string;
  /** The user's first language tag, such as `en-US`. */
  language?: string;
  /**
   * Reads the Play install referrer. Resolve `null` when there is none (iOS, sideloaded builds);
   * reject only when the read failed and should be tried again on the next foreground.
   */
  getInstallReferrer?: () => Promise<string | null | undefined> | string | null | undefined;
  /** Runs your App Attest or Play Integrity exchange and returns the server's answer. */
  getAttestation?: (context: { installId: string }) => Promise<Attestation | null | undefined>;
  /** Source of install and event IDs, for example `randomUUID` from `expo-crypto`. */
  randomUUID?: () => string;
  fetch?: typeof fetch;
  retries?: number;
  /** Receives failures of work this layer starts on its own. Without it they are dropped. */
  onError?: (error: unknown, stage: Stage) => void;
};
export type RunwayLink = {
  /** `initial`: the URL that launched the app. `open`: one received later. `install`: the first-launch match. */
  source: 'initial' | 'open' | 'install';
  /** The URL the app was opened with; absent for an install match. */
  url?: string;
  /** The link's in-app path as configured in LinkRunway. Route it through your own allowlist. */
  path?: string;
  /** The link's web destination. */
  destination?: string;
  metadata: Record<string, unknown>;
  /** Absent when the open was not recorded (the workspace is over its click allowance). */
  clickId?: string;
  method?: InstallMatch['method'];
};
export type TrackInput = Omit<TrackEvent, 'eventId'> & { eventId?: string };
export type LinkRunwayClient = {
  /** Resolves with the core SDK once saved state is loaded. Never rejects. */
  ready: Promise<LinkRunway>;
  setConsent(value: boolean): void;
  track(event: TrackInput): Promise<TrackingResult>;
  /**
   * Reports INSTALL after the first-launch match, with an ID derived from the install ID, so a
   * call on every launch records one event. Rejects while the match has not completed.
   */
  install(): Promise<TrackingResult>;
  createShare(input: {
    linkId: string;
    externalUserId?: string;
    channel?: string;
  }): Promise<{ shareId: string; url: string }>;
  /** Handles a URL that reached the app outside `Linking`, such as a push payload. */
  open(url: string): Promise<RunwayLink | undefined>;
  flush(): Promise<void>;
  attributionToken(): Promise<string | undefined>;
  installId(): Promise<string | undefined>;
  /** Calls `listener` for each resolved link and install match. Returns the unsubscribe function. */
  subscribe(listener: (link: RunwayLink) => void): () => void;
  /** The most recent link, for a component that subscribes after it arrived. */
  lastLink(): RunwayLink | undefined;
  /** Removes the `Linking` and `AppState` listeners. */
  destroy(): void;
};
