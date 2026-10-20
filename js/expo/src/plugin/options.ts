export type LinkRunwayPluginOptions = {
  /** Your verified link domains, as bare hostnames: `["go.example.com"]`. */
  domains: string[];
  /** A custom URL scheme to register for the app, such as `myapp`. Added to the config's `scheme`. */
  scheme?: string;
};
const label = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
const topLevel = /^([a-z]{2,63}|xn--[a-z0-9-]{1,59})$/;
const schemeShape = /^[a-z][a-z0-9+.-]*$/;
const reserved = ['http', 'https', 'file', 'about', 'data', 'javascript'];
function fail(message: string): never {
  throw new Error(`@linkrunway/sdk-expo: ${message}`);
}
/**
 * A bare DNS hostname in lowercase. A URL, a path, a port, a wildcard, an address or a single
 * label is refused: Associated Domains and App Links are verified per registered hostname.
 */
export function hostname(value: unknown): string {
  if (typeof value !== 'string') fail('each domain must be a string such as "go.example.com"');
  const host = value.trim().toLowerCase();
  const labels = host.split('.');
  const valid =
    host.length <= 253 &&
    labels.length >= 2 &&
    labels.every((part) => label.test(part)) &&
    topLevel.test(labels[labels.length - 1]!);
  if (!valid)
    fail(
      `"${value}" is not a hostname. Use the bare link domain, such as "go.example.com", ` +
        'without a scheme, path, port or wildcard.',
    );
  return host;
}
/** Checks the plugin options and returns them with lowercase, de-duplicated domains. */
export function normalizeOptions(options: unknown): LinkRunwayPluginOptions {
  if (!options || typeof options !== 'object' || Array.isArray(options))
    fail('pass options such as { "domains": ["go.example.com"] }');
  const { domains, scheme, ...unknown } = options as Record<string, unknown>;
  const extra = Object.keys(unknown);
  if (extra.length) fail(`unknown option "${extra[0]}". The options are "domains" and "scheme".`);
  if (!Array.isArray(domains) || !domains.length)
    fail('"domains" must list at least one link domain, such as ["go.example.com"]');
  const hosts = [...new Set(domains.map(hostname))];
  if (scheme === undefined) return { domains: hosts };
  if (typeof scheme !== 'string' || !schemeShape.test(scheme) || reserved.includes(scheme))
    fail(`"scheme" must be a custom URL scheme in lowercase, such as "myapp"`);
  return { domains: hosts, scheme };
}
/** Adds a scheme to the config's `scheme` value, which Expo accepts as a string or a list. */
export function mergeSchemes(existing: string | string[] | undefined, scheme: string) {
  if (existing === undefined || existing === scheme) return scheme;
  const list = Array.isArray(existing) ? existing : [existing];
  return list.includes(scheme) ? existing : [...list, scheme];
}
