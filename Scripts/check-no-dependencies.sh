#!/bin/sh
# v1 不依賴任何第三方套件（DESIGN.md 決策 D4）。CI 用這支腳本把關。
set -eu
cd "$(dirname "$0")/.."

manifest="Packages/ThunderKit/Package.swift"

if grep -nE '^[^/]*\.package\(' "$manifest"; then
    echo "錯誤：$manifest 宣告了外部套件。v1 不依賴第三方套件（DESIGN.md D4）。" >&2
    exit 1
fi

if [ -f "Packages/ThunderKit/Package.resolved" ]; then
    echo "錯誤：出現了 Package.resolved，代表有外部套件被解析。" >&2
    exit 1
fi

echo "ok：沒有第三方套件"
