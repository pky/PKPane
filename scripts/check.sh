#!/bin/zsh

set -euo pipefail

readonly project_root="${0:A:h:h}"
cd "$project_root"

swift format lint --recursive --parallel --strict \
    PKPane \
    PKPaneTests \
    PKPaneSnapshotTests \
    PKPaneUITests

"$project_root/scripts/generate_project.sh"

xcodebuild \
    -project PKPane.xcodeproj \
    -scheme PKPane \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath .derived-data \
    CODE_SIGNING_ALLOWED=NO \
    test
