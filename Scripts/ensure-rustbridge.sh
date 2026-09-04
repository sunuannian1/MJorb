#!/usr/bin/env bash
# 确保预编译 RustBridge.xcframework 与当前 Rust 源码一致（fail-safe：任何不确定都重编）。
#
# - 源码指纹与库内记录一致、且两个 slice 的 .a 都存在 -> 复用预编译库（快，不碰 cargo）
# - 指纹不一致 / 指纹缺失 / 任一 .a 缺失                     -> 安装 Rust target 并 make xcframework，
#                                                             然后做 minOS 与导出符号校验
#
# 这样“改了 Rust 源码但忘记回传预编译二进制”永远不会让 CI/打包用到过期的库。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SEAL_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BRIDGE_DIR="$ROOT/Vendor/Minimuxer/RustBridge"
XCFRAMEWORK="$BRIDGE_DIR/lib/RustBridge.xcframework"
DEVICE_LIB="$XCFRAMEWORK/ios-arm64/librust_bridge.a"
SIM_LIB="$XCFRAMEWORK/ios-arm64-simulator/librust_bridge.a"
FINGERPRINT_FILE="$XCFRAMEWORK/.source-fingerprint"
TOOLCHAIN="${RUST_TOOLCHAIN:-1.97.1}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"

current="$(bash "$SCRIPT_DIR/rustbridge-fingerprint.sh" "$BRIDGE_DIR")"
stored=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
  stored="$(tr -d '[:space:]' < "$FINGERPRINT_FILE" || true)"
fi

libs_present=true
[[ -f "$DEVICE_LIB" && -f "$SIM_LIB" ]] || libs_present=false

if [[ -n "$stored" && "$current" == "$stored" ]] && $libs_present; then
  echo "RustBridge up-to-date (fingerprint ${current:0:12}); reusing vendored xcframework."
  exit 0
fi

echo "RustBridge stale/missing (source=${current:0:12} stored=${stored:0:12} libs=$libs_present); rebuilding from source..."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "RustBridge rebuild requires macOS (xcodebuild -create-xcframework)." >&2
  exit 2
fi
if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is required to rebuild RustBridge" >&2
  exit 2
fi

rustup toolchain install "$TOOLCHAIN" --profile minimal --component llvm-tools-preview
rustup default "$TOOLCHAIN"
rustup target add --toolchain "$TOOLCHAIN" aarch64-apple-ios aarch64-apple-ios-sim
rustc --version --verbose

# Makefile 在 xcframework 组装完成后写入同源码指纹。
(
  cd "$BRIDGE_DIR"
  IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    make xcframework REPO_ROOT="$ROOT"
)

# 以实际源码指纹为准回写（防止 Makefile 路径异常导致漏写）。
mkdir -p "$XCFRAMEWORK"
printf '%s\n' "$current" > "$FINGERPRINT_FILE"

# 重编产物必须通过与专用 rebuild workflow 相同的两道质量门。
MAX_IOS_VERSION="$DEPLOYMENT_TARGET" bash "$SCRIPT_DIR/verify-rustbridge-minos.sh" "$XCFRAMEWORK"
bash "$SCRIPT_DIR/verify-rustbridge-symbols.sh" "$XCFRAMEWORK"

echo "RustBridge rebuilt and verified (fingerprint ${current:0:12})."
