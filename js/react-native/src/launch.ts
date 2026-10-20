import type { LinkRunway } from '@linkrunway/sdk';
import { withTimeout } from './links';
import type { ReactNativeOptions, RunwayLink, Stage } from './types';
const REFERRER_TIMEOUT_MS = 10000;
const ATTESTATION_TIMEOUT_MS = 30000;
const ATTESTATION_RETRY_MS = 15 * 60000;
const EXPIRY_MARGIN_MS = 60000;
type Report = (stage: Stage) => (error: unknown) => void;
/**
 * The work that belongs to an install rather than to a link: resolving its first launch once, and
 * keeping a device attestation fresh. Both use values the app supplies; nothing native is read here.
 */
export function installTasks(
  core: LinkRunway,
  options: ReactNativeOptions,
  emit: (link: RunwayLink) => void,
  report: Report,
) {
  let matching: Promise<void> | undefined;
  let attesting: Promise<void> | undefined;
  let attestAfter = 0;
  return {
    /** Asks the server which earlier touch led to this install. Later launches find the answer stored. */
    match() {
      matching ??= (async () => {
        // Consent can be withdrawn while a link resolves first; the referrer is read only with it.
        if (!core.consent || core.installMatch()) return;
        const read = options.getInstallReferrer;
        // A failed read stops here: asking without the referrer would store the wrong answer for good.
        const referrer = read
          ? await withTimeout(read(), REFERRER_TIMEOUT_MS, 'Install referrer')
          : undefined;
        if (!core.consent) return;
        const match = await core.matchInstall({
          platform: options.platform,
          osVersion: options.osVersion,
          language: options.language,
          referrer: referrer || undefined,
        });
        if (!match?.matched || match.cached) return;
        emit({
          source: 'install',
          path: match.path,
          destination: match.url,
          metadata: match.metadata ?? {},
          clickId: match.clickId,
          method: match.method,
        });
      })()
        .catch(report('install'))
        .finally(() => {
          matching = undefined;
        });
      return matching;
    },
    /** Runs the app's attestation exchange when there is no token, or the current one is expiring. */
    attest() {
      const provider = options.getAttestation;
      if (!provider || Date.now() < attestAfter) return Promise.resolve();
      attesting ??= (async () => {
        // A refused or failed attempt is not repeated on every foreground: providers have quotas.
        attestAfter = Date.now() + ATTESTATION_RETRY_MS;
        const installId = core.installId();
        if (!installId) return;
        const work = provider({ installId });
        const result = await withTimeout(work, ATTESTATION_TIMEOUT_MS, 'Attestation');
        if (!result?.attestation || !core.consent || core.installId() !== installId) return;
        core.setAttestation(result.attestation, result.expiresAt);
        const until = new Date(result.expiresAt).getTime();
        attestAfter = Math.max(Date.now(), until - EXPIRY_MARGIN_MS);
      })()
        .catch(report('attestation'))
        .finally(() => {
          attesting = undefined;
        });
      return attesting;
    },
    /** Consent was withdrawn: the next grant is a new install and attests again. */
    forget() {
      attestAfter = 0;
    },
  };
}
