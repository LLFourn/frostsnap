#!/usr/bin/env bash

set -e

BASEDIR=$(dirname "$0")
BUILD_TOOL_PKG_DIR="$BASEDIR/build_tool"

if [[ -z $FLUTTER_ROOT ]]; then # not defined
  DART=dart
else
  DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
fi

# build_tool runs under its own committed pubspec.lock, so its dependencies
# are pinned. Upstream cargokit wraps it in a generated package that has no
# lockfile.
(cd "$BUILD_TOOL_PKG_DIR" && "$DART" pub get --enforce-lockfile --no-precompile)
exec "$DART" --packages="$BUILD_TOOL_PKG_DIR/.dart_tool/package_config.json" "$BUILD_TOOL_PKG_DIR/bin/build_tool.dart" "$@"
