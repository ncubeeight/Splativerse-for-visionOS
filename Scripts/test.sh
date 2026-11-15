#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
swift test --package-path "$project_dir/Packages/SplativerseCore"
swift test --package-path "$project_dir/Vendor/MetalSplatter"
