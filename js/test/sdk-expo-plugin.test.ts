import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import expo from '@expo/config-plugins';
import manifest from '../expo/package.json';
import {
  addAppLinkIntentFilters,
  appLinkFilter,
  ASSOCIATED_DOMAINS,
  mainActivity,
  withLinkRunway,
} from '../expo/src/plugin';
type Manifest = Parameters<typeof addAppLinkIntentFilters>[0];
// From tests/ the package is reached through a symlinked relative path, where TypeScript cannot
// resolve its own `@expo/config-types` dependency. The evaluated config is read through this type.
type Compiled = {
  ios?: { entitlements?: Record<string, unknown> };
  _internal?: { modResults: { android: { manifest: Manifest } } };
};
const packageRoot = resolve('expo');
const { Scheme, IntentFilters } = expo.AndroidConfig;
const entitlement = (config: unknown) =>
  (config as Compiled).ios?.entitlements?.[ASSOCIATED_DOMAINS];
const manifestOf = (config: unknown) => (config as Compiled)._internal!.modResults.android.manifest;
/** Expo's own scheme mod, as prebuild applies it to an existing manifest. */
const setScheme = (scheme: string | string[], manifest: Manifest) =>
  Scheme.setScheme({ scheme } as Parameters<typeof Scheme.setScheme>[0], manifest);
// Expo's plugin functions register mods on the config they are given, so every use gets its own.
const app = () => ({ name: 'Shop', slug: 'shop' });
const options = { domains: ['go.example.com'] };
const link = appLinkFilter('go.example.com');
const projects: string[] = [];
function project() {
  const root = mkdtempSync(join(tmpdir(), 'linkrunway-expo-'));
  projects.push(root);
  return root;
}
afterAll(() => projects.forEach((root) => rmSync(root, { recursive: true, force: true })));
/** Runs the registered mods the way prebuild does, but reading Expo's templates and writing nothing. */
async function compile(config: Parameters<typeof expo.compileModsAsync>[0]) {
  const done = await expo.compileModsAsync(config, {
    projectRoot: project(),
    platforms: ['ios', 'android'],
    introspect: true,
  });
  return { config: done, filters: mainActivity(manifestOf(done))['intent-filter'] ?? [] };
}
const template = async () => (await compile(expo.withAndroidManifest(app(), (mod) => mod))).config;
const blank = async () => manifestOf(await template());
describe('the plugin inside the Expo mod compiler', () => {
  it('writes the entitlement, the manifest filter and the scheme', async () => {
    const config = withLinkRunway(
      { ...app(), scheme: 'shop', ios: { associatedDomains: ['webcredentials:example.com'] } },
      { domains: ['go.example.com', 'l.brand.io'], scheme: 'myapp' },
    );
    expect(config.scheme).toEqual(['shop', 'myapp']);
    expect(config.ios?.associatedDomains).toEqual([
      'webcredentials:example.com',
      'applinks:go.example.com',
      'applinks:l.brand.io',
    ]);
    const done = await compile(config);
    expect(entitlement(done.config)).toEqual(['applinks:go.example.com', 'applinks:l.brand.io']);
    expect(done.filters.slice(1)).toEqual([link, appLinkFilter('l.brand.io')]);
  });
  it('keeps its result next to Expo’s own mods, and when it is applied twice', async () => {
    const { withAssociatedDomains } = expo.IOSConfig.Entitlements;
    // Prebuild registers these after the plugins of the app config, so they run before them.
    const builtIns = (config: ReturnType<typeof app>) =>
      Scheme.withScheme(IntentFilters.withAndroidIntentFilters(withAssociatedDomains(config)));
    const start = () => ({
      ...app(),
      scheme: 'shop',
      ios: { associatedDomains: ['webcredentials:a.io'] },
    });
    const expected = ['webcredentials:a.io', 'applinks:go.example.com'];
    const done = await compile(builtIns(withLinkRunway(withLinkRunway(start(), options), options)));
    expect(entitlement(done.config)).toEqual(expected);
    expect(done.filters.filter((filter) => filter.$?.['android:autoVerify'])).toEqual([link]);
    expect(Scheme.getSchemesFromManifest(manifestOf(done.config)).sort()).toEqual([
      'https',
      'shop',
    ]);
    // The entitlement also survives the opposite order, in which Expo's mod rewrites it last.
    const reversed = await compile(withLinkRunway(builtIns(start()), options));
    expect(entitlement(reversed.config)).toEqual(expected);
  });
  it('rejects invalid options when the config is evaluated', () => {
    expect(() => withLinkRunway(app(), { domains: ['https://go.example.com'] })).toThrow(
      'is not a hostname',
    );
  });
});
describe('a custom scheme added to an existing manifest', () => {
  it('is moved back out of the app-link filter that Expo’s scheme mod appended it to', async () => {
    const built = addAppLinkIntentFilters(setScheme('shop', await blank()), options.domains);
    const filters = () => mainActivity(built)['intent-filter'] ?? [];
    expect(filters()[2]).toEqual(link);
    // The premise: on a later prebuild Expo appends a new scheme to every VIEW filter it finds.
    setScheme(['shop', 'promo'], built);
    expect(filters()[2]!.data).toContainEqual({ $: { 'android:scheme': 'promo' } });
    addAppLinkIntentFilters(built, options.domains);
    expect(filters()[2]).toEqual(link);
    expect(filters()).toHaveLength(3);
    expect(Scheme.getSchemesFromManifest(built).sort()).toEqual(['https', 'promo', 'shop']);
    const settled = structuredClone(built);
    addAppLinkIntentFilters(setScheme(['shop', 'promo'], built), options.domains);
    expect(built).toEqual(settled);
  });
  it('gets a filter of its own when the app-link filter was the only place it was put', async () => {
    const built = addAppLinkIntentFilters(await blank(), options.domains);
    setScheme('promo', built);
    addAppLinkIntentFilters(built, options.domains);
    const filters = mainActivity(built)['intent-filter'] ?? [];
    expect(filters[1]).toEqual(link);
    expect(filters[2]).toMatchObject({ data: [{ $: { 'android:scheme': 'promo' } }] });
    expect(filters[2]!.$).toBeUndefined();
    expect(Scheme.hasScheme('promo', built)).toBe(true);
    const settled = structuredClone(built);
    addAppLinkIntentFilters(setScheme('promo', built), options.domains);
    expect(built).toEqual(settled);
  });
});
describe('the entry file Expo loads', () => {
  const sources = readdirSync(join(packageRoot, 'src/plugin')).map((name) => ({
    name,
    code: readFileSync(join(packageRoot, 'src/plugin', name), 'utf8'),
  }));
  it('is exported, and its sources stay loadable by Node without a build', () => {
    expect(manifest.exports).toMatchObject({ './app.plugin.js': './app.plugin.js' });
    expect(sources.length).toBeGreaterThan(3);
    for (const { name, code } of sources) {
      const specifiers = [...code.matchAll(/from '(\.[^']*)'/g)].map((match) => match[1]!);
      expect(
        specifiers.filter((specifier) => !specifier.endsWith('.ts')),
        name,
      ).toEqual([]);
      expect(code, name).not.toMatch(
        /\benum\b|\bnamespace\b|constructor\([^)]*\b(private|public|readonly)\b/,
      );
      expect(code, name).not.toMatch(/from '@linkrunway\//);
    }
  });
  it('resolves by package name and runs under plain Node through Expo’s own loader', () => {
    const root = project();
    mkdirSync(join(root, 'node_modules/@linkrunway'), { recursive: true });
    symlinkSync(packageRoot, join(root, 'node_modules/@linkrunway/sdk-expo'));
    const script = `
      import expo from '@expo/config-plugins';
      const [root] = process.argv.slice(-1);
      const plugin = ['@linkrunway/sdk-expo', { domains: ['Go.Example.com'] }];
      let config = expo.withStaticPlugin({ name: 'Shop', slug: 'shop' }, { plugin, projectRoot: root });
      config = await expo.compileModsAsync(config, { projectRoot: root, introspect: true });
      const activity = config._internal.modResults.android.manifest.manifest.application[0].activity[0];
      console.log(JSON.stringify({ ios: config.ios.entitlements, filters: activity['intent-filter'] }));`;
    // Node 22.18+ strips types by default; older 22.x releases need the flag.
    const flags = process.features.typescript ? [] : ['--experimental-strip-types'];
    const output = execFileSync(
      process.execPath,
      [...flags, '--no-warnings', '--input-type=module', '-e', script, root],
      { cwd: packageRoot, encoding: 'utf8' },
    );
    const result = JSON.parse(output) as { ios: Record<string, unknown>; filters: unknown[] };
    expect(result.ios[ASSOCIATED_DOMAINS]).toEqual(['applinks:go.example.com']);
    expect(result.filters[1]).toEqual(link);
  });
});
