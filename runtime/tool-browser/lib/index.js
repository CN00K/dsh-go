/**
 * dsh-go browser_use tool (Stage 5.x).
 *
 * A Cordis plugin that registers the `browser_use` tool with the DSH agent.
 * Modeled on @deepseek-ai/dsh-tool-bash (lib/index.js): defineTool() +
 * apply(ctx) + ctx.tools.register(tool). The executor does no browser work
 * itself — it forwards the action to the Swift browser through the bridge
 * client installed on globalThis[Symbol.for('dsh.browser')] by
 * runtime/native-node/browser-bridge.mjs (installBrowserBridge(), called by
 * engine-worker.mjs before DSH starts), the same Symbol pattern ish-bridge.mjs
 * uses for Symbol.for("dsh.ish.pty") / Symbol.for("dsh.go.direct").
 *
 * Wiring (see DESIGN.md §8):
 * - cordis.patch.yml preset `plugins:` gains a row:
 *     - id: tool-browser
 *       name: '@dsh-go/dsh-tool-browser'
 * - The engine's node_modules must contain @dsh-go/dsh-tool-browser
 *   (build-side install; how it gets there is an open item — see VERIFY.md).
 *
 * Screenshot -> model (OPEN VERIFICATION ITEM): the result object carries
 * base64Image (base64 JPEG) and the screenshot is also saved to disk with
 * the path in `text`. Whether the DSH engine forwards base64Image to the
 * model as a vision image is NOT verifiable from the available source
 * (dsh-tools / dsh-agent are not in the local package subset), so v1's
 * render() returns a text block only — a guessed image block could break
 * the tool call if the engine does not accept that block type. Needs a
 * device test: ask the agent to screenshot a page and describe it.
 *
 * Failure mode is fail-closed everywhere: if the bridge is not installed or
 * the loopback service is unreachable, execute() throws and the tool
 * reports the failure (never a bare success, never a silent no-op).
 *
 * Node 24.20.0 (NodeMobile) only. No global fetch, no global WebSocket.
 */
import {defineTool} from '@deepseek-ai/dsh-tools';

/** Symbol the browser bridge client is installed on (browser-bridge.mjs). */
const BROWSER_BRIDGE_SYMBOL = Symbol.for('dsh.browser');

export const name = 'tool-browser';

/** No injected services: the executor reads the bridge from the global Symbol. */
export const inject = [];

/** The 22 actions (Minis BrowserUseTool.kt / BrowserUseActions.swift). */
const BROWSER_ACTIONS = [
  'navigate',
  'screenshot',
  'click',
  'type',
  'get_text',
  'scroll',
  'get_page_info',
  'execute_js',
  'find_elements',
  'hover',
  'get_readable',
  'set_user_agent',
  'set_viewport',
  'get_backbone',
  'fetch',
  'new_tab',
  'close_tab',
  'list_tabs',
  'get_cookies',
  'set_cookies',
  'scroll_and_collect',
  'wait_for_dom_stable',
];

function browserDescription() {
  return 'Interact with the iOS browser (native WKWebView, up to 3 tabs). Use it to open pages, click, type, read page content, run JavaScript, and take screenshots. Screenshots are returned as base64 JPEG and saved to disk; describe what you see in them. Prefer get_readable for article-style pages and find_elements before clicking. The browser is a separate app surface from the terminal sandbox — it cannot run shell commands and the shell cannot see its pages.';
}

/**
 * Validate the tool call arguments before anything executes.
 * The Swift side validates again; this catches the obvious mistakes early
 * (and gives the model a clear error instead of a native round-trip).
 */
function validateBrowserArgs(args) {
  if (typeof args?.action !== 'string' || args.action.length === 0) {
    throw new Error('invalid action: expected a non-empty string');
  }
  if (!BROWSER_ACTIONS.includes(args.action)) {
    throw new Error(
      `invalid action: ${args.action} (expected one of ${BROWSER_ACTIONS.join(', ')})`,
    );
  }
  if (args.action === 'navigate' && typeof args.url !== 'string') {
    throw new Error('invalid url: navigate requires a url string');
  }
  if ((args.action === 'click' || args.action === 'type' || args.action === 'hover'
      || args.action === 'find_elements')
    && typeof args.selector !== 'string') {
    throw new Error(`invalid selector: ${args.action} requires a selector string`);
  }
  if (args.action === 'type' && typeof args.text !== 'string') {
    throw new Error('invalid text: type requires a text string');
  }
  if (args.action === 'execute_js' && typeof args.script !== 'string') {
    throw new Error('invalid script: execute_js requires a script string');
  }
}

const browserUseTool = () => defineTool({
  name: 'browser_use',
  description: browserDescription(),
  parameters: {
    tool_title: {
      type: 'string',
      description: 'Short title for this browser action, shown in the UI (e.g. "Open example.com").',
    },
    action: {
      type: 'string',
      required: true,
      enum: BROWSER_ACTIONS,
      description: 'The browser action to perform.',
    },
    url: {
      type: 'string',
      description: 'URL for navigate (scheme optional; https is assumed) or fetch.',
    },
    selector: {
      type: 'string',
      description: 'CSS selector for click, type, hover, find_elements.',
    },
    text: {
      type: 'string',
      description: 'Text to type (type action).',
    },
    coordinate_x: {
      type: 'number',
      description: 'X coordinate in CSS pixels for click (when no selector is given).',
    },
    coordinate_y: {
      type: 'number',
      description: 'Y coordinate in CSS pixels for click (when no selector is given).',
    },
    direction: {
      type: 'string',
      enum: ['up', 'down', 'left', 'right'],
      description: 'Scroll direction (scroll action).',
    },
    amount: {
      type: 'number',
      description: 'Scroll amount in pixels (scroll action).',
    },
    script: {
      type: 'string',
      description: 'JavaScript to run in the page (execute_js action).',
    },
    user_agent: {
      type: 'string',
      description: 'Custom user agent string (set_user_agent action).',
    },
    max_depth: {
      type: 'number',
      description: 'Max scroll depth for scroll_and_collect (number of viewport heights).',
    },
    tab_id: {
      type: 'number',
      description: 'Target tab id (omit for the active tab).',
    },
    full_page: {
      type: 'boolean',
      description: 'Capture the full page, not just the viewport (screenshot action).',
    },
  },
  output: {
    type: 'object',
    additionalProperties: false,
    properties: {
      text: {
        type: 'string',
        required: true,
      },
      success: {
        type: 'boolean',
        required: true,
      },
      base64Image: {
        type: 'string',
        description: 'Base64 JPEG screenshot (screenshot action only).',
      },
      imageFilePath: {
        type: 'string',
        description: 'Local path of the saved screenshot JPEG (screenshot action only).',
      },
      pageURL: {
        type: 'string',
        description: 'URL of the page the action ran on.',
      },
      tabId: {
        type: 'integer',
        description: 'Id of the tab the action ran on.',
      },
    },
    // v1 renders the result as text only. See the header note: whether the
    // engine forwards base64Image as a vision image is unverified, and a
    // guessed image block could break the tool call.
    render: (_args, value) => [{type: 'text', text: value.text}],
    presentationMeta: (_args, value) => ({
      ...(value.pageURL !== undefined ? {pageURL: value.pageURL} : {}),
      ...(value.tabId !== undefined ? {tabId: value.tabId} : {}),
    }),
  },
  async execute(args, exec) {
    validateBrowserArgs(args);
    const bridge = globalThis[BROWSER_BRIDGE_SYMBOL];
    if (!bridge?.execute) {
      throw new Error(
        'browser bridge unavailable: the native browser loopback service is not running '
        + '(browser-service.json missing or the browser was never started). '
        + 'Open the browser page once, or restart the app.',
      );
    }
    if (exec.signal?.aborted) {
      const error = new Error('browser_use aborted');
      error.name = 'AbortError';
      throw error;
    }
    const result = await bridge.execute(args, {
      signal: exec.signal,
      // navigate and full-page screenshots are slow; the bridge's own
      // default is 60s, the Swift side caps navigate at 30s.
      timeoutMs: args.action === 'screenshot' && args.full_page === true ? 120_000 : 60_000,
    });
    if (typeof result !== 'object' || result === null || typeof result.text !== 'string') {
      throw new Error(`browser execute returned an unexpected result: ${JSON.stringify(result)?.slice(0, 200)}`);
    }
    return result;
  },
  presentCall: (args) => {
    const label = args.tool_title ?? `${args.action}${args.url ? ` ${args.url}` : ''}`;
    return {title: 'Browser', detail: label};
  },
  presentResult: (_args, value) => ({
    title: 'Browser',
    detail: value.success ? value.text.slice(0, 200) : `Failed: ${value.text.slice(0, 200)}`,
  }),
});

/**
 * Cordis plugin entry: register the browser_use tool.
 * The engine loads this plugin when cordis.patch.yml lists it:
 *   - id: tool-browser
 *     name: '@dsh-go/dsh-tool-browser'
 */
function apply(ctx) {
  ctx.tools.register(browserUseTool());
  ctx.systemPrompt.section({
    name: 'tool:browser_use',
    order: ctx.systemPrompt.getSectionOrder('TOOL_BROWSER_USE'),
    text: 'When you take a screenshot, describe what you see in it before deciding the next action. Prefer get_readable for article pages and find_elements before clicking an element you have not seen.',
  });
}

export {apply};
