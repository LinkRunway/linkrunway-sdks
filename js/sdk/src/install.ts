import type { InstallMatchResult } from './api-types';
import type { Claim, Session } from './state';
import { call, type Transport } from './transport';
import type { ClaimResult, InstallMatch, InstallMatchRequest } from './types';
import { queryParam } from './url';
const MATCH_REFERRER_LIMIT = 4000;
const versionShape = /^\d{1,3}(\.\d{1,3}){0,2}$/;
const languageShape = /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/;
/** `major[.minor[.patch]]`, or nothing when the platform reports another format. */
export function osVersion(value?: string) {
  const version = (value ?? '').trim().split('.').slice(0, 3).join('.');
  return versionShape.test(version) ? version : undefined;
}
/** A plain language tag such as `en-US`; extension and private-use subtags are dropped. */
export function languageTag(value?: string) {
  const parts = (value ?? '').trim().replace(/_/g, '-').split('-');
  const end = parts.findIndex((part) => part.length < 2);
  const tag = (end < 0 ? parts : parts.slice(0, end)).join('-');
  const usable = tag.length <= 35 && languageShape.test(tag) && !/^und(-|$)/i.test(tag);
  return usable ? tag : undefined;
}
// The match contract caps the referrer; an oversized one is reduced to the token it is read for.
function matchable(referrer?: string) {
  if (!referrer || referrer.length <= MATCH_REFERRER_LIMIT) return referrer || undefined;
  const token = queryParam(referrer, 'lr_token');
  const reduced = token ? `lr_token=${encodeURIComponent(token)}` : '';
  return reduced && reduced.length <= MATCH_REFERRER_LIMIT ? reduced : undefined;
}
function installOf(session: Session) {
  if (!session.client) throw new Error('Install calls run in the app with a publishable key');
  return session.installId();
}
/** The stored first-launch answer, if this install has one. */
export function storedMatch(session: Session): InstallMatch | undefined {
  return session.consent && session.match ? { ...session.match, cached: true } : undefined;
}
/**
 * Asks the server once which earlier touch, if any, led to this install. The answer is stored, so
 * later calls make no request. Its click token is kept unless a link opened since has set one.
 */
export async function resolveInstall(
  session: Session,
  transport: Transport,
  input: InstallMatchRequest,
): Promise<InstallMatch | undefined> {
  const installId = installOf(session);
  if (!installId) return undefined;
  const stored = storedMatch(session);
  if (stored) return stored;
  const { data } = await call<InstallMatchResult>(transport, 'POST', 'installs/match', {
    installId,
    platform: input.platform,
    osVersion: osVersion(input.osVersion),
    language: languageTag(input.language),
    referrer: matchable(input.referrer),
    consent: true,
  });
  // An answer for an identity the user has since withdrawn is dropped, not stored.
  if (!session.current(installId)) return undefined;
  const { clickToken, ...outcome } = data;
  session.match = outcome;
  if (clickToken && !session.clickToken) session.clickToken = clickToken;
  session.persist();
  return { ...data, cached: false };
}
const paths: Record<Claim, string> = { referrer: 'claims/referrer', appleAds: 'claims/apple-ads' };
/**
 * Sends ad-network evidence for the server to verify, once per install. A 202 means the network has
 * not processed it yet: the request is repeated `retries` times, `delayMs` apart, then reported as
 * pending so the app can submit it again later.
 */
export async function submitClaim(
  session: Session,
  transport: Transport,
  kind: Claim,
  evidence: Record<string, string>,
  retries: number,
  delayMs: number,
): Promise<ClaimResult | undefined> {
  const installId = installOf(session);
  if (!installId) return undefined;
  if (session.claims[kind]) return { status: 'alreadySubmitted' };
  for (let attempt = 0; ; attempt++) {
    const reply = await call<Record<string, unknown>>(transport, 'POST', paths[kind], {
      installId,
      ...evidence,
      consent: true,
    });
    if (!session.current(installId)) return undefined;
    if (reply.status !== 202 && reply.data.pending !== true) {
      session.claims[kind] = true;
      session.persist();
      return { status: 'submitted', data: reply.data };
    }
    if (attempt >= retries) return { status: 'pending', data: reply.data };
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    if (!session.current(installId)) return undefined;
  }
}
