BridgeDock 桥接台 1.4.10

面向 Apple Silicon Mac 的本地模型反代桌面应用。
界面使用 SwiftUI，内置 CLIProxyAPI 8.0.51 与 Kiro Plugin 0.1.1。
发行包包含运行所需内核，运行时无需安装 Node、Python、Docker 或 Homebrew。

主要功能

• 官方 API Key、Coding Plan Key、第三方中转站的新增、编辑、启停和删除。
• Claude、Codex、Kimi 国内/国际、Grok Build / xAI 与 Kiro 的账号登录入口。
• Grok Bot 通过 Cursor 网页授权后自动接入，账号 Key 也可分别接入两种通道。
• Kiro 的 AWS Builder ID 与组织账号登录，Google / GitHub 凭据 JSON 导入。
• Claude Code、ChatGPT / Codex、Kiro 本机登录一键导入，自动区分模型前缀。
• OpenAI Chat Completions、OpenAI Responses、Anthropic Messages 接口。
• 流式输出与工具调用由反代内核进行协议转换。
• /v1/images/generations 与 /v1/images/edits 统一改用 GPT 账号中版本最新的 gpt-image 模型，
  忽略客户端指定的生图模型，需要已连接 GPT / Codex 登录。
• 渠道独立前缀与模型别名，多渠道同名模型可分别选择。
• 真实模型列表获取、三种协议的手动测试。
• Claude 桌面端独立入口、第三方推理网关配置指引及连接信息复制。
• Claude Code、Codex CLI、Kimi Code 配置合并、自动备份和恢复。
• ZCode 和其他支持自定义 API 的工具可复制连接信息手动接入。
• 本机监听、独立管理密钥、菜单栏启停、全局与渠道级出站代理。

使用方法

1. 双击 BridgeDock.app，确认左下角显示服务已启动。
2. API 渠道中选择服务商，填写 Key，获取模型或手动填写模型 ID，再保存。
   模型列表每行一个，也可以写成“上游模型ID = 别名”。对外调用名为“渠道名称前四字/别名”。
3. 订阅账号使用浏览器完成授权。密码、二次验证和授权由账号持有人操作。
   已在官方客户端登录的 Claude、GPT / Codex、Kiro，可以直接点“连接本机登录”。
   Claude 读取 macOS 钥匙串或 .claude/.credentials.json；GPT 读取 .codex/auth.json；
   Kiro 读取 .aws/sso/cache/kiro-auth-token.json 及对应客户端注册文件。
   首次连接分别分配 claude、gpt、kiro 前缀；被占用时自动添加序号。
   能识别为同一账号时，更新保留前缀、备注、代理与停用状态；无法确认身份时会明确提示。
   原始客户端登录文件不会被修改。
   没有本机登录时会提示先登录，也可继续使用浏览器授权。
   通用 JSON 导入现在也接受 Claude Code 和 Codex 的原生凭据格式。
4. 点击任意页面顶部的“模型”按钮，勾选需要开放给各工具的反代模型。
   在模型与测试页选择已开放模型，测试需要的协议。真实测试会产生少量用量。
5. 在工具接入页选择工具与模型，可复制启动命令、复制连接配置、导出文件，
   或应用到选定的配置文件。应用前会保存原始文件备份。
6. 工具需要重新启动会话以加载新配置。退出 BridgeDock 会停止反代。
   只关闭窗口时服务继续运行，点击菜单栏图标可以重新打开。

接入地址

默认 OpenAI 兼容地址为 http://127.0.0.1:18417/v1
默认 Anthropic 兼容地址为 http://127.0.0.1:18417
API Key 使用工具接入页给出的本地密钥。
上游服务商的 Key 填写在 API 渠道里。
修改端口后，需要更新已接入工具中的本地地址。

当前适配范围

• Kiro 官方客户端的主模型配置入口，目前未在所核实的官方文档中找到任意
  Base URL 配置。这里提供 Kiro 账号作为上游来源。若要在 Kiro 编辑器使用
  其他接口，可使用支持自定义 API 的扩展。软件内的 Kiro 页会说明这一点。
• 在“Cursor / Grok Bot”中点击“Grok Bot 网页登录”，在授权页面完成登录，
  账号会自动保存。Grok Build / xAI 使用独立设备码授权。
  模型与额度以账号权限和实际响应为准。
• ZCode 对应的服务来源使用智谱 / Z.ai 的 API 或 Coding Plan Key。
  ZCode 客户端通过自定义模型连接信息手动配置。
• Kimi 自动配置按当前 Kimi Code CLI 的 ~/.kimi-code/config.toml 格式生成。
  旧版 kimi-cli 的路径、参数或能力字段可能不同，请核对配置预览。
• 自动合并 TOML 会保留其他普通配置。含多行字符串或冲突的手工 bridgedock
  配置时，需要手动合并。也可使用临时启动命令进行接入。
• 模型上下文长度、图片能力、推理参数、额度和权限由上游决定。Kimi 预设
  上下文长度为 32768，可在接入页按所选模型调整。
• 本次验收使用本地模拟接口。真实订阅授权、服务商网络和账号额度需添加后验证。

首页 Agent 启动器

在首页点击 Agent 图标，选择项目文件夹，再点“开始编辑”。
成功启动后记住所选 Agent 和项目，下次打开 BridgeDock 自动恢复。
Cursor 使用 Agents Window；Claude Code、Codex CLI、Kimi Code 在终端启动并接入 BD。
Kimi Code 首次启动会备份并应用其连接配置。Kiro 和 ZCode 按其客户端现有配置启动。
对应应用或 CLI 需要已经安装。

余额与额度

“余额与额度”按每个订阅账号、每个 API 渠道分别显示数据，支持搜索和手动刷新。
代理运行时每 5 分钟自动查询，显示最近成功更新时间；刷新失败会保留上次数据并标出原因。
支持 Claude、Codex、Kimi Code、Grok、Kiro 的可获取额度，以及 DeepSeek、Moonshot、
智谱 / Z.ai Coding Plan、New API 类中转站。各接口实际返回的额度、赠金、积分、
现金余额、周期和到期时间分别展示。缺少的数据不记作 0，也不混合不同货币。
API 渠道可以选择余额查询类型，或设置同一域名下的自定义余额接口路径。
New API 的令牌额度与账户额度分开显示；站内额度不会擅自换算成货币。
OpenAI、Anthropic、xAI 等普通 API Key 未提供可用余额接口时会说明原因。
查询仅使用只读接口；Grok 额度不可用时不会额外调用模型来探测。
当前版本使用模拟响应验收，真实账号需要添加后验证其权限与接口可用性。

Cursor 反代开关

在“工具接入”顶部选择 Cursor，用“使用 BD 反代”开关切换：
开启时，Cursor 主窗口使用 BridgeDock 中已接入的模型；关闭时，使用原来的 Cursor 官方账号。
无需单独安装或恢复。首次开启由 BridgeDock 自动备份并适配 Cursor，当前支持 3.27.22。
切换时会请求 Cursor 正常退出并重新打开。如出现保存提示，请在 Cursor 中完成保存。
如果取消退出或适配失败，则保持原模式，不强制结束 Cursor。
官方账号的登录凭据会保留；BD 模式前的模型列表与选择会保存，切回时恢复。
旧版本已改动但没有留下快照的模型选择无法追溯，切回后由 Cursor 刷新官方模型。

开启 BD 反代需要先在“订阅账号”或“API 渠道”中接入模型；开启时会自动启动本地服务。
关闭此开关只切换 Cursor，不会停止其他工具正在使用的 BridgeDock 服务。
关闭时，“打开 Cursor 主窗口”和首页打开项目均可直接使用官方模式。
本地会话服务使用 127.0.0.1:18418，仅接受本机安装时生成的会话密钥。
停止 BridgeDock 服务会暂停 BD 模式，新打开的窗口需在服务恢复后才能使用本地会话。
Cursor 的官方云端功能和订阅权益仍由其官方账号提供。

开关显示实际可用状态：服务未启动、会话失败或适配缺失时不再显示已开启。
切换时立即显示目标位置和进度；失败后恢复实际状态，并可重试连接或使用官方账号。
服务暂停后仍保留上次的 BD 模式选择，下次启动服务时会恢复。
退出检测同时核实进程是否存在，避免 Cursor 已退出后仍等待旧状态超时。

适配会保留已有汉化等其他修改，每次变更前的完整备份位于数据目录 cursor-backups。
汉化开关与 BD 适配可以任意顺序开关：切换汉化时，BridgeDock 先把 BD 适配原样撤下
（逐处还原注入的代码，不动汉化写入的内容），让语言包按它自己的记录安装或恢复，
完成后再装回 BD 适配。单独运行 cursor-zh/install.sh 时检测到 BD 适配仍会停下，
请在 BridgeDock 的开关里切换。
切换前会核对语言包的安装记录：如果汉化是在更早的 BD 适配之上装的，记录里已含旧适配
代码，撤下新适配也对不上，这时开关会提示原因并保持不动，不改任何文件。处理方法是
重新安装 Cursor 3.27.22，先开汉化，再开 BD 反代；之后两个开关可以随意切换。
Cursor 更新后会重新检查兼容性；遇到不支持的版本会停止切换。

数据与恢复

正常数据目录是 ~/Library/Application Support/BridgeDock。
目录权限为 0700，应用写入的配置与备份文件权限为 0600。
API Key 与 OAuth 凭据按内核要求以明文保存在该私有目录内。
state.json 是桌面端配置，config.yaml 是生成的内核配置，accounts 存放账号凭据。
backups 保存修改工具配置前的副本。removed-accounts 保存移除账号前的恢复副本。
恢复会核对文件摘要，如果目标文件已被其他程序修改，需要手工合并。
导出配置和复制命令包含本地连接密钥。
环境变量 BRIDGEDOCK_DATA_DIR 可将应用数据放入独立目录，用于开发验收。

开发构建

需要 macOS Xcode Command Line Tools，运行 ./build.sh。
默认输出 ../BridgeDock.app 和同目录的 BridgeDock-macOS-arm64.zip，也可传入自定义 App 路径。
在本机磁盘临时目录完成签名和打包，U 盘上不会产生 ._ 附带文件。
在受沙盒限制的终端中构建时，可加 SWIFT_EXTRA_FLAGS=-disable-sandbox。
构建生成本地 ad-hoc 签名，未进行 Apple 开发者公证。
Sources 为桌面应用源码，Vendor 内核及扩展保留各自 MIT 许可证。

本地测试

xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Integrations.swift Tests/LogicTests.swift -o /tmp/bridgedock-logic-tests
/tmp/bridgedock-logic-tests /tmp/bridgedock-test-data
python3 Tests/proxy_test.py /tmp/bridgedock-test-data

测试使用 127.0.0.1:19417 与 127.0.0.1:19419。
模拟服务使用测试凭据，OAuth 测试只生成并取消登录会话。

内核来源与校验

CLIProxyAPI 8.0.51
https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.51
原始 darwin_aarch64 压缩包 SHA-256
fb8e2568e98e3304a1b892c4f70a4c154c661078ad87007e63cf7ba71b4ce168

Kiro Plugin 0.1.1
https://github.com/xiaokui-dev/cliproxyapi-kiro-plugin/releases/tag/v0.1.1
原始 darwin_arm64 压缩包 SHA-256
17a393f5f1a431069b26f40bfe7f371759c81795369c56c229d7e75c76238feb
Vendor/kiro.dylib 由 Vendor/build-kiro.sh 从 v0.1.1 源码加 Vendor/KiroStreamChunks.patch 编译。
补丁把流式输出的 event 行和 data 行拆成两个分片：内核逐片转换成 OpenAI 格式时，
只识别以 data: 开头的分片，原版在 /v1/chat/completions 流式请求上会全部丢弃，
报 empty_stream: upstream stream closed before first payload。

适配参考

https://learn.chatgpt.com/docs/config-file/config-advanced
https://claude.com/docs/third-party/claude-desktop/gateway
https://code.claude.com/docs/en/llm-gateway
https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files
https://www.zcode.network/en/docs/configuration/
https://kiro.dev/docs/models/
https://docs.bigmodel.cn/cn/coding-plan/tool/claude
https://docs.x.ai/developers/rest-api-reference/inference/responses
https://help.router-for.me/management/api

额度与余额适配参考

https://help.router-for.me/management/apiv8
https://github.com/router-for-me/Cli-Proxy-API-Management-Center
https://github.com/xiaokui-dev/cliproxyapi-kiro-plugin
https://api-docs.deepseek.com/api/get-user-balance/
https://github.com/zai-org/zai-coding-plugins
https://docs.newapi.pro/en/docs/api/management/token-management/usage-token-get

额度解析回归测试

xcrun swiftc -O -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Integrations.swift Sources/Quotas.swift Tests/QuotaTests.swift -o /tmp/bridgedock-quota-tests
/tmp/bridgedock-quota-tests

ZCode 余额与流量修复（2026-11-03）

订阅账号使用 ZCode 插件查询套餐、赠送 Token、有效期和可用重置卡。
新版 Coding Plan 的 CREDIT_LIMIT 从对应国内或国际官方接口补充，分别显示
5 小时与每周积分；赠送 Token 与套餐积分保持原始单位，不合并为现金余额。
接口未提供的数值保持未知，辅助重置次数不计作余额，赠送套餐到期不标作重置。
参考 https://github.com/WizisCool/omc-zcode-oauth/blob/v0.2.0/go/quota.go
请求路由回归测试：
xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/ZCodeQuota.swift Tests/ZCodeQuotaTests.swift -o /tmp/bridgedock-zcode-quota-tests
/tmp/bridgedock-zcode-quota-tests


订阅与多账号更新（2026-11-03）

订阅页新增 Cursor Key 导入与 ZCode 国内/国际授权；每个账号独立保存。
ZCode 插件需要 macOS 15 或以上，macOS 14 可继续使用其他订阅和 Coding Plan API Key。
Grok Bot 支持通过 Cursor 网页授权自动保存凭据，也支持账户 Dashboard → API Keys
中创建的 User API Key。Cursor 通道继续通过 User API Key 接入。
https://cursor.com/docs/cli/reference/authentication

账号可以搜索、筛选、查看其模型，设置备注、独立模型前缀、优先级与出站代理。
同级账号默认轮询；高优先级优先选择。不同账号需要指定调用时请设不同前缀。
启停与删除只作用于选中凭据；删除前仍保留本机恢复副本。

Codex、Kiro 和 ZCode 支持针对已有凭据重新授权。Claude、Kimi、Grok 的再次登录
按内核规则保存凭据，Kimi 通常新增文件，不会按邮箱合并或自动删除旧账号。
Claude 支持完整回调 URL 与 code#state；回调必须匹配本次会话。
设备码流程采用内核提供的有效期；插件未回传有效期时，本机最多等待 15 分钟。
授权失败和超时会释放会话，允许重新登录。保存与运行时加载失败分开显示。
Kiro 可选择 Builder ID 或组织 SSO，切换方式保留设置中的组织 Start URL。

导入支持 CLIProxyAPI JSON、Kiro 原始 camelCase JSON、ZCode 原生 JSON、Cursor Key JSON。
完全相同的导入文件会跳过；不会按邮箱自动合并不同凭据。

新增插件来源
https://github.com/WizisCool/omc-zcode-oauth/releases/tag/v0.2.0
ZCode darwin_arm64 ZIP SHA-256
229811628567443d3053032ae70398da02456e7f8bc404213a2bf558ac3e03c5
https://github.com/enderzcx/cursor-agent2api/releases/tag/v0.2.2
Cursor darwin-arm64 tar SHA-256
f78596c782a77999212df2cbb19c01c375247ecf784cd0b504ccea57b918e25e
插件许可证与 NOTICE 均保存在 Vendor 并随应用分发。

订阅回归测试
xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Tests/SubscriptionTests.swift -o /tmp/bridgedock-subscription-tests
/tmp/bridgedock-subscription-tests
python3 Tests/subscription_proxy_test.py

验证包含隔离目录中的假凭据和本机接口。真实账号需由持有人在浏览器完成密码、
二次验证与授权，并用其可用模型验证订阅权益；未把模拟测试记作真实账号已通过。


官方渠道自动填写（1.3.1）
选择官方渠道时，名称、协议、Base URL、唯一前缀、余额类型、常用模型全部预填。
填入 Key 后自动查询真实模型列表；查询失败保留已有内容，不用错误清空模型。
Kimi Code会员订阅与Moonshot开放平台分别提供国内/国际预设；误选同地域产品时，
仅在原接口返回401、另一官方接口明确验证成功后修正地址与协议。
模型发现采用官方鉴权，Kimi Code使用Bearer；不会伪装成其他客户端。
智谱/Z.ai Coding Plan按官方文档预填glm-5.3、glm-5.3-flash，不依赖未公开的models接口。
默认模型仅表示服务商文档列出的模型，不代表当前Key拥有所有模型权限。
正在查询时改动Key、地址或模型，旧响应不会覆盖新输入；现存模型与别名由用户选择更新。
预设来源链接在编辑页显示，便于核对。


Kimi Work 通道（1.3.2）
在本机Kimi桌面端登录Work后，在订阅页点击“连接本机Work”。
通道使用独立的agent-gw.kimi.com/coding/v1网关，模型从Work实时查询。
与Kimi Code订阅Key渠道分开；Work消耗会员月度共享额度，不是无限额度。
账号绑定只保存用户ID摘要；每12秒检查桌面凭据变化，并更新内核私有配置。
state.json不保存Work/Web令牌；内核运行配置按原安全机制存放在0700目录、0600文件内。
不会修改Kimi桌面配置或消费其refresh token；由桌面端负责登录续期。
切换桌面账号时暂停旧通道，需要明确点击重新连接。
余额页仅显示会员共享池；登录过期或接口失败保留未知，不将其写成0。
此接入参考社区实现和本机官方客户端，属于未公开的桌面接口，版本变化时可能需重新适配。
参考 https://github.com/keenlin/magpie-plugins/tree/3e966bb4b5f21b9b3d1cbe6c4d15cca8fbf32fe9/packages/kimi-work
额度规则 https://www.kimi.com/help/membership/membership-update-rules


模型发布与 Cursor 参数（1.4.0）

在“模型与测试”点击“选择反代模型”，可搜索渠道或模型、全选、清空，再保存选择。
“工具接入 → Cursor”也有相同入口。只发布勾选的模型；未勾选的模型不会出现在
/v1/models 中，手工填写模型 ID 也不能调用。API 渠道与订阅账号均适用。

对外名称采用“渠道名称前四个字符/模型名或别名”，例如“我的渠道/gpt-model”。
订阅账号采用账号备注（没有备注时用服务商名称）；前四字相同的渠道会添加稳定短标记。
升级或修改渠道名称后，请刷新客户端模型列表，并更新手工保存的旧模型 ID。
首次升级默认发布全部现有模型。第一次保存后使用固定选择，新发现的模型需要另行勾选；
清空后保存会关闭全部模型的对外调用。已配置工具的 API 地址和本地 Key 保持原值。

“工具接入 → Cursor → 在 Cursor 中调整模型参数”为独立开关。
开启“使用 BD 反代”和参数开关后，在 Cursor 原生模型选择器中选择 BD 模型，
即可调整“上下文”和“思考强度”。首次适配或改变参数开关会正常重启 Cursor；
遇到保存提示请先保存，不会强制结束 Cursor。适配支持 Cursor 3.27.22。

模型上下文与思考强度（2026-11-03）

每个模型的上下文窗口和可选思考强度按模型分别查询，不再使用统一档位：
• API 渠道获取模型时一并读取服务商 /models 返回的 context_length、思考档位
  （如 Kimi 的 think_efforts），写入该渠道的模型记录。旧渠道启动后自动补查一次，
  只补记录，不改模型列表和别名。
• 订阅账号和未返回这些字段的渠道，使用反代内核按服务商整理的模型资料
  （/v8/management/routing/model-definitions）。同名模型优先用所属服务商的资料，
  例如 Kiro 的 claude-opus-4-5 是 200K，直连 Claude 时按 Claude 的资料。
• 两处都没有的模型保持“未知”，不会编造上限；图像模型等本来就没有上下文窗口。
“模型”选择窗口在每个模型下方显示记录到的上下文和思考强度。

这些信息随 /v1/models 发布为 capabilities.context_length 和 reasoning_effort。
Cursor 本地 Agent 用它作为剩余上下文的分母，因此 BD 模式下输入框旁的剩余上下文
会正常显示；不开参数开关也会显示。开启参数开关后：
• “上下文”默认是模型真实上限，另外提供几档较小的预算，选小值会更早压缩对话。
  模型没有公布上限时不显示此项。
• “思考强度”只列出该模型支持的档位，另有“关闭”表示不发送思考参数。
  模型不支持思考时不显示此项。
这些设置进入本地 Agent 的实际上下文预算与推理请求，不只是显示标签。

参数偏好按 BD 模型保存，与 Cursor 官方模型配置分开。关闭参数开关后停止应用这些覆盖，
重新开启可以恢复已保存偏好；关闭“使用 BD 反代”仍恢复原来的 Cursor 官方模式。
本次回归使用本机模拟上游，未消耗真实账号额度；服务商实际支持范围仍以其响应为准。


Kimi 账号分组（1.4.2）

订阅账号页将 Kimi Code 国内、Code 国际和 Work 的添加入口集中在“Kimi 账号”。
已连接的 Code 与 Work 也在同一个 Kimi 分组中显示，可以统一搜索和筛选。
Work 可直接在账号页管理设置、模型、启停和断开；原有 API 渠道入口仍可使用。

Code 与 Work 继续使用各自的凭据、模型、调用前缀和额度查询，不合并计费通道。
新连接 Work 时会避开已有账号及渠道的前缀；保存渠道时也会拒绝与订阅账号重名的前缀。
已保存的前缀不会自动改名。如旧配置存在重名，请在 Work 设置中换用独立前缀。

Claude 登录修复（1.4.5）

Claude 登录页地址包含 code=true，它是请求显示授权码的开关，不是授权结果。
现在会在本机拦截误贴的登录页链接，提示先完成网页授权；校验失败不会提交到
内核，也不会丢失本次登录会话。完成后通常自动返回 BridgeDock；需要手动提交时，
请复制授权完成页面的整段 code#state，或 localhost 上的完整回调地址。
提交成功后禁用重复提交。Claude / Codex 等待期限按内核的 5 分钟显示，
不再错误显示 15 分钟；超时请重新授权，不要复用之前页面的授权码。

回归测试覆盖登录页误贴、完整回调解码、会话有效期和重复提交。实际提交链路
使用隔离目录与本机模拟接口，不会请求 Claude 或读取现有账号：
python3 Tests/claude_oauth_flow_test.py /tmp/bridgedock-claude-oauth-flow-tests
测试二进制由 Sources 中除 App.swift 外的 Swift 文件与
Tests/ClaudeOAuthFlowTests.swift 一同编译（链接 SwiftUI、AppKit、CryptoKit）。


Cursor 参数菜单可见性（1.4.6）

启用“在 Cursor 中调整模型参数”后，打开 Cursor 模型菜单，点击模型行右侧的 Edit。
上下文预算和思考深度沿用 Cursor 原生编辑控件；Edit 按钮保持可见。
所有模型的菜单显示名、输入框短名与别名均保留完整的“渠道前四字/模型名”。
参数设置已经在真实 Cursor 3.27.22 的模型菜单中验证，可保存并恢复默认。
此适配不改变 Cursor 账号权限与计费权益；上下文真实上限仍由上游模型决定。


独立模型按钮（1.4.8）

每个页面右上角固定显示“模型”按钮及已开放数量。点击后按渠道分组勾选反代模型，
支持搜索渠道或模型、只看已选、全选搜索结果、整组选择与清空全部。
“工具接入 → Cursor”和“模型与测试”的原入口打开同一个选择窗口。
保存会更新所有接入工具共享的反代范围；取消不会改变已保存配置。
服务停止时仍可打开窗口，点击“启动服务”后获取目录并保存。
搜索与刷新不会覆盖已经编辑的勾选；暂不可用的已选模型仍保留原来的选择。
此入口只管理模型是否开放，与 Cursor 选择本次对话模型、调整模型参数分别独立。


Cursor 模型选择界面整理（1.4.8）

BD 模式下，Cursor 原生模型菜单按完整渠道名称分组，并显示各组模型数量。
列表加宽以容纳模型名称；“搜索渠道或模型”支持渠道名和模型关键词，
原来的 Edit 改为“参数”，仍沿用原生上下文预算与思考深度控件。
完整调用名称保持不变；同名渠道分别显示，不合并模型或计费通道。

从 BridgeDock 返回 Cursor 或重新打开模型菜单时，自动获取最新的反代目录。
目录没有变化时保持当前选择；刷新失败保留上次列表。确认清空全部发布模型后，
菜单也清空，不用旧模型记录或官方 Auto 补回。官方模式保持原有菜单与模型设置。
这与 BridgeDock 的“模型”按钮分别作用：前者选择对话使用的模型，后者控制反代范围。


Cursor / Grok Bot 共享登录入口（1.4.10）

订阅账号页的“Grok Bot 网页登录”创建独立授权会话，使用 Cursor 的
loginDeepControl 页面、随机 proof key 和 redirectTarget=sand。
内核轮询 auth/poll，完成后保存账号并加载模型。授权可取消，五分钟后超时。
网页登录使用 sand 通道，通过账号自身的 refresh token 续期。
在“添加账号 Key”中可选择 Cursor 或 Grok Bot：前者使用 agent_v1，后者使用 sand。
两者都交给 cursor-agent-v1 插件处理；Grok Bot 不会误走 Grok Build / xAI 授权。
同一个 Key 可接入两个通道，分别保存凭据和独立前缀；已接入的 Cursor 账号不改名。
账号列表和模型分组按所选通道显示。选择 Grok Bot 会使用插件对应的模型目录。

本地插件在 cursor-agent2api v0.2.2 上补充网页授权和续期。
每次明确发起网页登录会添加一份独立凭据，使用独立前缀。
补丁与重建脚本位于 Vendor/CursorWebLogin.patch 和 Vendor/build-cursor-web-login.sh。
网页登录依据以下项目及本机 Grok Bot 0.78.1 的客户端流程适配。
参考：https://github.com/qunqin24/Pulse/blob/main/Sources/Pulse/Auth/CursorWebLogin.swift
参考：https://github.com/andreanjos/grokbot-headless/blob/main/grok-bot-headless.mjs
参考：https://cursor.com/help/grok-bot/sign-in
参考：https://github.com/enderzcx/cursor-agent2api/tree/v0.2.2

验证：订阅凭据单元测试、隔离内核双通道模型目录测试和完整应用构建。
测试仅使用模拟 Key，并通过沙盒阻断外网，不消耗真实模型额度。
