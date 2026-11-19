#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/UUDisplay/UUConnectionState.swift tests/connection-main.swift -o "$TEST_DIR/connection-tests"
"$TEST_DIR/connection-tests"
swiftc Sources/UUDisplay/UUConnectionState.swift Sources/UUDisplay/UUMonitor.swift tests/monitor-main.swift -o "$TEST_DIR/monitor-tests"
"$TEST_DIR/monitor-tests"
swiftc Sources/UUDisplay/VirtualDisplayIdentityPool.swift tests/identity-main.swift -o "$TEST_DIR/identity-tests"
"$TEST_DIR/identity-tests"
# 用模拟模块替换私有 API，测试实际 DisplayManager 执行器，不改变真实屏幕。
swiftc -emit-library -emit-module -module-name CGVirtualDisplayBridge tests/fixtures/CGVirtualDisplayBridge.swift -emit-module-path "$TEST_DIR/CGVirtualDisplayBridge.swiftmodule" -o "$TEST_DIR/libCGVirtualDisplayBridge.dylib"
swiftc -I "$TEST_DIR" -L "$TEST_DIR" -lCGVirtualDisplayBridge -Xlinker -rpath -Xlinker "$TEST_DIR" Sources/UUDisplay/Config.swift Sources/UUDisplay/VirtualDisplayIdentityPool.swift Sources/UUDisplay/DisplayManager.swift tests/display-main.swift -o "$TEST_DIR/display-tests"
"$TEST_DIR/display-tests"
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/PhysicalDisplays.swift tests/display-config-main.swift -o "$TEST_DIR/display-config-tests"
"$TEST_DIR/display-config-tests"
python3 tests/colorsync-maintenance.py
