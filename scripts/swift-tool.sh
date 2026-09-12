#!/bin/bash
set -euo pipefail
# Some CLT releases ship SwiftPM frameworks outside the binary's rpaths.
# Invoke the toolchain directly: /usr/bin wrappers can strip DYLD_* variables.
task_developer_dir="$(xcode-select -p)"
if [[ -d "$task_developer_dir/usr/lib/swift/pm/BuildServerProtocol.framework" ]]; then
  task_pm="$task_developer_dir/usr/lib/swift/pm"
  export DYLD_FRAMEWORK_PATH="$task_pm:$task_pm/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle/Contents/Frameworks:$task_pm/llbuild:$task_developer_dir/Library/Developer/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
  export DYLD_LIBRARY_PATH="$task_developer_dir/Library/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  task_command="$1"
  shift
  task_testing_plugin="$task_developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  if [[ "$task_command" == "test" && -f "$task_testing_plugin" ]]; then
    set -- "$@" -Xswiftc -load-plugin-library -Xswiftc "$task_testing_plugin"
  fi
  exec "$task_developer_dir/usr/bin/swift-$task_command" "$@"
else
  exec swift "$@"
fi
