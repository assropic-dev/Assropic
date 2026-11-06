#!/usr/bin/env node
// Run with: node Tests/CursorRuntimeTests.js
// No Cursor process, account, network connection, or user files are modified.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../Resources/CursorLocal/runtime.js"), "utf8")
  .replaceAll("__BD_SESSION_PORT__", "18418")
  .replaceAll("__BD_SESSION_SECRET__", JSON.stringify("test-session-secret"));
const snapshotKey = "bridgedock/officialModelState/v1";
const clone = value => JSON.parse(JSON.stringify(value));
const session = {
  id: "local-test", token: "local-test-token", name: "BridgeDock test",
  baseURL: "http://127.0.0.1:18417/v1", gatewayURL: "http://127.0.0.1:18418",
  key: "test-key", model: "bd-model"
};

function runtime(localSession, document) {
  const context = vm.createContext({
    console: { info() {} },
    document,
    XMLHttpRequest: class {
      open(method, url, async) {
        assert.equal(method, "GET");
        assert.equal(url, "http://127.0.0.1:18418/session");
        assert.equal(async, false);
      }
      setRequestHeader(name, value) {
        assert.equal(name, "X-BridgeDock-Session");
        assert.equal(value, "test-session-secret");
      }
      send() {
        this.status = localSession ? 200 : 403;
        this.responseText = JSON.stringify(localSession);
      }
    }
  });
  vm.runInContext(source, context);
  return context;
}

// The same native menu is used with either official experiments or local parameters.
assert.equal(runtime(undefined).__bridgeDockParameterMenu(true), true);
assert.equal(runtime(undefined).__bridgeDockParameterMenu(false), false);
assert.equal(runtime({ ...session, modelParametersEnabled: true }).__bridgeDockParameterMenu(false), true);
assert.equal(runtime({ ...session, modelParametersEnabled: false }).__bridgeDockParameterMenu(true), false);

{
  const ctx = runtime({ ...session, modelParametersEnabled: true });
  const definitions = [{ id: 'reasoning', name: 'Effort', parameterType: { enumParameter: {
    values: [{ value: 'low', displayName: 'Low' }, { value: 'max', displayName: 'Max' }]
  } } }, { id: 'fast', name: 'Fast', parameterType: { booleanParameter: {
    values: [{ value: 'false' }, { value: 'true', displayName: 'Fast' }]
  } } }];
  const variants = [{ parameterValues: [{ id: 'reasoning', value: 'max' }, { id: 'fast', value: 'true' }], isDefaultNonMaxConfig: true }];
  const rows = ctx.__bridgeDockEnrichModels([{ name: 'Cursor/test' }], [{ id: 'Cursor/test',
    bridgedock_parameters: { version: 1, definitions, variants } }]);
  assert.deepEqual(clone(rows[0].parameterDefinitions.map(item => item.name)), ['思考强度', '快速模式']);
  assert.deepEqual(clone(rows[0].parameterDefinitions[0].parameterType.enumParameter.values.map(item => item.displayName)), ['Low', 'Max'],
    '保留 Cursor 官方档位名');
  assert.deepEqual(clone(rows[0].variants[0].parameterValues), variants[0].parameterValues);
  assert.equal(rows[0].variants[0].displayNameOutsidePicker, 'Cursor/test Max 快速');
  const [tooltip] = ctx.__bridgeDockEnrichModels([{ name: 'test', tagline: 'Local provider model', tooltipData: {
    markdownContent: 'Discovered from your local provider.\n\nContext: 1,048,576 tokens.\n\nMax output: 64,000 tokens.\n\nReasoning: supported.\n\nVision: supported.'
  } }], []);
  assert.equal(tooltip.tagline, '本地供应商模型');
  assert.equal(tooltip.tooltipData.markdownContent, '来自本地供应商。\n\n上下文：1,048,576 词元。\n\n最大输出：64,000 词元。\n\n支持思考。\n\n支持图片输入。');
}

// version 2：供应商作为参数排在 Effort 后面；每个供应商都覆盖全部档位，缺的档位按 effective 标注。
{
  const ctx = runtime({ ...session, modelParametersEnabled: true });
  const values = (...ids) => ids.map(id => ({ id, label: id }));
  const entry = { id: 'claude-opus-5.5', bridgedock_parameters: { version: 2,
    definitions: [
      { id: 'fast', name: 'Fast', values: values('false', 'true') },
      { id: 'context', name: '上下文', values: values('300000', '1000000') },
      { id: 'reasoning', name: '思考强度', values: values('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max') },
      { id: 'provider', name: '供应商', values: [{ id: 'account:a', label: 'Cursor 账号' }, { id: 'kiro:b', label: 'Kiro' }] }
    ],
    providers: [
      { id: 'account:a', name: 'Cursor 账号', context_length: 1000000,
        fast: true, context_options: [300000, 1000000],
        reasoning_effort: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'], reasoning_default: 'medium' },
      { id: 'kiro:b', name: 'Kiro', context_length: 300000, reasoning_effort: ['low', 'high'],
        effective: { reasoning: { minimal: 'low', medium: 'low', xhigh: 'high', max: 'high' },
          context: { '1000000': '' }, fast: { true: 'false' } } }
    ] } };
  const [row] = ctx.__bridgeDockEnrichModels([{ name: 'claude-opus-5.5' }], [entry]);
  assert.deepEqual(clone(row.parameterDefinitions.map(item => item.id)), ['fast', 'context', 'reasoning', 'provider']);
  const labels = id => clone(row.parameterDefinitions.find(item => item.id === id).parameterType.enumParameter.values.map(item => item.displayName));
  assert.deepEqual(labels('reasoning'), ['默认', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'], '没有官方名称时显示档位原名');
  assert.deepEqual(clone(row.parameterDefinitions.map(item => item.name)), ['快速模式', '上下文', '思考强度', '供应商']);
  assert.deepEqual(labels('context'), ['300K', '1M']);
  assert.deepEqual(labels('provider'), ['Cursor 账号', 'Kiro']);
  const of = (variant, id) => variant.parameterValues.find(item => item.id === id)?.value;
  const kiro = row.variants.filter(variant => of(variant, 'provider') === 'kiro:b');
  assert.deepEqual([...new Set(kiro.map(variant => of(variant, 'context')))].sort(), ['1000000', '300000'],
    'Kiro 也提供其他供应商的上下文档位，选中时不会换供应商');
  assert.deepEqual([...new Set(kiro.map(variant => of(variant, 'reasoning')))].sort(),
    ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].sort(), 'Kiro 覆盖全部思考档位');
  assert.deepEqual([...new Set(kiro.map(variant => of(variant, 'fast')))].sort(), ['false', 'true']);
  assert.equal(kiro.length, 2 * 7 * 2);
  assert.equal(row.variants.length, 2 * (2 * 7 * 2));
  const kiroMax = kiro.find(variant => of(variant, 'reasoning') === 'max' && of(variant, 'context') === '1000000' && of(variant, 'fast') === 'true');
  assert.equal(kiroMax.displayName, 'Kiro-Opus-5.5', '选择器内按所选供应商显示规范名称');
  assert.equal(kiroMax.displayNameOutsidePicker, 'claude-opus-5.5 max 快速（按 high，上下文按默认，按标准速度）',
    '名称里写明该供应商实际按哪档');
  assert.equal(kiro.find(variant => of(variant, 'reasoning') === 'high' && of(variant, 'context') === '300000'
    && of(variant, 'fast') === 'false').displayNameOutsidePicker, 'claude-opus-5.5 high', '本来就支持的档位不加注');
  assert.equal(row.variants.find(variant => of(variant, 'provider') === 'account:a').displayName, 'Cursor-账号-Opus-5.5');
  const kiroDefault = kiro.find(variant => variant.parameterValues.length && of(variant, 'context') === '300000'
    && of(variant, 'reasoning') === 'low' && of(variant, 'fast') === 'false');
  assert.ok(kiroDefault, 'Kiro 的默认组合取它自己的上下文和思考档位');
  const defaults = row.variants.filter(variant => variant.isDefaultNonMaxConfig);
  assert.equal(defaults.length, 1);
  assert.deepEqual(clone(defaults[0].parameterValues), [{ id: 'fast', value: 'false' }, { id: 'context', value: '1000000' },
    { id: 'reasoning', value: 'medium' }, { id: 'provider', value: 'account:a' }]);
  assert.equal(defaults[0].displayNameOutsidePicker, 'claude-opus-5.5 medium');
  const fastMax = row.variants.find(variant => of(variant, 'fast') === 'true' && of(variant, 'reasoning') === 'max');
  assert.equal(fastMax.displayNameOutsidePicker, 'claude-opus-5.5 max 快速');
  assert.equal(row.variants.find(variant => of(variant, 'reasoning') === 'none').displayNameOutsidePicker, 'claude-opus-5.5');

  // 只声明供应商时只出现供应商参数，不猜测 Fast/Context/Effort。
  const [bare] = ctx.__bridgeDockEnrichModels([{ name: 'kimi-k3' }], [{ id: 'kimi-k3', bridgedock_parameters: { version: 2,
    definitions: [{ id: 'provider', name: '供应商', values: [{ id: 'p1', label: 'P1' }] }], providers: [{ id: 'p1', name: 'P1' }] } }]);
  assert.deepEqual(clone(bare.parameterDefinitions.map(item => item.id)), ['provider']);
  assert.deepEqual(clone(bare.variants.map(variant => variant.parameterValues)), [[{ id: 'provider', value: 'p1' }]]);
  assert.equal(bare.variants[0].isDefaultNonMaxConfig, true);
}

// Picker labels are provider-model-version names while routing IDs and the
// outside-picker trigger remain the original model IDs.
{
  const ctx = runtime({ ...session, modelParametersEnabled: true });
  const providerOnly = (id, ownedBy, providers) => ({ id, owned_by: ownedBy,
    bridgedock_parameters: { version: 2, definitions: [{ id: 'provider', name: '供应商',
      values: providers.map(provider => ({ id: provider.id, label: provider.name })) }], providers } });
  const catalog = [
    providerOnly('claude-opus-5-5', 'Kiro', [
      { id: 'provider:kiro', name: 'Kiro' }, { id: 'provider:anthropic', name: 'Claude' }
    ]),
    providerOnly('k3.1-pro', 'Kimi Code 国内', [
      { id: 'channel:kimi', name: 'Kimi Code 国内' }
    ])
  ];
  const rows = ctx.__bridgeDockEnrichModels(catalog.map(entry => ({ name: entry.id })), catalog);
  const opus = rows.find(row => row.name === 'claude-opus-5-5');
  const kimi = rows.find(row => row.name === 'k3.1-pro');
  const byProvider = (row, value) => row.variants.find(variant =>
    variant.parameterValues.some(parameter => parameter.id === 'provider' && parameter.value === value));
  assert.equal(byProvider(opus, 'provider:kiro').displayName, 'Kiro-Opus-5.5');
  assert.equal(byProvider(opus, 'provider:anthropic').displayName, 'Claude-Opus-5.5');
  assert.equal(kimi.variants[0].displayName, 'Kimi-K3.1-Pro');
  assert.equal(byProvider(opus, 'provider:kiro').displayNameOutsidePicker, 'claude-opus-5-5');
  assert.equal(opus.clientDisplayName, 'claude-opus-5-5');
}

// Preserve provider-specific budgets and exact Cursor combinations across refreshes.
{
  const ctx = runtime({ ...session, modelParametersEnabled: true });
  const params = values => Object.entries(values).map(([id, value]) => ({ id, value }));
  const entry = { id: 'claude-opus-5-5', bridgedock_parameters: { version: 2,
    definitions: [
      { id: 'context', values: ['200000', '262144', '524288', '1000000'].map(id => ({ id })) },
      { id: 'reasoning', values: ['low', 'high'].map(id => ({ id })) },
      { id: 'fast', values: ['false', 'true'].map(id => ({ id })) },
      { id: 'provider', values: ['cursor', 'kiro', 'work'].map(id => ({ id, label: id })) }
    ], providers: [
      { id: 'cursor', context_length: 1000000, context_options: [1000000], fast: true, reasoning_effort: ['low', 'high'], variants: [
        { parameterValues: params({ context: '1000000', reasoning: 'low', fast: 'false' }), isDefaultNonMaxConfig: true },
        { parameterValues: params({ context: '1000000', reasoning: 'high', fast: 'true' }) }
      ] },
      { id: 'kiro', context_length: 200000, context_options: [200000] },
      { id: 'work', context_length: 1000000, context_options: [262144, 1000000], context_default: 262144,
        fast: true, fast_default: true, reasoning_effort: ['high'], reasoning_default: 'high' }
    ] } };
  const [row] = ctx.__bridgeDockEnrichModels([{ name: entry.id }], [entry]);
  const variants = id => row.variants.filter(variant => variant.parameterValues.some(p => p.id === 'provider' && p.value === id));
  assert.equal(variants('cursor').length, 4 * 2 * 2, 'Cursor 缺的组合也留在 Cursor，由网关取最接近的一组');
  assert.deepEqual(clone(variants('cursor')[0].parameterValues), params({ context: '1000000', reasoning: 'low', fast: 'false', provider: 'cursor' }),
    'Cursor 列出的默认组合仍是默认');
  assert.equal(variants('kiro').length, 4 * 2 * 2, '不支持思考的供应商也覆盖全部档位');
  assert.deepEqual(clone(variants('work')[0].parameterValues), params({ fast: 'true', context: '262144', reasoning: 'high', provider: 'work' }));
  ctx.testRow = row;
  const restored = vm.runInContext('selectedParameters(testRow, [{id:"provider",value:"kiro"},{id:"context",value:"1000000"},{id:"reasoning",value:"high"}])', ctx);
  assert.deepEqual(clone(restored), params({ fast: 'false', context: '1000000', reasoning: 'high', provider: 'kiro' }),
    '刷新时保留 Kiro 和所选档位，实际生效值由网关换算');
}

function makeService(initial, storage = new Map()) {
  const state = clone(initial);
  const service = {
    _storageService: {
      get(key) { return storage.get(key); },
      store(key, value) { storage.set(key, value); },
      remove(key) { storage.delete(key); }
    },
    _reactiveStorageService: {
      applicationUserPersistentStorage: state,
      setApplicationUserPersistentStorage(...parts) {
        const value = parts.pop();
        const key = parts.pop();
        let parent = state;
        for (const part of parts) parent = parent[part] ??= {};
        parent[key] = value;
      }
    },
    async fetchLocalProviderModelEnrichment() {
      return { pickerModels: [{ name: "bd-model" }], allProviderModelIds: ["bd-model"] };
    },
    deserializePickerModels(rows) { return rows; },
    withLocalPickerSection(row) { return { ...row, local: true }; },
    persistAvailableDefaultModels() { throw new Error("Do not clear Cursor catalog caches"); },
    _modelConfigService: {
      triggerParameterizedModelConfigMigration() {
        state.aiSettings.modelVisibilityMigrated = true;
        state.aiSettings.modelOverrideDisabled = [];
      },
      getStoredModelConfig() { return state.aiSettings.modelConfig.composer; },
      setModelConfig(feature, value) {
        state.aiSettings.modelConfig[feature] = value;
        state.aiSettings.modelParameterPreferences = {};
        state.aiSettings.previousModelBeforeDefault = {};
        state.aiSettings.modelOverrideEnabled.push(value.modelName);
      }
    },
    _aiSettingsService: { handleAvailableModelsChange() {} }
  };
  return { service, state, storage };
}

const original = {
  availableDefaultModels2: [{ name: "official-model" }],
  localProviderModelIds: ["existing-provider"],
  localProviderAgentModelIds: ["existing-agent"],
  aiSettings: {
    modelConfig: {
      composer: { modelName: "official-model", maxMode: true, selectedModels: [{ modelId: "official-model" }] },
      "background-composer": { modelName: "official-cloud-model" }
    },
    modelOverrideEnabled: ["official-model"],
    modelOverrideDisabled: ["another-model"],
    modelVisibilityMigrated: false,
    previousModelBeforeDefault: { composer: "previous-model" },
    modelParameterPreferences: { "official-model": { parameters: [{ id: "effort", value: "high" }] } },
    unrelatedPreference: "keep-this"
  },
  cursorCreds: { backendUrl: "https://official.test", websiteUrl: "https://website.test" },
  authAccessToken: "official-test-token"
};

(async () => {
  const local = runtime(session);
  const official = runtime(null);

  // Save once across refreshes/windows, then restore exact model state. Other
  // preferences edited while in local mode and official credentials survive.
  {
    const { service, state, storage } = makeService(original);
    await local.__bridgeDockRefreshModels(service, row => row);
    const firstSnapshot = storage.get(snapshotKey);
    assert.ok(firstSnapshot);
    assert.equal(firstSnapshot.includes("official-test-token"), false);
    assert.equal(firstSnapshot.includes("official.test"), false);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "bd-model");
    assert.deepEqual(state.localProviderModelIds, ["bd-model"]);
    local.__bridgeDockRestoreModels(service);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "bd-model");
    await runtime(session).__bridgeDockRefreshModels(service, row => row);
    assert.equal(storage.get(snapshotKey), firstSnapshot);
    state.aiSettings.unrelatedPreference = "changed-in-local-mode";
    official.__bridgeDockRestoreModels(service);
    const expected = clone(original);
    expected.aiSettings.unrelatedPreference = "changed-in-local-mode";
    assert.deepEqual(clone(state), expected);
    assert.equal(storage.has(snapshotKey), false);
    official.__bridgeDockRestoreModels(service); // Repeated official refresh is a no-op.
    assert.deepEqual(clone(state), expected);
  }

  // Properties absent before local mode are cleared, rather than left behind.
  {
    const initial = clone(original);
    delete initial.localProviderModelIds;
    delete initial.localProviderAgentModelIds;
    delete initial.aiSettings.modelVisibilityMigrated;
    const { service, state } = makeService(initial);
    await local.__bridgeDockRefreshModels(service, row => row);
    official.__bridgeDockRestoreModels(service);
    assert.deepEqual(clone(state), initial);
  }

  // A failed provider fetch does not change the model catalog or overwrite the
  // snapshot. The next official launch can still complete restoration.
  {
    const { service, state, storage } = makeService(original);
    service.fetchLocalProviderModelEnrichment = async () => { throw new Error("provider unavailable"); };
    await assert.rejects(local.__bridgeDockRefreshModels(service, row => row), /provider unavailable/);
    assert.deepEqual(clone(state), original);
    assert.ok(storage.has(snapshotKey));
    official.__bridgeDockRestoreModels(service);
    assert.equal(storage.has(snapshotKey), false);
  }

  // Never replace an invalid backup with local state or apply arbitrary paths.
  {
    const storage = new Map([[snapshotKey, JSON.stringify({ version: 1, values: [] })]]);
    const { service, state } = makeService(original, storage);
    await assert.rejects(local.__bridgeDockRefreshModels(service, row => row), /snapshot is invalid/);
    assert.throws(() => official.__bridgeDockRestoreModels(service), /snapshot is invalid/);
    assert.deepEqual(clone(state), original);
    assert.equal(storage.get(snapshotKey), JSON.stringify({ version: 1, values: [] }));
  }

  // A partial storage failure retains the backup; a later launch retries it.
  {
    const { service, state, storage } = makeService(original);
    await local.__bridgeDockRefreshModels(service, row => row);
    const setter = service._reactiveStorageService.setApplicationUserPersistentStorage;
    let writes = 0;
    service._reactiveStorageService.setApplicationUserPersistentStorage = (...args) => {
      if (++writes === 3) throw new Error("storage unavailable");
      setter(...args);
    };
    assert.throws(() => official.__bridgeDockRestoreModels(service), /storage unavailable/);
    assert.ok(storage.has(snapshotKey));
    service._reactiveStorageService.setApplicationUserPersistentStorage = setter;
    official.__bridgeDockRestoreModels(service);
    assert.deepEqual(clone(state), original);
    assert.equal(storage.has(snapshotKey), false);
  }

  // Routing copies credential configuration instead of modifying its source.
  {
    const credentials = { ...original.cursorCreds, localLoopInferenceUrl: "old-loopback" };
    const routed = local.__bridgeDockCredentials(credentials);
    assert.equal(routed.backendUrl, session.gatewayURL);
    assert.equal(routed.websiteUrl, credentials.websiteUrl);
    assert.equal(routed.localLoopInferenceUrl, "");
    assert.equal(credentials.backendUrl, "https://official.test");
    assert.equal(credentials.localLoopInferenceUrl, "old-loopback");
  }

  // Choices come from each model's published capabilities: the real window is the
  // default context, smaller budgets sit below it, and only listed efforts appear.
  {
    const ctx = runtime({ ...session, modelParametersEnabled: true });
    const rows = ctx.__bridgeDockEnrichModels([{ name: "bd-model" }], [{
      id: "bd-model", capabilities: { context_length: 100000, reasoning_effort: ["minimal", "high", "ultra"] }
    }]);
    const definitions = rows[0].parameterDefinitions;
    const reasoning = definitions.find(item => item.id === "reasoning");
    assert.deepEqual(clone(reasoning.parameterType.enumParameter.values.map(item => item.value)), ["none", "minimal", "high", "ultra"]);
    const sizes = definitions.find(item => item.id === "context").parameterType.enumParameter.values.map(item => item.value);
    assert.equal(sizes.at(-1), "100000");
    assert.ok(!sizes.includes("auto") && sizes.every(item => Number(item) <= 100000));
    assert.equal(rows[0].contextTokenLimit, 100000);
    assert.equal(rows[0].supportsThinking, true);
    assert.ok(rows[0].variants.some(item => item.parameterValues.some(param => param.value === "ultra")));
    const defaults = rows[0].variants.filter(item => item.isDefaultNonMaxConfig);
    assert.equal(defaults.length, 1);
    assert.deepEqual(clone(defaults[0].parameterValues), [{ id: "context", value: "100000" }, { id: "reasoning", value: "none" }]);
    const cursor = ctx.__bridgeDockEnrichModels([{ name: "cursor/gpt-medium" }], [{
      id: "cursor/gpt-medium", capabilities: { context_length: 272000,
        reasoning_effort: ["low", "medium", "high", "max"], reasoning_default: "medium" }
    }]);
    const cursorDefault = cursor[0].variants.find(item => item.isDefaultNonMaxConfig);
    assert.equal(cursorDefault.parameterValues.find(item => item.id === "reasoning").value, "medium");
    assert.equal(cursor[0].parameterDefinitions.find(item => item.id === "reasoning")
      .parameterType.enumParameter.values.find(item => item.value === "none").displayName, "默认");
    assert.equal(cursorDefault.displayNameOutsidePicker, "cursor/gpt-medium medium");
    assert.ok(cursor[0].variants.some(item => item.parameterValues.some(param => param.id === "reasoning" && param.value === "max")));
    const kimi = ctx.__bridgeDockEnrichModels([{ name: "kimi/k3" }], [{ id: "kimi/k3", context_length: 1048576,
      capabilities: { context_length: 1048576, reasoning_effort: ["low", "high", "max"] } }]);
    assert.deepEqual(clone(kimi[0].parameterDefinitions.find(item => item.id === "context").parameterType.enumParameter.values.map(item => item.displayName)),
      ["200K", "256K", "512K", "1M"]);
    // Unknown windows publish no limit and no invented choices; no efforts means no thinking.
    const unknown = ctx.__bridgeDockEnrichModels([{ name: "unknown-model" }], []);
    assert.deepEqual(clone(unknown[0].parameterDefinitions), []);
    assert.equal(unknown[0].contextTokenLimit, undefined);
    assert.equal(unknown[0].supportsThinking, false);
    const plain = ctx.__bridgeDockEnrichModels([{ name: "plain" }], [{ id: "plain", capabilities: { context_length: 200000 } }]);
    assert.deepEqual(clone(plain[0].parameterDefinitions.map(item => item.id)), ["context"]);
    // The real window is published to Cursor even when parameter editing is off.
    const off = local.__bridgeDockEnrichModels([{ name: "bd-model" }], [{ id: "bd-model", capabilities: { context_length: 100000 } }]);
    assert.equal(off[0].contextTokenLimit, 100000);
    assert.equal(ctx.__bridgeDockParameterHeaders()["X-BridgeDock-Model-Parameters"], "1");
    assert.equal(local.__bridgeDockParameterHeaders()["X-BridgeDock-Model-Parameters"], "0");
    const unchanged = [{ name: "bd-model", parameterDefinitions: [] }];
    const named = local.__bridgeDockEnrichModels(unchanged, []);
    assert.equal(named[0].clientDisplayName, "bd-model");
    assert.deepEqual(clone(named[0].parameterDefinitions), []);
    const aliased = ctx.__bridgeDockEnrichModels([{ name: "渠道前四/gpt-6", clientDisplayName: "GPT-6", inputboxShortModelName: "GPT" }], []);
    assert.equal(aliased[0].clientDisplayName, "渠道前四/gpt-6");
    assert.equal(aliased[0].inputboxShortModelName, "渠道前四/gpt-6");
    assert.ok(aliased[0].variants.every(variant => variant.displayName === "渠道前四-GPT-6" && variant.displayNameOutsidePicker === "渠道前四/gpt-6"));
  }

  // Native choices survive refresh, switch-off and switch-on. Official model
  // settings remain independent, including their original parameter values.
  {
    const ctx = runtime({ ...session, modelParametersEnabled: true });
    const { service, state } = makeService(original);
    const name = 'claude-opus-5-5';
    service.fetchLocalProviderModelEnrichment = async () => ({ pickerModels: [{ name }], allProviderModelIds: [name],
      providerModelCatalog: [{ id: name, bridgedock_parameters: { version: 2,
        definitions: [
          { id: 'context', values: ['200000', '1000000'].map(id => ({ id })) },
          { id: 'provider', values: ['claude', 'kiro'].map(id => ({ id, label: id })) }
        ], providers: [{ id: 'claude', context_length: 1000000 }, { id: 'kiro', context_length: 200000 }]
      } }]
    });
    await ctx.__bridgeDockRefreshModels(service, row => row);
    state.aiSettings.modelConfig.composer = { modelName: 'claude-opus-5.5', selectedModels: [{ modelId: 'claude-opus-5.5',
      parameters: [{ id: 'context', value: '1000000' }, { id: 'provider', value: 'kiro' }] }] };
    await ctx.__bridgeDockRefreshModels(service, row => row);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, name, '旧点号名称迁移到统一模型入口');
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels[0].parameters),
      [{ id: 'context', value: '1000000' }, { id: 'provider', value: 'kiro' }], '迁移保留原供应商和所选预算，超出部分由网关换算');
  }

  {
    const enabled = runtime({ ...session, modelParametersEnabled: true });
    const { service, state, storage } = makeService(original);
    service.fetchLocalProviderModelEnrichment = async () => ({
      pickerModels: [{ name: "bd-model" }], allProviderModelIds: ["bd-model"],
      providerModelCatalog: [{ id: "bd-model", capabilities: { context_length: 128000, reasoning_effort: ["low", "high"] } }]
    });
    await enabled.__bridgeDockRefreshModels(service, row => row);
    const parameters = [{ id: "context", value: "65536" }, { id: "reasoning", value: "high" }];
    state.aiSettings.modelConfig.composer.selectedModels[0].parameters = clone(parameters);
    state.aiSettings.modelParameterPreferences = { "bd-model": { parameters: clone(parameters) } };
    await enabled.__bridgeDockRefreshModels(service, row => row);
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels[0].parameters), parameters);
    await local.__bridgeDockRefreshModels(service, row => row);
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels[0].parameters), []);
    assert.equal(storage.get("bridgedock/localModelParametersActive/v1"), "false");
    await enabled.__bridgeDockRefreshModels(service, row => row);
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels[0].parameters), parameters);
    official.__bridgeDockRestoreModels(service);
    assert.deepEqual(clone(state), original);
    await enabled.__bridgeDockRefreshModels(service, row => row);
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels[0].parameters), parameters);
  }

  // While parameter editing is disabled, changing the selected model must
  // survive catalog refreshes and re-enabling parameter controls.
  {
    const enabled = runtime({ ...session, modelParametersEnabled: true });
    const { service, state } = makeService(original);
    service.fetchLocalProviderModelEnrichment = async () => ({
      pickerModels: [{ name: "bd-model" }, { name: "second-model" }],
      allProviderModelIds: ["bd-model", "second-model"]
    });
    await enabled.__bridgeDockRefreshModels(service, row => row);
    await local.__bridgeDockRefreshModels(service, row => row);
    state.aiSettings.modelConfig.composer = { modelName: "second-model", selectedModels: [{ modelId: "second-model", parameters: [] }] };
    await local.__bridgeDockRefreshModels(service, row => row);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "second-model");
    await enabled.__bridgeDockRefreshModels(service, row => row);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "second-model");
  }

  // The existing native Edit button is visible without hover only in BD
  // parameter mode; no account or permission gate is changed.
  {
    function fakeDocument() {
      const classes = new Set(), styles = [];
      return { classes, styles, documentElement: { classList: { add(value) { classes.add(value); } } },
        head: { appendChild(value) { styles.push(value); } }, createElement() { return {}; },
        getElementById(id) { return styles.find(value => value.id === id); }, addEventListener() {} };
    }
    const enabledDoc = fakeDocument();
    runtime({ ...session, modelParametersEnabled: true }, enabledDoc);
    assert.ok(enabledDoc.classes.has("bridgedock-model-parameters"));
    assert.equal(enabledDoc.styles.length, 1);
    assert.ok(enabledDoc.styles[0].textContent.includes('[data-testid^="model-item-"] .ui-model-picker__edit-btn'));
    const disabledDoc = fakeDocument();
    runtime(session, disabledDoc);
    assert.equal(disabledDoc.classes.size, 0);
    assert.equal(disabledDoc.styles.length, 0);
  }

  // Sections follow model families across providers while keeping every route
  // and supporting full source-name searches.
  {
    const ctx = runtime(session);
    const models = [{ name: "第二/same" }, { name: "第一/model-10" }, { name: "第一/model-2" }, { name: "同名/same" }];
    const catalog = [
      { id: "第一/model-2", owned_by: "国内完整渠道名称" },
      { id: "第一/model-10", owned_by: "国内完整渠道名称" },
      { id: "第二/same", owned_by: "第二个渠道" },
      { id: "同名/same", owned_by: "第二个渠道" }
    ];
    const rows = ctx.__bridgeDockEnrichModels(models, catalog);
    assert.deepEqual(rows.map(row => row.name).sort(), models.map(row => row.name).sort());
    const first = rows.filter(row => row.name.startsWith("第一/"));
    assert.equal(first[0].namedModelSectionIndex, first[1].namedModelSectionIndex);
    assert.deepEqual(first.map(row => row.name), ["第一/model-2", "第一/model-10"]);
    const second = rows.find(row => row.name === "第二/same");
    const duplicateName = rows.find(row => row.name === "同名/same");
    assert.equal(second.namedModelSectionIndex, duplicateName.namedModelSectionIndex);
    assert.equal(ctx.__bridgeDockModelSection({ models: first }).title, "model · 2");
    assert.equal(ctx.__bridgeDockModelSection({ models: [second, duplicateName] }).title, "same · 2");
    assert.equal(ctx.__bridgeDockModelSection({ models: rows }).title, undefined);
    assert.ok(ctx.__bridgeDockModelMatches(first[0], "完整渠道 model-2"));
    assert.ok(ctx.__bridgeDockModelMatches(first[0], "ＭＯＤＥＬ-2"));
    assert.equal(ctx.__bridgeDockModelMatches(first[0], "不存在"), false);
    const props = { models: first, title: "已有标题" };
    assert.equal(ctx.__bridgeDockModelSection(props), props);
    assert.equal(official.__bridgeDockModelSection(props), props);
    assert.equal(official.__bridgeDockModelMatches(first[0], "model-2"), false);

    const liveCatalog = [
      { id: 'claude-fable-5-1', owned_by: 'Claude' },
      { id: 'claude-opus-5-5', owned_by: 'Kiro', bridgedock_parameters: { version: 2, providers: [
        { id: 'provider:kiro', name: 'Kiro' }, { id: 'provider:anthropic', name: 'Claude' }
      ] } },
      { id: 'glm-5.3-flash', owned_by: 'ZCode 国际' },
      { id: 'gpt-6-astra', owned_by: '本机 GPT / Codex' },
      { id: 'k3.1-pro', owned_by: 'Kimi Code 国内' },
      { id: 'k3.1-pro-highspeed', owned_by: 'Kimi Code 国内' }
    ];
    const liveRows = ctx.__bridgeDockEnrichModels(liveCatalog.map(entry => ({ name: entry.id })), liveCatalog);
    assert.deepEqual(clone(liveRows.map(row => row.name)), [
      'gpt-6-astra', 'claude-fable-5-1', 'claude-opus-5-5', 'k3.1-pro', 'k3.1-pro-highspeed', 'glm-5.3-flash'
    ], '截图中的 Claude 模型必须连续排列');
    assert.equal(liveRows[1].namedModelSectionIndex, liveRows[2].namedModelSectionIndex, 'Fable 和 Opus 不再被供应商分开');
    assert.equal(ctx.__bridgeDockModelSection({ models: liveRows.slice(1, 3) }).title, 'Claude · 2');
    assert.ok(ctx.__bridgeDockModelMatches(liveRows[2], 'Claude opus'), '可按非默认供应商搜索');
    assert.ok(ctx.__bridgeDockModelMatches(liveRows[2], 'Kiro opus'));
    const reorderedCatalog = liveCatalog.toReversed().map(entry => ({ ...entry, owned_by: '其他供应商' }));
    const reordered = ctx.__bridgeDockEnrichModels(reorderedCatalog.map(entry => ({ name: entry.id })), reorderedCatalog);
    assert.deepEqual(clone(reordered.map(row => [row.name, row.namedModelSectionIndex])),
      clone(liveRows.map(row => [row.name, row.namedModelSectionIndex])), '供应商变化或目录顺序变化不打散模型系列');

    const families = [['claude/claude-sonnet-5-5', 'kiro/claude-opus-5.5'], ['gpt-6-astra', 'relay/o3'],
      ['kimi-k3', 'k3.1-pro', 'kimi-work/k2d8-preview', 'kimi-work/k3d1-agent'],
      ['gemini-3-pro', 'gemini-3-flash'], ['glm-5.3-flash', 'chatglm-6b'], ['qwen3-coder', 'qwq-32b'],
      ['deepseek-v3', 'deepseek-r1'], ['grok-4', 'grok-4-fast']];
    const grouped = ctx.__bridgeDockEnrichModels(families.flat().map(name => ({ name })), []);
    const indices = families.map(names => {
      const entries = grouped.filter(row => names.includes(row.name));
      assert.equal(new Set(entries.map(row => row.namedModelSectionIndex)).size, 1, names.join(', '));
      return entries[0].namedModelSectionIndex;
    });
    assert.equal(new Set(indices).size, families.length, '不同模型系列分组独立');
    const labels = { editParameters: "Edit", other: "keep" };
    assert.equal(ctx.__bridgeDockPickerLabels(labels).editParameters, "参数");
    assert.equal(ctx.__bridgeDockPickerLabels(labels).searchPlaceholder, "搜索渠道或模型");
    assert.equal(ctx.__bridgeDockPickerLabels(labels).other, "keep");
    assert.equal(official.__bridgeDockPickerLabels(labels), labels);
    const layout = { children: "native-content" };
    assert.equal(ctx.__bridgeDockPickerLayout(layout).menuWidth, 440);
    ctx.innerWidth = 360; ctx.innerHeight = 480;
    assert.equal(ctx.__bridgeDockPickerLayout(layout).menuWidth, 328);
    assert.equal(ctx.__bridgeDockPickerLayout(layout).menuMaxHeight, 380);
    assert.equal(official.__bridgeDockPickerLayout(layout), layout);
  }

  // Returning to/opening the picker applies changed publications, without
  // rewriting stable selections or reintroducing names from native overrides.
  {
    const ctx = runtime(session);
    const { service, state, storage } = makeService(original);
    let result = { pickerModels: [{ name: "channel/first" }, { name: "channel/second" }],
      allProviderModelIds: ["channel/first", "channel/second"] };
    service.fetchLocalProviderModelEnrichment = async () => clone(result);
    await ctx.__bridgeDockRefreshModels(service, row => row);
    const firstRows = state.availableDefaultModels2;
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, firstRows, "unchanged catalog does not mutate native selection state");
    state.aiSettings.modelOverrideEnabled.push("channel/first");
    result = { pickerModels: [{ name: "channel/second" }], allProviderModelIds: ["channel/second"] };
    await ctx.__bridgeDockSyncModels();
    assert.deepEqual(clone(state.availableDefaultModels2.map(row => row.name)), ["channel/second"]);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "channel/second");
    assert.equal(state.aiSettings.modelOverrideEnabled.includes("channel/first"), false);
    const validRows = state.availableDefaultModels2;
    result = { succeeded: false, allProviderModelIds: [] };
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, validRows, "network failure keeps last successful catalog");
    // The native lower layer also swallows HTTP errors into an empty array.
    result = { succeeded: false, pickerModels: [], allProviderModelIds: [] };
    ctx.fetch = async () => { throw new Error("connection refused"); };
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, validRows, "swallowed transport failure does not clear catalog");
    ctx.fetch = async () => ({ ok: false });
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, validRows, "HTTP error does not clear catalog");
    ctx.fetch = async () => ({ ok: true, json: async () => ({ invalid: [] }) });
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, validRows, "malformed catalog does not clear catalog");
    ctx.fetch = async () => ({ ok: true, json: async () => ({ data: [{ id: "channel/second" }] }) });
    await ctx.__bridgeDockSyncModels();
    assert.equal(state.availableDefaultModels2, validRows, "failed native discovery cannot erase a nonempty catalog");
    ctx.fetch = async (url, options) => {
      assert.equal(url, session.baseURL + "/models");
      assert.equal(options.headers.Authorization, "Bearer " + session.key);
      assert.equal(options.redirect, "error");
      return { ok: true, json: async () => ({ data: [] }) };
    };
    await ctx.__bridgeDockSyncModels();
    assert.deepEqual(clone(state.availableDefaultModels2), [], "intentional empty publication clears models");
    assert.deepEqual(clone(state.aiSettings.modelOverrideEnabled), []);
    assert.deepEqual(clone(state.localProviderAgentModelIds), []);
    assert.equal(state.aiSettings.modelConfig.composer.modelName, "");
    assert.deepEqual(clone(state.aiSettings.modelConfig.composer.selectedModels), []);
    assert.ok(storage.has(snapshotKey));
    official.__bridgeDockRestoreModels(service);
    assert.deepEqual(clone(state), original);
  }

  // A native refresh and a menu-open refresh share the same in-flight request.
  {
    const ctx = runtime(session);
    const { service } = makeService(original);
    let finish, calls = 0;
    service.fetchLocalProviderModelEnrichment = () => { calls++; return new Promise(resolve => { finish = resolve; }); };
    const pending = ctx.__bridgeDockRefreshModels(service, row => row);
    const another = ctx.__bridgeDockSyncModels();
    assert.equal(calls, 1);
    finish({ pickerModels: [{ name: "bd-model" }], allProviderModelIds: ["bd-model"] });
    await Promise.all([pending, another]);
  }

  // Cursor's normal empty-catalog path falls back to its built-in Auto model.
  // Both BD entry points must return the actual list, including an empty one.
  {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "../Resources/CursorLocal/patches.json"), "utf8"));
    for (const file of manifest.files.filter(file => file.scope !== "app")) {
      const patch = file.patches.find(patch => patch.find === "computeAvailableDefaultModels(){");
      const compute = new Function("globalThis", "Osp", "Yug", patch.replace.slice(patch.find.length) + ';return "official-fallback";');
      const storage = { availableDefaultModels2: [] };
      const owner = { reactiveStorageService: { applicationUserPersistentStorage: storage, availableModelsCatalogRevision() {} } };
      const normalize = value => value;
      assert.deepEqual(compute.call(owner, { __bridgeDockLocal: session }, normalize, normalize), []);
      storage.availableDefaultModels2 = [{ name: "channel/only-published" }];
      assert.deepEqual(compute.call(owner, { __bridgeDockLocal: session }, normalize, normalize), storage.availableDefaultModels2);
      assert.equal(compute.call(owner, {}, normalize, normalize), "official-fallback");
    }
  }

  console.log("Cursor runtime: 14 model-state, grouped-picker, refresh and parameter checks passed");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
