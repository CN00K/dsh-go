/**
 * dsh-go browser_use bridge (Stage 5.x).
 *
 * Forwards browser_use tool calls from the DSH engine (Node) to the Swift
 * browser (WKWebView) through the browser loopback service
 * (BrowserLoopbackService: GET /browser/status, POST /browser/execute on
 * 127.0.0.1, Bearer token from browser-service.json). Installed by
 * engine-worker.mjs before DSH starts, next to the iSH bridge shim.
 *
 * Architecture (mirrors ish-bridge.mjs):
 * - The service file lives at Application Support/NativeNode/
 *   browser-service.json (written by Swift, 0600). The JS side derives it
 *   from HOME the same way ish-bridge.mjs derives ish-service.json
 *   (HOME is NativeNode/home, so HOME/../browser-service.json is the file).
 * - installBrowserBridge() puts a client on
 *   globalThis[Symbol.for('dsh.browser')] so the browser_use tool executor
 *   (runtime/tool-browser/lib/index.js) can call it without importing this
 *   file — the same Symbol pattern ish-bridge.mjs uses for
 *   Symbol.for("dsh.ish.pty") / Symbol.for("dsh.go.direct").
 * - Failure mode is fail-closed everywhere: if the loopback service is not
 *   reachable, execute() throws BROWSER_BRIDGE_UNAVAILABLE and the tool
 *   reports it (never a bare success, never a silent no-op).
 *
 * Node 24.20.0 (NodeMobile) only: uses node:http / node:fs / node:path.
 * No global fetch, no global WebSocket.
 */
import {readFileSync} from 'node:fs';
import {request as httpRequest} from 'node:http';
import {join} from 'node:path';
import {StringDecoder} from 'node:string_decoder';

/** Symbol the browser_use tool executor reads for the client. */
export const BROWSER_BRIDGE_SYMBOL = Symbol.for('dsh.browser');

/** Fatal signature when the bridge cannot reach the Swift browser. */
export const BROWSER_BRIDGE_UNAVAILABLE = 'browser bridge unavailable';
export const BROWSER_NOT_BOOTED = 'browser_not_booted';

/** How long the first service-file miss waits for the file to appear. */
const SERVICE_FILE_WAIT_MS = 30_000;

/** Default per-action timeout (the tool executor passes its own). */
const DEFAULT_TIMEOUT_MS = 60_000;

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/**
 * Host roots, derived from HOME (same derivation as ish-bridge.mjs).
 * HOME is NativeNode/home in the app sandbox, so the service file is
 * HOME/../browser-service.json == Application Support/NativeNode/.
 */
function hostRoots() {
  const home = process.env.HOME;
  if (!home) return null;
  return {
    home,
    serviceFile: join(home, '..', 'browser-service.json'),
  };
}

/** Read and parse browser-service.json; returns null when absent/unparsable. */
function readServiceFile(serviceFile) {
  try {
    const parsed = JSON.parse(readFileSync(serviceFile, 'utf8'));
    if (typeof parsed?.token !== 'string' || parsed.token.length === 0) return null;
    if (!Number.isSafeInteger(parsed?.port) || parsed.port <= 0) return null;
    return {host: '127.0.0.1', port: parsed.port, token: parsed.token};
  } catch {
    return null;
  }
}

let cachedService = null;
let cachedServiceFile = null;
let waitedForServiceFile = false;

/**
 * Resolve the loopback service (lazy, cached). First call waits up to 30s
 * for the file to appear (the Swift browser may still be starting).
 * @returns service info, or null when the bridge is unavailable.
 */
export async function getServiceInfo(opts = {}) {
  const roots = hostRoots();
  const serviceFile = opts.serviceFile ?? roots?.serviceFile ?? null;
  if (!serviceFile) return null;
  if (cachedService && cachedServiceFile === serviceFile) return cachedService;
  let info = readServiceFile(serviceFile);
  if (!info && !waitedForServiceFile) {
    waitedForServiceFile = true;
    const deadline = Date.now() + SERVICE_FILE_WAIT_MS;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 500));
      info = readServiceFile(serviceFile);
      if (info) break;
    }
  }
  if (info) {
    cachedService = info;
    cachedServiceFile = serviceFile;
  }
  return info;
}

function bridgeUnavailableError(opts = {}) {
  const roots = hostRoots();
  const serviceFile = opts.serviceFile ?? roots?.serviceFile ?? null;
  const detail = serviceFile != null
    ? `browser-service.json not found at ${serviceFile}`
    : 'HOME is not set (cannot locate browser-service.json)';
  return Object.assign(new Error(detail), {code: 'BROWSER_BRIDGE_UNAVAILABLE'});
}

// ---------------------------------------------------------------------------
// HTTP client
// ---------------------------------------------------------------------------

/**
 * POST one action to /browser/execute and parse the JSON result.
 * @param service {host, port, token} from getServiceInfo().
 * @param body JSON string of the action input.
 * @param opts {signal, timeoutMs} — AbortSignal aborts the request.
 * @returns the parsed result object {text, success, base64Image?,
 *   imageFilePath?, pageURL?, tabId?}.
 */
function postExecute(service, body, opts = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const settleResolve = (value) => { if (!settled) { settled = true; resolvePromise(value); } };
    const settleReject = (error) => { if (!settled) { settled = true; rejectPromise(error); } };
    const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    const timer = setTimeout(() => {
      const error = new Error(`browser execute timed out after ${timeoutMs}ms`);
      error.code = 'BROWSER_TIMEOUT';
      settleReject(error);
      req.destroy();
    }, timeoutMs);
    timer.unref?.();
    const req = httpRequest({
      host: service.host,
      port: service.port,
      path: '/browser/execute',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${service.token}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
      signal: opts.signal,
    }, (res) => {
      if (res.statusCode === 503) {
        const error = new Error(BROWSER_NOT_BOOTED);
        error.code = 'BROWSER_NOT_BOOTED';
        clearTimeout(timer);
        settleReject(error);
        res.resume();
        return;
      }
      if (res.statusCode !== 200) {
        const error = new Error(`browser execute failed: HTTP ${res.statusCode}`);
        error.code = 'BROWSER_HTTP_ERROR';
        clearTimeout(timer);
        settleReject(error);
        res.resume();
        return;
      }
      const decoder = new StringDecoder('utf8');
      let text = '';
      res.on('data', (chunk) => { text += decoder.write(chunk); });
      res.on('end', () => {
        clearTimeout(timer);
        text += decoder.end();
        try {
          settleResolve(JSON.parse(text));
        } catch {
          const error = new Error(`browser execute returned non-JSON: ${text.slice(0, 200)}`);
          error.code = 'BROWSER_BAD_RESPONSE';
          settleReject(error);
        }
      });
      res.on('error', (error) => {
        clearTimeout(timer);
        settleReject(error);
      });
    });
    req.on('error', (error) => {
      clearTimeout(timer);
      settleReject(error);
    });
    req.end(body);
  });
}

/**
 * GET /browser/status.
 * @returns the parsed status object {tabs, activeTabId, maxTabs}.
 */
async function getStatus(opts = {}) {
  const service = await getServiceInfo(opts);
  if (!service) throw bridgeUnavailableError(opts);
  return new Promise((resolvePromise, rejectPromise) => {
    let settled = false;
    const settleResolve = (value) => { if (!settled) { settled = true; resolvePromise(value); } };
    const settleReject = (error) => { if (!settled) { settled = true; rejectPromise(error); } };
    const req = httpRequest({
      host: service.host,
      port: service.port,
      path: '/browser/status',
      method: 'GET',
      headers: {'Authorization': `Bearer ${service.token}`},
      signal: opts.signal,
    }, (res) => {
      if (res.statusCode !== 200) {
        settleReject(new Error(`browser status failed: HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      const decoder = new StringDecoder('utf8');
      let text = '';
      res.on('data', (chunk) => { text += decoder.write(chunk); });
      res.on('end', () => {
        text += decoder.end();
        try {
          settleResolve(JSON.parse(text));
        } catch {
          settleReject(new Error(`browser status returned non-JSON: ${text.slice(0, 200)}`));
        }
      });
      res.on('error', settleReject);
    });
    req.on('error', settleReject);
    req.end();
  });
}

// ---------------------------------------------------------------------------
// Public client
// ---------------------------------------------------------------------------

/**
 * Execute one browser_use action against the Swift browser.
 * @param input the action object (same fields as the tool schema:
 *   action, url, selector, text, coordinate_x/y, direction, amount,
 *   script, user_agent, max_depth, tab_id, full_page, ...).
 * @param opts {signal, timeoutMs, serviceFile} — serviceFile overrides the
 *   service-file path (tests).
 * @returns the result object {text, success, base64Image?, imageFilePath?,
 *   pageURL?, tabId?}.
 * @throws BROWSER_BRIDGE_UNAVAILABLE when the loopback service cannot be
 *   reached (fail closed — the tool reports it, never a bare success).
 */
export async function executeBrowserAction(input, opts = {}) {
  const service = await getServiceInfo(opts);
  if (!service) throw bridgeUnavailableError(opts);
  const body = JSON.stringify(input);
  return postExecute(service, body, opts);
}

/**
 * Install the browser client on the global Symbol so the browser_use tool
 * executor can reach it without importing this file. Never throws: when the
 * loopback service is not up yet, calls fail closed per call.
 * Called by engine-worker.mjs before DSH starts, next to installIshBridge().
 */
export function installBrowserBridge() {
  globalThis[BROWSER_BRIDGE_SYMBOL] = {
    execute: executeBrowserAction,
    status: getStatus,
  };
}
