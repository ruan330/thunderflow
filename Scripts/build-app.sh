#!/bin/sh
# 把 App/ 編成 build/ThunderFlow.app。不需要開 Xcode。
#
# 簽章：預設用 ad-hoc（不需要任何憑證，在自己的電腦上可以直接執行）。
# 缺點是每次重新編譯，鑰匙圈與麥克風的授權都會重新詢問。有可用的開發者憑證時，
# 可以用環境變數 THUNDERFLOW_SIGN_IDENTITY 指定（`security find-identity -v -p codesigning` 列出的名稱或雜湊值）。
#
# 不自動挑選鑰匙圈裡的憑證：用已經被撤銷的憑證簽章，macOS 會把 App 當成惡意軟體、直接丟進垃圾桶。
set -eu
cd "$(dirname "$0")/.."

configuration="${1:-release}"
swift build --package-path App -c "$configuration"
binary="$(swift build --package-path App -c "$configuration" --show-bin-path)/ThunderFlow"

app="build/ThunderFlow.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/ThunderFlow"
cp App/Resources/Info.plist "$app/Contents/Info.plist"

identity="${THUNDERFLOW_SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements App/Resources/ThunderFlow.entitlements --sign "$identity" "$app"

if [ "$identity" = "-" ]; then
    echo "已建立 ${app}（ad-hoc 簽章）"
else
    echo "已建立 ${app}（以指定的身分簽章）"
fi
