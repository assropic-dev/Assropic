#!/usr/bin/env node
// Read-only validation against Cursor 3.27.22. Tests extracted native transport
// code from a patched in-memory copy, without editing or launching Cursor.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../Resources/CursorLocal/patches.json'), 'utf8'));
const appRoot = process.argv[2] || '/Applications/Cursor.app/Contents/Resources/app';
let checks = 0;
for (const file of manifest.files.filter(value => value.scope === 'app')) {
  let source = fs.readFileSync(path.join(appRoot, file.name), 'utf8');
  for (const patch of file.patches) {
    if (!source.includes(patch.replace)) {
      for (const previous of patch.previousReplacements ?? []) source = source.replace(previous, patch.replace);
    }
    if (source.includes(patch.replace)) {
      assert.equal(source.split(patch.replace).length - 1, 1, 'exact installed Cursor version entry');
    } else {
      assert.equal(source.split(patch.find).length - 1, 1, 'exact Cursor version entry');
      source = source.replace(patch.find, patch.replace);
    }
  }
  new vm.Script(source, { filename: file.name });
  checks++;
  const patch = file.patches.find(value => value.find.startsWith('configuredEffortValues:'));
  const configuration = new Function('e', 's', 'o', `return ({${patch.replace}})`);
  const metadata = { reasoningEffortValues: ['minimal', 'high', 'ultra'] };
  assert.equal(configuration({}, metadata, metadata).configuredEffortValues, undefined);
  assert.equal(configuration({ customHeaders: { 'X-BridgeDock-Model-Parameters': '0' } }, metadata, metadata).configuredEffortValues, undefined);
  assert.deepEqual(configuration({ customHeaders: { 'X-BridgeDock-Model-Parameters': '1' } }, metadata, metadata).configuredEffortValues, metadata.reasoningEffortValues);
  assert.deepEqual(configuration({ customHeaders: { 'X-BridgeDock-Model-Parameters': '1' } }, {}, {}).configuredEffortValues, ['low', 'medium', 'high', 'xhigh', 'max']);
  checks += 4;
  const entry = file.patches.find(value => value.find.startsWith('async function'));
  const normalize = new Function('e', entry.replace.slice(entry.find.length) + ';return e');
  const parameters = [{ id: 'context', value: '65536' }, { id: 'reasoning', value: 'high' }, { id: 'provider', value: 'account:abc' }, { id: 'speed', value: 'fast' }];
  const inactive = normalize({ customHeaders: { 'X-BridgeDock-Model-Parameters': '0' }, modelParameters: parameters });
  assert.deepEqual(inactive.modelParameters, [{ id: 'speed', value: 'fast' }]);
  assert.equal(normalize({ customHeaders: { 'X-BridgeDock-Model-Parameters': '1' }, modelParameters: parameters }).modelParameters, parameters);
  assert.equal(normalize({ modelParameters: parameters }).modelParameters, parameters);
  const enabledRequest = normalize({ customHeaders: { 'X-BridgeDock-Model-Parameters': '1' }, modelParameters: parameters });
  assert.deepEqual(JSON.parse(decodeURIComponent(enabledRequest.customHeaders['X-BridgeDock-Parameters'])), parameters);
  assert.ok(JSON.parse(decodeURIComponent(enabledRequest.customHeaders['X-BridgeDock-Parameters'])).some(item => item.id === 'provider'));
  assert.equal(inactive.customHeaders['X-BridgeDock-Parameters'], undefined);
  checks += 3;

  const promptStart = source.indexOf('content:"Generate a short, descriptive name for a chat');
  assert.ok(promptStart > 0);
  const promptEnd = source.indexOf('"}', promptStart) + 1;
  const titlePrompt = vm.runInNewContext(source.slice(promptStart + 'content:'.length, promptEnd));
  assert.match(titlePrompt, /same language as the user's message/);
  assert.match(titlePrompt, /Title Case only for English/);
  assert.match(titlePrompt, /\nMessage: 帮我看看登录页为什么一直报错 -> <name>登录页报错排查<\/name>\n/);
  assert.doesNotMatch(titlePrompt, /verb; Title Case;/);
  checks += 4;

  const languagePatch = file.patches.find(value => value.find.startsWith('systemPromptGenerator:'));
  const subagentPatch = file.patches.find(value => value.find.includes('baseSystemPromptGenerator:'));
  assert.ok(languagePatch && subagentPatch);
  const generatorName = languagePatch.find.slice('systemPromptGenerator:'.length, languagePatch.find.indexOf('('));
  const generatorArgs = languagePatch.find.match(/\(e,([a-z]),([a-z])\)/).slice(1);
  const wrapPrompt = (headers, base) => new Function(generatorName, 'e', ...generatorArgs,
    `return ({${languagePatch.replace}0}).systemPromptGenerator`)(() => base, { customHeaders: headers });
  const main = wrapPrompt({ 'X-BridgeDock-Model-Parameters': '0' }, () => 'BASE');
  const mainPrompt = main({}, {});
  assert.match(mainPrompt, /^BASE\n\n<language_preference>\n.*尽可能使用简体中文/s);
  assert.match(mainPrompt, /用户明确要求使用其他语言时，以用户要求为准/);
  assert.equal(main({}, {}).split('<language_preference>').length - 1, 1);
  assert.equal(wrapPrompt(undefined, () => 'BASE')({}, {}), 'BASE');
  const wrappedTwice = wrapPrompt({ 'X-BridgeDock-Model-Parameters': '1' }, () => mainPrompt);
  assert.equal(wrappedTwice({}, {}), mainPrompt);

  const subStart = subagentPatch.replace.indexOf('i=');
  const subExpr = subagentPatch.replace.slice(subStart + 2, subagentPatch.replace.indexOf(',a=t.systemReminder;'));
  const [subArgA, subArgB] = subagentPatch.find.match(/e\.systemPromptGenerator\(([a-z]),([a-z])\)/).slice(1);
  const runSub = (override, generator) => new Function('t', 'e', subArgA, subArgB, 'n', 'r', `return ${subExpr}`)(
    { systemPromptOverride: override }, { systemPromptGenerator: generator }, {}, {}, 'id', 'id');
  const subPrompt = runSub(() => 'SUB', main);
  assert.match(subPrompt, /^SUB\n\n<language_preference>/);
  assert.equal(runSub((a, b, c) => c.baseSystemPromptGenerator(a, b), main), mainPrompt);
  assert.equal(runSub(() => 'SUB', () => 'OFFICIAL'), 'SUB');
  checks += 8;

  // GenerateImage rejects descriptions of <=3 whitespace-separated words, which
  // made any unspaced Chinese prompt count as a single word.
  const wordPatch = file.patches.find(value => /^function \w+\(e\)\{const t=e\.trim\(\)/.test(value.find));
  assert.ok(wordPatch);
  const wordCounter = wordPatch.find.match(/^function (\w+)/)[1];
  const guardStart = source.indexOf(`=function(e,t){const r=${wordCounter}(e)`) + 1 || source.indexOf(`=function(e,t){const n=${wordCounter}(e)`) + 1;
  assert.ok(guardStart > 0);
  const guardEnd = source.indexOf('}', source.indexOf('.some(', guardStart)) + 1;
  const countWords = new Function(`${wordPatch.replace};return ${wordCounter}`)();
  const suspicious = new Function(wordCounter, `return ${source.slice(guardStart, guardEnd)}`)(countWords);
  const keywords = ['ignore', 'skip', 'stop', 'noop'];
  assert.equal(suspicious('一只橘猫坐在窗台上看雨，水彩风格', keywords), false);
  assert.equal(suspicious('赛博朋克城市夜景', keywords), false);
  assert.equal(suspicious('A watercolor cat sitting by a rainy window', keywords), false);
  assert.equal(suspicious('猫', keywords), true);
  assert.equal(suspicious('test image', keywords), true);
  assert.equal(suspicious('skip this one now', keywords), true);
  assert.equal(countWords('   '), 0);
  checks += 7;

  if (file.name.includes('cursor-agent-exec/')) {
    // Run the actual native context-budget expression, including cap handling.
    const budgetStart = source.indexOf('d=function(e){const t=e?.find((e=>e.id===F))');
    assert.ok(budgetStart > 0);
    const budgetEnd = source.indexOf(',m=jze(', budgetStart);
    const budget = new Function('e', 'u', 'F', 'const ' + source.slice(budgetStart, budgetEnd) + ';return p;');
    assert.equal(budget({ modelParameters: parameters }, 128000, 'context'), 65536);
    assert.equal(budget({ modelParameters: [{ id: 'context', value: '200000' }] }, 128000, 'context'), 128000);
    assert.equal(budget({ modelParameters: [{ id: 'context', value: 'auto' }] }, 128000, 'context'), 128000);
    assert.equal(budget({ modelParameters: parameters }, undefined, 'context'), 65536);
    assert.equal(budget(inactive, 128000, 'context'), 128000);
    checks += 5;

    // Execute Cursor's native HTTP payload transformer, so the assertion covers
    // reasoning_effort/reasoning.effort on the wire, not merely picker metadata.
    const anchor = source.indexOf('const a=function(e,t,r,n,s,o,i,a){if("string"!=typeof e?.body)');
    assert.ok(anchor > 0);
    const bodyEnd = source.indexOf('}catch{return e}}', anchor) + '}catch{return e}}'.length;
    const transform = vm.runInNewContext('(' + source.slice(anchor + 'const a='.length, bodyEnd) + ')', {
      DLe: init => JSON.parse(init.body), qLe: (init, body) => ({ ...init, body: JSON.stringify(body) }),
      Dze: value => !!value && typeof value === 'object', I: () => undefined, v: () => undefined
    });
    const makeRequest = () => ({ body: JSON.stringify({ model: '渠道/gpt-test', messages: [{ role: 'user', content: 'test' }] }) });
    const supported = ['low', 'medium', 'high'];
    const chat = JSON.parse(transform(makeRequest(), '渠道/gpt-test', parameters, 'openai_compatible', 'chat_completions', true, undefined, supported).body);
    assert.equal(chat.reasoning_effort, 'high');
    const responses = JSON.parse(transform(makeRequest(), '渠道/gpt-test', parameters, 'openai_compatible', 'responses', true, undefined, supported).body);
    assert.equal(responses.reasoning.effort, 'high');
    assert.equal(responses.reasoning_effort, undefined);
    const disabled = JSON.parse(transform(makeRequest(), '渠道/gpt-test', inactive.modelParameters, 'openai_compatible', 'chat_completions', true, undefined, undefined).body);
    assert.equal(disabled.reasoning_effort, undefined);
    const defaultRequest = JSON.parse(transform(makeRequest(), '渠道/gpt-test', [{ id: 'reasoning', value: 'none' }], 'openai_compatible', 'chat_completions', true, undefined, supported).body);
    assert.equal(defaultRequest.reasoning_effort, undefined);
    checks += 5;
  }
}
console.log(`Cursor native transport: ${checks} exact-version, context-budget, toggle and on-wire reasoning checks passed`);
