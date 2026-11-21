import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Same DSH_PREFIX convention as ptc-wasm-probe.test.mjs; running from the
// port root without it also works.
const ptcLib = join(resolve(process.env.DSH_PREFIX || '.'),
  'node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib');
const indexSrc = readFileSync(join(ptcLib, 'index.js'), 'utf8');

// Harness run in a child node: it extracts the two helper functions from
// the real patched lib/index.js verbatim (brace-matched by the closing
// brace at column 0), builds the three real resolveMode stripTypes shapes
// around the real stripTypeScriptTypes, and runs each case through the
// real stripTypesWithFallback. Nothing here re-implements the fallback.
const HARNESS_LINES = [
  "import { readFileSync } from 'node:fs';",
  "import { stripTypeScriptTypes } from 'node:module';",
  "import { Script } from 'node:vm';",
  'const src = readFileSync(process.argv[2], \'utf8\');',
  'const input = JSON.parse(process.argv[3]);',
  'const prefix = input.prefix;',
  'const suffix = input.suffix;',
  'const cases = input.cases;',
  'function extractFunction(name) {',
  "  const start = src.indexOf('function ' + name + '(');",
  "  if (start < 0) throw new Error('helper not found: ' + name);",
  "  const end = src.indexOf('\\n}\\n', start);",
  "  if (end < 0) throw new Error('helper end not found: ' + name);",
  '  return src.slice(start, end + 3);',
  '}',
  "const helperSrc = extractFunction('stripTypesWithFallback') + '\\n' + extractFunction('isPlainJavaScript');",
  'const warns = [];',
  'const fakeConsole = { warn: function () { warns.push(Array.from(arguments).map(String).join(\' \')); }, log: function () {}, error: function () {} };',
  "const stripTypesWithFallback = new Function('Script', 'console', helperSrc + '\\nreturn stripTypesWithFallback;')(Script, fakeConsole);",
  'function modeFor(format) {',
  "  if (format === 'function-body') {",
  '    return { format: format, stripTypes: function (p) {',
  '      const s = stripTypeScriptTypes(prefix + p + suffix);',
  '      return s.slice(prefix.length, s.length - suffix.length);',
  '    } };',
  '  }',
  '  return { format: format, stripTypes: stripTypeScriptTypes };',
  '}',
  'const results = [];',
  'for (const c of cases) {',
  '  warns.length = 0;',
  '  const mode = modeFor(c.mode);',
  "  if (c.strip === 'fail-other') mode.stripTypes = function () { throw new Error('boom'); };",
  '  try {',
  '    const code = stripTypesWithFallback(mode, c.program);',
  '    results.push({ ok: true, code: code, warns: warns.slice() });',
  '  } catch (error) {',
  '    results.push({ ok: false, errorCode: error.code || null, message: error.message, warns: warns.slice() });',
  '  }',
  '}',
  'console.log(JSON.stringify(results));',
];

function stripPrefix() {
  const match = indexSrc.match(/const STRIP_PREFIX = ("(?:[^"\\]|\\.)*");/);
  assert.ok(match, 'STRIP_PREFIX not found in index.js');
  return JSON.parse(match[1]);
}

function stripSuffix() {
  const match = indexSrc.match(/const STRIP_SUFFIX = ("(?:[^"\\]|\\.)*");/);
  assert.ok(match, 'STRIP_SUFFIX not found in index.js');
  return JSON.parse(match[1]);
}

function runHarness(jitless, cases) {
  const dir = mkdtempSync(join(tmpdir(), 'ptc-strip-'));
  try {
    const harnessPath = join(dir, 'harness.mjs');
    writeFileSync(harnessPath, `${HARNESS_LINES.join('\n')}\n`);
    const args = [...(jitless ? ['--jitless'] : []), harnessPath,
      join(ptcLib, 'index.js'),
      JSON.stringify({ prefix: stripPrefix(), suffix: stripSuffix(), cases })];
    const run = spawnSync(process.execPath, args, { encoding: 'utf8' });
    assert.equal(run.status, 0, `harness failed: ${run.stderr}`);
    // Node itself warns that stripTypeScriptTypes is experimental on stderr;
    // that is not harness output. Anything else on stderr fails the test.
    const unexpectedStderr = run.stderr.split('\n').filter((line) =>
      line.length > 0
      && !line.includes('ExperimentalWarning: stripTypeScriptTypes is an experimental feature')
      && !line.includes('Use `node --trace-warnings')).join('\n');
    assert.equal(unexpectedStderr, '', `harness wrote to stderr: ${run.stderr}`);
    return JSON.parse(run.stdout.trim());
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('P1 strip fallback: the single strip call site goes through the helper, 52z probes intact', () => {
  assert.ok(indexSrc.includes('evaluation.data.code = stripTypesWithFallback(this.mode, spec.program);'),
    'call site must use stripTypesWithFallback');
  assert.equal(indexSrc.includes('evaluation.data.code = this.mode.stripTypes(spec.program);'),
    false, 'old direct stripTypes call must be gone');
  assert.ok(indexSrc.includes('function stripTypesWithFallback(mode, program) {'), 'helper missing');
  assert.ok(indexSrc.includes('function isPlainJavaScript(program) {'), 'plain-JS check missing');
  assert.ok(indexSrc.includes('import { Script } from "node:vm";'), 'Script import missing');
  assert.equal(indexSrc.match(/\[ptc-wasm-probe\]/g).length, 2,
    'index.js must keep exactly the 2 wave-2 probes');
  for (const file of ['process.js', 'persistent-process.js']) {
    const src = readFileSync(join(ptcLib, file), 'utf8');
    assert.ok(src.includes('[ptc-wasm-probe] createScriptContext'),
      `${file}: context probe must be untouched`);
  }
});

test('P1 strip fallback: only ERR_WEBASSEMBLY_NOT_SUPPORTED is caught; annotated programs get a named error', () => {
  assert.ok(indexSrc.includes('if (error?.code !== "ERR_WEBASSEMBLY_NOT_SUPPORTED") throw error;'),
    'fallback must catch only ERR_WEBASSEMBLY_NOT_SUPPORTED');
  assert.ok(indexSrc.includes('failure.code = "PTC_TYPESCRIPT_REQUIRES_WASM";'),
    'annotated-program error must carry PTC_TYPESCRIPT_REQUIRES_WASM');
  assert.ok(indexSrc.includes('console.warn(`[ptc-strip-no-wasm]'),
    'fallback must warn with the [ptc-strip-no-wasm] marker');
  assert.ok(indexSrc.includes('() => new Script(program),'), 'script-form attempt missing');
  assert.ok(indexSrc.includes('() => new Function(program),'), 'function-body attempt missing');
  assert.ok(indexSrc.includes('() => new Function(`return (async () => {'),
    'async-wrapper attempt missing');
  // The fallback returns the raw program; the per-call strip path returns
  // the same text (STRIP_PREFIX is 35 chars, STRIP_SUFFIX is 2), so the
  // two agree exactly for pure-JS programs.
  assert.equal(stripPrefix(), 'async function __dsh_program__() {\n');
  assert.equal(stripPrefix().length, 35, 'slice(35, -2) must remove exactly STRIP_PREFIX');
  assert.equal(stripSuffix(), '\n}');
  assert.equal(stripSuffix().length, 2, 'slice(35, -2) must remove exactly STRIP_SUFFIX');
});

test('P1 strip fallback: --jitless pure-JS programs pass through unchanged in all three modes', () => {
  const cases = [
    { mode: 'function-body', program: 'return { ok: true };' },
    { mode: 'function-body', program: 'const x = await Promise.resolve(1);\nreturn x;' },
    { mode: 'repl', program: 'const x = 1;\nawait Promise.resolve(x);' },
    { mode: 'script', program: 'const x = 1;\nconsole.log(x);' },
  ];
  const results = runHarness(true, cases);
  assert.equal(results.length, cases.length);
  results.forEach((result, i) => {
    assert.equal(result.ok, true, `case ${i} (${cases[i].mode}) must pass through: ${JSON.stringify(result)}`);
    assert.equal(result.code, cases[i].program, `case ${i}: fallback must return the program unchanged`);
    assert.equal(result.warns.length, 1, `case ${i}: exactly one fallback warn`);
    assert.match(result.warns[0], /\[ptc-strip-no-wasm\]/, `case ${i}: warn marker`);
    assert.match(result.warns[0], new RegExp(`mode=${cases[i].mode}`), `case ${i}: warn names the mode`);
  });
});

test('P1 strip fallback: --jitless annotated programs get PTC_TYPESCRIPT_REQUIRES_WASM, not a SyntaxError', () => {
  const cases = [
    { mode: 'function-body', program: 'const x: number = 1;\nreturn x;' },
    { mode: 'script', program: 'const x: number = 1;' },
  ];
  const results = runHarness(true, cases);
  results.forEach((result, i) => {
    assert.equal(result.ok, false, `case ${i} must fail`);
    assert.equal(result.errorCode, 'PTC_TYPESCRIPT_REQUIRES_WASM', `case ${i}: error code`);
    assert.match(result.message, /--jitless/, `case ${i}: message names --jitless`);
    assert.match(result.message, /plain JavaScript/, `case ${i}: message tells the user to retry in plain JS`);
    assert.doesNotMatch(result.message, /SyntaxError/, `case ${i}: must not surface a misleading SyntaxError`);
    assert.equal(result.warns.length, 0, `case ${i}: no fallback warn on failure`);
  });
});

test('P1 strip fallback: a non-WASM strip error is rethrown unchanged', () => {
  const [result] = runHarness(true, [
    { mode: 'script', program: 'const x = 1;', strip: 'fail-other' },
  ]);
  assert.equal(result.ok, false, 'fail-other strip error must propagate');
  assert.equal(result.errorCode, null, 'fail-other error must not gain the WASM code');
  assert.equal(result.message, 'boom', 'fail-other error message must be unchanged');
  assert.equal(result.warns.length, 0, 'fail-other must not warn');
});

test('P1 strip fallback: with WASM, normal stripping is unchanged and silent', () => {
  const cases = [
    { mode: 'function-body', program: 'const x: number = 1;\nreturn x;' },
    { mode: 'script', program: 'const x: number = 1;' },
    { mode: 'function-body', program: 'return { ok: true };' },
    { mode: 'repl', program: 'const x = 1;' },
  ];
  const results = runHarness(false, cases);
  assert.equal(results[0].ok, true);
  // Amaro blanks annotations position-preservingly (": number" -> spaces),
  // it does not delete them; pure-JS programs are the identity case.
  assert.equal(results[0].code, 'const x         = 1;\nreturn x;');
  assert.equal(results[1].ok, true);
  assert.equal(results[1].code, 'const x         = 1;');
  assert.equal(results[2].code, 'return { ok: true };');
  assert.equal(results[3].code, 'const x = 1;');
  results.forEach((result, i) => {
    assert.equal(result.warns.length, 0, `case ${i}: no warn when WASM strips normally`);
  });
});
