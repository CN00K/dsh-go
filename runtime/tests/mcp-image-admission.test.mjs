// P2 (58z): an image-only MCP result for a text-only model fails outright
// (MODEL_NO_IMAGE_INPUT) instead of projecting a "successful" diagnostic
// string; mixed text+image results keep the old diagnostic projection.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const prefix = resolve(process.env.DSH_PREFIX);
const { createMcpToolDefinition } = await import(pathToFileURL(join(
  prefix, 'node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js')));

const MODEL = 'deepseek-v4.1-flash';
// 1x1 transparent PNG, canonical base64.
const PNG_1X1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const IMAGE = { type: 'image', data: PNG_1X1, mimeType: 'image/png' };
const DEFAULT_DIAGNOSTIC = '[image unavailable: image/png; this result was not admitted to durable model context; raw image data remains available to programmatic callers]';
const ADMISSION_MESSAGE = `model "${MODEL}" does not declare image input; switch to an image-capable model or set this custom model's Input to Text + image`;

function harness(modalities) {
  let saved = 0;
  const ctx = {
    get(name) {
      if (name === 'attachments') {
        return { saveImages: async (decoded) => {
          saved++;
          return decoded.map((_, i) => ({ id: `att-${i}` }));
        } };
      }
      if (name === 'llm') {
        return { resolveModelInfo: async () => ({ inputModalities: modalities }) };
      }
      return undefined;
    },
  };
  const exec = {
    agent: {
      session: { requestHeader: () => ({ config: { provider: 'deepseek', model: MODEL } }) },
      options: {},
    },
    signal: new AbortController().signal,
  };
  return { ctx, exec, savedCalls: () => saved };
}

function definitionFor(ctx, call) {
  return createMcpToolDefinition(ctx, {
    name: 'mcp__browser__screenshot',
    rawName: 'screenshot',
    description: 'screenshot',
    inputSchema: { type: 'object', properties: {} },
    taskRequired: false,
    call,
  });
}

test('P2: image-only result on a text-only model rejects with MODEL_NO_IMAGE_INPUT', async () => {
  const { ctx, exec, savedCalls } = harness(['text']);
  const definition = definitionFor(ctx, async () => ({ content: [IMAGE] }));
  await assert.rejects(definition.execute({}, exec), (error) => {
    assert.equal(error.code, 'MODEL_NO_IMAGE_INPUT');
    assert.match(error.message, /deepseek-v4\.1-flash/);
    assert.match(error.message, /Text \+ image/);
    return true;
  });
  assert.equal(savedCalls(), 0, 'rejected before any image storage');
});

test('P2: mixed text+image result on a text-only model keeps the text and projects the image', async () => {
  const { ctx, exec, savedCalls } = harness(['text']);
  const content = [{ type: 'text', text: 'hello' }, IMAGE];
  const definition = definitionFor(ctx, async () => ({ content }));
  const value = await definition.execute({}, exec);
  assert.deepEqual(value, { content });
  assert.equal(savedCalls(), 0);
  const projected = definition.projectContent(exec, {
    isError: false,
    value,
    content: [{ type: 'text', text: `hello\n${DEFAULT_DIAGNOSTIC}` }],
  });
  assert.deepEqual(projected, [
    { type: 'text', text: 'hello' },
    { type: 'text', text: `[image unavailable: image/png; ${ADMISSION_MESSAGE}; raw image data remains available to programmatic callers]` },
  ]);
});

test('P2: image-only result on an image-capable model still stores and projects', async () => {
  const { ctx, exec, savedCalls } = harness(['text', 'image']);
  const definition = definitionFor(ctx, async () => ({ content: [IMAGE] }));
  const value = await definition.execute({}, exec);
  assert.deepEqual(value, { content: [IMAGE] });
  assert.equal(savedCalls(), 1);
  const projected = definition.projectContent(exec, {
    isError: false,
    value,
    content: [{ type: 'text', text: DEFAULT_DIAGNOSTIC }],
  });
  assert.deepEqual(projected, [{ type: 'image', attachment: { id: 'att-0' } }]);
});
