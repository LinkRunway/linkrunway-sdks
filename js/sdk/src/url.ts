export type ParsedUrl = {
  protocol: string;
  hostname: string;
  origin: string;
  pathname: string;
  param(name: string): string | null;
};
type NativeUrl = new (value: string) => {
  protocol: string;
  hostname: string;
  origin: string;
  pathname: string;
  searchParams: { get(name: string): string | null };
};
function decode(text: string) {
  const spaced = text.replace(/\+/g, ' ');
  try {
    return decodeURIComponent(spaced);
  } catch {
    return spaced;
  }
}
/** The first value of `name` in a query string such as `a=1&b=2`, decoded like URLSearchParams. */
export function queryParam(query: string, name: string): string | null {
  for (const pair of query.split('&')) {
    if (!pair) continue;
    const cut = pair.indexOf('=');
    if (decode(cut < 0 ? pair : pair.slice(0, cut)) === name)
      return cut < 0 ? '' : decode(pair.slice(cut + 1));
  }
  return null;
}
const shape = /^([A-Za-z][A-Za-z0-9+.-]*):(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#[\s\S]*)?$/;
const defaultPorts: Record<string, string> = { 'http:': '80', 'https:': '443' };
function fromText(value: string): ParsedUrl {
  const match = shape.exec(value.trim());
  if (!match) throw new TypeError('Invalid URL');
  const protocol = `${match[1]!.toLowerCase()}:`;
  const authority = match[2] ?? '';
  // Credentials are never part of the host: `http://localhost@example.com` is example.com.
  const host = authority.slice(authority.lastIndexOf('@') + 1).toLowerCase();
  const port = /:(\d*)$/.exec(host)?.[1];
  const hostname = port === undefined ? host : host.slice(0, -port.length - 1);
  const shown = port && port !== defaultPorts[protocol] ? `:${port}` : '';
  const query = match[4] ?? '';
  return {
    protocol,
    hostname,
    origin: `${protocol}//${hostname}${shown}`,
    pathname: match[3] || '/',
    param: (name) => queryParam(query, name),
  };
}
function works(Native: NativeUrl) {
  try {
    const probe = new Native('https://Probe.Example:8443/a/b?k=1%2B2&e=#f');
    return (
      probe.protocol === 'https:' &&
      probe.hostname === 'probe.example' &&
      probe.origin === 'https://probe.example:8443' &&
      probe.pathname === '/a/b' &&
      probe.searchParams.get('k') === '1+2'
    );
  } catch {
    return false;
  }
}
/**
 * Some runtimes (older React Native among them) ship a URL class whose getters throw or return
 * nothing. The built-in class is used only when it demonstrably works; otherwise URLs are parsed
 * as text, which covers what the SDK reads: scheme, host, path and query parameters.
 */
export function urlParser(Native = (globalThis as { URL?: NativeUrl }).URL) {
  if (!Native || !works(Native)) return fromText;
  return (value: string): ParsedUrl => {
    const url = new Native(value);
    return {
      protocol: url.protocol,
      hostname: url.hostname,
      origin: url.origin,
      pathname: url.pathname,
      param: (name) => url.searchParams.get(name),
    };
  };
}
/** Parses an absolute URL; throws a TypeError when it is not one. */
export const parseUrl = urlParser();
