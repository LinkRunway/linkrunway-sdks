import { describe, expect, it } from 'vitest';
import expo from '@expo/config-plugins';
import {
  addAppLinkIntentFilters,
  addAssociatedDomains,
  appLinkFilter,
  ASSOCIATED_DOMAINS,
  hostname,
  mainActivity,
  mergeSchemes,
  normalizeOptions,
} from '../expo/src/plugin';
type Manifest = Parameters<typeof addAppLinkIntentFilters>[0];
const fixture = `
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.shop">
  <uses-permission android:name="android.permission.INTERNET"/>
  <application android:name=".MainApplication" android:label="@string/app_name">
    <meta-data android:name="expo.modules.updates.ENABLED" android:value="false"/>
    <activity android:name=".MainActivity" android:launchMode="singleTask" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
      <intent-filter>
        <action android:name="android.intent.action.VIEW"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <category android:name="android.intent.category.BROWSABLE"/>
        <data android:scheme="shop"/>
      </intent-filter>
    </activity>
    <activity android:name=".ShareActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.SEND"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <data android:mimeType="text/plain"/>
      </intent-filter>
    </activity>
  </application>
</manifest>`;
// The same object shape Expo hands a manifest mod: its own XML parser reads the fixture.
const parse = async (xml = fixture) => (await expo.XML.parseXMLAsync(xml)) as Manifest;
const filters = (manifest: Manifest) => mainActivity(manifest)['intent-filter'] ?? [];
const copy = <T>(value: T): T => structuredClone(value);
describe('plugin options', () => {
  it('accepts bare hostnames and normalizes them', () => {
    expect(normalizeOptions({ domains: [' Go.Example.com ', 'go.example.com'] })).toEqual({
      domains: ['go.example.com'],
    });
    expect(
      normalizeOptions({ domains: ['xn--mnchen-3ya.example', 'a.b.co'], scheme: 'my-app' }),
    ).toEqual({ domains: ['xn--mnchen-3ya.example', 'a.b.co'], scheme: 'my-app' });
  });
  it('rejects anything that is not a hostname', () => {
    for (const value of [
      'https://go.example.com',
      'go.example.com/l/',
      'go.example.com:8443',
      '*.example.com',
      'localhost',
      '192.168.1.10',
      'go example.com',
      '-go.example.com',
      'go-.example.com',
      'go..example.com',
      'münchen.example',
      `${'a'.repeat(64)}.example.com`,
      `${Array.from({ length: 5 }, () => 'a'.repeat(60)).join('.')}.com`,
      '',
      42,
      null,
    ])
      expect(() => hostname(value), String(value)).toThrow('@linkrunway/sdk-expo');
    expect(() => hostname('https://go.example.com')).toThrow('is not a hostname');
  });
  it('rejects missing, unknown and unusable options', () => {
    for (const options of [
      undefined,
      {},
      { domains: [] },
      { domains: 'go.example.com' },
      { domain: ['go.example.com'] },
      { domains: ['go.example.com'], schemes: ['myapp'] },
      { domains: ['go.example.com'], scheme: 'My App' },
      { domains: ['go.example.com'], scheme: 'https' },
      { domains: ['go.example.com'], scheme: '1app' },
    ])
      expect(() => normalizeOptions(options), JSON.stringify(options)).toThrow(
        '@linkrunway/sdk-expo',
      );
    expect(mergeSchemes(undefined, 'myapp')).toBe('myapp');
    expect(mergeSchemes('shop', 'myapp')).toEqual(['shop', 'myapp']);
    expect(mergeSchemes(['shop', 'myapp'], 'myapp')).toEqual(['shop', 'myapp']);
  });
});
describe('iOS Associated Domains', () => {
  const existing = {
    'aps-environment': 'development',
    [ASSOCIATED_DOMAINS]: ['webcredentials:example.com', 'applinks:Other.example.com'],
  };
  it('adds an applinks entry per domain, keeps what is there, and is idempotent', () => {
    const once = addAssociatedDomains(existing, ['go.example.com', 'other.example.com']);
    expect(once).toEqual({
      'aps-environment': 'development',
      [ASSOCIATED_DOMAINS]: [
        'webcredentials:example.com',
        'applinks:Other.example.com',
        'applinks:go.example.com',
      ],
    });
    expect(addAssociatedDomains(once, ['go.example.com', 'other.example.com'])).toEqual(once);
    expect(existing[ASSOCIATED_DOMAINS]).toHaveLength(2);
    expect(addAssociatedDomains({}, ['go.example.com'])).toEqual({
      [ASSOCIATED_DOMAINS]: ['applinks:go.example.com'],
    });
  });
});
describe('Android app links', () => {
  it('adds one verified HTTPS filter per domain to the main activity', async () => {
    const manifest = addAppLinkIntentFilters(await parse(), ['go.example.com', 'l.brand.io']);
    expect(filters(manifest).slice(2)).toEqual([
      appLinkFilter('go.example.com'),
      appLinkFilter('l.brand.io'),
    ]);
    const xml = expo.XML.format(manifest);
    expect(xml).toContain('<intent-filter android:autoVerify="true">');
    expect(xml).toContain(
      '<data android:scheme="https" android:host="go.example.com" android:pathPrefix="/l/"/>',
    );
    expect(xml).toContain('<action android:name="android.intent.action.VIEW"/>');
    expect(xml).toContain('<category android:name="android.intent.category.BROWSABLE"/>');
  });
  it('is idempotent and leaves every unrelated element as it was', async () => {
    const original = await parse();
    const once = addAppLinkIntentFilters(copy(original), ['go.example.com']);
    const twice = addAppLinkIntentFilters(copy(once), ['go.example.com']);
    expect(twice).toEqual(once);
    expect(filters(once).slice(0, 2)).toEqual(filters(original));
    const without = copy(once);
    mainActivity(without)['intent-filter'] = filters(original);
    expect(without).toEqual(original);
    // Adding a domain later keeps the first one and adds only the new filter.
    const grown = addAppLinkIntentFilters(copy(once), ['go.example.com', 'l.brand.io']);
    expect(filters(grown)).toEqual([...filters(once), appLinkFilter('l.brand.io')]);
  });
  it('recognizes an equivalent filter and leaves a different one for the same host alone', async () => {
    const declared = await parse();
    const same = { ...appLinkFilter('go.example.com') };
    same.$ = { 'android:autoVerify': 'true', 'data-generated': 'true' };
    same.category = [...same.category!].reverse();
    filters(declared).push(same);
    expect(filters(addAppLinkIntentFilters(copy(declared), ['go.example.com']))).toHaveLength(3);
    // A filter that is not exactly ours belongs to the app: it stays, and the verified one is added.
    const wider = appLinkFilter('go.example.com');
    wider.data!.push({ $: { 'android:pathPrefix': '/promo/' } });
    const ported = appLinkFilter('go.example.com');
    ported.data![0]!.$['android:port'] = '8443';
    const unverified = appLinkFilter('go.example.com');
    delete unverified.$;
    for (const theirs of [wider, ported, unverified]) {
      const custom = await parse();
      filters(custom).push(copy(theirs));
      const result = addAppLinkIntentFilters(custom, ['go.example.com']);
      expect(filters(result).slice(2)).toEqual([theirs, appLinkFilter('go.example.com')]);
    }
  });
  it('finds the launcher activity when it has another name, and fails without one', async () => {
    const renamed = await parse(fixture.replace('".MainActivity"', '".ShopActivity"'));
    addAppLinkIntentFilters(renamed, ['go.example.com']);
    expect(mainActivity(renamed).$['android:name']).toBe('.ShopActivity');
    expect(filters(renamed)).toHaveLength(3);
    const none = await parse('<manifest><application android:name=".App"/></manifest>');
    expect(() => addAppLinkIntentFilters(none, ['go.example.com'])).toThrow('no main activity');
  });
});
