#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
build_dir="${SPLATIVERSE_BUILD_DIR:-$project_dir/.build-device}"
xcodebuild -project "$project_dir/Splativerse.xcodeproj" -scheme Splativerse \
  -configuration Release -destination 'generic/platform=visionOS' \
  -derivedDataPath "$build_dir" CODE_SIGNING_ALLOWED=NO build
