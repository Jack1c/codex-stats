#!/bin/bash
# 构建 CodexStats.app：swiftc 编译 + 手工拼 .app 包 + ad-hoc 签名
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)"
app="$src_dir/CodexStats.app"

mkdir -p "$app/Contents/MacOS"

swiftc -parse-as-library -swift-version 5 -O \
  -target "$(uname -m)-apple-macosx13.0" \
  -o "$app/Contents/MacOS/CodexStats" \
  "$src_dir/CodexStatsApp.swift"

cp "$src_dir/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "已生成 $app"
echo "运行： open \"$app\""
