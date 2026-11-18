// Test-only module customization hooks for ish-adapter-install-failure.test.mjs.
//
// Redirects ish-adapter.mjs's import of './ish-bridge.mjs' to the
// throwing stub next to this file, so installIshBridge() throws on
// first use. Every other import resolves normally.
export async function resolve(specifier, context, nextResolve) {
  if (specifier === './ish-bridge.mjs'
    && typeof context.parentURL === 'string'
    && context.parentURL.endsWith('/ish-adapter.mjs')) {
    return {
      url: new URL('./ish-bridge-install-failure-stub.mjs', import.meta.url).href,
      shortCircuit: true,
    };
  }
  return nextResolve(specifier, context);
}
