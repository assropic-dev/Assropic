BridgeDock 桥接台 1.0

面向 Apple Silicon Mac 的本地模型反代桌面应用。
界面使用 SwiftUI，内置 CLIProxyAPI 8.0.51 与 Kiro Plugin 0.1.1。
发行包包含运行所需内核，运行时无需安装 Node、Python、Docker 或 Homebrew。

主要功能

• 官方 API Key、Coding Plan Key、第三方中转站的新增、编辑、启停和删除。
• Claude、Codex、Kimi 国内/国际、Grok Build / xAI 与 Kiro 的账号登录入口。
• Kiro 的 AWS Builder ID 与组织账号登录，Google / GitHub 凭据 JSON 导入。
• OpenAI Chat Completions、OpenAI Responses、Anthropic Messages 接口。
• 流式输出与工具调用由反代内核进行协议转换。
• 渠道独立前缀与模型别名，多渠道同名模型可分别选择。
• 真实模型列表获取、三种协议的手动测试。
• Claude Code、Codex CLI、Kimi Code 配置合并、自动备份和恢复。
• ZCode 和其他支持自定义 API 的工具可复制连接信息手动接入。
• 本机监听、独立管理密钥、菜单栏启停、全局与渠道级出站代理。

使用方法

1. 双击 BridgeDock.app，确认左下角显示服务已启动。
2. API 渠道中选择服务商，填写 Key，获取模型或手动填写模型 ID，再保存。
   模型列表每行一个，也可以写成“上游模型ID = 别名”。调用名为“前缀/别名”。
3. 订阅账号使用浏览器完成授权。密码、二次验证和授权由账号持有人操作。
4. 在模型与测试页选择模型，测试需要的协议。真实测试会产生少量用量。
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
• Grok 登录走 xAI / Grok Build 授权。普通 Grok 网页订阅的权益是否可用，以
  账号授权后的模型列表和实际请求结果为准。也可直接添加 xAI API Key。
• ZCode 对应的服务来源使用智谱 / Z.ai 的 API 或 Coding Plan Key。
  ZCode 客户端通过自定义模型连接信息手动配置。
• Kimi 自动配置按当前 Kimi Code CLI 的 ~/.kimi-code/config.toml 格式生成。
  旧版 kimi-cli 的路径、参数或能力字段可能不同，请核对配置预览。
• 自动合并 TOML 会保留其他普通配置。含多行字符串或冲突的手工 bridgedock
  配置时，需要手动合并。也可使用临时启动命令进行接入。
• 模型上下文长度、图片能力、推理参数、额度和权限由上游决定。Kimi 预设
  上下文长度为 32768，可在接入页按所选模型调整。
• 本次验收使用本地模拟接口。真实订阅授权、服务商网络和账号额度需添加后验证。

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

xcrun swiftc -swift-version 5 Sources/Models.swift Sources/Integrations.swift Tests/LogicTests.swift -o /tmp/bridgedock-logic-tests
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

适配参考

https://learn.chatgpt.com/docs/config-file/config-advanced
https://code.claude.com/docs/en/llm-gateway
https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/config-files
https://www.zcode.network/en/docs/configuration/
https://kiro.dev/docs/models/
https://docs.bigmodel.cn/cn/coding-plan/tool/claude
https://docs.x.ai/developers/rest-api-reference/inference/responses
https://help.router-for.me/management/api
