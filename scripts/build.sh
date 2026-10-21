#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
./scripts/swift-tool.sh build -c release
task_bin="$(./scripts/swift-tool.sh build -c release --show-bin-path)"
task_app="$task_root/dist/AI Pulse.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin/CodexPulse" "$task_app/Contents/MacOS/CodexPulse"
cp Resources/Info.plist "$task_app/Contents/Info.plist"
swift scripts/make-icon.swift "$task_root/dist"
iconutil -c icns "$task_root/dist/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$task_app"
printf 'Built: %s\n' "$task_app"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  # Preserve the bundle identifier so preferences, Keychain keys and Reset history survive.
  # Store rollback copies as archives, outside Spotlight's application search results.
  task_backup="$HOME/.local/share/ai-pulse/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$task_backup"
  pkill -TERM -x CodexPulse || true
  for task_old in "$HOME/Applications/Codex Pulse.app" "$HOME/Applications/AI Pulse.app"; do
    if [[ -d "$task_old" ]]; then
      task_archive="$task_backup/$(basename "$task_old").zip"
      ditto -c -k --sequesterRsrc --keepParent "$task_old" "$task_archive"
      unzip -tq "$task_archive" >/dev/null
      mv "$task_old" "$task_backup/$(basename "$task_old").noindex"
    fi
  done
  ditto "$task_app" "$HOME/Applications/AI Pulse.app"
  open "$HOME/Applications/AI Pulse.app"
fi
