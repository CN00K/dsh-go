import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { homedir } from 'node:os';

const semver = createRequire(new URL('../../../package.json', import.meta.url))('semver');
const packageName = /^(?:@[a-z0-9._~-]+\/)?[a-z0-9_~][a-z0-9._~-]*$/;
const metadataLimit = 16 * 1024 * 1024;

export function registryError(message, code = 'ERR_OHOS_PLUGIN_PACKAGE') {
  return Object.assign(new Error(message), { code });
}

export function parseRegistrySpec(raw) {
  if (typeof raw !== 'string') throw registryError('Unsupported registry spec');
  const spec = raw.trim();
  const at = spec.indexOf('@', 1);
  const name = at < 0 ? spec : spec.slice(0, at);
  const range = at < 0 ? 'latest' : spec.slice(at + 1);
  if (!packageName.test(name) || name.length > 214 || !range ||
      (!semver.validRange(range) && !/^[a-zA-Z][a-zA-Z0-9._-]*$/.test(range))) {
    throw registryError('Unsupported registry spec');
  }
  return { name, range };
}

export function secureUrl(value) {
  let url;
  try { url = new URL(value); } catch { throw registryError('Invalid package URL'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || url.search)
    throw registryError('Package URL must use HTTPS without credentials, query or fragment');
  return url;
}

/** A local plugin directory on this device, or null. Registry names are not paths;
 *  the engine only ever passes absolute paths (its parser rejects relative ones),
 *  unless a base is given: then a relative local path resolves against it, and a
 *  leading ~ against the home directory (same rule as the engine's dependencySpec). */
export function localDirectoryPath(spec, base) {
  if (typeof spec !== 'string') return null;
  const trimmed = spec.trim();
  const local = /^(?:file|link):(.*)$/s.exec(trimmed);
  if (local === null) return trimmed.startsWith('/') ? trimmed : null;
  let path = local[1].replace(/^~(?=$|[\\/])/, () => homedir());
  if (!path.startsWith('/')) {
    if (base === undefined) return null;
    path = resolve(base, path);
  }
  return path;
}

const maxRedirects = 5;

/** Follow HTTP redirects manually so every hop stays HTTPS without credentials,
 *  query or fragment. A registry or CDN edge may 302; refusing every 3xx blocks
 *  installs on networks where the registry redirects. */
export async function fetchFollowingRedirects(fetchImpl, url, { signal, headers } = {}) {
  let current = url;
  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const response = await fetchImpl(current, { signal, redirect: 'manual', ...(headers ? { headers } : {}) });
    if (response.status < 300 || response.status >= 400) return response;
    if (hop === maxRedirects) {
      await response.body?.cancel();
      throw registryError('Registry redirect limit exceeded');
    }
    const location = response.headers?.get?.('location');
    await response.body?.cancel();
    if (!location) throw registryError('Registry redirect is unsupported');
    try { current = secureUrl(new URL(location, current).href).href; }
    catch (error) {
      if (error.code?.startsWith('ERR_OHOS_PLUGIN_')) throw error;
      throw registryError('Registry redirect is unsupported');
    }
  }
}

async function readJson(response, signal) {
  const reader = response.body?.getReader();
  if (!reader) throw registryError('Registry returned an empty body');
  let size = 0;
  const chunks = [];
  try {
    for (;;) {
      signal.throwIfAborted();
      let next;
      try { next = await reader.read(); }
      catch {
        signal.throwIfAborted();
        throw registryError('Registry response stream failed', 'ERR_PNPM_META_FETCH_FAIL');
      }
      const { done, value } = next;
      if (done) break;
      size += value.byteLength;
      if (size > metadataLimit) throw registryError('Registry metadata exceeds 16 MiB');
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

/** One operation owns this client: a packument is fetched at most once. */
export function createRegistry({ registry = 'https://registry.npmjs.org', fetchImpl = globalThis.fetch,
  signal, timeoutMs = 30000 } = {}) {
  const base = secureUrl(registry).href.replace(/\/$/, '');
  const cache = new Map();
  async function packument(name) {
    signal?.throwIfAborted();
    if (!cache.has(name)) cache.set(name, (async () => {
      const timeout = AbortSignal.timeout(timeoutMs);
      const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
      let response;
      try {
        response = await fetchFollowingRedirects(fetchImpl, `${base}/${encodeURIComponent(name)}`, {
          signal: requestSignal, headers: { accept: 'application/json' },
        });
      } catch (error) {
        requestSignal.throwIfAborted();
        if (error.code?.startsWith('ERR_OHOS_PLUGIN_')) throw error;
        throw registryError('Registry network request failed', 'ERR_PNPM_META_FETCH_FAIL');
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw registryError(`Registry request failed (HTTP ${response.status})`,
          response.status === 404 ? 'ERR_PNPM_FETCH_404' : 'ERR_PNPM_META_FETCH_FAIL');
      }
      let data;
      try { data = await readJson(response, requestSignal); }
      catch (error) {
        requestSignal.throwIfAborted();
        if (error.code) throw error;
        throw registryError('Registry returned invalid JSON metadata');
      }
      if (!data || typeof data !== 'object' || Array.isArray(data) ||
          !data.versions || typeof data.versions !== 'object' || Array.isArray(data.versions))
        throw registryError('Registry returned invalid versions metadata');
      return data;
    })());
    return cache.get(name);
  }
  async function readManifest(spec) {
    const { name, range } = parseRegistrySpec(spec);
    const data = await packument(name);
    const selected = semver.valid(range) ?? (semver.validRange(range)
      ? semver.maxSatisfying(Object.keys(data.versions), range) : data['dist-tags']?.[range]);
    const manifest = selected && Object.hasOwn(data.versions, selected) ? data.versions[selected] : undefined;
    if (!manifest) throw registryError(`No matching registry version for ${name}`, 'ERR_PNPM_NO_MATCHING_VERSION');
    if (manifest.name !== name || manifest.version !== selected || !semver.valid(selected))
      throw registryError(`Registry package identity mismatch for ${name}`);
    return structuredClone(manifest);
  }
  async function view(spec, fields) {
    const { name } = parseRegistrySpec(spec);
    const listing = fields.some(field => ['versions', 'time', 'dist-tags'].includes(field));
    const source = listing ? await packument(name) : await readManifest(spec);
    return Object.fromEntries(fields.filter(field => Object.hasOwn(source, field)).map(field =>
      [field, field === 'versions' && listing ? Object.keys(source.versions) : structuredClone(source[field])]));
  }
  return { registry: base, readManifest, view };
}
