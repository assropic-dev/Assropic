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
    assert.ok(aliased[0].variants.every(variant => variant.displayName === "渠道前四/gpt-6" && variant.displayNameOutsidePicker === "渠道前四/gpt-6"));
  }

  // Native choices survive refresh, switch-off and switch-on. Official model
  // settings remain independent, including their original parameter values.
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

  // Native sections keep every route, distinguish equally named sources and
  // support source-name searches even when the public prefix is abbreviated.
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
    assert.notEqual(second.namedModelSectionIndex, duplicateName.namedModelSectionIndex);
    assert.equal(ctx.__bridgeDockModelSection({ models: first }).title, "国内完整渠道名称 · 2");
    assert.equal(ctx.__bridgeDockModelSection({ models: [second] }).title, "第二个渠道 · 第二 · 1");
    assert.equal(ctx.__bridgeDockModelSection({ models: [duplicateName] }).title, "第二个渠道 · 同名 · 1");
    assert.equal(ctx.__bridgeDockModelSection({ models: rows }).title, undefined);
    assert.ok(ctx.__bridgeDockModelMatches(first[0], "完整渠道 model-2"));
    assert.ok(ctx.__bridgeDockModelMatches(first[0], "ＭＯＤＥＬ-2"));
    assert.equal(ctx.__bridgeDockModelMatches(first[0], "不存在"), false);
    const props = { models: first, title: "已有标题" };
    assert.equal(ctx.__bridgeDockModelSection(props), props);
    assert.equal(official.__bridgeDockModelSection(props), props);
    assert.equal(official.__bridgeDockModelMatches(first[0], "model-2"), false);
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
