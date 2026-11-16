#!/bin/zsh
# 实机验证：四次创建、两组 UUID；保留物理屏，不执行主屏/布局配置事务。
# 必须显式传入 --real-displays，常规回归测试不会调用它。
set -euo pipefail
if [[ "${1:-}" != "--real-displays" || "$#" != 1 ]]; then
  echo '用法：scripts/test-display-identities.sh --real-displays'
  echo '先保存工作并完全退出主应用和探测工具。该测试会创建并安全撤销真实虚拟屏。'
  exit 2
fi
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swift build -c release --build-system native --product UUDisplay
BIN_DIR="$(swift build -c release --build-system native --show-bin-path)"
swiftc -parse-as-library -I "$BIN_DIR/CGVirtualDisplayBridge.build" Sources/UUDisplay/VirtualDisplayIdentityPool.swift tests/real-identity-main.swift -o "$TEST_DIR/real-identities"
"$TEST_DIR/real-identities" "$TEST_DIR/identities.json"
