#!/usr/bin/env python3
"""Detach only AI Pulse's stale Control Center aliases from other launchers.

Tahoe retains menuItemLocations under the app that originally launched a menu
utility. A disabled historical owner can suppress it even after an independent
launch. Preserve every app's allow/deny choice and every unrelated menu item.
"""
import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


BUNDLE_ID = "dev.yuwangzhi.codexpulse"


def detach_aliases(tracked):
    if not isinstance(tracked, list) or len(tracked) % 2:
        raise ValueError("Unrecognized Control Center records; nothing changed")
    for key, row in zip(tracked[::2], tracked[1::2]):
        if (not isinstance(key, dict) or not isinstance(row, dict)
                or row.get("location") != key
                or not isinstance(row.get("isAllowed"), bool)
                or not isinstance(row.get("menuItemLocations"), list)
                or not all(isinstance(x, dict) for x in row["menuItemLocations"])):
            raise ValueError("Unrecognized Control Center record; nothing changed")
    own_location = {"bundle": {"_0": BUNDLE_ID}}
    # Without a separate owner, removing an alias might remove the only control.
    if own_location not in tracked[::2]:
        return copy.deepcopy(tracked), []
    result = copy.deepcopy(tracked)
    detached = []
    for key, row in zip(result[::2], result[1::2]):
        if key == own_location:
            continue
        locations = row["menuItemLocations"]
        if own_location in locations:
            row["menuItemLocations"] = [x for x in locations if x != own_location]
            detached.append(key)
    return result, detached


def read_preferences(domain):
    data = subprocess.check_output(["/usr/bin/defaults", "export", str(domain), "-"])
    return data, plistlib.loads(data)


def main():
    domain = (Path.home() / "Library/Group Containers/group.com.apple.controlcenter"
              / "Library/Preferences/group.com.apple.controlcenter")
    if not Path(str(domain) + ".plist").exists():
        return
    original, prefs = read_preferences(domain)
    encoded = prefs.get("trackedApplications")
    if encoded is None:
        return
    if not isinstance(encoded, bytes):
        raise ValueError("Unrecognized trackedApplications value; nothing changed")
    repaired, detached = detach_aliases(plistlib.loads(encoded))
    if not detached:
        print("AI Pulse menu ownership: no stale aliases")
        return
    backup_root = Path.home() / ".local/share/ai-pulse/backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="menu-ownership-", dir=backup_root))
    (backup / "controlcenter-before.plist").write_bytes(original)
    # Catch concurrent settings changes before writing only the one affected key.
    _, latest = read_preferences(domain)
    if latest.get("trackedApplications") != encoded:
        raise RuntimeError("Menu preferences changed during repair; retry installation")
    updated = plistlib.dumps(repaired, fmt=plistlib.FMT_BINARY, sort_keys=False)
    subprocess.run(["/usr/bin/defaults", "write", str(domain), "trackedApplications",
                    "-data", updated.hex()], check=True)
    _, verified = read_preferences(domain)
    if plistlib.loads(verified["trackedApplications"]) != repaired:
        raise RuntimeError("Menu ownership write could not be verified")
    (backup / "detached-owners.json").write_text(json.dumps(detached, indent=2))
    # Refresh the host's cached ownership, without resetting any menu preferences.
    stopped = subprocess.run(["/usr/bin/pkill", "-TERM", "-u", str(os.getuid()),
                              "-x", "ControlCenter"], check=False)
    if stopped.returncode not in (0, 1):
        raise RuntimeError("Could not refresh Control Center")
    print(f"AI Pulse menu ownership: detached {len(detached)} stale owner(s); backup: {backup}")


if __name__ == "__main__":
    main()
