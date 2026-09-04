#!/usr/bin/env bash
# RustBridge 源码指纹：任何会改变 cargo 编译产物的输入变化都会改变该指纹。
# 输入范围：RustBridge/src 下全部 .rs + Cargo.toml + Cargo.lock。
# 输出：单行 sha256 hex（stdout）。跨 macOS/Linux、跨文件树顺序稳定。
set -euo pipefail

BRIDGE_DIR="${1:-Vendor/Minimuxer/RustBridge}"

if [[ ! -d "$BRIDGE_DIR/src" ]]; then
  echo "RustBridge source directory not found: $BRIDGE_DIR/src" >&2
  exit 2
fi

# 统一选择可用的 sha256 工具（macOS 自带 shasum，Linux 多为 sha256sum）。
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    command sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    command shasum -a 256
  else
    echo "no sha256 tool (sha256sum/shasum) found" >&2
    exit 2
  fi
}

{
  # 逐个源码文件输出 "<内容hash>  <相对路径>"，按路径排序保证确定性。
  while IFS= read -r -d '' file; do
    rel="${file#"$BRIDGE_DIR"/}"
    hash="$(sha256 < "$file" | awk '{print $1}')"
    printf '%s  %s\n' "$hash" "$rel"
  done < <(find "$BRIDGE_DIR/src" -type f -name '*.rs' -print0 | LC_ALL=C sort -z)

  for manifest in Cargo.toml Cargo.lock; do
    if [[ -f "$BRIDGE_DIR/$manifest" ]]; then
      hash="$(sha256 < "$BRIDGE_DIR/$manifest" | awk '{print $1}')"
      printf '%s  %s\n' "$hash" "$manifest"
    fi
  done
} | sha256 | awk '{print $1}'
