Assropic 1.4.22

Assropic 是原 BridgeDock 的新品牌名称。本次改名只更新应用外观、发行包和仓库名称；
已有的 BridgeDock 数据目录、配置键、协议头和 Cursor 适配文件保持兼容，升级后无需重新登录。

面向 Apple Silicon Mac 的本地模型反代桌面应用。
界面使用 SwiftUI，内置 CLIProxyAPI 8.0.53、Kiro Plugin 0.1.1 与 kiro2cc-proxy 3.5.1。
发行包包含运行所需内核，运行时无需安装 Node、Python、Docker 或 Homebrew。

主要功能

• 官方 API Key、Coding Plan Key、第三方中转站的新增、编辑、启停和删除。
• 接管中转站的“导入 CC Switch”按钮，自动识别并直接导入为 BD 渠道，后台入口保留在中转站。
• 登录 Sub2API 中转站：内嵌网页登录一次，BD 独立续期；随时新建 Key 并一键接入，Key 失效自动换新，定时核验模型真伪。
• Claude、Codex、Cursor（含 Grok Bot 与 Grok Build / xAI）、Kimi 国内/国际与 Kiro 的账号登录入口。
• Cursor 独立账号入口，支持账号 Key、邮箱----user_…::令牌、会话 Cookie 或 JWT。
  会话先经 Cursor 官方接口验证身份再保存；可使用账号有权限的第三方模型。
  同一账号重新粘贴新会话时更新令牌，保留前缀、备注、代理及停用状态。
  会话到期后需要重新导入，不会把网页会话误当成能自动续期的 API Key。
  Cursor 模型从账号的官方 GetUsableModels 目录读取，沿用 BD 的统一接口、
  模型选择、渠道前缀和反代逻辑。此操作不登录或切换本机 Cursor 编辑器账号。
  仅需 Max 模式才能使用的条目暂不开放。上游账单、权限和版本错误显示具体原因。
  模型按钮打开原生参数菜单，显示 Cursor 官方提供且账号可用的参数组合。
  Fast、Context、Effort 和 Thinking 按所选模型提供，映射到同账号对应的上游模型 ID。
  其他渠道显示自身公布的思考档位和上下文预算；不可用的档位或组合会明确报错。
• Grok Bot 通过 Cursor 网页授权后自动接入，账号 Key 也可分别接入两种通道。
• Kiro 的 AWS Builder ID 与组织账号登录，Google / GitHub 凭据 JSON 导入。
• 自动扫描 Claude Code、ChatGPT / Codex、Kiro 本机登录，一键导入并自动区分模型前缀。
  首次接入后凭据复制到 Assropic 私有数据目录，由 BD 独立刷新和运行；删除源 Harness 或 Agent 不影响已接入账号。
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

1. 双击 Assropic.app，确认左下角显示服务已启动。
2. API 渠道中选择服务商，填写 Key，获取模型或手动填写模型 ID，再保存。
   模型列表每行一个，也可以写成“上游模型ID = 别名”。对外调用名为“渠道名称前四字/别名”。
3. 订阅账号使用浏览器完成授权。密码、二次验证和授权由账号持有人操作。
   已在官方客户端登录的 Claude、GPT / Codex、Kiro，可以点击“自动读取本机登录”，一次扫描并接入所有已发现账号；也可以在服务商卡片中单独连接。
   Claude Code 读取 macOS 钥匙串或 .claude/.credentials.json；设置了
   CLAUDE_CONFIG_DIR / CLAUDE_SECURESTORAGE_CONFIG_DIR 时也会查找对应的分身钥匙串；
   Claude Desktop 运行时会从已启动的内置 Code 会话读取本机 OAuth 登录；GPT 读取 .codex/auth.json；
   Kiro 读取 .aws/sso/cache/kiro-auth-token.json 及对应客户端注册文件。
   Kimi Code、Cursor 和 ZCode 也提供“读取本机订阅”入口，会按各自客户端的
   credentials/auth/config 文件（Kimi Code 登录 token 会按 config.toml 中的 OAuth 引用读取
   ~/.kimi-code/credentials/，也支持 KIMI_CODE_HOME）读取；找不到或格式不匹配时
   明确提示，不要求覆盖粘贴凭据。原始登录文件只读，不会被修改。
   首次连接分别分配 claude、gpt、kiro 前缀；同一服务商再连接的账号加入已有账号池（共用前缀）。
   能识别为同一账号时，更新保留前缀、备注、代理与停用状态；无法确认身份时会明确提示。
   原始客户端登录文件不会被修改。规范化后的令牌会复制到 Assropic 私有数据目录
   的 accounts/，账号行显示“BD 已保存”；后续模型调用、额度刷新和凭据续期由 BD 自己完成，
   即使删除原来的 Harness 或 Agent，已接入账号仍可继续运行。
   没有本机登录时会提示先登录，也可继续使用浏览器授权。
   通用 JSON 导入现在也接受 Claude Code 和 Codex 的原生凭据格式。
4. 点击任意页面顶部的“模型”按钮，勾选需要开放给各工具的反代模型。
   在模型与测试页选择已开放模型，测试需要的协议。真实测试会产生少量用量。
5. 在工具接入页选择工具与模型，可复制启动命令、复制连接配置、导出文件，
   或应用到选定的配置文件。应用前会保存原始文件备份。
6. 工具需要重新启动会话以加载新配置。退出 Assropic 会停止反代。
   只关闭窗口时服务继续运行，点击菜单栏图标可以重新打开。
7. 从“应用程序”或其他文件夹重复打开 Assropic，会显示正在运行的窗口。
   同一数据目录仅允许一个实例运行，避免两个副本争抢端口或修改同一份配置。
   应用意外退出后可直接重开，无需删除锁文件；其他程序占用端口时会显示具体端口。

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
• 在“Cursor”中点击“Grok Bot 网页登录”，在授权页面完成登录，
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
成功启动后记住所选 Agent 和项目，下次打开 Assropic 自动恢复。
Cursor 使用 Agents Window；Claude Code、Codex CLI、Kimi Code 在终端启动并接入 BD。
Kimi Code 首次启动会备份并应用其连接配置。Kiro 和 ZCode 按其客户端现有配置启动。
对应应用或 CLI 需要已经安装。

模型读取与 Fast 模式

模型目录读取不再只认 `data[].id`：也接受 `modelId`、`model_id`、`slug`、`name`、
`modelName` 及嵌套的 `result/models`、`items` 等常见结构，并把上下文、输出上限、
思考档位和视觉能力统一成标准能力字段。Cursor 的非标准 slug 会按官方目录的
family/variant 归并；目录接口字段变化时，会从已注册的真实 slug 推导基础模型、
思考档位和 Fast 选项，调用仍使用原始上游 ID。

同一渠道中带 `-highspeed`、`-high-speed`、`-fast` 或 `-高速` 后缀的 Kimi 等模型，
在能力一致或服务商明确为 Kimi 时合并成一个基础模型，并在模型选择器显示“快速模式”。
旧的高速模型 ID 仍可调用，会自动转换为基础模型加 Fast=true。

余额与额度

“余额与额度”按每个订阅账号、每个 API 渠道分别显示数据，支持搜索和手动刷新。
代理运行时每 5 分钟自动查询，显示最近成功更新时间；刷新失败会保留上次数据并标出原因。
支持 Claude、Codex、Kimi Code、Grok、Kiro 的可获取额度，以及 DeepSeek、Moonshot、
智谱 / Z.ai Coding Plan、New API 类中转站。各接口实际返回的额度、赠金、积分、
现金余额、周期和到期时间分别展示。缺少的数据不记作 0，也不混合不同货币。
API 渠道可以选择余额查询类型，或设置同一域名下的自定义余额接口路径。未知中转站
不会再自动猜测 New API；需要在渠道设置中明确选择查询类型。余额页会隐藏没有任何
数值的空指标，保留上次成功结果并标记刷新失败，不再显示一堆“未提供数值”的空卡片。
New API 的令牌额度与账户额度分开显示；站内额度不会擅自换算成货币。
OpenAI、Anthropic、xAI 等普通 API Key 未提供可用余额接口时会说明原因。
查询仅使用只读接口；Grok 额度不可用时不会额外调用模型来探测。
当前版本使用模拟响应验收，真实账号需要添加后验证其权限与接口可用性。

Cursor 反代开关

在“工具接入”顶部选择 Cursor，用“使用 BD 反代”开关切换：
开启时，Cursor 主窗口使用 Assropic 中已接入的模型；关闭时，使用原来的 Cursor 官方账号。
无需单独安装或恢复。首次开启由 Assropic 自动备份并适配 Cursor，当前支持 3.27.22。
切换时会请求 Cursor 正常退出并重新打开。如出现保存提示，请在 Cursor 中完成保存。
如果取消退出或适配失败，则保持原模式，不强制结束 Cursor。
官方账号的登录凭据会保留；BD 模式前的模型列表与选择会保存，切回时恢复。
旧版本已改动但没有留下快照的模型选择无法追溯，切回后由 Cursor 刷新官方模型。

开启 BD 反代需要先在“订阅账号”或“API 渠道”中接入模型；开启时会自动启动本地服务。
关闭此开关只切换 Cursor，不会停止其他工具正在使用的 Assropic 服务。
关闭时，“打开 Cursor 主窗口”和首页打开项目均可直接使用官方模式。
本地会话服务使用 127.0.0.1:18418，仅接受本机安装时生成的会话密钥。
停止 Assropic 服务会暂停 BD 模式，新打开的窗口需在服务恢复后才能使用本地会话。
Cursor 的官方云端功能和订阅权益仍由其官方账号提供。

开关显示实际可用状态：服务未启动、会话失败或适配缺失时不再显示已开启。
切换时立即显示目标位置和进度；失败后恢复实际状态，并可重试连接或使用官方账号。
服务暂停后仍保留上次的 BD 模式选择，下次启动服务时会恢复。
退出检测同时核实进程是否存在，避免 Cursor 已退出后仍等待旧状态超时。

适配会保留已有汉化等其他修改，每次变更前的完整备份位于数据目录 cursor-backups。
汉化开关与 BD 适配可以任意顺序开关：切换汉化时，Assropic 先把 BD 适配原样撤下
（逐处还原注入的代码，不动汉化写入的内容），让语言包按它自己的记录安装或恢复，
完成后再装回 BD 适配。单独运行 cursor-zh/install.sh 时检测到 BD 适配仍会停下，
请在 Assropic 的开关里切换。
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

运行模式

设置与诊断中提供两个顶层模式：

• 传统反代模式：沿用 Assropic 原有账号池、会话粘性和本地反代，不启动 CCBaga。
• CCBaga 模式：本机 Claude 账号按账号名保存独立环境记录，新导入账号使用独立路由前缀，刷新时不自动并入 Claude 账号池。
  每个 Claude 账号可以单独选择“使用 CCBaga 浏览器”或“不使用 CCBaga 浏览器”。该开关只记录本地环境偏好，
  不修改 Claude Desktop / Claude Code，也不读取 CCBaga 的 token、Cookie 或加密 vault。

本机 Claude 登录导入后，凭据会复制到 Assropic 自己的 accounts/ 目录；退出或切换源 Claude 客户端不会删除这份副本。
如果来源只有 Claude Desktop 进程中的短期 access token，界面会提示凭据过期后需要重新授权；已存在的 refresh token 不会被短期来源覆盖。

开发构建

需要 macOS Xcode Command Line Tools，运行 ./build.sh。
默认输出 Assropic.app 和同目录的 Assropic-macOS-arm64.zip，也可传入自定义 App 路径。
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

CLIProxyAPI 8.0.53
https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.53
原始 darwin_aarch64 压缩包 SHA-256
24a9116a9be459e9d1df5a9792eca17f04c0bb8505584d40c5b255565d07186f

Kiro Plugin 0.1.1
https://github.com/xiaokui-dev/cliproxyapi-kiro-plugin/releases/tag/v0.1.1
原始 darwin_arm64 压缩包 SHA-256
17a393f5f1a431069b26f40bfe7f371759c81795369c56c229d7e75c76238feb
Vendor/kiro.dylib 由 Vendor/build-kiro.sh 从 v0.1.1 源码加 Vendor/KiroStreamChunks.patch 编译。
插件现在只负责 Kiro 登录、账号列表、额度和凭据刷新；它会把上游回复收完再一次性发出，
所以 Kiro 的模型请求改由 kiro2cc-proxy 处理。

kiro2cc-proxy 3.5.1（Kiro 推理，逐段流式输出）
https://github.com/TsinHzl/kiro2cc-proxy/tree/e5387453c10a87e350fbe2d7c6505a1b128f5445
源码压缩包 SHA-256
b2e35fd35b9daeaffaa290298d4d64c18cb00387631868eee4745c9218200ec9
Vendor/kiro2cc-proxy 由 Vendor/build-kiro2cc.sh 编译，构建时运行上游测试；
打上 Vendor/Kiro2ccFreeOpus.patch：上游按订阅名把 KIRO FREE 账号排除在 Opus 之外，而 Free 账号
实际可以调用 Opus 5.5，补丁去掉这条限制，Opus 请求也在所有账号间轮流。某账号上游确实不提供
某模型时，仍由 kiro2cc 按各账号 ListAvailableModels 结果的路由过滤排除。补丁还让
reasoning_effort 接受 xhigh、max（原版会忽略，等于不开思考）；kiro2cc 把思考预算统一封顶在
24576，所以这两档在 Kiro 上与 high 相同。Assropic 给 Kiro 的 Claude 模型声明 low–max 五档，
合并模型里选思考强度时不会再被切到其他供应商；
再打上 Vendor/Kiro2ccTruncatedToolUse.patch：上游有时在工具调用参数输出到一半时干净地结束流
（没有 stop、没有 meteringEvent，读流也不报错），原版照常收尾，客户端拿到 tool_calls 结束原因后
执行半截参数的工具调用，残缺历史带进下一轮后上游对该会话持续返回空响应。补丁在这种情况下
改发“流中断”error，客户端按出错重试这一轮；
内置管理网页用空页面替代，Assropic 不使用它。
运行方式：
• 内核启动后，Assropic 把 accounts/ 中的 Kiro 账号转换成 kiro-runtime/credentials.json，
  在 127.0.0.1:18421 启动 kiro2cc-proxy。每个模型前缀单独一个随机内部 Key，只绑定该前缀的账号。
• 启用两个或更多 Kiro 账号时，额外生成一个绑定全部账号的共享 Key，kiro2cc 以 balanced 模式运行：
  所有账号同时在线、各自刷新令牌互不覆盖；新会话依次分给 A → B → A …，同一会话按
  agentContinuationId 留在原账号；某个账号失效时自动跳过，恢复后重新加入。
  此时客户端选 kiro/… 还是 kiro-2/… 都走共享池。账号文件里写 "pool": false 可让它退出共享池，
  只通过自己的前缀调用。若某个会话收到非超大上下文的 200 空流，运行时会清除该会话的
  sticky 绑定，客户端重试时自动轮到另一个账号；超大上下文仍提示压缩，不盲目切号。
• 网关把 owned_by 为 kiro 的模型的 Chat、Messages、Responses 请求转给它；其他接口和
  未就绪时仍走内核里的 Kiro 插件。连不上 kiro2cc（例如崩溃后重启的几秒）且还没向客户端
  回任何内容时，网关把这条请求改发给内核，只是变回整段返回，不会报错。
• 账号增删、启停、调优先级、重新登录都通过 kiro2cc 管理接口热更新，不重启进程，其他账号上
  正在输出的流不受影响；新凭据和 Key 先建好、网关切过去后才删除旧的。只有上游代理变化，
  或管理接口无法表达的改动（例如去掉 clientId），才整进程重启。
• kiro2cc 自己退出时自动重启，间隔 1、2、4 … 秒，最长 60 秒；稳定运行 5 分钟后重新从 1 秒算。
• 各账号的额度（订阅等级）启动时同时查询，之后每 30 分钟刷新一次。
• kiro2cc 刷新的令牌每分钟及停止前写回 accounts/，读写在后台队列上进行，不占主线程；
  写回前会再读一次文件，界面里刚重新登录的账号不会被旧令牌覆盖。credentials.json 保持 0600。
• kiro2cc.log 在 info 级别只记请求元数据（会话 id、哈希、token 数），不含令牌和提示词。
• HOME 指向 kiro-runtime/，不会读取用户的 ~/.aws 缓存。
测试：
xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/ModelPublishing.swift Sources/ModelGateway.swift Sources/KiroRuntime.swift Tests/KiroRuntimeTests.swift -o /tmp/bridgedock-kiro-runtime-tests
/tmp/bridgedock-kiro-runtime-tests
xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/ModelPublishing.swift Sources/ModelDiscovery.swift Sources/ModelGateway.swift Sources/KiroRuntime.swift Tests/ModelGatewayTests.swift -o /tmp/bridgedock-gateway-tests
python3 Tests/model_gateway_test.py /tmp/bridgedock-gateway-tests
压力测试（走 BD 网关，和 Cursor 同一条路径；需要 Assropic 正在运行且启用两个以上 Kiro 账号）：
python3 -I Tests/kiro_pool_stress.py [smoke rotation sticky burst hot crash refresh soak]
  hot 阶段会临时禁用一个账号再恢复；crash 阶段会 kill -9 kiro2cc 验证自动重启。
  BD_STRESS_SOAK=秒数、BD_STRESS_WORKERS=并发数 控制 soak 阶段；结果写到 kiro-stress-result.json。
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
同一服务商的账号组成账号池，新对话依次分到各账号；高优先级优先选择。需要单独调用某个账号时，
给它填一个不同的前缀（独立账号）；清空前缀即回到账号池。
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


Kimi Work 独立通道（2026-11-04）
在订阅页 Kimi Work 中点击“网页登录”，在 Assropic 内的官方网页完成登录。
Assropic 独立保存会话与 Work Key，并为自己的会话续期；无需安装或运行 Kimi 客户端。
旧版桌面绑定在首次启动时迁移一次；不再轮询桌面文件，也不消费桌面端的 refresh token。
迁移时保留原账号、前缀、模型别名和启停状态。旧网页令牌过期时，模型 Key 仍可独立反代，
但刷新模型目录和查询额度需要点击“重新网页登录”。凭据保存在数据目录 kimi-work/，
目录权限 0700、文件权限 0600；state.json 仅保存账号摘要与模型能力。

模型改从官方 DescribeKimiWorkConfig 获取，包含 K3.1 Pro（k3d1-agent）及可用速度选项；
不再将仍只返回 K3/K2.8 的旧 /coding/v1/models 列表当成完整 Work 目录。
旧连接迁移时可一次性导入同账号的官方目录缓存；在线刷新失败会保留已保存目录。
新发现模型追加到可选目录，已有别名保留；固定发布列表仍需在“模型”中勾选新模型。
Fast 按上游 speedOptions 显示，在 Cursor 模型参数菜单切换，也可在 API 请求中传入
X-Kimi-Model-Speed: fast（普通速度为 standard）。只有账号目录明确支持的速度才允许使用。
上下文由 X-Kimi-Context-Length 传递，默认 262144，可选 1000000 以上游权限为准。
Work 的 low/high/max 思考档位完整传入反代内核，避免 max 被降为 high。
三种协议（Chat Completions、Responses、Messages）均支持上述参数与流式输出。
Fast、超长上下文和高思考强度可能消耗更多会员额度；Work 与 Kimi Code 的计费通道分开。

回归测试：
xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/KimiWork.swift Sources/KimiWorkCatalog.swift Sources/KimiWorkRouting.swift Sources/ModelPublishing.swift Sources/ModelGateway.swift Tests/KimiWorkIndependentTests.swift -o /tmp/bridgedock-work-tests
/tmp/bridgedock-work-tests
python3 Tests/kimi_work_proxy_test.py /tmp/bridgedock-work-tests Vendor/cli-proxy-api

协议参考：本机官方 Kimi 3.2.24 客户端（登录、DescribeKimiWorkConfig、Work Key 与速度请求头）
模型发布 https://www.kimi.com/en/blog/kimi-k3-1-pro
旧版迁移参考 https://github.com/keenlin/magpie-plugins/tree/3e966bb4b5f21b9b3d1cbe6c4d15cca8fbf32fe9/packages/kimi-work


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
内核，也不会丢失本次登录会话。完成后通常自动返回 Assropic；需要手动提交时，
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

从 Assropic 返回 Cursor 或重新打开模型菜单时，自动获取最新的反代目录。
目录没有变化时保持当前选择；刷新失败保留上次列表。确认清空全部发布模型后，
菜单也清空，不用旧模型记录或官方 Auto 补回。官方模式保持原有菜单与模型设置。
这与 Assropic 的“模型”按钮分别作用：前者选择对话使用的模型，后者控制反代范围。


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


模型选择器修复（1.4.18）

Cursor 的上下文、思考强度、快速模式与档位名称统一使用中文。
Claude 模型版本号的点号和短横线写法合并到同一个入口，供应商菜单可分别选择 Claude 与 Kiro；真实调用 ID 和原有发布选择保持不变。
普通 API 渠道恢复较小的本地上下文预算，例如 1M 窗口可选 200K、256K、512K、1M。
Cursor / Work 继续只提供账号实际支持的档位与组合，不跨供应商借用参数。
旧的 Kiro 点号模型名称仍可调用，客户端刷新会保留原供应商选择。


中转站一键导入（1.4.20）

Sub2API、New API 等中转站的令牌页有“导入 CC Switch”按钮，点击后浏览器打开
ccswitch://v1/import?resource=provider&app=…&endpoint=…&apiKey=… 链接。
Assropic 登记并接管这个链接：点击按钮后自动识别，直接存成一条 API 渠道，
请求仍经 Assropic 自带的本地反代内核转发，不改用 CC Switch 或其他程序。
协议按所选客户端识别（Claude Code → Anthropic Messages，Codex → OpenAI Responses，
Grok Build → xAI，OpenCode 等 → Chat Completions）。链接不带模型时自动查询中转站的模型列表；
已手动挑选过开放模型时，新渠道的模型一并开放。导入结果显示在“账号与渠道”页顶部。
只有查不到模型、本地服务没启动等无法自动完成的情况，才打开编辑器补全。
渠道前缀取站点域名（例如 api.aiportx.com → aiportx），中文站名不影响路由。
同一站点、同一 Key、同一协议再次导入时更新原渠道，不会重复添加。

渠道仍归中转站管理：导入时记住站点名和后台地址（Sub2API 为 /keys 令牌页，
其他站点为站点首页，也可在渠道设置里修改）。渠道行显示“中转站 · 站名”，
右侧“中转站后台”按钮直接打开该页面，充值、换 Key、查看明细和删除令牌都在那里操作。
链接带的余额脚本指向 /v1/usage 时，余额查询使用新的“Sub2API 令牌、订阅与钱包额度”，
显示钱包余额、令牌总额度、5 小时 / 每日 / 7 天限额、订阅周期用量、到期时间和今日消费。

设置与诊断页的“中转站一键导入”开关默认开启，关闭后忽略收到的导入链接。
只支持服务商链接，Gemini 原生协议、MCP、提示词和技能链接会提示原因，不会导入。

xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Quotas.swift Sources/CCSwitchLink.swift Tests/CCSwitchLinkTests.swift -o /tmp/bridgedock-ccswitch-tests && /tmp/bridgedock-ccswitch-tests


登录中转站与模型核验

账号与渠道 → 自定义 → “登录中转站”。目前支持 Sub2API 站点（AIportX、Noot 等）。
1. 填写站点后台地址。BD 先读取 /api/v1/settings/public 确认是 Sub2API，再在内嵌网页打开它的登录页。
   密码、QQ、微信、验证码等任何登录方式都在站点自己的页面完成，密码不经过 BD。
   网页使用独立的临时会话；登录成功后 BD 取走 auth_token 与 refresh_token，存入数据目录 relay-sites/（权限 600），
   state.json 只记站点地址、邮箱和用户 ID。调用后台接口时沿用登录网页的 User-Agent。
2. 登录令牌 24 小时有效。剩余不到 2 小时时 BD 调用 /api/v1/auth/refresh 续期；刷新令牌每次轮换，先落盘再使用，
   同一站点同时只刷新一次。刷新被拒（401）时站点标为“需重新登录”，已接入的 Key 不受影响。
3. “管理 Key”列出站点全部 Key 与可用分组：可选分组新建 Key（可设额度上限）并直接接入，也可把已有 Key 接入。
   分组平台决定协议：Claude 走 Anthropic Messages（地址去掉 /v1），GPT 走 Responses，Grok 走 xAI；Gemini 暂不支持。
   接口地址取站点公布的 api_base_url，模型取分组模型列表；同一 Key 再次接入时更新原渠道，保留别名。
4. 每 10 分钟刷新余额与今日消费，并检查已接入的 Key：Key 在站点被删除，或 BD 新建（名称以 Assropic 开头）的 Key
   停用、到期、额度用完时，在原分组新建一个并替换渠道里的 Key（可在站点“更多”菜单关闭）。用户自己的 Key 失效只提示。
5. 退出登录会调用站点 /auth/logout 注销这次会话并删除本地令牌，已接入的渠道保留。

渠道“管理”菜单 → “模型核验…”可立即核验或设定每 6 / 12 / 24 小时、每周自动核验，任意 API 渠道都能用。
每次对每个模型发 3–4 个小请求（约 1 万输入 token），同一时间只核验一个渠道：
• 响应格式：Messages / Responses 的原生字段（type、object、usage、ID 前缀），以及返回的模型标识。
• 分词指纹：加入约 4,500 token 固定文本前后的输入 token 差值。差值由分词器决定，用差值可排除站点附加的系统提示。
  BD 里有同名模型的官方订阅时，经本地网关测一次官方差值作参照（7 天内复用）；没有时与首次测得的基准比较。
• 提示缓存：同一长前缀重复请求应命中缓存（cache_read_input_tokens / cached_tokens）。
• thinking 签名（Anthropic）或推理 token（Responses）。
• 计费核对（登录中转站接入的渠道）：读取该 Key 的站点计费记录，与接口返回的 usage 逐条比对。
结论：任一项失败为“确认异常”，有提醒为“可疑”，否则“可信”；调用失败为“无法检测”。
结果记在数据目录 verification/，渠道行显示最近结论；可选“确认异常时自动停用渠道”。
没有一项检测能单独证明真伪，结论由多项证据合成；站点关闭缓存等正常配置也可能触发“可疑”。

xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/Quotas.swift Sources/CCSwitchLink.swift Sources/ModelPublishing.swift Sources/ModelDiagnostics.swift Sources/RelaySites.swift Sources/ModelVerification.swift Tests/RelaySitesTests.swift -o /tmp/bridgedock-relay-tests && /tmp/bridgedock-relay-tests


账号池与多账号并行（1.4.22）

同一订阅的多个账号组成一个账号池，在 Cursor、Claude Code、Codex CLI 等任何工具里都按对话分配：
新对话依次分到 1 号、2 号、3 号账号，再回到 1 号……；同一对话一直留在它的账号上，提示词缓存持续命中；
某个账号额度用完时，只有它上面的对话换到其他账号，客户端感觉不到。
• 池按上游划分：Claude、GPT / Codex、Kimi 国内、Kimi 国际、Grok、ZCode 国内 / 国际、Cursor、Grok Bot 各自一池。
  Kiro 每个账号独立进程，由网关按同样的规则分配（见下方“Kiro 账号池”）。
• 账号池共用一个模型前缀（例如 gpt/…）。旧版本给每个本机导入的账号分配了独立前缀（gpt、gpt-2…），
  合并模型时只会用到第一个账号，新账号的模型也不会进入开放列表。1.4.22 启动后自动把这类账号并入同一账号池，
  开放模型列表和长上下文检测结果随之迁移，活动记录里会写明合并了哪些账号。
• 自定义前缀（不是“服务商名”或“服务商名-数字”）的账号，以及在账号设置里填了其他前缀的账号，保持独立，
  只在调用“前缀/模型名”时使用。账号行显示“账号池 N 个账号”或“独立账号”。
• Claude Code 的主对话和它启动的每个子代理共用一个会话标识。网关在转发前按“会话标识 + 对话开头”
  为每个对话生成独立的会话标识，所以一次并发的多个子代理会分散到池里的不同账号；从主对话 fork 出来的
  子代理开头相同，仍留在主对话的账号上，继续使用它的缓存。Kiro 账号池使用同样的对话划分。
• “账号与渠道”页的每个订阅账号池都有独立的“账号轮流 / 账号并发”开关。轮流模式给每次请求生成新的
  内核会话键，按请求在账号间轮换；并发模式保留会话粘性，让不同会话并行分散。旧配置缺少该字段时默认使用并发模式。
• Claude 桌面端只需登录一次。在“工具接入 → Claude”打开“启用账号并发”后，同一个窗口里的多个会话
  会通过本地网关使用同一 Claude 账号池；某个账号额度或认证失败时，网关自动把该会话切到其他账号，
  Claude 发送的消息历史继续随请求转发，因此对话记录和上下文不丢失。该开关也可在“账号与渠道”页调整。

xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/LocalSubscriptionIdentity.swift Sources/AccountPools.swift Sources/ModelPublishing.swift Sources/ModelGateway.swift Sources/KiroRouting.swift Sources/KiroRuntime.swift Tests/AccountPoolsTests.swift -o /tmp/bridgedock-pool-tests && /tmp/bridgedock-pool-tests


会话粘性、限流与冷却（1.4.21）

同一个对话固定使用同一个账号或同一把 Key，上游的提示词缓存可以持续命中，省额度、首字更快。
内核按 Claude Code / Codex / OpenCode 的会话标识、prompt_cache_key 或首条消息识别对话；
新对话在账号之间依次分配。Claude Code 的子代理按各自的对话分配（见下方“账号池”），
Codex 等声明了父会话的子代理跟随父对话的账号。
• 临时错误（408、5xx、空响应）只让这一次请求换号，账号休息 15 秒（内核默认 60 秒），
  同一账号上的其他对话不会被一起挪走。额度和认证错误才让对话换到别的账号。
• 流式响应在长时间思考时每 15 秒发送 SSE 心跳；还没输出任何内容前失败，会静默重试一次。
• Claude / Codex 某个模型的额度用完时，只冷却这个模型，账号的其他模型照常可用。
• 每个 Claude 账号固定一套设备画像（系统、架构、客户端版本基线），日期按本机时区。
  指纹基线随内核版本更新，内核保持较新版本可以与真实客户端保持一致。
• 冷却状态保存在 accounts 目录（*.cds），重启后不会立刻再请求刚被限流的账号。

Kiro 账号池同样按这些原则切换：
• 429 是限流，不是额度用完（kiro2cc 已在内部退避，额度用完会返回 402）。账号按 Retry-After
  休息（最长 60 秒，未给出时 5 秒），期间对话的单轮请求由其他账号临时接手，结束后回到原账号，
  不计入连续失败。
• 401 / 403 先休息 30 秒待确认，10 分钟内再出现一次才按认证失败处理（熔断 10 分钟并改派对话）。
  进程刚重启时短暂拒绝密钥，不会再被误判为账号失效。
• 临时接手的请求按进行中的请求数分配，多个请求同时换号时会分散到不同账号。
• 一个模型的所有账号都在休息时，返回 429 并在 Retry-After 写明最早恢复的秒数。

“账号与渠道”页的订阅账号在冷却时显示原因和倒计时，例如“冷却中 · 上游限流 · 约 2 分 5 秒后恢复”；
只冷却部分模型时会列出模型名。账号菜单的“立即解除冷却”可以马上恢复分配。

xcrun swiftc -swift-version 5 Sources/AccountRest.swift Sources/KiroRouting.swift Tests/AccountRestTests.swift -o /tmp/bridgedock-rest-tests && /tmp/bridgedock-rest-tests


模型系列分组（1.4.19）

Cursor 模型列表按 GPT、Claude、Gemini、Grok、Kimi、GLM 等模型系列分组。
同系列的不同版本与子型号连续排列，不受默认供应商、渠道名称或目录返回顺序影响。
供应商仍在模型参数中单独选择；搜索同时匹配模型系列和该模型的所有供应商。
