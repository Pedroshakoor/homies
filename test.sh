#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$PWD/build/module-cache" \
  -parse-as-library Sources/Models.swift Sources/EventParser.swift Sources/CLIAdapter.swift Sources/AgentServices.swift Tests/Checks.swift -o build/checks
exec build/checks "$@"
