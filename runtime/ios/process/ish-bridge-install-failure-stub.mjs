// Test-only stand-in for ish-bridge.mjs (see ish-adapter-install-failure-hooks.mjs).
// installIshBridge() throws, as the audit's T-2 premise assumes it can;
// the other exports are dummies that must never be reached on this path.
export const ISH_RUNNER_COMMAND = '/ish-runner';
export function installIshBridge() {
  throw new Error('injected ish-bridge install failure');
}
export function spawnIshExec() {
  throw new Error('ish-bridge stub: spawnIshExec must not run');
}
export function ishWorkerExec() {
  throw new Error('ish-bridge stub: ishWorkerExec must not run');
}
export function nextSyntheticPid() {
  throw new Error('ish-bridge stub: nextSyntheticPid must not run');
}
export function toGuest() {
  throw new Error('ish-bridge stub: toGuest must not run');
}
export function ishPtySpawn() {
  throw new Error('ish-bridge stub: ishPtySpawn must not run');
}
