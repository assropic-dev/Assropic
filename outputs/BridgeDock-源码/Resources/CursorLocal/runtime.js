// Loaded before the Cursor workbench. The session exists only while BridgeDock runs.
const sessionPort = __BD_SESSION_PORT__;
const sessionSecret = __BD_SESSION_SECRET__;

try {
  const request = new XMLHttpRequest();
  request.open("GET", `http://127.0.0.1:${sessionPort}/session`, false);
  request.setRequestHeader("X-BridgeDock-Session", sessionSecret);
  request.send();
  if (request.status === 200) {
    const session = JSON.parse(request.responseText);
    if (session.id && session.token && session.baseURL && session.gatewayURL) {
      globalThis.__bridgeDockLocal = Object.freeze(session);
    }
  }
} catch {
  console.info("BridgeDock local session is inactive");
}

// The native Edit control is normally hover-only. Keep that existing control
// visible for BD parameter editing, without changing membership or UI gates.
function showParameterControls() {
  const document = globalThis.document;
  if (!document?.documentElement || !globalThis.__bridgeDockLocal?.modelParametersEnabled) return;
  document.documentElement.classList.add("bridgedock-model-parameters");
  if (document.getElementById("bridgedock-parameter-style")) return;
  const style = document.createElement("style");
  style.id = "bridgedock-parameter-style";
  style.textContent = `.bridgedock-model-parameters [data-testid^="model-item-"] .ui-model-picker__edit-btn { display: inline-flex !important; opacity: 1 !important; visibility: visible !important; }`;
  (document.head ?? document.documentElement).appendChild(style);
}
showParameterControls();
globalThis.document?.addEventListener("DOMContentLoaded", showParameterControls, { once: true });

// Keep the official account's model choices separate from the local catalog.
// Only model state is saved here; account credentials are never copied.
const officialModelsKey = "bridgedock/officialModelState/v1";
const officialModelPaths = [
  ["availableDefaultModels2"],
  ["localProviderModelIds"],
  ["localProviderAgentModelIds"],
  ["aiSettings", "modelConfig"],
  ["aiSettings", "modelOverrideEnabled"],
  ["aiSettings", "modelOverrideDisabled"],
  ["aiSettings", "modelVisibilityMigrated"],
  ["aiSettings", "previousModelBeforeDefault"],
  ["aiSettings", "modelParameterPreferences"]
];

function readOfficialModelSnapshot(service) {
  const raw = service._storageService.get(officialModelsKey, -1);
  if (raw === undefined || raw === null) return undefined;
  const snapshot = JSON.parse(raw);
  if (snapshot.version !== 1 || !Array.isArray(snapshot.values) ||
      snapshot.values.length !== officialModelPaths.length ||
      snapshot.values.some((entry, index) =>
        !entry || typeof entry.present !== "boolean" ||
        JSON.stringify(entry.path) !== JSON.stringify(officialModelPaths[index]))) {
    throw new Error("BridgeDock official model snapshot is invalid");
  }
  return snapshot;
}

function saveOfficialModels(service) {
  // Multiple Cursor windows share storage. The first snapshot remains the
  // official one until a window starts without a BridgeDock session.
  if (readOfficialModelSnapshot(service)) return;
  const root = service._reactiveStorageService.applicationUserPersistentStorage;
  const values = officialModelPaths.map(path => {
    let parent = root;
    for (const part of path.slice(0, -1)) parent = parent?.[part];
    const key = path[path.length - 1];
    const present = parent != null && Object.prototype.hasOwnProperty.call(parent, key) &&
      parent[key] !== undefined;
    return { path, present, ...(present ? { value: parent[key] } : {}) };
  });
  // Serialize before changing any state so the snapshot is not a live reference.
  service._storageService.store(officialModelsKey, JSON.stringify({ version: 1, values }), -1, 1);
}

globalThis.__bridgeDockRestoreModels = function (service) {
  if (globalThis.__bridgeDockLocal) return;
  const snapshot = readOfficialModelSnapshot(service);
  if (!snapshot) return;
  saveLocalParameters(service);
  for (const entry of snapshot.values) {
    service._reactiveStorageService.setApplicationUserPersistentStorage(
      ...entry.path, entry.present ? entry.value : undefined
    );
  }
  // Remove only after every field was restored. A failed write can be retried
  // safely on the next launch without losing the original model choices.
  service._storageService.remove(officialModelsKey, -1);
};

const localParametersKey = "bridgedock/localModelParameters/v1";
const localParametersActiveKey = "bridgedock/localModelParametersActive/v1";
let parameterService;
const copy = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));

function saveLocalParameters(service) {
  if (service._storageService.get(localParametersActiveKey, -1) !== "true") return;
  const settings = service._reactiveStorageService.applicationUserPersistentStorage.aiSettings;
  service._storageService.store(localParametersKey, JSON.stringify({
    version: 1, preferences: settings.modelParameterPreferences ?? {},
    composer: settings.modelConfig?.composer
  }), -1, 1);
}

function localParameters(service) {
  const raw = service._storageService.get(localParametersKey, -1);
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw);
    return value?.version === 1 && value.preferences && typeof value.preferences === "object" ? value : undefined;
  } catch { return undefined; }
}

globalThis.addEventListener?.("pagehide", () => parameterService && saveLocalParameters(parameterService));
globalThis.addEventListener?.("beforeunload", () => parameterService && saveLocalParameters(parameterService));

globalThis.__bridgeDockParameterHeaders = function () {
  return { "X-BridgeDock-Model-Parameters": globalThis.__bridgeDockLocal?.modelParametersEnabled ? "1" : "0" };
};

// Reuse Cursor's native sections, search and selection controls. Public model
// names remain routing identifiers; grouping never rewrites or drops them.
let modelSources = new Map();
function organizeModels(rows, catalog) {
  const entries = Array.isArray(catalog) ? catalog : catalog?.data ?? [];
  const metadata = new Map(entries.map(entry => [entry.id, entry]));
  const sources = new Map();
  const byModel = new Map();
  for (const row of rows) {
    const prefix = row.name.includes("/") ? row.name.slice(0, row.name.indexOf("/")) : "";
    const entry = metadata.get(row.name) ?? {};
    const key = prefix || entry.owned_by || "BridgeDock";
    const name = entry.owned_by || prefix || "BridgeDock";
    if (!sources.has(key)) sources.set(key, { key, name });
    byModel.set(row.name, sources.get(key));
  }
  const ordered = [...sources.values()].sort((a, b) => a.name.localeCompare(b.name, "zh-CN", { numeric: true }) || a.key.localeCompare(b.key));
  const sections = new Map(ordered.map((source, index) => [source.key, index + 1]));
  const nameCounts = new Map();
  ordered.forEach(source => nameCounts.set(source.name, (nameCounts.get(source.name) ?? 0) + 1));
  ordered.forEach(source => { source.title = nameCounts.get(source.name) > 1 ? `${source.name} · ${source.key}` : source.name; });
  modelSources = byModel;
  return rows.map(row => ({ ...row, namedModelSectionIndex: sections.get(byModel.get(row.name).key),
    clientDisplayName: row.name, inputboxShortModelName: row.name,
    variants: row.variants?.map(variant => ({ ...variant, displayName: row.name, displayNameOutsidePicker: row.name }))
  })).sort((a, b) => a.namedModelSectionIndex - b.namedModelSectionIndex || a.name.localeCompare(b.name, "zh-CN", { numeric: true }));
}

globalThis.__bridgeDockModelSection = function (props) {
  if (!globalThis.__bridgeDockLocal || props.title || !props.models?.length) return props;
  const source = modelSources.get(props.models[0].name);
  if (!source || !props.models.every(model => modelSources.get(model.name)?.key === source.key)) return props;
  return { ...props, title: `${source.title} · ${props.models.length}` };
};

globalThis.__bridgeDockModelMatches = function (model, query) {
  if (!globalThis.__bridgeDockLocal) return false;
  const normalize = value => String(value ?? "").normalize("NFKC").toLocaleLowerCase();
  const source = modelSources.get(model.name);
  const text = normalize([model.name, model.name?.replace(/-/g, " "), model.clientDisplayName,
    source?.name, source?.key, ...(model.variants ?? []).map(variant => variant.displayName)].join(" "));
  return normalize(query).trim().split(/\s+/).every(word => text.includes(word));
};

globalThis.__bridgeDockPickerLabels = function (labels) {
  return globalThis.__bridgeDockLocal ? { ...labels, searchPlaceholder: "搜索渠道或模型",
    noModelsFound: "没有匹配的模型", modelSelection: "选择模型", countOptions: "数量选项",
    restoreDefaultParameters: "恢复默认参数", editParameters: "参数" } : labels;
};

globalThis.__bridgeDockPickerLayout = function (props) {
  if (!globalThis.__bridgeDockLocal) return props;
  return { ...props, menuWidth: Math.max(180, Math.min(440, (globalThis.innerWidth || 1000) - 32)),
    menuMaxHeight: Math.max(180, Math.min(500, (globalThis.innerHeight || 800) - 100)) };
};

// BridgeDock publishes each model's real context window and reasoning levels in
// /v1/models (capabilities.context_length / reasoning_effort). Cursor's local runtime
// reads the same fields for the remaining-context ring; the picker offers only
// values the model actually supports.
const effortLabels = { none: "关闭", minimal: "极低", low: "低", medium: "中", high: "高", xhigh: "超高", "extra-high": "超高", max: "最高", ultra: "极深" };
const tokenLabel = value => {
  if (value % 1048576 === 0) return `${value / 1048576}M`;
  if (value % 1000000 === 0) return `${value / 1000000}M`;
  if (value % 1024 === 0 && value < 1048576) return `${value / 1024}K`;
  return value >= 1000000 ? `${(value / 1000000).toFixed(1)}M` : `${Math.round(value / 1000)}K`;
};

function modelCapability(metadata) {
  const capabilities = metadata?.capabilities ?? {};
  const limit = Number(capabilities.context_length ?? metadata?.context_length);
  const efforts = Array.isArray(capabilities.reasoning_effort) ? capabilities.reasoning_effort
    .filter(value => typeof value === "string" && /^[a-z][a-z0-9_-]{0,31}$/.test(value) && value !== "none") : [];
  return { limit: Number.isSafeInteger(limit) && limit > 0 ? limit : undefined, efforts: [...new Set(efforts)] };
}

// Budgets below the real window let a long conversation be summarized earlier.
// Without a published window there is nothing truthful to offer.
function contextChoices(limit) {
  if (!limit) return [];
  const steps = [32768, 65536, 131072, 200000, 262144, 524288, 1000000, 2000000];
  const below = steps.filter(value => value < limit * 0.9 && value >= Math.min(32768, limit / 8));
  return [...below.slice(-3), limit];
}

globalThis.__bridgeDockEnrichModels = function (rows, catalog) {
  rows = organizeModels(rows, catalog);
  const entries = Array.isArray(catalog) ? catalog : catalog?.data ?? [];
  const parametersEnabled = !!globalThis.__bridgeDockLocal?.modelParametersEnabled;
  return rows.map(row => {
    const { limit, efforts } = modelCapability(entries.find(entry => entry.id === row.name));
    const base = { ...row, ...(limit ? { contextTokenLimit: limit } : {}), supportsThinking: efforts.length > 0,
      supportsNonMaxMode: true, supportsMaxMode: false };
    if (!parametersEnabled) return base;
    const contexts = contextChoices(limit);
    const reasoning = efforts.length ? ["none", ...efforts] : [];
    const parameterDefinitions = [
      ...(contexts.length > 1 ? [{ id: "context", name: "上下文",
        markdownTooltip: `模型上下文上限 ${tokenLabel(limit)}。选较小的值会更早压缩对话。`,
        parameterType: { enumParameter: { values: contexts.map(value => ({ value: String(value), displayName: tokenLabel(value) })) } } }] : []),
      ...(reasoning.length ? [{ id: "reasoning", name: "思考强度", isCycleableByHotkey: true,
        markdownTooltip: "选项来自模型资料。“关闭”不发送思考参数，使用渠道默认。",
        parameterType: { enumParameter: { values: reasoning.map(value => ({ value, displayName: effortLabels[value] ?? value })) } } }] : [])
    ];
    if (!parameterDefinitions.length) return { ...base, parameterDefinitions: [], variants: [] };
    const contextValues = contexts.length > 1 ? contexts.map(String) : [undefined];
    const reasoningValues = reasoning.length ? reasoning : [undefined];
    const variants = contextValues.flatMap(context => reasoningValues.map(effort => {
      const isDefault = (context === undefined || context === String(limit)) && (effort === undefined || effort === "none");
      return { parameterValues: [...(context !== undefined ? [{ id: "context", value: context }] : []),
        ...(effort !== undefined ? [{ id: "reasoning", value: effort }] : [])],
        displayName: row.name, displayNameOutsidePicker: row.name,
        isMaxMode: false, isDefaultNonMaxConfig: isDefault, isDefaultMaxConfig: isDefault };
    }));
    return { ...base, parameterDefinitions, variants };
  });
};

const modelRefreshes = new WeakMap();
const modelFingerprints = new WeakMap();
let activeModelService;
globalThis.__bridgeDockRefreshModels = function (service, toPlain, onlyIfChanged = false) {
  if (modelRefreshes.has(service)) return modelRefreshes.get(service);
  activeModelService = { service, toPlain };
  const pending = refreshModels(service, toPlain, onlyIfChanged).finally(() => modelRefreshes.delete(service));
  modelRefreshes.set(service, pending);
  return pending;
};

// Opening the native picker or returning from BridgeDock is enough to see a
// changed publication list. No polling, inference calls, or app restart needed.
globalThis.__bridgeDockSyncModels = function () {
  if (!globalThis.__bridgeDockLocal || !activeModelService) return Promise.resolve();
  const { service, toPlain } = activeModelService;
  return globalThis.__bridgeDockRefreshModels(service, toPlain, true).catch(() => {
    console.info("BridgeDock model refresh unavailable; keeping the last catalog");
  });
};
globalThis.addEventListener?.("focus", () => globalThis.__bridgeDockSyncModels());

async function refreshModels(service, toPlain, onlyIfChanged) {
  const hadOfficialSnapshot = !!readOfficialModelSnapshot(service);
  const wasParametersActive = service._storageService.get(localParametersActiveKey, -1) === "true";
  if (hadOfficialSnapshot) saveLocalParameters(service);
  saveOfficialModels(service);
  let result = await service.fetchLocalProviderModelEnrichment();
  if (!Array.isArray(result.pickerModels)) throw new Error("BridgeDock model catalog unavailable");
  // Cursor's low-level discovery folds both HTTP failures and a valid empty
  // catalog into pickerModels:[] with no catalog. Confirm only this ambiguous
  // case against the local endpoint before clearing a previously usable list.
  const catalog = Array.isArray(result.providerModelCatalog) ? result.providerModelCatalog : result.providerModelCatalog?.data;
  if (!result.pickerModels.length && !Array.isArray(catalog)) {
    const session = globalThis.__bridgeDockLocal;
    const response = await fetch(session.baseURL.replace(/\/$/, "") + "/models", {
      headers: { Authorization: "Bearer " + session.key }, credentials: "omit", redirect: "error", cache: "no-store",
      signal: globalThis.AbortSignal?.timeout?.(3000)
    });
    if (!response.ok) throw new Error("BridgeDock model catalog unavailable");
    const confirmed = await response.json();
    if (!Array.isArray(confirmed?.data) || confirmed.data.length) throw new Error("BridgeDock empty catalog not confirmed");
    result = { ...result, providerModelCatalog: [], allProviderModelIds: [] };
  }
  const fingerprint = JSON.stringify([result.pickerModels, result.providerModelCatalog,
    result.allProviderModelIds, globalThis.__bridgeDockLocal.modelParametersEnabled]);
  if (onlyIfChanged && modelFingerprints.get(service) === fingerprint) return;
  const rows = globalThis.__bridgeDockEnrichModels(service.deserializePickerModels(result.pickerModels ?? []).map(
    row => toPlain(service.withLocalPickerSection(row, 1, true))
  ), result.providerModelCatalog);
  const saved = localParameters(service);
  service._reactiveStorageService.setApplicationUserPersistentStorage("availableDefaultModels2", rows);
  service._reactiveStorageService.setApplicationUserPersistentStorage("localProviderModelIds", result.allProviderModelIds);
  service._reactiveStorageService.setApplicationUserPersistentStorage("localProviderAgentModelIds", rows.map(row => row.name));
  service._modelConfigService.triggerParameterizedModelConfigMigration();
  // Old custom-model overrides otherwise reinsert unpublished names into the
  // native menu. Official overrides are already preserved in the snapshot.
  service._reactiveStorageService.setApplicationUserPersistentStorage("aiSettings", "modelOverrideEnabled", []);
  service._reactiveStorageService.setApplicationUserPersistentStorage("aiSettings", "modelOverrideDisabled", []);
  const enabled = !!globalThis.__bridgeDockLocal.modelParametersEnabled;
  if (enabled && saved) {
    service._reactiveStorageService.setApplicationUserPersistentStorage("aiSettings", "modelParameterPreferences", copy(saved.preferences));
  }
  if (rows.length) {
    const stored = service._modelConfigService.getStoredModelConfig("composer");
    const selected = hadOfficialSnapshot ? stored : saved?.composer;
    const sessionDefault = globalThis.__bridgeDockLocal.model;
    const name = [selected?.modelName, sessionDefault].find(candidate => rows.some(row => row.name === candidate)) ?? rows[0].name;
    const row = rows.find(row => row.name === name);
    const restoredParameters = saved?.preferences?.[name]?.parameters
      ?? saved?.composer?.selectedModels?.find(value => value.modelId === name)?.parameters ?? [];
    const requested = enabled ? ((wasParametersActive ? selected?.selectedModels?.find(value => value.modelId === name)?.parameters : undefined) ?? restoredParameters) : [];
    const parameters = row.variants?.find(variant => requested.length && variant.parameterValues.every(value => requested.some(item => item.id === value.id && item.value === value.value)))?.parameterValues
      ?? (enabled ? row.variants?.find(variant => variant.isDefaultNonMaxConfig)?.parameterValues : undefined) ?? [];
    service._modelConfigService.setModelConfig("composer", { modelName: name,
      selectedModels: [{ modelId: name, parameters: copy(parameters) }], maxMode: false });
    // Some Cursor migrations rewrite preferences while selecting a model.
    if (enabled && saved) service._reactiveStorageService.setApplicationUserPersistentStorage("aiSettings", "modelParameterPreferences", copy(saved.preferences));
  } else {
    // The native setter applies default-model invariants. Write an explicit
    // empty choice here so it cannot re-enable the last unpublished model.
    const previous = service._reactiveStorageService.applicationUserPersistentStorage.aiSettings.modelConfig?.composer;
    service._reactiveStorageService.setApplicationUserPersistentStorage("aiSettings", "modelConfig", "composer",
      { ...previous, modelName: "", selectedModels: [], maxMode: false });
  }
  service._storageService.store(localParametersActiveKey, String(enabled), -1, 1);
  parameterService = service;
  service._aiSettingsService.handleAvailableModelsChange();
  modelFingerprints.set(service, fingerprint);
}

// Local sessions send Cursor backend traffic to the local gateway as well.
// Unsupported cloud operations receive an explicit local 404 response.
globalThis.__bridgeDockCredentials = function (credentials) {
  const local = { ...credentials };
  const url = globalThis.__bridgeDockLocal.gatewayURL;
  for (const key of Object.keys(local)) {
    if (key.includes("Url") && key !== "websiteUrl" && typeof local[key] === "string") local[key] = url;
  }
  local.localLoopInferenceUrl = "";
  return local;
};
