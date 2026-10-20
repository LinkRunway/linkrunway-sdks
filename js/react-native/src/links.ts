import { parseUrl } from '@linkrunway/sdk';
// The same shape the API's resolve endpoint accepts.
const linkPath = /^\/l\/[A-Za-z0-9_-]+$/;
/** `token`: the URL carries a signed click token. `link`: it is a LinkRunway link to resolve. */
export type Incoming = 'token' | 'link' | undefined;
/** Decides what an incoming URL means to LinkRunway. Any other URL is left to the app. */
export function classify(url: string, hosts: ReadonlySet<string>): Incoming {
  try {
    const parsed = parseUrl(url);
    if (parsed.param('lr_token')) return 'token';
    const web = parsed.protocol === 'https:' || parsed.protocol === 'http:';
    return web && hosts.has(parsed.hostname) && linkPath.test(parsed.pathname) ? 'link' : undefined;
  } catch {
    return undefined;
  }
}
/** The same decision for app code that routes URLs itself, such as a navigation intent filter. */
export const linkKind = (url: string, domains: string[]): Incoming =>
  classify(url, new Set(domains.map((host) => host.trim().toLowerCase())));
/** The hosts whose `/l/<key>` URLs are resolved: the configured domains, or the endpoint's host. */
export function linkHosts(endpoint: string, domains?: string[]): ReadonlySet<string> {
  const hosts = domains?.length ? domains : [parseUrl(endpoint).hostname];
  return new Set(hosts.map((host) => host.trim().toLowerCase()));
}
/**
 * Some platforms deliver the URL that launched the app twice, as the initial URL and as an event.
 * A URL repeated within the window is one open, so it is resolved, and counted, once.
 */
export function duplicateFilter(windowMs = 2000, now: () => number = Date.now) {
  let last: { url: string; at: number } | undefined;
  return (url: string) => {
    const at = now();
    const repeated = !!last && last.url === url && at - last.at < windowMs;
    last = { url, at };
    return repeated;
  };
}
/** Rejects when `work` takes longer than `ms`, so a provider that never answers cannot stall. */
export function withTimeout<T>(work: Promise<T> | T, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms);
    Promise.resolve(work).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}
