#!/bin/sh
# 把 App/ 編成 build/ThunderFlow.app。不需要開 Xcode（但要裝 Xcode：圖示與強調色用它附的 actool 編譯）。
#
# 簽章：預設用 ad-hoc（不需要任何憑證，在自己的電腦上可以直接執行）。
# 缺點是每次重新編譯，鑰匙圈與麥克風的授權都會重新詢問。有可用的開發者憑證時，
# 可以用環境變數 THUNDERFLOW_SIGN_IDENTITY 指定（`security find-identity -v -p codesigning` 列出的名稱或雜湊值）。
#
# 不自動挑選鑰匙圈裡的憑證：用已經被撤銷的憑證簽章，macOS 會把 App 當成惡意軟體、直接丟進垃圾桶。
#
# 圖示與強調色：App/Resources/ThunderFlow.icon（Icon Composer 的文件）與
# App/Resources/Assets.xcassets（AccentColor）由 actool 編成 Contents/Resources/Assets.car，
# 另外產生 ThunderFlow.icns（給讀不了 Assets.car 的工具看的小尺寸圖示）。actool 寫出的 Info.plist 片段
# （CFBundleIconName、CFBundleIconFile、NSAccentColorName）併進 App 的 Info.plist，和 Xcode 的做法一樣。
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

# 圖示與強調色。圖示名稱要和 .icon 的檔名相同：名稱不對時 actool 不會失敗，只是什麼都不產生，所以下面逐項檢查。
assets="build/actool"
rm -rf "$assets"
mkdir -p "$assets"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' App/Resources/Info.plist)"
if ! xcrun actool App/Resources/ThunderFlow.icon App/Resources/Assets.xcassets \
    --compile "$app/Contents/Resources" \
    --app-icon ThunderFlow --accent-color AccentColor \
    --output-partial-info-plist "$assets/Info.plist" \
    --platform macosx --target-device mac --minimum-deployment-target "$minimum" \
    --output-format human-readable-text --errors --warnings >"$assets/actool.log" 2>&1; then
    cat "$assets/actool.log" >&2
    echo "錯誤：actool 沒辦法編譯圖示與強調色" >&2
    exit 1
fi
if grep -q -E "(^|: )(warning|error):|com\.apple\.actool\.(document\.)?(warnings|errors)" "$assets/actool.log"; then
    cat "$assets/actool.log" >&2
fi
/usr/libexec/PlistBuddy -c "Merge $assets/Info.plist" "$app/Contents/Info.plist" >/dev/null
for key in CFBundleIconName CFBundleIconFile NSAccentColorName; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" >/dev/null 2>&1; then
        echo "錯誤：Info.plist 沒有 ${key}，actool 沒有編出圖示或強調色（${assets}/actool.log）" >&2
        exit 1
    fi
done
if [ ! -s "$app/Contents/Resources/Assets.car" ]; then
    echo "錯誤：actool 沒有產生 Assets.car" >&2
    exit 1
fi

identity="${THUNDERFLOW_SIGN_IDENTITY:--}"
codesign --force --options runtime --entitlements App/Resources/ThunderFlow.entitlements --sign "$identity" "$app"

# 簽章之後的程式能執行，而且讀得到合併後的 Info.plist（`--version` 印出版本就結束，不會打開視窗）
expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
actual="$("$app/Contents/MacOS/ThunderFlow" --version)"
if [ "$actual" != "$expected" ]; then
    echo "錯誤：${app} 的 --version 印出「${actual}」，應該是「${expected}」" >&2
    exit 1
fi

if [ "$identity" = "-" ]; then
    echo "已建立 ${app}（ad-hoc 簽章）"
else
    echo "已建立 ${app}（以指定的身分簽章）"
fi
