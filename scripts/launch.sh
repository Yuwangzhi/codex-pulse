#!/bin/bash
set -euo pipefail
# Launch from a short-lived GUI launchd job, rather than inheriting a terminal or
# AI client's menu-bar attribution. This does not install a login/background job.
task_app="${1:-$HOME/Applications/AI Pulse.app}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ ! -d "$task_app/Contents/MacOS" ]]; then
  printf 'Application not found: %s\n' "$task_app" >&2
  exit 1
fi
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/ai-pulse-launch.XXXXXX")"
task_label="dev.yuwangzhi.codexpulse.open.$$"
task_service="gui/$(id -u)/$task_label"
task_loaded=false
cleanup() {
  if [[ "$task_loaded" == true ]]; then
    launchctl bootout "$task_service" >/dev/null 2>&1 || true
  fi
  rm -rf "$task_dir"
}
trap cleanup EXIT
/usr/bin/python3 - "$task_dir" "$task_label" "$task_app" "$@" <<'PY'
import pathlib, plistlib, sys
directory, label, app, *arguments = sys.argv[1:]
command = ['/usr/bin/open', '-a', app]
if arguments:
    command += ['--args', *arguments]
job = {
    'Label': label,
    'ProgramArguments': command,
    'RunAtLoad': True,
    'KeepAlive': False,
    'AbandonProcessGroup': True,
    'ProcessType': 'Interactive',
    'StandardOutPath': str(pathlib.Path(directory) / 'stdout'),
    'StandardErrorPath': str(pathlib.Path(directory) / 'stderr'),
}
(pathlib.Path(directory) / 'launch.plist').write_bytes(plistlib.dumps(job))
PY
launchctl bootstrap "gui/$(id -u)" "$task_dir/launch.plist"
task_loaded=true
for ((task_attempt = 0; task_attempt < 100; task_attempt++)); do
  task_state="$(launchctl print "$task_service")"
  task_exit="$(awk '/last exit code = / { print $5; exit }' <<< "$task_state")"
  if [[ "$task_exit" =~ ^[0-9]+$ ]]; then
    if [[ "$task_exit" != 0 ]]; then cat "$task_dir/stderr" >&2; fi
    exit "$task_exit"
  fi
  sleep 0.1
done
printf 'Timed out launching %s\n' "$task_app" >&2
exit 1
