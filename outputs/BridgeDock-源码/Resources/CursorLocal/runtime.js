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

// Model families define picker sections. Providers remain independent routing
// choices and searchable metadata, never the basis for splitting a family.
const pickerFamilies = [
  ["gpt", "GPT", /^(?:gpt|chatgpt)(?:[-_.\s]|$)|^o\d+(?:[-_.\s]|$)/],
  ["claude", "Claude", /^claude(?:[-_.\s]|$)/],
  ["gemini", "Gemini", /^gemini(?:[-_.\s]|$)/],
  ["grok", "Grok", /^grok(?:[-_.\s]|$)/],
  ["kimi", "Kimi", /^(?:kimi|moonshot)(?:[-_.\s]|$)|^k\d+(?:[.]\d+|d\d+)*(?:[-_\s]|$)/],
  ["glm", "GLM", /^(?:glm|chatglm)(?:[-_.\s]|$)/],
  ["deepseek", "DeepSeek", /^deepseek(?:[-_.\s]|$)/],
  ["qwen", "Qwen", /^(?:qwen|qwq|qvq)(?:\d|[-_.\s]|$)/],
  ["minimax", "MiniMax", /^minimax(?:[-_.\s]|$)/],
  ["mistral", "Mistral", /^(?:mistral|mixtral|ministral|codestral|devstral|pixtral|magistral)(?:[-_.\s]|$)/],
  ["llama", "Llama", /^(?:meta-)?llama(?:\d|[-_.\s]|$)/],
  ["composer", "Composer", /^composer(?:[-_.\s]|$)/],
  ["muse", "Muse", /^muse(?:[-_.\s]|$)/],
  ["doubao", "豆包", /^doubao(?:[-_.\s]|$)/],
  ["ernie", "文心", /^ernie(?:[-_.\s]|$)/]
];
function pickerFamily(name) {
  const model = name.split("/").at(-1).normalize("NFKC").toLowerCase();
  const index = pickerFamilies.findIndex(([, , pattern]) => pattern.test(model));
  if (index >= 0) {
    const [key, title] = pickerFamilies[index];
    return { key, title, order: index };
  }
  // Unrecognized/custom families still group by model name, not by their channel.
  const stem = model.split(/[-_.\s]/)[0] || model;
  return { key: "other:" + stem, title: stem || "其他模型", order: pickerFamilies.length };
}
let modelGroups = new Map();
function organizeModels(rows, catalog) {
  const entries = Array.isArray(catalog) ? catalog : catalog?.data ?? [];
  const metadata = new Map(entries.map(entry => [entry.id, entry]));
  const groups = new Map();
  const byModel = new Map();
  for (const row of rows) {
    const prefix = row.name.includes("/") ? row.name.slice(0, row.name.indexOf("/")) : "";
    const entry = metadata.get(row.name) ?? {};
    const family = pickerFamily(row.name);
    if (!groups.has(family.key)) groups.set(family.key, family);
    const providers = Array.isArray(entry.bridgedock_parameters?.providers) ? entry.bridgedock_parameters.providers : [];
    byModel.set(row.name, { ...family, sources: [prefix, entry.owned_by,
      ...providers.flatMap(provider => [provider.name, provider.id])].filter(Boolean) });
  }
  const ordered = [...groups.values()].sort((a, b) => a.order - b.order || a.title.localeCompare(b.title, "zh-CN", { numeric: true }));
  const sections = new Map(ordered.map((group, index) => [group.key, index + 1]));
  modelGroups = byModel;
  return rows.map(row => ({ ...row, namedModelSectionIndex: sections.get(byModel.get(row.name).key),
    ...(row.tagline === "Local provider model" ? { tagline: "本地供应商模型" } : {}),
    ...(row.tooltipData?.markdownContent ? { tooltipData: { ...row.tooltipData,
      markdownContent: row.tooltipData.markdownContent
        .replaceAll("Discovered from your local provider.", "来自本地供应商。")
        .replace(/Context: ([\d,. ]+) tokens\./g, "上下文：$1 词元。")
        .replace(/Max output: ([\d,. ]+) tokens\./g, "最大输出：$1 词元。")
        .replaceAll("Reasoning: supported.", "支持思考。")
        .replaceAll("Vision: supported.", "支持图片输入。")
    } } : {}),
    clientDisplayName: row.name, inputboxShortModelName: row.name,
    variants: row.variants?.map(variant => ({ ...variant, displayName: row.name, displayNameOutsidePicker: row.name }))
  })).sort((a, b) => a.namedModelSectionIndex - b.namedModelSectionIndex ||
    a.name.split("/").at(-1).localeCompare(b.name.split("/").at(-1), "zh-CN", { numeric: true }) || a.name.localeCompare(b.name));
}

globalThis.__bridgeDockModelSection = function (props) {
  if (!globalThis.__bridgeDockLocal || props.title || !props.models?.length) return props;
  const group = modelGroups.get(props.models[0].name);
  if (!group || !props.models.every(model => modelGroups.get(model.name)?.key === group.key)) return props;
  return { ...props, title: `${group.title} · ${props.models.length}` };
};

globalThis.__bridgeDockModelMatches = function (model, query) {
  if (!globalThis.__bridgeDockLocal) return false;
  const normalize = value => String(value ?? "").normalize("NFKC").toLocaleLowerCase();
  const group = modelGroups.get(model.name);
  const text = normalize([model.name, model.name?.replace(/-/g, " "), model.clientDisplayName,
    group?.title, ...(group?.sources ?? []), ...(model.variants ?? []).map(variant => variant.displayName)].join(" "));
  return normalize(query).trim().split(/\s+/).every(word => text.includes(word));
};

// Choose the existing native parameter submenu for this local provider only.
globalThis.__bridgeDockParameterMenu = function (officialEnabled) {
  return globalThis.__bridgeDockLocal ? !!globalThis.__bridgeDockLocal.modelParametersEnabled : officialEnabled;
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
// 档位名称沿用上游原名（Cursor 的 displayName、Work 的“标准 / 进阶 / 极致”，否则为档位 ID）；
// 只有本地补出的 none 档显示为“默认”。
const effortLabel = (value, official) => official || (value === "none" ? "默认" : value);
const parameterNames = { context: "上下文", reasoning: "思考强度", fast: "快速模式", thinking: "深度思考", provider: "供应商" };
const publicModelName = name => typeof name === "string"
  ? name.replace(/^(claude-(?:opus|sonnet|haiku|fable)-[0-9]+)\.([0-9]+)(?=-|$)/, "$1-$2") : name;

function localizedDefinitions(definitions) {
  return definitions.map(definition => {
    const type = definition.parameterType;
    const key = type?.enumParameter ? "enumParameter" : type?.booleanParameter ? "booleanParameter" : undefined;
    if (!key) return { ...definition, name: parameterNames[definition.id] ?? definition.name };
    const values = type[key].values.map(choice => ({ ...choice,
      displayName: definition.id === "reasoning" ? effortLabel(choice.value, choice.displayName)
        : ["fast", "thinking"].includes(definition.id) && ["false", "true"].includes(choice.value)
          ? choice.value === "true" ? "开" : "关" : choice.displayName
    }));
    return { ...definition, name: parameterNames[definition.id] ?? definition.name,
      parameterType: { ...type, [key]: { ...type[key], values } } };
  });
}
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
  const defaultEffort = efforts.includes(capabilities.reasoning_default) ? capabilities.reasoning_default : "none";
  return { limit: Number.isSafeInteger(limit) && limit > 0 ? limit : undefined, efforts: [...new Set(efforts)], defaultEffort };
}

// Budgets below the real window let a long conversation be summarized earlier.
// Without a published window there is nothing truthful to offer.
function contextChoices(limit) {
  if (!limit) return [];
  const steps = [32768, 65536, 131072, 200000, 262144, 524288, 1000000, 2000000];
  const below = steps.filter(value => value < limit * 0.9 && value >= Math.min(32768, limit / 8));
  return [...below.slice(-3), limit];
}

function parameterLabel(name, parameters, definitions) {
  const labels = parameters.filter(parameter => parameter.id === "reasoning" ||
    (parameter.id === "fast" && parameter.value === "true")).map(parameter => {
    if (parameter.id === "fast") return "快速";
    const definition = definitions.find(item => item.id === parameter.id);
    const values = definition?.parameterType?.enumParameter?.values ?? definition?.parameterType?.booleanParameter?.values ?? [];
    const label = values.find(item => item.value === parameter.value)?.displayName ?? parameter.value;
    return label === "默认" || label === "Default" ? "" : label;
  }).filter(Boolean);
  return [name, ...labels].join(" ");
}

function selectedParameters(row, requested) {
  const all = row.variants ?? [];
  const provider = requested.find(parameter => parameter.id === "provider")?.value;
  const matching = all.filter(variant => variant.parameterValues.some(parameter => parameter.id === "provider" && parameter.value === provider));
  const variants = matching.length ? matching : all;
  const fallback = variants.find(variant => variant.isDefaultNonMaxConfig) ?? variants[0];
  if (!fallback) return [];
  const desired = new Map(fallback.parameterValues.map(parameter => [parameter.id, parameter.value]));
  for (const parameter of requested) {
    if (variants.some(variant => variant.parameterValues.some(value =>
      value.id === parameter.id && value.value === parameter.value))) {
      desired.set(parameter.id, parameter.value);
    }
  }
  return variants.find(variant => variant.parameterValues.every(parameter =>
    desired.get(parameter.id) === parameter.value))?.parameterValues ?? fallback.parameterValues;
}

// version 2：同名模型合并为一条，供应商作为参数。每个供应商只组合自己声明的
// context/effort，切换供应商后原生菜单里的可选项随之变化。
function nativeParametersV2(name, native) {
  const valid = value => typeof value === "string" && /^[a-z][a-z0-9_-]{0,31}$/.test(value);
  const declared = id => {
    const values = native.definitions.find(item => item?.id === id)?.values;
    return Array.isArray(values) ? values.filter(value => typeof value?.id === "string" && value.id) : [];
  };
  const providers = (Array.isArray(native.providers) ? native.providers : [])
    .filter(provider => typeof provider?.id === "string" && provider.id);
  const providerValues = declared("provider").filter(value => providers.some(provider => provider.id === value.id));
  if (!providerValues.length) return undefined;
  const contextValues = declared("context").filter(value => Number.isSafeInteger(Number(value.id)) && Number(value.id) > 0);
  const reasoningValues = declared("reasoning").filter(value => valid(value.id));
  const fast = declared("fast").some(value => value.id === "true");

  const definitions = [
    ...(fast ? [{ id: "fast", name: "快速模式", parameterType: { booleanParameter: {
      values: [{ value: "false", displayName: "关" }, { value: "true", displayName: "开" }] } } }] : []),
    ...(contextValues.length ? [{ id: "context", name: "上下文",
      markdownTooltip: "选较小的值会更早压缩对话。",
      parameterType: { enumParameter: { values: contextValues.map(value =>
        ({ value: value.id, displayName: tokenLabel(Number(value.id)) })) } } }] : []),
    ...(reasoningValues.length ? [{ id: "reasoning", name: "思考强度", isCycleableByHotkey: true,
      parameterType: { enumParameter: { values: reasoningValues.map(value =>
        ({ value: value.id, displayName: effortLabel(value.id, value.label !== value.id ? value.label : undefined) })) } } }] : []),
    { id: "provider", name: native.definitions.find(item => item.id === "provider")?.name || "供应商",
      parameterType: { enumParameter: { values: providerValues.map(value =>
        ({ value: value.id, displayName: value.label || value.id })) } } }
  ];

  const variants = [];
  providerValues.forEach((value, index) => {
    const provider = providers.find(item => item.id === value.id);
    const limit = Number(provider.context_length);
    const declaredContexts = Array.isArray(provider.context_options) ? provider.context_options.map(String) : undefined;
    const contexts = Number.isSafeInteger(limit) && limit > 0
      ? contextValues.map(item => item.id).filter(id => Number(id) <= limit && (!declaredContexts || declaredContexts.includes(id))) : [];
    const supported = Array.isArray(provider.reasoning_effort) ? provider.reasoning_effort : [];
    const efforts = reasoningValues.map(item => item.id).filter(id => supported.includes(id));
    const defaultEffort = efforts.includes(provider.reasoning_default) ? provider.reasoning_default : efforts[0];
    const defaultContext = contexts.includes(String(provider.context_default)) ? String(provider.context_default) : contexts.at(-1);
    const speeds = fast && provider.fast === true ? ["false", "true"] : [undefined];
    const defaultSpeed = provider.fast_default === true ? "true" : speeds[0];
    const combos = (contexts.length ? contexts : [undefined]).flatMap(context =>
      (efforts.length ? efforts : [undefined]).flatMap(effort =>
        speeds.map(speed => ({ context, effort, speed }))));
    const generated = combos.map(({ context, effort, speed }) => ({
      parameterValues: [...(speed !== undefined ? [{ id: "fast", value: speed }] : []),
        ...(context !== undefined ? [{ id: "context", value: context }] : []),
        ...(effort !== undefined ? [{ id: "reasoning", value: effort }] : [])],
      isDefaultNonMaxConfig: context === defaultContext && effort === defaultEffort && speed === defaultSpeed
    }));
    // Cursor publishes exact combinations, which may not form a Cartesian product.
    const declaredVariants = Array.isArray(provider.variants) && provider.variants.length ? provider.variants : generated;
    const choices = declaredVariants.filter(variant => Array.isArray(variant.parameterValues))
      .slice().sort((a, b) => Number(!!b.isDefaultNonMaxConfig) - Number(!!a.isDefaultNonMaxConfig));
    choices.forEach((variant, choiceIndex) => {
      const parameterValues = [...variant.parameterValues.filter(item => item.id !== "provider"), { id: "provider", value: value.id }];
      const isDefault = index === 0 && choiceIndex === 0;
      variants.push({ parameterValues, displayName: name,
        displayNameOutsidePicker: parameterLabel(name, [...parameterValues.filter(item => item.id !== "fast"),
          ...parameterValues.filter(item => item.id === "fast")], definitions),
        isMaxMode: false, isDefaultNonMaxConfig: isDefault, isDefaultMaxConfig: isDefault });
    });
  });
  return { definitions, variants };
}

globalThis.__bridgeDockEnrichModels = function (rows, catalog) {
  rows = organizeModels(rows, catalog);
  const entries = Array.isArray(catalog) ? catalog : catalog?.data ?? [];
  const parametersEnabled = !!globalThis.__bridgeDockLocal?.modelParametersEnabled;
  return rows.map(row => {
    const metadata = entries.find(entry => entry.id === row.name);
    const { limit, efforts, defaultEffort } = modelCapability(metadata);
    const base = { ...row, ...(limit ? { contextTokenLimit: limit } : {}), supportsThinking: efforts.length > 0,
      supportsNonMaxMode: true, supportsMaxMode: false };
    if (!parametersEnabled) return { ...base, parameterDefinitions: [], variants: [] };
    const native = metadata?.bridgedock_parameters;
    if (native?.version === 1 && native.definitions?.length && native.variants?.length) {
      const definitions = localizedDefinitions(native.definitions);
      return { ...base, parameterDefinitions: definitions,
        variants: native.variants.map(variant => ({ ...variant,
          displayName: row.name, displayNameOutsidePicker: parameterLabel(row.name, variant.parameterValues, definitions),
          isMaxMode: false })) };
    }
    if (native?.version === 2 && Array.isArray(native.definitions)) {
      const parsed = nativeParametersV2(row.name, native);
      return parsed ? { ...base, parameterDefinitions: parsed.definitions, variants: parsed.variants }
        : { ...base, parameterDefinitions: [], variants: [] };
    }
    const contexts = contextChoices(limit);
    const reasoning = efforts.length ? ["none", ...efforts] : [];
    const parameterDefinitions = [
      ...(contexts.length > 1 ? [{ id: "context", name: "上下文预算",
        markdownTooltip: `模型上下文上限 ${tokenLabel(limit)}。选较小的值会更早压缩对话。`,
        parameterType: { enumParameter: { values: contexts.map(value => ({ value: String(value), displayName: tokenLabel(value) })) } } }] : []),
      ...(reasoning.length ? [{ id: "reasoning", name: "思考强度", isCycleableByHotkey: true,
        markdownTooltip: "选择本次请求的思考强度。“默认”使用所选模型原有的档位。",
        parameterType: { enumParameter: { values: reasoning.map(value => ({ value, displayName: effortLabel(value) })) } } }] : [])
    ];
    if (!parameterDefinitions.length) return { ...base, parameterDefinitions: [], variants: [] };
    const contextValues = contexts.length > 1 ? contexts.map(String) : [undefined];
    const reasoningValues = reasoning.length ? reasoning : [undefined];
    const variants = contextValues.flatMap(context => reasoningValues.map(effort => {
      const isDefault = (context === undefined || context === String(limit)) && (effort === undefined || effort === defaultEffort);
      return { parameterValues: [...(context !== undefined ? [{ id: "context", value: context }] : []),
        ...(effort !== undefined ? [{ id: "reasoning", value: effort }] : [])],
        displayName: row.name, displayNameOutsidePicker: parameterLabel(row.name,
          effort === undefined ? [] : [{ id: "reasoning", value: effort }], parameterDefinitions),
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
    const previousName = [selected?.modelName, sessionDefault].find(candidate => rows.some(row => row.name === publicModelName(candidate)));
    const name = publicModelName(previousName) ?? rows[0].name;
    const row = rows.find(row => row.name === name);
    const restoredParameters = saved?.preferences?.[name]?.parameters
      ?? saved?.preferences?.[previousName]?.parameters
      ?? saved?.composer?.selectedModels?.find(value => publicModelName(value.modelId) === name)?.parameters ?? [];
    const requested = enabled ? ((wasParametersActive ? selected?.selectedModels?.find(value => publicModelName(value.modelId) === name)?.parameters : undefined) ?? restoredParameters) : [];
    const parameters = enabled ? selectedParameters(row, requested) : [];
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
