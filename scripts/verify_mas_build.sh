#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
  print -u2 "使用方法: scripts/verify_mas_build.sh <PKPane.app>"
  exit 64
fi

readonly app_path="$1"
readonly info_plist_path="$app_path/Contents/Info.plist"

if [[ ! -d "$app_path" || ! -f "$info_plist_path" ]]; then
  print -u2 "PKPane.appを確認できません: $app_path"
  exit 66
fi

/usr/bin/codesign --verify --deep --strict "$app_path"
readonly entitlements="$(/usr/bin/codesign -d --entitlements - "$app_path" 2>/dev/null)"

has_true_entitlement() {
  local key="$1"
  print -r -- "$entitlements" \
    | /usr/bin/grep -A 2 -F "[Key] $key" \
    | /usr/bin/grep -q -F "[Bool] true"
}

readonly required_entitlements=(
  "com.apple.security.app-sandbox"
  "com.apple.security.files.bookmarks.app-scope"
  "com.apple.security.files.user-selected.read-write"
  "com.apple.security.network.client"
)

for entitlement in "${required_entitlements[@]}"; do
  if ! has_true_entitlement "$entitlement"; then
    print -u2 "必須entitlementが有効ではありません: $entitlement"
    exit 65
  fi
done

if [[ -e "$app_path/Contents/Helpers/pkpane" ]]; then
  print -u2 "Mac App Store構成に削除済みCLIヘルパーが残っています。"
  exit 65
fi

readonly folder_rank="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' \
    "$info_plist_path"
)"
if [[ "$folder_rank" != "Alternate" ]]; then
  print -u2 "public.folderのLSHandlerRankがAlternateではありません。"
  exit 65
fi

if [[ ! -f "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" ]]; then
  print -u2 "PrivacyInfo.xcprivacyがアプリへ収録されていません。"
  exit 65
fi

if [[ ! -f "$app_path/Contents/Resources/AppIcon.icns" ]]; then
  print -u2 "App Iconがアプリへ収録されていません。"
  exit 65
fi

if [[ ! -f "$app_path/Contents/Resources/Citadel-LICENSE.txt" \
  || ! -f "$app_path/Contents/Resources/UnRAR-LICENSE.txt" \
  || ! -f "$app_path/Contents/Resources/SwiftCrypto-LICENSE.txt" ]]; then
  print -u2 "主要な依存ライセンス文書がアプリへ収録されていません。"
  exit 65
fi

print "Mac App Store用ビルド構成を確認しました。"
