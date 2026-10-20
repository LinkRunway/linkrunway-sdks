// The runtime entry an Expo app imports. The config plugin lives in `./plugin` and is loaded by
// Expo CLI through `app.plugin.js`; it must never be imported from app code, because it depends
// on Node-only modules that cannot be bundled.
export * from '@linkrunway/sdk-react-native';
