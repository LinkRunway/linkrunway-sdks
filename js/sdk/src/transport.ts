export class LinkRunwayError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}
export type Transport = {
  fetch: typeof fetch;
  endpoint: string;
  apiKey: string;
  retries: number;
  userAgent?: string;
};
export type Reply<T> = { status: number; data: T };
// A page or worker cannot set User-Agent, and trying turns a cross-origin call into a preflight
// the API does not allow. The header is sent everywhere else (Node, React Native).
const inBrowser = () => typeof document !== 'undefined' || 'WorkerGlobalScope' in globalThis;
function failure(data: unknown) {
  const message = (data as { message?: unknown } | null)?.message;
  if (typeof message === 'string' && message) return message;
  return Array.isArray(message) ? message.join(', ') : 'Tracking request failed';
}
/** One API call with a timeout and bounded retries. Resolves with the status and the JSON body. */
export async function call<T>(
  transport: Transport,
  method: 'GET' | 'POST' | 'PUT',
  path: string,
  body?: unknown,
): Promise<Reply<T>> {
  const headers: Record<string, string> = { Authorization: `Bearer ${transport.apiKey}` };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (transport.userAgent && !inBrowser()) headers['User-Agent'] = transport.userAgent;
  for (let attempt = 0; attempt <= transport.retries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await transport.fetch(
        `${transport.endpoint.replace(/\/$/, '')}/v1/${path}`,
        {
          method,
          redirect: 'error',
          headers,
          body: body === undefined ? undefined : JSON.stringify(body),
          signal: controller.signal,
        },
      );
      const text = await response.text();
      let data: unknown;
      try {
        data = text ? JSON.parse(text) : {};
      } catch {
        data = undefined;
      }
      if (!response.ok) throw new LinkRunwayError(failure(data), response.status);
      // A success that is not a JSON object did not come from the API (a captive portal, a proxy
      // page): it is retried like a network failure and never counted as delivered.
      if (!data || typeof data !== 'object') throw new TypeError('Unexpected tracking response');
      return { status: response.status, data: data as T };
    } catch (error) {
      const retryable =
        !(error instanceof LinkRunwayError) || error.status === 429 || error.status >= 500;
      if (!retryable || attempt === transport.retries) throw error;
      await new Promise((resolve) => setTimeout(resolve, Math.min(3100, 300 * 2 ** attempt)));
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error('Tracking request failed');
}
