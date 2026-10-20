import type { AndroidConfig, AndroidManifest } from '@expo/config-plugins';
type IntentFilter = AndroidConfig.Manifest.ManifestIntentFilter;
type Activity = AndroidConfig.Manifest.ManifestActivity;
type Data = NonNullable<IntentFilter['data']>[number];
const action = (name: string) => `android.intent.action.${name}`;
const category = (name: string) => `android.intent.category.${name}`;
/** LinkRunway links live under this path on a link domain. */
export const LINK_PATH_PREFIX = '/l/';
// A hand-edited manifest can hold elements without attributes, which the parser leaves bare.
const names = (items?: { $?: { 'android:name'?: string } }[]) =>
  (items ?? []).flatMap((item) => item?.$?.['android:name'] ?? []);
const attributes = (data: Data): Record<string, string | undefined> => data?.$ ?? {};
const sameSet = (left: string[], right: string[]) =>
  left.length === right.length && right.every((name) => left.includes(name));
function isLinkData(data: Data, host: string) {
  const found = attributes(data);
  return (
    Object.keys(found).length === 3 &&
    found['android:scheme'] === 'https' &&
    found['android:host'] === host &&
    found['android:pathPrefix'] === LINK_PATH_PREFIX
  );
}
/** A custom scheme on its own: what Expo's scheme mod appends to every VIEW filter it finds. */
function strayScheme(data: Data) {
  const found = attributes(data);
  const scheme = found['android:scheme'];
  const alone = Object.keys(found).length === 1 && !!scheme;
  return alone && scheme !== 'https' && scheme !== 'http' ? scheme : undefined;
}
/** The verified HTTPS filter for one link domain: `https://<host>/l/...` opens the app. */
export function appLinkFilter(host: string): IntentFilter {
  return {
    $: { 'android:autoVerify': 'true' },
    action: [{ $: { 'android:name': action('VIEW') } }],
    category: [
      { $: { 'android:name': category('DEFAULT') } },
      { $: { 'android:name': category('BROWSABLE') } },
    ],
    data: [
      {
        $: {
          'android:scheme': 'https',
          'android:host': host,
          'android:pathPrefix': LINK_PATH_PREFIX,
        },
      },
    ],
  };
}
// Exactly the filter above, possibly with custom schemes appended to it since it was written.
function isAppLinkFilter(filter: IntentFilter, host: string) {
  const data = filter.data ?? [];
  return (
    filter.$?.['android:autoVerify'] === 'true' &&
    sameSet(names(filter.action), [action('VIEW')]) &&
    sameSet(names(filter.category), [category('DEFAULT'), category('BROWSABLE')]) &&
    data.filter((item) => isLinkData(item, host)).length === 1 &&
    data.every((item) => isLinkData(item, host) || strayScheme(item) !== undefined)
  );
}
const handlesScheme = (filter: IntentFilter, scheme: string) =>
  names(filter.action).includes(action('VIEW')) &&
  !names(filter.category).includes(category('LAUNCHER')) &&
  (filter.data ?? []).some((item) => attributes(item)['android:scheme'] === scheme);
/** Expo's `.MainActivity`, or else the activity the launcher starts. */
export function mainActivity(manifest: AndroidManifest): Activity {
  const activities = manifest.manifest?.application?.[0]?.activity ?? [];
  const launched = (activity: Activity) =>
    (activity['intent-filter'] ?? []).some(
      (filter) =>
        names(filter.action).includes(action('MAIN')) &&
        names(filter.category).includes(category('LAUNCHER')),
    );
  const found =
    activities.find((activity) => activity.$?.['android:name'] === '.MainActivity') ??
    activities.find(launched);
  if (!found)
    throw new Error('@linkrunway/sdk-expo: AndroidManifest.xml has no main activity for app links');
  return found;
}
/**
 * Gives the main activity one verified app-link filter per domain. Running it again changes
 * nothing, and every other filter, activity and element is left as it is.
 *
 * When Expo's scheme mod runs against an existing manifest it appends a newly added custom scheme
 * to every VIEW filter, these included. Android merges the data of one filter, so such a filter
 * would also claim `myapp://<host>/l/` and would no longer be a pure web filter. A custom scheme
 * found here is therefore moved back out, into a filter of its own if no other one declares it.
 */
export function addAppLinkIntentFilters(
  manifest: AndroidManifest,
  domains: string[],
): AndroidManifest {
  const activity = mainActivity(manifest);
  const filters = (activity['intent-filter'] ??= []);
  const moved: string[] = [];
  for (const host of domains) {
    const existing = filters.filter((filter) => isAppLinkFilter(filter, host));
    if (!existing.length) filters.push(appLinkFilter(host));
    for (const filter of existing) {
      for (const item of filter.data ?? []) {
        const scheme = strayScheme(item);
        if (scheme && !moved.includes(scheme)) moved.push(scheme);
      }
      filter.data = (filter.data ?? []).filter((item) => strayScheme(item) === undefined);
    }
  }
  const homeless = moved.filter(
    (scheme) => !filters.some((filter) => handlesScheme(filter, scheme)),
  );
  if (homeless.length)
    filters.push({
      action: [{ $: { 'android:name': action('VIEW') } }],
      category: [
        { $: { 'android:name': category('DEFAULT') } },
        { $: { 'android:name': category('BROWSABLE') } },
      ],
      data: homeless.map((scheme) => ({ $: { 'android:scheme': scheme } })),
    });
  return manifest;
}
