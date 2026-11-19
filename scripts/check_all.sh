#!/bin/zsh

set -euo pipefail

readonly project_root="${0:A:h:h}"
readonly adhoc_entitlements_path="$project_root/Config/PKPane-adhoc.entitlements"
readonly store_entitlements_path="$project_root/Config/PKPane.entitlements"
readonly plzma_checkout_path="$project_root/.derived-data/SourcePackages/checkouts/PLzmaSDK"
readonly plzma_expected_revision="f449bc3e13204b68a7e05fca80ce8c31642085ec"
ftp_loopback_configuration=""
sftp_loopback_configuration=""
sftp_jump_loopback_configuration=""
sftp_auth_matrix_configuration=""
readonly sftp_jump_root_pointer="/private/tmp/pkpane-rv26-sftp-jump-root.txt"
cd "$project_root"

# 引数なしはアプリを起動・操作しないビルド専用にする。
readonly check_mode="${1:---build-only}"

case "$check_mode" in
  --build-only|--release-archive|--preview-archive|--test|--only-testing|--sandbox-sidebar-test|--format-files|--browser-performance-test|--sftp-ui-test|--ftp-ui-test|--ftp-live-test|--ftp-live-write-test|--ftp-live-sandbox-test|--ftp-loopback-test|--sftp-loopback-test|--sftp-jump-loopback-test|--sftp-auth-matrix-test|--workspace-ui-test|--toolbar-appearance-ui-test|--transfer-ui-test|--provider-rename-ui-test|--nas-delete-ui-test|--sftp-two-pane-ui-test|--remote-edit-ui-test|--archive-ui-test|--archive-extract-ui-test) ;;
  *)
    echo "使用方法: scripts/check_all.sh [--build-only|--release-archive|--preview-archive|--test|--only-testing|--format-files|--browser-performance-test|--sftp-ui-test|--ftp-ui-test|--ftp-live-test|--ftp-live-write-test|--ftp-live-sandbox-test|--sftp-jump-loopback-test|--sftp-auth-matrix-test|--workspace-ui-test|--toolbar-appearance-ui-test|--transfer-ui-test|--provider-rename-ui-test|--nas-delete-ui-test|--sftp-two-pane-ui-test|--remote-edit-ui-test|--archive-ui-test|--archive-extract-ui-test]"
    echo "局所単体検証: scripts/check_all.sh --only-testing PKPaneTests/スイート[/メソッド] ..."
    echo "Sandboxのホーム・サイドバー検証: scripts/check_all.sh --sandbox-sidebar-test"
    echo "配布署名Release Archive: scripts/check_all.sh --release-archive"
    echo "検証用ad-hoc署名Release Archive: scripts/check_all.sh --preview-archive"
    echo "局所整形: scripts/check_all.sh --format-files PKPane/明示ファイル.swift ...（1件以上）"
    echo "隔離FTP実通信: scripts/check_all.sh --ftp-loopback-test（確認済み一時pyftpdlib配布物が必要）"
    echo "隔離SFTP読取実通信: scripts/check_all.sh --sftp-loopback-test [PKPaneTests/SFTPLoopbackWireTests/メソッド]（専用一時設定が必要）"
    echo "踏み台経由SFTP実通信: scripts/check_all.sh --sftp-jump-loopback-test（踏み台・目的役の専用一時設定が必要）"
    echo "SFTP認証方式の行列: scripts/check_all.sh --sftp-auth-matrix-test（Dockerが必要。無ければskip）"
    exit 2
    ;;
esac

# 整形は明示された実在Swiftファイルだけに限定し、通常lintやビルドへ進めない。
if [[ "$check_mode" == "--format-files" ]]; then
  if (( $# < 2 )); then
    echo "--format-filesにはPKPaneまたはPKPaneTests内のSwiftファイル指定が必要です。" >&2
    exit 2
  fi
  readonly format_file_pattern='^(PKPane|PKPaneTests)/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.swift$'
  typeset -a formatted_swift_files
  for format_file in "${@:2}"; do
    if [[ ! "$format_file" =~ "$format_file_pattern" || ! -f "$format_file" ]]; then
      echo "整形対象は既存PKPane/PKPaneTests内の明示Swift相対パスだけを指定してください。" >&2
      exit 2
    fi
    format_resolved_path="${format_file:A}"
    if [[ "$format_resolved_path" != "$project_root/PKPane/"* &&
      "$format_resolved_path" != "$project_root/PKPaneTests/"* ]]; then
      echo "整形対象の実体が許可範囲外です。" >&2
      exit 2
    fi
    formatted_swift_files+=("$format_file")
  done
  swift format format --in-place "${formatted_swift_files[@]}"
  exit 0
fi

# 局所指定は単体スイートまたはメソッドだけを許可し、指定漏れを全体実行へ広げない。
typeset -a unit_test_filters
if [[ "$check_mode" == "--only-testing" || "$check_mode" == "--sftp-loopback-test" ]]; then
  if [[ "$check_mode" == "--only-testing" ]] && (( $# < 2 )); then
    echo "--only-testingにはPKPaneTestsのスイートまたはメソッド指定が必要です。" >&2
    exit 2
  fi
  readonly unit_test_selector_pattern='^PKPaneTests/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(\))?)?$'
  readonly sftp_wire_selector_pattern='^PKPaneTests/SFTPLoopbackWireTests(/[A-Za-z_][A-Za-z0-9_]*(\(\))?)?$'
  for unit_test_selector in "${@:2}"; do
    if [[ ! "$unit_test_selector" =~ "$unit_test_selector_pattern" ]]; then
      echo "局所検証にはPKPaneTests/スイート[/メソッド]だけを指定してください。" >&2
      exit 2
    fi
    if [[ "$check_mode" == "--sftp-loopback-test" && ! "$unit_test_selector" =~ "$sftp_wire_selector_pattern" ]]; then
      echo "隔離SFTPにはSFTPLoopbackWireTestsのスイートまたはメソッドだけを指定してください。" >&2
      exit 2
    fi
    unit_test_filters+=("-only-testing:$unit_test_selector")
  done
elif (( $# > 1 )); then
  echo "追加引数は--only-testingまたは--sftp-loopback-testでのみ使用できます。" >&2
  exit 2
else
  unit_test_filters=(-only-testing:PKPaneTests)
fi

# 遅延フィクスチャの実測は明示時だけ有効にし、単体ホストへ同じ値を渡す。
readonly rv26_measurements="${PKPANE_RV26_MEASUREMENTS:-0}"
if [[ "$rv26_measurements" != "0" && "$rv26_measurements" != "1" ]]; then
  echo "PKPANE_RV26_MEASUREMENTSには0または1だけを指定してください。" >&2
  exit 2
fi

# 配布署名は明示された有効IDだけを使い、証明書の導入・ad-hocへの代替は行わない。
if [[ "$check_mode" == "--release-archive" ]]; then
  readonly distribution_identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]{40})[[:space:]]+"(Apple Distribution|Mac App Distribution|3rd Party Mac Developer Application):'
  typeset -a distribution_identities
  readonly available_signing_identities="$(security find-identity -v -p codesigning)"
  for signing_identity_line in "${(@f)available_signing_identities}"; do
    if [[ "$signing_identity_line" =~ "$distribution_identity_pattern" ]]; then
      distribution_identities+=("$match[1]")
    fi
  done
  if (( ${#distribution_identities} == 0 )); then
    echo "有効なMac App Store配布署名IDがありません。Archive生成は未実施です。" >&2
    exit 69
  fi
  readonly distribution_signing_identity="${(U)PKPANE_DISTRIBUTION_SIGNING_IDENTITY:-}"
  readonly distribution_team_id="${PKPANE_DISTRIBUTION_TEAM_ID:-}"
  readonly distribution_profile_uuid="${PKPANE_DISTRIBUTION_PROFILE_UUID:-}"
  readonly signing_hash_pattern='^[A-F0-9]{40}$'
  readonly signing_team_pattern='^[A-Z0-9]{10}$'
  readonly signing_profile_pattern='^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$'
  if [[ ! "$distribution_signing_identity" =~ "$signing_hash_pattern" \
    || ! "$distribution_team_id" =~ "$signing_team_pattern" \
    || ! "$distribution_profile_uuid" =~ "$signing_profile_pattern" ]]; then
    echo "配布証明書のSHA-1、Team ID、導入済みProfile UUIDをPKPANE_DISTRIBUTION_SIGNING_IDENTITY/TEAM_ID/PROFILE_UUIDへ指定してください。" >&2
    exit 64
  fi
  if (( ${distribution_identities[(Ie)$distribution_signing_identity]} == 0 )); then
    echo "指定した配布署名IDは有効なMac App Store配布証明書ではありません。" >&2
    exit 69
  fi
fi

cleanup_test_application() {
  local loopback_cleanup_failed=0
  if [[ -n "$sftp_loopback_configuration" ]]; then
    if python3 "$project_root/scripts/rv26_sftp_loopback.py" stop; then
      sftp_loopback_configuration=""
    else
      echo "隔離SFTPの停止結果を確認できません。" >&2
      loopback_cleanup_failed=1
    fi
  fi
  if [[ -n "$sftp_jump_loopback_configuration" ]]; then
    if python3 "$project_root/scripts/rv26_sftp_loopback.py" stop "$sftp_jump_root_pointer"; then
      sftp_jump_loopback_configuration=""
    else
      echo "隔離SFTP踏み台の停止結果を確認できません。" >&2
      loopback_cleanup_failed=1
    fi
  fi
  if [[ -n "$sftp_auth_matrix_configuration" ]]; then
    if python3 "$project_root/scripts/rv26_sftp_auth_matrix.py" stop "$sftp_auth_matrix_configuration"; then
      sftp_auth_matrix_configuration=""
    else
      echo "SFTP認証行列サーバー群の停止結果を確認できません。" >&2
      loopback_cleanup_failed=1
    fi
  fi
  if [[ -n "$ftp_loopback_configuration" ]]; then
    if python3 "$project_root/scripts/rv26_ftp_loopback.py" stop "$ftp_loopback_configuration"; then
      ftp_loopback_configuration=""
    else
      echo "隔離FTPの停止結果を確認できません。" >&2
      loopback_cleanup_failed=1
    fi
  fi
  pkill -f "$project_root/.derived-data/Build/Products/Debug/PKPane.app" || true
  pkill -f "$project_root/.derived-data/Build/Products/Debug/PKPaneUITests-Runner.app" || true
  return "$loopback_cleanup_failed"
}

# 検証用Archiveは実行中のアプリへ干渉しない。
if [[ "$check_mode" != "--preview-archive" ]]; then
  cleanup_test_application
  trap cleanup_test_application EXIT
fi

swift format lint --recursive --parallel --strict \
    PKPane \
    PKPaneTests \
    PKPaneSnapshotTests \
    PKPaneUITests

"$project_root/scripts/generate_project.sh"

# 依存元は既知コミットの未改変チェックアウトを使い、通常Xcodeと同じ条件で検証する。
if [[ ! -f "$plzma_checkout_path/Package.swift" ]]; then
  xcodebuild \
      -resolvePackageDependencies \
      -project PKPane.xcodeproj \
      -clonedSourcePackagesDirPath .derived-data/SourcePackages
fi

if [[ "$(git -C "$plzma_checkout_path" rev-parse HEAD)" != "$plzma_expected_revision" ]]; then
  echo "PLzmaSDKのリビジョンが固定した依存指定と一致しません。" >&2
  exit 1
fi

if ! git -C "$plzma_checkout_path" diff --quiet HEAD -- Package.swift; then
  echo "PLzmaSDKのPackage.swiftが変更されています。通常Xcodeと同じ未改変依存を使用してください。" >&2
  exit 1
fi

if [[ "$check_mode" == "--release-archive" ]]; then
  mkdir -p "$project_root/.derived-data/release-archives"
  readonly archive_output_root="$(mktemp -d "$project_root/.derived-data/release-archives/PKPane.XXXXXXXX")"
  readonly release_archive_path="$archive_output_root/PKPane.xcarchive"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane \
      -configuration Release \
      -destination "generic/platform=macOS" \
      -derivedDataPath .derived-data \
      -archivePath "$release_archive_path" \
      ARCHS=arm64 \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$distribution_signing_identity" \
      DEVELOPMENT_TEAM="$distribution_team_id" \
      PROVISIONING_PROFILE_SPECIFIER="$distribution_profile_uuid" \
      AD_HOC_CODE_SIGNING_ALLOWED=NO \
      CODE_SIGN_ENTITLEMENTS="$store_entitlements_path" \
      archive
  "$project_root/scripts/verify_mas_build.sh" "$release_archive_path/Products/Applications/PKPane.app"
  # 生成物の署名証明書も照合し、設定だけの成功やad-hoc署名を除外する。
  codesign -d --extract-certificates "$archive_output_root/signing-certificate-" \
      "$release_archive_path/Products/Applications/PKPane.app" 2>/dev/null
  readonly archive_signing_certificate_path="$archive_output_root/signing-certificate-0"
  if [[ ! -f "$archive_signing_certificate_path" ]]; then
    echo "Archiveの配布署名証明書を確認できません。" >&2
    exit 65
  fi
  readonly archive_certificate_digest="$(shasum -a 1 "$archive_signing_certificate_path")"
  if [[ "${(U)${archive_certificate_digest%% *}}" != "$distribution_signing_identity" ]]; then
    echo "Archiveの署名証明書が指定した配布署名IDと一致しません。" >&2
    exit 65
  fi
  echo "配布署名Release Archiveと静的構成を確認しました: $release_archive_path"
elif [[ "$check_mode" == "--preview-archive" ]]; then
  # 配布署名経路とは分離し、本番Sandbox構成の検証用Archiveを新規作成する。
  mkdir -p "$project_root/.derived-data/local-archives"
  readonly preview_output_root="$(mktemp -d "$project_root/.derived-data/local-archives/PKPane-preview.XXXXXXXX")"
  readonly preview_archive_path="$preview_output_root/PKPane.xcarchive"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane \
      -configuration Release \
      -destination "generic/platform=macOS" \
      -derivedDataPath .derived-data \
      -archivePath "$preview_archive_path" \
      ARCHS=arm64 \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$store_entitlements_path" \
      archive
  "$project_root/scripts/verify_mas_build.sh" "$preview_archive_path/Products/Applications/PKPane.app"
  echo "検証用ad-hoc署名Release Archiveと静的構成を確認しました: $preview_archive_path"
elif [[ "$check_mode" == "--build-only" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -quiet \
      build
elif [[ "$check_mode" == "--test" || "$check_mode" == "--only-testing" || "$check_mode" == "--sandbox-sidebar-test" ]]; then
  unit_test_entitlements_path="$adhoc_entitlements_path"
  if [[ "$check_mode" == "--sandbox-sidebar-test" ]]; then
    # 実ユーザーのフォルダを開かず、本番Sandbox下のホーム解決だけを確認する。
    unit_test_entitlements_path="$store_entitlements_path"
    unit_test_filters=(-only-testing:PKPaneTests/UserHomeDirectoryTests)
  fi
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$unit_test_entitlements_path" \
      PKPANE_RV26_MEASUREMENTS="$rv26_measurements" \
      -parallel-testing-enabled NO \
      "${unit_test_filters[@]}" \
      -quiet \
      test
elif [[ "$check_mode" == "--browser-performance-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/LocalFileProviderTests \
      -only-testing:PKPaneTests/LocalFileProviderPerformanceTests \
      -only-testing:PKPaneTests/FileTreePerformanceTests \
      -only-testing:PKPaneTests/FileColumnPerformanceTests \
      -only-testing:PKPaneTests/BrowserNavigationRegressionTests \
      test
elif [[ "$check_mode" == "--sftp-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPFirstConnectionPresentsTrustConfirmation \
      test
elif [[ "$check_mode" == "--ftp-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelOpensViaKeyboardShortcutAndSwitchesProtocol \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelFormShowsConnectionTestButtonForAllProtocols \
      test
elif [[ "$check_mode" == "--sftp-loopback-test" ]]; then
  if (( $# == 1 )); then
    unit_test_filters=(-only-testing:PKPaneTests/SFTPLoopbackWireTests)
  fi
  sftp_loopback_configuration="$(python3 "$project_root/scripts/rv26_sftp_loopback.py" start)"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      PKPANE_RV26_SFTP_WIRE_CONFIG="$sftp_loopback_configuration" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_SFTP_LOOPBACK_TESTS' \
      -parallel-testing-enabled NO \
      "${unit_test_filters[@]}" \
      -quiet \
      test
elif [[ "$check_mode" == "--sftp-jump-loopback-test" ]]; then
  sftp_jump_loopback_configuration="$(python3 "$project_root/scripts/rv26_sftp_loopback.py" start "$sftp_jump_root_pointer")"
  sftp_loopback_configuration="$(python3 "$project_root/scripts/rv26_sftp_loopback.py" start)"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      PKPANE_RV26_SFTP_WIRE_CONFIG="$sftp_loopback_configuration" \
      PKPANE_RV26_SFTP_JUMP_CONFIG="$sftp_jump_loopback_configuration" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_SFTP_LOOPBACK_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/SFTPJumpLoopbackWireTests \
      -quiet \
      test
elif [[ "$check_mode" == "--sftp-auth-matrix-test" ]]; then
  # Dockerが無い環境では終了コード3で戻るので、失敗ではなくskipとして0終了する。
  set +e
  sftp_auth_matrix_configuration="$(python3 "$project_root/scripts/rv26_sftp_auth_matrix.py" start)"
  matrix_start_status=$?
  set -e
  if (( matrix_start_status == 3 )); then
    sftp_auth_matrix_configuration=""
    echo "Dockerが見つからないためSFTP認証行列テストをskipしました。"
    exit 0
  elif (( matrix_start_status != 0 )); then
    sftp_auth_matrix_configuration=""
    echo "SFTP認証行列サーバー群の起動に失敗しました。" >&2
    exit "$matrix_start_status"
  fi
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      PKPANE_RV26_SFTP_MATRIX_CONFIG="$sftp_auth_matrix_configuration" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_SFTP_LOOPBACK_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/SFTPAuthMatrixWireTests \
      -quiet \
      test
elif [[ "$check_mode" == "--ftp-loopback-test" ]]; then
  # 資格情報はargvへ渡さず、専用600設定ファイルから単体ホストへ渡す。
  ftp_loopback_configuration="$(python3 "$project_root/scripts/rv26_ftp_loopback.py" start)"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      PKPANE_RV26_FTP_WIRE_CONFIG="$ftp_loopback_configuration" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_FTP_LOOPBACK_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/FTPLoopbackWireTests \
      -quiet \
      test
elif [[ "$check_mode" == "--ftp-live-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_LIVE_FTP_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/FTPLiveServerTests \
      test
elif [[ "$check_mode" == "--ftp-live-write-test" ]]; then
  read "live_ftp_host?FTPホスト: "
  read "live_ftp_port?FTPポート [21]: "
  read "live_ftp_username?FTPユーザー名: "
  read -s "live_ftp_password?FTPパスワード: "
  echo
  read "live_ftp_directory?FTPテストディレクトリ [/]: "
  read "live_ftp_security?接続方式 [plain/explicitTLS]: "
  live_ftp_port="${live_ftp_port:-21}"
  live_ftp_directory="${live_ftp_directory:-/}"
  live_ftp_security="${live_ftp_security:-explicitTLS}"
  export PKPANE_LIVE_FTP_HOST="$live_ftp_host"
  export PKPANE_LIVE_FTP_PORT="$live_ftp_port"
  export PKPANE_LIVE_FTP_USERNAME="$live_ftp_username"
  export PKPANE_LIVE_FTP_PASSWORD="$live_ftp_password"
  export PKPANE_LIVE_FTP_DIRECTORY="$live_ftp_directory"
  export PKPANE_LIVE_FTP_SECURITY="$live_ftp_security"
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_LIVE_FTP_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/FTPLiveServerTests/roundTripsWritableFTPServer\(\) \
      test
elif [[ "$check_mode" == "--ftp-live-sandbox-test" ]]; then
  # Releaseのxctestホストはad-hoc署名したSwiftPM動的frameworkとのTeam IDが一致しない。
  # 動的Sandbox確認はDebugで行い、本番Releaseはverify_mas_build.shで別に検証する。
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$store_entitlements_path" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PKPANE_LIVE_FTP_TESTS' \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneTests/FTPLiveServerTests \
      test
elif [[ "$check_mode" == "--toolbar-appearance-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testToolbarDoesNotShowSplitViewSeparators \
      test
elif [[ "$check_mode" == "--workspace-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testRestoredLocalFolderUsesCommonWorkspace \
      -only-testing:PKPaneUITests/PKPaneUITests/testDefaultLaunchUsesTwoPaneLayout \
      -only-testing:PKPaneUITests/PKPaneUITests/testMainMenuProvidesFileEditViewAndGoMenus \
      -only-testing:PKPaneUITests/PKPaneUITests/testMainEditMenuCopyPasteTransfersFile \
      -only-testing:PKPaneUITests/PKPaneUITests/testMainViewMenuChangesListSortOrder \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnViewShortcutExpandsSelectedFolder \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnViewRowShowsContextMenu \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnViewShowsItemsAfterOpeningSidebarFavorite \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnFileSelectionUpdatesDetailsInspector \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnArrowKeysMoveBetweenRowsAndColumns \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnWidthCanBeResizedAndPersistsAcrossRelaunch \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnViewModePersistsAcrossRelaunch \
      -only-testing:PKPaneUITests/PKPaneUITests/testFileMoveAndCommandMenusExposeMenuBarCompleteItems \
      -only-testing:PKPaneUITests/PKPaneUITests/testFileMenuDuplicateCreatesCopyOfSelectedItem \
      -only-testing:PKPaneUITests/PKPaneUITests/testGoMenuServerConnectionOpensConnectPanelListMode \
      -only-testing:PKPaneUITests/PKPaneUITests/testClickingInactivePaneListActivatesPane \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnHeadersSortListAndToggleDirection \
      -only-testing:PKPaneUITests/PKPaneUITests/testListDisclosureTriangleExpandsAndCollapsesChildren \
      -only-testing:PKPaneUITests/PKPaneUITests/testListArrowKeysExpandCollapseAndSelectParentFolder \
      -only-testing:PKPaneUITests/PKPaneUITests/testListCommandClickTogglesMultipleSelection \
      -only-testing:PKPaneUITests/PKPaneUITests/testCommandDeleteRemovesAllSelectedFiles \
      -only-testing:PKPaneUITests/PKPaneUITests/testListShiftClickSelectsRange \
      -only-testing:PKPaneUITests/PKPaneUITests/testIconViewCommandClickSelectsMultipleItemsForCopy \
      -only-testing:PKPaneUITests/PKPaneUITests/testIconViewCommandPlusIncreasesIconGridCellSize \
      -only-testing:PKPaneUITests/PKPaneUITests/testNavigatedLocalFolderIsAddedToRecentLocations \
      -only-testing:PKPaneUITests/PKPaneUITests/testActionMenuTogglesCurrentLocalFolderFavorite \
      -only-testing:PKPaneUITests/PKPaneUITests/testFolderContextMenuAddsLocalFolderToFavorites \
      -only-testing:PKPaneUITests/PKPaneUITests/testDraggingLocalFolderToFavoritesRegistersIt \
      -only-testing:PKPaneUITests/PKPaneUITests/testRecentLocationCanBeRemoved \
      -only-testing:PKPaneUITests/PKPaneUITests/testFavoriteLocationCanBeRemoved \
      -only-testing:PKPaneUITests/PKPaneUITests/testRecentNASConnectionCanBeRemoved \
      -only-testing:PKPaneUITests/PKPaneUITests/testContextMenuExposesOpenWithAndCopyPathSubmenus \
      -only-testing:PKPaneUITests/PKPaneUITests/testContextMenuChooseCopyDestinationOpensDestinationSheet \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelOpensViaKeyboardShortcutAndSwitchesProtocol \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelOpensViaKeyboardShortcutShowsListMode \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelNewConnectionButtonNavigatesToFormAndBackReturnsToList \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelFormShowsConnectionTestButtonForAllProtocols \
      -only-testing:PKPaneUITests/PKPaneUITests/testConnectPanelConnectionTestShowsUnreachableGuidanceForInvalidHost \
      -only-testing:PKPaneUITests/PKPaneUITests/testSidebarConnectButtonOpensConnectPanel \
      -only-testing:PKPaneUITests/PKPaneUITests/testSidebarConnectionCanBeHiddenAndRestoredFromConnectPanel \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPConnectionContextMenuDeletesConnection \
      -only-testing:PKPaneUITests/PKPaneUITests/testFileInfoDialogShowsThumbnailAndNameHeaderForSingleSelection \
      -only-testing:PKPaneUITests/PKPaneUITests/testFileInfoDialogShowsItemCountAndTotalSizeForMultipleSelection \
      -only-testing:PKPaneUITests/PKPaneUITests/testDetailsInspectorFollowsSelectionAfterOpeningWithShortcut \
      -only-testing:PKPaneUITests/PKPaneUITests/testDetailsInspectorClosesWithKeyboardShortcut \
      -only-testing:PKPaneUITests/PKPaneUITests/testDetailsDisplayModeChangesFromToolbarMenu \
      test
elif [[ "$check_mode" == "--transfer-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPCopyToOppositePaneTransfersSelectedFile \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPMultipleCopiesShowAllJobsAndTransferFiles \
      -only-testing:PKPaneUITests/PKPaneUITests/testContextMenuCopyPasteTransfersFile \
      -only-testing:PKPaneUITests/PKPaneUITests/testContextMenuCutPasteMovesFile \
      -only-testing:PKPaneUITests/PKPaneUITests/testLocalDragAndDropTransfersFileToOppositePane \
      -only-testing:PKPaneUITests/PKPaneUITests/testLocalDragAndDropMoveRemovesSourceFile \
      -only-testing:PKPaneUITests/PKPaneUITests/testLocalDragAndDropCopiesFileToSidebarFavorite \
      -only-testing:PKPaneUITests/PKPaneUITests/testListFolderRowDropMovesExpandedChildIntoFolder \
      -only-testing:PKPaneUITests/PKPaneUITests/testColumnDragAndDropMovesFileIntoFolderAndColumnBackground \
      -only-testing:PKPaneUITests/PKPaneUITests/testTransferDestinationSheetCopiesToOppositePane \
      test
elif [[ "$check_mode" == "--provider-rename-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPRenameChangesFileNameViaContextMenu \
      -only-testing:PKPaneUITests/PKPaneUITests/testClickToRenameEditsFileNameInline \
      -only-testing:PKPaneUITests/PKPaneUITests/testInactivePaneRowClickDoesNotStartInlineRename \
      test
elif [[ "$check_mode" == "--nas-delete-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testNASWithoutTrashUsesCancelAsPermanentDeleteDefault \
      -only-testing:PKPaneUITests/PKPaneUITests/testNASContextMenuDeletesAllSelectedItems \
      -only-testing:PKPaneUITests/PKPaneUITests/testRecentNetworkLocationUsesMountedProvider \
      test
elif [[ "$check_mode" == "--remote-edit-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPExternalEditCreatesWorkingCopy \
      test
elif [[ "$check_mode" == "--archive-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testLocalZIPCompressionFromContextMenu \
      test
elif [[ "$check_mode" == "--archive-extract-ui-test" ]]; then
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testLocalZIPExtractionFromContextMenu \
      test
else
  xcodebuild \
      -project PKPane.xcodeproj \
      -scheme PKPane-All \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath .derived-data \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY=- \
      AD_HOC_CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_ENTITLEMENTS="$adhoc_entitlements_path" \
      -parallel-testing-enabled NO \
      -only-testing:PKPaneUITests/PKPaneUITests/testSFTPConnectionPreservesTwoPaneLayout \
      test
fi
