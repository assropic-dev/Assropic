#!/bin/bash
# BridgeDock Kiro 共享池改动的验证脚本：编译并运行相关测试，然后打包到 outputs/BridgeDock.app。
# 输出写到同目录的 bd-verify.log。
cd "$(dirname "$0")" || exit 1
LOG="$PWD/bd-verify.log"
exec > "$LOG" 2>&1
set -u
step() { echo; echo "===== $1 ====="; }
status=0
run() { "$@"; local rc=$?; echo "[exit $rc] $*"; [ $rc -eq 0 ] || status=1; return $rc; }

step "Kiro 运行时测试"
run xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/ModelPublishing.swift Sources/ModelGateway.swift Sources/KiroRouting.swift Sources/KiroRuntime.swift Sources/KiroWorkers.swift Tests/KiroRuntimeTests.swift -o /tmp/bridgedock-kiro-runtime-tests \
  && run /tmp/bridgedock-kiro-runtime-tests

step "网关测试"
run xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/ModelPublishing.swift Sources/ModelDiscovery.swift Sources/ModelGateway.swift Sources/KiroRouting.swift Sources/KiroRuntime.swift Tests/ModelGatewayTests.swift -o /tmp/bridgedock-gateway-tests \
  && run python3 Tests/model_gateway_test.py /tmp/bridgedock-gateway-tests

step "Kimi Work 测试（只编译 ModelGateway，不含 KiroRuntime）"
run xcrun swiftc -swift-version 5 Sources/Models.swift Sources/SubscriptionAccounts.swift Sources/KimiWork.swift Sources/KimiWorkCatalog.swift Sources/KimiWorkRouting.swift Sources/ModelPublishing.swift Sources/ModelGateway.swift Sources/KiroRouting.swift Tests/KimiWorkIndependentTests.swift -o /tmp/bridgedock-work-tests \
  && run /tmp/bridgedock-work-tests

step "Cursor 参数面板与传输测试（JS）"
run node Tests/CursorRuntimeTests.js
run node Tests/CursorParameterTransportTests.js

if [ $status -eq 0 ]; then
  step "打包 outputs/BridgeDock.app"
  run ./build.sh
else
  step "测试失败，跳过打包"
fi
echo; echo "===== 完成，status=$status ====="
