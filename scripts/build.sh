#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
./scripts/swift-tool.sh build -c release
task_bin="$(./scripts/swift-tool.sh build -c release --show-bin-path)"
task_app="$task_root/dist/Codex Pulse.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/CodexPulse" "$task_app/Contents/MacOS/CodexPulse"
cp Resources/Info.plist "$task_app/Contents/Info.plist"
swift scripts/make-icon.swift "$task_root/dist"
iconutil -c icns "$task_root/dist/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$task_app"
printf 'Built: %s\n' "$task_app"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  # ditto updates only this app bundle; no system settings are changed.
  ditto "$task_app" "$HOME/Applications/Codex Pulse.app"
  open "$HOME/Applications/Codex Pulse.app"
fi
