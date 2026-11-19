#!/bin/zsh

set -euo pipefail

readonly project_root="${0:A:h:h}"
cd "$project_root"

if ! command -v xcodegen >/dev/null 2>&1; then
    print -u2 "XcodeGenが見つかりません。HomebrewなどでXcodeGen 2.45.4以上を導入してください。"
    exit 1
fi

xcodegen generate
