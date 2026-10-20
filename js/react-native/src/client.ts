import { LinkRunway, SDK_VERSION, storageKey, uuid, type TrackEvent } from '@linkrunway/sdk';
import { installTasks } from './launch';
import { classify, duplicateFilter, linkHosts } from './links';
import { createStorageBridge } from './storage';
import type { LinkRunwayClient, ReactNativeOptions, RunwayLink, Stage } from './types';
/** How the API recognizes this layer. It also keeps app traffic from being counted as a bot. */
export const USER_AGENT = `LinkRunwaySDK/${SDK_VERSION} ReactNative`;
const PLATFORMS = ['ios', 'android', 'tvos', 'androidtv'];
/**
 * Connects the core SDK to a React Native app: persistent storage, incoming links, the offline
 * queue and the first-launch match. The platform pieces are passed in, so this package never
 * imports `react-native`.
 */
export function createLinkRunway(options: ReactNativeOptions): LinkRunwayClient {
  if (!options.apiKey.startsWith('lr_pk_')) throw new Error('Use a publishable key in mobile apps');
  if (!PLATFORMS.includes(options.platform))
    throw new Error('platform must be ios, android, tvos or androidtv');
  const report = (stage: Stage) => (error: unknown) => {
    try {
      options.onError?.(error, stage);
    } catch {
      /* A reporting hook must not break the client */
    }
  };
  const newId = () => {
    const id = options.randomUUID?.();
    return typeof id === 'string' && id ? id : uuid();
  };
  const bridge = createStorageBridge(options.storage, report('storage'));
  // The core starts without consent, so it reads nothing until the saved state is in memory.
  const core = new LinkRunway({
    endpoint: options.endpoint,
    apiKey: options.apiKey,
    consent: false,
    storage: bridge.adapter,
    fetch: options.fetch,
    retries: options.retries,
    randomUUID: options.randomUUID,
    userAgent: USER_AGENT,
  });
  const hosts = linkHosts(options.endpoint, options.domains);
  const resolveAs = options.platform.startsWith('android') ? 'android' : 'ios';
  const repeated = duplicateFilter();
  const listeners = new Set<(link: RunwayLink) => void>();
  let wanted = options.consent;
  let refused = false;
  let declined = false;
  let hydrated = false;
  let closed = false;
  let waiting: { url: string; source: 'initial' | 'open' } | undefined;
  let last: RunwayLink | undefined;
  const emit = (link: RunwayLink) => {
    if (closed) return;
    last = link;
    for (const listener of [...listeners]) {
      try {
        listener(link);
      } catch (error) {
        report('listener')(error);
      }
    }
  };
  // A deferred link restores a handoff the install interrupted. Once a link has been opened in
  // this session there is nothing to restore, so the match is stored without being announced.
  const install = installTasks(core, options, (link) => void (last ?? emit(link)), report);
  const ready = bridge.hydrate(storageKey(options.endpoint, options.apiKey)).then(() => {
    hydrated = true;
    // Choices made while loading are applied in order: an explicit refusal erases what was saved
    // even if consent was granted again afterwards. Starting without consent erases nothing.
    if (refused) core.setConsent(false);
    if (wanted) core.setConsent(true);
    return core;
  });
  async function incoming(url: string, source: 'initial' | 'open') {
    const kind = classify(url, hosts);
    if (!kind) return undefined;
    await ready;
    if (closed) return undefined;
    if (!core.consent) {
      // Nothing is resolved or stored without consent. Until the user has answered, the newest
      // link waits in memory for a yes; after a no it is dropped.
      if (!declined) waiting = { url, source };
      return undefined;
    }
    if (kind === 'token') {
      core.capture(url);
      return undefined;
    }
    const result = await core.open(url, resolveAs);
    if (!result) return undefined;
    const link: RunwayLink = {
      source,
      url,
      path: result.path,
      destination: result.url,
      metadata: result.metadata ?? {},
      clickId: result.clickId || undefined,
    };
    emit(link);
    return link;
  }
  /** Everything that waits for consent: the pending link, queued events, the match, attestation. */
  async function resume() {
    if (closed || !core.consent) return;
    const link = waiting;
    waiting = undefined;
    if (link) await incoming(link.url, link.source).catch(report('link'));
    await Promise.all([core.flush().catch(report('flush')), install.match(), install.attest()]);
  }
  const initial = Promise.resolve()
    .then(() => options.linking.getInitialURL())
    .then((url) => (url && !repeated(url) ? url : null))
    .catch((error: unknown) => {
      report('link')(error);
      return null;
    });
  // The launch URL is handled before the first-launch match, so the newer touch keeps its token.
  const started = ready.then(async () => {
    const url = await initial;
    if (url) await incoming(url, 'initial').catch(report('link'));
    await resume();
  });
  const later = () => void started.then(resume).catch(report('flush'));
  const subscriptions = [
    options.linking.addEventListener('url', (event) => {
      const url = event?.url;
      if (typeof url === 'string' && !repeated(url))
        void incoming(url, 'open').catch(report('link'));
    }),
    options.appState.addEventListener('change', (state) => {
      if (state === 'active') later();
    }),
  ];
  return {
    ready,
    setConsent(value) {
      wanted = value;
      declined = !value;
      if (!value) {
        refused = true;
        waiting = undefined;
        install.forget();
      }
      if (!hydrated) return;
      core.setConsent(value);
      if (value) later();
    },
    async track(input) {
      // The ID and time belong to the moment of the call, not to when storage finished loading.
      const event: TrackEvent = {
        ...input,
        eventId: input.eventId ?? newId(),
        occurredAt: input.occurredAt ?? new Date().toISOString(),
      };
      return (await ready).track(event);
    },
    async install() {
      // An INSTALL sent before the match would be stored without the matched click, and its fixed
      // ID makes every later copy a duplicate of that first one. So it waits for the match.
      await started;
      await resume();
      const installId = core.installId();
      if (!installId) return { skipped: true };
      if (!core.installMatch())
        throw new Error('This install’s first launch is not resolved yet. Call install() later.');
      return core.track({ eventId: `install-${installId}`, type: 'INSTALL' });
    },
    createShare: async (input) => (await ready).createShare(input),
    open: (url) => incoming(url, 'open'),
    flush: async () => (await ready).flush(),
    attributionToken: async () => (await ready).attributionToken(),
    installId: async () => (await ready).installId(),
    subscribe(listener) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    lastLink: () => last,
    destroy() {
      closed = true;
      listeners.clear();
      for (const subscription of subscriptions) subscription.remove();
    },
  };
}
