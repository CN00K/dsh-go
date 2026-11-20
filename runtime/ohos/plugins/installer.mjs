import { constants } from 'node:fs';
import { lstat, mkdir, mkdtemp, open, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { createRegistry, fetchFollowingRedirects, localDirectoryPath, parseRegistrySpec, registryError, secureUrl } from './registry.mjs';
import { fields, hostEdge, resolveGraph } from './graph.mjs';
import { ARCHIVE_LIMITS, copyLocalPackage, extractPackage } from './archive.mjs';
import { transactionFor } from './store.mjs';

const generationBytes = 256 * 1024 * 1024;
const manifestFields = ['name', 'version', 'dependencies', 'optionalDependencies', 'peerDependencies',
  'peerDependenciesMeta', 'bundledDependencies', 'bundleDependencies', 'os', 'cpu', 'libc', 'engines',
  'dsh', 'scripts', 'gypfile', 'type', 'main', 'module', 'exports', 'imports', 'bin'];

async function directory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  if (!(await lstat(path)).isDirectory()) throw registryError('Plugin directory is not a real directory');
}

async function download(node, path, options, budget) {
  const timeout = AbortSignal.timeout(options.lookupTimeoutMs ?? 30000);
  const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout;
  signal.throwIfAborted();
  let response;
  try {
    response = await fetchFollowingRedirects(options.fetchImpl ?? globalThis.fetch,
      secureUrl(node.resolved).href, { signal });
  } catch (error) {
    signal.throwIfAborted();
    if (error.code?.startsWith('ERR_OHOS_PLUGIN_')) throw error;
    throw registryError('Package download failed', 'ERR_PNPM_META_FETCH_FAIL');
  }
  if (!response.ok || response.status >= 300 && response.status < 400) {
    await response.body?.cancel();
    throw registryError(`Package download failed (HTTP ${response.status})`, 'ERR_PNPM_META_FETCH_FAIL');
  }
  const reader = response.body?.getReader();
  if (!reader) throw registryError('Package download returned an empty body');
  let file, bytes = 0;
  try {
    file = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    for (;;) {
      signal.throwIfAborted();
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength; budget.downloaded += value.byteLength;
      if (bytes > ARCHIVE_LIMITS.compressedBytes || budget.downloaded > generationBytes)
        throw registryError('Plugin download exceeds installation byte limit');
      await file.writeFile(value);
    }
  } catch (error) {
    signal.throwIfAborted();
    if (error.code?.startsWith('ERR_OHOS_PLUGIN_') || ['ENOSPC', 'EACCES', 'EPERM', 'EIO', 'EMFILE'].includes(error.code)) throw error;
    throw registryError('Package download stream failed', 'ERR_PNPM_META_FETCH_FAIL');
  } finally {
    await reader.cancel().catch(() => {}); reader.releaseLock(); await file?.close();
  }
}

function checkManifest(expected, actual) {
  for (const field of manifestFields) {
    if (!isDeepStrictEqual(expected[field], actual[field]))
      throw registryError(`${expected.name}: archive manifest differs from locked ${field}`);
  }
}

// This tree is owned by this operation and contains only ordinary files/directories.
async function syncTree(path, budget, directoriesOnly = false) {
  const info = await lstat(path);
  if (info.isSymbolicLink()) throw registryError('Unexpected link in plugin generation');
  if (info.isDirectory()) {
    for (const name of await readdir(path)) await syncTree(join(path, name), budget, directoriesOnly);
  } else if (info.isFile()) {
    if (directoriesOnly) return;
    budget.expanded += info.size;
    if (budget.expanded > generationBytes) throw registryError('Plugin files exceed installation byte limit');
  } else throw registryError('Unexpected special file in plugin generation');
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW |
    (info.isDirectory() ? constants.O_DIRECTORY : 0));
  try { await file.sync(); } finally { await file.close(); }
}

/** Manager owns the profile lock and transaction lifetime, including post-install validation. */
export async function runProfileOperation(context, args, options) {
  const tx = transactionFor(context.dir);
  const logRoot = join(context.dir, '.plugin-manager', 'logs');
  await directory(logRoot);
  const logDir = await mkdtemp(join(logRoot, 'operation-'));
  const logPath = join(logDir, 'ohos.log');
  const log = await open(logPath, 'wx', 0o600);
  let output = Buffer.alloc(0), truncated = false;
  const emit = async (message, stream) => {
    await log.writeFile(message);
    const bytes = Buffer.concat([output, Buffer.from(message)]);
    const limit = options.outputBytes ?? 8192;
    truncated ||= bytes.length > limit;
    output = bytes.subarray(Math.max(0, bytes.length - limit));
    options.onOutput?.(message, stream);
  };
  let timedOut = false;
  try {
    options.signal?.throwIfAborted();
    const [action, spec, ...flags] = args;
    if (!['add', 'remove'].includes(action) || typeof spec !== 'string' ||
        flags.some(flag => flag !== '--save-exact' && !/^--(?:config\.)?registry=/.test(flag)))
      throw registryError('Unsupported OHOS package operation');
    const localPath = localDirectoryPath(spec);
    let parsed = null;
    if (localPath !== null) {
      if (action === 'remove') throw registryError('Removal requires a package name');
    } else {
      parsed = parseRegistrySpec(spec);
    }
    const registryFlags = flags.filter(flag => /^--(?:config\.)?registry=/.test(flag));
    if (registryFlags.length > 1) throw registryError('Multiple registry arguments are unsupported');
    const registry = registryFlags[0]?.slice(registryFlags[0].indexOf('=') + 1);
    if (registry !== undefined) secureUrl(registry);
    const manifest = JSON.parse(await readFile(join(context.dir, 'package.json'), 'utf8'));
    const dependencies = { ...manifest.dependencies };
    if (action === 'remove') {
      if (spec !== parsed.name) throw registryError('Removal requires a package name');
      tx.publish(parsed.name, null);
      delete dependencies[parsed.name];
      tx.writeManifest({ ...manifest, dependencies });
      await emit(`Removed ${parsed.name}; previous files retained until a future process.\n`, 'stdout');
    } else {
      // Install: a local pure-JS bundle (root copied in) or a registry spec
      // (root resolved from the registry). A local root's own dependencies
      // still come from the registry, as the plugin expects.
      const client = createRegistry({ registry, fetchImpl: options.fetchImpl,
        signal: options.signal, timeoutMs: options.lookupTimeoutMs ?? 30000 });
      const hostPackages = options.hostPackages ?? new Map();
      const generation = tx.newGeneration();
      const budget = { downloaded: 0, expanded: 0 };
      let graph, localStaging = null;
      if (localPath !== null) {
        const staging = join(generation, 'local-staging');
        const localManifest = await copyLocalPackage({ source: localPath,
          destination: staging, signal: options.signal });
        const id = `${localManifest.name}@${localManifest.version}`;
        const rootNode = { id, name: localManifest.name, version: localManifest.version,
          resolved: `file:${localPath}`, manifest: localManifest,
          dependencies: {}, peers: {}, omitted: {}, local: true };
        const nodes = new Map([[id, rootNode]]);
        const optionalRanges = fields(localManifest, 'optionalDependencies');
        const peerRanges = fields(localManifest, 'peerDependencies');
        const peerMeta = fields(localManifest, 'peerDependenciesMeta');
        for (const [depName, range] of Object.entries({ ...fields(localManifest, 'dependencies'), ...optionalRanges })) {
          parseRegistrySpec(`${depName}@${range}`);
          const host = Object.hasOwn(peerRanges, depName)
            ? hostEdge(depName, range, hostPackages) : undefined;
          if (host !== undefined) {
            Object.defineProperty(rootNode.peers, depName, { value: host, enumerable: true });
            continue;
          }
          try {
            const sub = await resolveGraph({ spec: `${depName}@${range}`, registryClient: client,
              hostPackages, signal: options.signal });
            for (const node of sub.nodes) if (!nodes.has(node.id)) nodes.set(node.id, node);
            Object.defineProperty(rootNode.dependencies, depName,
              { value: { type: 'package', id: sub.root }, enumerable: true });
          } catch (error) {
            if (!Object.hasOwn(optionalRanges, depName)) throw error;
            Object.defineProperty(rootNode.omitted, depName,
              { value: 'optional dependency excluded by platform', enumerable: true });
          }
        }
        for (const [peerName, range] of Object.entries(peerRanges)) {
          if (Object.hasOwn(rootNode.peers, peerName) || Object.hasOwn(rootNode.dependencies, peerName)) continue;
          parseRegistrySpec(`${peerName}@${range}`);
          const edge = hostEdge(peerName, range, hostPackages);
          if (edge !== undefined) Object.defineProperty(rootNode.peers, peerName, { value: edge, enumerable: true });
          else if (peerMeta[peerName]?.optional === true)
            Object.defineProperty(rootNode.omitted, peerName, { value: 'missing optional peer', enumerable: true });
          else throw registryError(`${localManifest.name}: unsupported non-host peer ${peerName}`);
        }
        graph = { schema: 1, root: id, nodes: [...nodes.values()] };
        localStaging = staging;
      } else {
        graph = await resolveGraph({ spec, registryClient: client, hostPackages,
          signal: options.signal });
      }
      const directories = new Map();
      for (const [index, node] of graph.nodes.entries()) {
        options.signal?.throwIfAborted();
        const destination = join(generation, `package-${index}`, 'node_modules', node.name);
        await directory(dirname(destination));
        if (node.local === true) {
          await rename(localStaging, destination);
        } else {
          await emit(`Downloading ${node.id}\n`, 'stdout');
          const archivePath = join(generation, `archive-${index}.tgz`);
          await download(node, archivePath, options, budget);
          const extracted = await extractPackage({ archivePath, integrity: node.integrity,
            stagingRoot: generation, name: node.name, version: node.version, signal: options.signal });
          checkManifest(node.manifest, extracted.manifest);
          await rm(archivePath);
          await rename(extracted.directory, destination);
        }
        await syncTree(destination, budget);
        node.directory = relative(generation, destination);
        directories.set(node.id, destination);
      }
      await writeFile(join(generation, 'lock.json'), JSON.stringify(graph, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
      await syncTree(join(generation, 'lock.json'), budget);
      await syncTree(generation, budget, true);
      options.signal?.throwIfAborted();
      const root = graph.nodes.find(node => node.id === graph.root);
      tx.publish(root.name, directories.get(root.id));
      Object.defineProperty(dependencies, root.name, { value: root.version, enumerable: true, configurable: true });
      tx.writeManifest({ ...manifest, dependencies });
      await emit(`Saved ${root.id}${localPath !== null ? ' from local path' : ''}; activation remains subject to host validation.\n`, 'stdout');
    }
    return { exitCode: 0, output: output.toString('utf8'), truncated, logPath };
  } catch (error) {
    // Restore before returning a retryable network failure to the manager.
    tx.rollbackAttempt();
    timedOut = error.name === 'TimeoutError';
    const controlled = /^ERR_(?:OHOS_PLUGIN_|PNPM_)/.test(error.code ?? '');
    const message = controlled ? `${error.code}: ${error.message}` :
      timedOut ? 'ERR_PNPM_META_FETCH_FAIL: Package operation timed out' :
      error.name === 'AbortError' ? 'Package operation cancelled' : `Package operation failed (${error.code ?? 'invalid-data'})`;
    await emit(message + '\n', 'stderr');
    return { exitCode: 1, output: output.toString('utf8'), truncated, logPath, ...(timedOut ? { timedOut: true } : {}) };
  } finally { await log.close(); }
}
