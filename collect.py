#!/usr/bin/env python3
"""Print the JetBrains Toolbox tools and recent projects as one JSON object.

Toolbox has no public API for this, so the data comes from the files Toolbox
and the IDEs keep on disk. Every source is optional: a missing or unreadable
file adds a line to "errors" instead of failing the whole snapshot.

The snapshot never touches the network. Pending updates come from a cache
that --check-updates refreshes from the JetBrains release feed, so the panel
stays instant and works offline.
"""

import argparse
import glob
import json
import os
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share")
CONFIG_HOME = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
CACHE_HOME = os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache")
TOOLBOX_DIR = os.path.join(DATA_HOME, "JetBrains", "Toolbox")
IDE_CONFIG_DIR = os.path.join(CONFIG_HOME, "JetBrains")

TOOLBOX_BINARIES = [
    "/opt/jetbrains-toolbox/jetbrains-toolbox",
    os.path.join(TOOLBOX_DIR, "bin", "jetbrains-toolbox"),
]

UPDATES_CACHE = os.path.join(CACHE_HOME, "goldbarth.arcula", "updates.json")
UPDATES_TTL = 6 * 3600
RELEASES_URL = "https://data.services.jetbrains.com/products/releases"
# The release feed names a few products differently than the IDEs do.
FEED_CODES = {"IU": "IIU", "IC": "IIC", "PY": "PCP", "PC": "PCC", "DB": "DG"}


def read_json(path, errors):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        errors.append(f"Missing {tilde(path)}")
    except (OSError, ValueError) as exc:
        errors.append(f"Cannot read {tilde(path)}: {exc}")
    return {}


def tilde(path):
    return "~" + path[len(HOME):] if path == HOME or path.startswith(HOME + os.sep) else path


def first_existing(paths):
    return next((p for p in paths if os.path.exists(p)), "")


def tool_icon(install_location):
    name = os.path.basename(install_location.rstrip(os.sep))
    pattern = os.path.join(TOOLBOX_DIR, "dotDesktopIcons", f"jetbrains-{glob.escape(name)}-*.svg")
    return next(iter(sorted(glob.glob(pattern))), "")


def initials(name):
    # Same rule as the IDEs' project avatars: first and last word, or for a
    # single word its first letter plus the next capital.
    # "retrieval-regression-harness" -> "RH", "ServiceDeskLite" -> "SD", "goldbarth" -> "G"
    words = re.findall(r"[^\W_]+", name)
    if not words:
        return name[:1].upper()
    if len(words) > 1:
        return (words[0][0] + words[-1][0]).upper()
    word = words[0]
    return (word[0] + next((char for char in word[1:] if char.isupper()), "")).upper()


def build_key(build):
    # "262.10968.170" -> (262, 10968, 170), so builds compare numerically.
    return tuple(int(part) for part in re.findall(r"\d+", build or ""))


def read_updates():
    try:
        with open(UPDATES_CACHE, encoding="utf-8") as handle:
            cache = json.load(handle)
    except (OSError, ValueError):
        return {}
    return cache if isinstance(cache, dict) else {}


def check_updates(force):
    """Refresh the cached latest release of every installed tool."""
    age = time.time() - (read_updates().get("checkedAt") or 0)
    if not force and 0 <= age < UPDATES_TTL:
        return
    state = read_json(os.path.join(TOOLBOX_DIR, "state.json"), [])
    codes = {tool.get("productCode") for tool in state.get("tools") or []} - {None, ""}
    if not codes:
        return
    by_feed_code = {FEED_CODES.get(code, code): code for code in codes}
    query = urllib.parse.urlencode({
        "code": ",".join(sorted(by_feed_code)),
        "latest": "true",
        "type": "release",
    })
    with urllib.request.urlopen(f"{RELEASES_URL}?{query}", timeout=10) as response:
        feed = json.load(response)
    latest = {}
    for feed_code, releases in feed.items():
        if feed_code in by_feed_code and releases:
            latest[by_feed_code[feed_code]] = {
                "version": releases[0].get("version") or "",
                "build": releases[0].get("build") or "",
            }
    os.makedirs(os.path.dirname(UPDATES_CACHE), exist_ok=True)
    pending = UPDATES_CACHE + ".tmp"
    with open(pending, "w", encoding="utf-8") as handle:
        json.dump({"checkedAt": int(time.time()), "latest": latest}, handle)
    os.replace(pending, UPDATES_CACHE)


def collect_tools(errors):
    state = read_json(os.path.join(TOOLBOX_DIR, "state.json"), errors)
    latest = read_updates().get("latest") or {}
    tools = []
    for tool in state.get("tools") or []:
        command = tool.get("launchCommand") or ""
        if not command:
            continue
        code = tool.get("productCode") or ""
        release = latest.get(code) or {}
        outdated = build_key(release.get("build")) > build_key(tool.get("buildNumber"))
        tools.append({
            "name": tool.get("displayName") or tool.get("toolId") or "",
            "version": tool.get("displayVersion") or "",
            "latestVersion": (release.get("version") or "") if outdated else "",
            "productCode": code,
            "launchCommand": command,
            "iconPath": tool_icon(tool.get("installLocation") or ""),
        })
    return tools


def hidden_projects(errors):
    settings = read_json(os.path.join(TOOLBOX_DIR, ".settings.json"), errors)
    projects = settings.get("projects") or {}
    return {path for path, meta in projects.items() if isinstance(meta, dict) and meta.get("hidden")}


def recent_entries(errors):
    """Yield (path, meta element) for every recent project of every IDE."""
    files = []
    for name in ("recentProjects.xml", "recentSolutions.xml"):
        files += glob.glob(os.path.join(glob.escape(IDE_CONFIG_DIR), "*", "options", name))
    for path in sorted(files):
        try:
            root = ET.parse(path).getroot()
        except (OSError, ET.ParseError) as exc:
            errors.append(f"Cannot read {tilde(path)}: {exc}")
            continue
        for entry in root.iter("entry"):
            meta = entry.find("./value/RecentProjectMetaInfo")
            key = entry.get("key") or ""
            if meta is not None and key:
                yield key.replace("$USER_HOME$", HOME), meta


def collect_projects(tools, errors):
    by_code = {tool["productCode"]: tool for tool in tools}
    hidden = hidden_projects(errors)
    projects = {}
    for path, meta in recent_entries(errors):
        options = {opt.get("name"): opt.get("value") for opt in meta.findall("option")}
        tool = by_code.get(options.get("productionCode") or "")
        # Toolbox lists a project only for an installed IDE that has actually
        # opened it, and drops the ones whose folder is gone.
        if tool is None or path in hidden or not os.path.exists(path):
            continue
        try:
            opened_at = int(options.get("projectOpenTimestamp") or 0)
        except ValueError:
            opened_at = 0
        known = projects.get(path)
        if known is not None and known["openedAt"] >= opened_at:
            continue
        stem = os.path.basename(path.rstrip(os.sep))
        name = meta.get("displayName") or (os.path.splitext(stem)[0] if os.path.isfile(path) else stem)
        projects[path] = {
            "name": name,
            "initials": initials(name),
            "path": path,
            "displayPath": tilde(path),
            "toolName": tool["name"],
            "launchCommand": tool["launchCommand"],
            "iconPath": tool["iconPath"],
            "opened": meta.get("opened") == "true",
            "openedAt": opened_at,
        }
    return sorted(projects.values(), key=lambda project: project["openedAt"], reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check-updates", action="store_true",
                        help="refresh the pending-update cache from the JetBrains release feed")
    parser.add_argument("--force", action="store_true",
                        help="with --check-updates, refresh even if the cache is still fresh")
    args = parser.parse_args()
    if args.check_updates:
        try:
            check_updates(args.force)
        except (OSError, ValueError) as exc:
            sys.exit(f"Update check failed: {exc}")
        return

    errors = []
    tools = collect_tools(errors)
    projects = collect_projects(tools, errors)
    json.dump({
        "tools": tools,
        "projects": projects,
        "toolbox": {
            "command": first_existing(TOOLBOX_BINARIES) or shutil.which("jetbrains-toolbox") or "",
        },
        "errors": errors,
    }, sys.stdout)


if __name__ == "__main__":
    main()
