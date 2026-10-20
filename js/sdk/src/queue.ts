import type { QueuedEvent, Session } from './state';
import { LinkRunwayError } from './transport';
import type { TrackingResult } from './types';
const LIMIT = 100;
type Post = (path: string, body: unknown) => Promise<TrackingResult>;
/** True when the failure says nothing about the event itself: it is worth sending again later. */
export const transient = (error: unknown) =>
  !(error instanceof LinkRunwayError) || error.status >= 500 || error.status === 429;
/**
 * Sends one event. The attestation is added here, when the request is made, so a queued event
 * never carries a stale one and the token is never written to storage.
 */
export async function send(session: Session, post: Post, event: QueuedEvent, attestation?: string) {
  const body = { ...event, attestation: event.attestation ?? attestation, consent: true };
  try {
    return await post('track', body);
  } catch (error) {
    // The API refuses an event whose click token has expired. In an app the event is sent once
    // more without it; if that is accepted the token was the reason and is forgotten, so later
    // events are not refused too. A backend gets the error for the token it supplied.
    const refused = error instanceof LinkRunwayError && error.status === 400;
    if (!refused || !event.clickToken || !session.client) throw error;
    const result = await post('track', { ...body, clickToken: undefined }).catch(
      (again: unknown) => {
        // Refused again: the event itself is invalid. A network failure is worth another try.
        throw transient(again) ? again : error;
      },
    );
    if (session.clickToken === event.clickToken) {
      session.clickToken = undefined;
      session.persist();
    }
    return result;
  }
}
/** Keeps an undelivered event for a later flush. The queue holds the newest 100 events. */
export function enqueue(session: Session, event: QueuedEvent) {
  if (!session.queue.some((item) => item.eventId === event.eventId)) session.queue.push(event);
  session.queue = session.queue.slice(-LIMIT);
  session.persist();
}
/** Sends the queued events in order, each with its original ID and timestamp. */
export async function drain(session: Session, deliver: (event: QueuedEvent) => Promise<unknown>) {
  let refused: unknown;
  const { epoch } = session;
  for (const event of [...session.queue]) {
    if (!session.since(epoch)) return;
    if (!session.queue.includes(event)) continue;
    try {
      await deliver(event);
    } catch (error) {
      // Only these answers concern one event: an invalid event is dropped and a conflict waits
      // for the next flush. Any other failure would repeat for the rest, so the flush stops.
      const status = error instanceof LinkRunwayError ? error.status : 0;
      if (![400, 409, 422].includes(status)) throw error;
      refused ??= error;
      if (status === 409) continue;
    }
    if (!session.since(epoch)) return;
    session.queue = session.queue.filter((item) => item !== event);
    session.persist();
  }
  if (refused) throw refused;
}
