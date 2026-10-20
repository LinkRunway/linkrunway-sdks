// This folder is loaded by Node itself when Expo evaluates the app config, without a build step.
// Keep it runnable as plain type-stripped TypeScript: relative imports name the `.ts` file, types
// are imported with `import type`, and enums, namespaces and parameter properties are not used.
// The package is CommonJS. Node detects these two as named exports, and a bundler compiling the
// plugin to CommonJS for publishing reads them the same way, unlike a default import.
import { withAndroidManifest, withEntitlementsPlist } from '@expo/config-plugins';
import type { ConfigPlugin } from '@expo/config-plugins';
import { addAppLinkIntentFilters } from './android.ts';
import { addAssociatedDomains, mergeAssociatedDomains } from './ios.ts';
import { mergeSchemes, normalizeOptions } from './options.ts';
import type { LinkRunwayPluginOptions } from './options.ts';
export {
  addAppLinkIntentFilters,
  appLinkFilter,
  LINK_PATH_PREFIX,
  mainActivity,
} from './android.ts';
export {
  addAssociatedDomains,
  appLink,
  ASSOCIATED_DOMAINS,
  mergeAssociatedDomains,
} from './ios.ts';
export { hostname, mergeSchemes, normalizeOptions } from './options.ts';
export type { LinkRunwayPluginOptions } from './options.ts';
/**
 * Makes an Expo app open its LinkRunway link domains: `applinks:` Associated Domains on iOS and a
 * verified HTTPS intent filter for `/l/` links on Android. It changes native project files only;
 * it adds no native code and no permissions.
 */
export const withLinkRunway: ConfigPlugin<LinkRunwayPluginOptions> = (config, options) => {
  const { domains, scheme } = normalizeOptions(options);
  // Expo's own Associated Domains mod rewrites the entitlement from this config field, so the
  // domains are added here as well as in the entitlement: either order gives the same result.
  const associatedDomains = mergeAssociatedDomains(config.ios?.associatedDomains, domains);
  config = { ...config, ios: { ...config.ios, associatedDomains } };
  // Expo registers `scheme` on both platforms, and `expo-linking` reads it from the config.
  if (scheme) config = { ...config, scheme: mergeSchemes(config.scheme, scheme) };
  config = withEntitlementsPlist(config, (mod) => {
    mod.modResults = addAssociatedDomains(mod.modResults, domains);
    return mod;
  });
  return withAndroidManifest(config, (mod) => {
    mod.modResults = addAppLinkIntentFilters(mod.modResults, domains);
    return mod;
  });
};
export default withLinkRunway;
