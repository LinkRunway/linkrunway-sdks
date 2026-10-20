export const ASSOCIATED_DOMAINS = 'com.apple.developer.associated-domains';
/** The Associated Domains entry that lets iOS open a domain's links in the app. */
export const appLink = (domain: string) => `applinks:${domain}`;
/**
 * The list with an `applinks:` entry for each domain. Entries that are already there stay where
 * they are, including other services (`webcredentials:`) and other domains, and nothing is added
 * twice.
 */
export function mergeAssociatedDomains(existing: unknown, domains: string[]): string[] {
  const kept = Array.isArray(existing)
    ? existing.filter((entry): entry is string => typeof entry === 'string')
    : [];
  const present = new Set(kept.map((entry) => entry.toLowerCase()));
  return [...kept, ...domains.map(appLink).filter((entry) => !present.has(entry))];
}
/** The entitlements with the link domains in the Associated Domains entitlement. */
export function addAssociatedDomains<T extends Record<string, unknown>>(
  entitlements: T,
  domains: string[],
): T {
  const merged = mergeAssociatedDomains(entitlements[ASSOCIATED_DOMAINS], domains);
  return { ...entitlements, [ASSOCIATED_DOMAINS]: merged };
}
