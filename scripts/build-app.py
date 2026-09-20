#!/usr/bin/env python3
"""Build and optionally install the signed Tablet Companion application."""
from __future__ import annotations
import argparse
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--identity", help="Apple Development or Developer ID signing identity")
parser.add_argument("--install", action="store_true", help="Install into ~/Applications")
args = parser.parse_args()


def run(*command: str, capture: bool = True) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    return result.stdout or ""


if args.identity == "-":
    raise SystemExit("Ad-hoc signing is refused; provide a persistent Apple Development identity.")
pin = ROOT / ".local/macos-signing-identity"
requested = args.identity or os.environ.get("APPLE_SIGNING_IDENTITY")
pinned = pin.read_text().strip() if pin.exists() else None
identities = re.findall(r'\) ([A-Fa-f0-9]{40}) "((?:Apple Development:|Developer ID Application:)[^"]+)"',
                        run("security", "find-identity", "-v", "-p", "codesigning"))
identity = requested or pinned
if pinned and requested and requested != pinned:
    raise SystemExit("Signing identity differs from local pin; migrate intentionally.")
if identity:
    matches = [(key, name) for key, name in identities if identity in (key, name)]
    if len(matches) != 1:
        raise SystemExit("Signing identity unavailable or ambiguous.")
    identity = matches[0][0]
elif identities and len({name for _, name in identities}) == 1:
    identity = sorted(key for key, _ in identities)[0]
else:
    raise SystemExit("Select a persistent signing identity with --identity.")
pin.parent.mkdir(exist_ok=True)
pin.write_text(identity + "\n")

run("swift", "build", "-c", "release", capture=False)
bin_dir = Path(run("swift", "build", "-c", "release", "--show-bin-path").strip())
binary = bin_dir / "WacomCompanion"
if not binary.is_file():
    raise SystemExit(f"SwiftPM did not produce {binary}")

app = ROOT / ".build/Tablet Companion.app"
staging = ROOT / ".build/Tablet Companion-staging.app"
for candidate in (app, staging):
    if candidate.exists():
        info_path = candidate / "Contents/Info.plist"
        if not info_path.is_file():
            raise SystemExit(f"Refusing to replace foreign bundle: {candidate}")
        with info_path.open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != "dev.tucker.wacom-companion":
                raise SystemExit(f"Refusing to replace foreign bundle: {candidate}")
if subprocess.run(["pgrep", "-x", "WacomCompanion"], capture_output=True).returncode == 0:
    raise SystemExit("WacomCompanion is running; quit it before replacing the bundle.")
if staging.exists():
    shutil.rmtree(staging)
contents = staging / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
shutil.copy2(binary, contents / "MacOS/WacomCompanion")
iconset = ROOT / ".build/TabletCompanion.iconset"
run("swift", str(ROOT / "scripts/make-icon.swift"), str(iconset))
run("iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources/TabletCompanion.icns"))

info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Tablet Companion",
    "CFBundleExecutable": "WacomCompanion",
    "CFBundleIdentifier": "dev.tucker.wacom-companion",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Tablet Companion",
    "CFBundleIconFile": "TabletCompanion",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "26.0",
    "NSAppleEventsUsageDescription": "Tablet Companion uses Automation to read and update Wacom tablet preferences when you ask it to.",
}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
entitlements = ROOT / ".build/WacomCompanion.entitlements.plist"
entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
run("codesign", "--force", "--options", "runtime", "--sign", identity,
    "--entitlements", str(entitlements), str(staging), capture=False)
run("codesign", "--verify", "--deep", "--strict", str(staging), capture=False)
if app.exists():
    shutil.rmtree(app)
staging.rename(app)
print(f"Built {app}")
print("Signed with persistent identity; not notarized.")

if args.install:
    destination = Path.home() / "Applications/Tablet Companion.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        info_path = destination / "Contents/Info.plist"
        if not info_path.exists():
            raise SystemExit(f"Refusing to replace foreign bundle: {destination}")
        with info_path.open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != "dev.tucker.wacom-companion":
                raise SystemExit(f"Refusing to replace foreign bundle: {destination}")
        if subprocess.run(["pgrep", "-x", "WacomCompanion"], capture_output=True).returncode == 0:
            raise SystemExit("WacomCompanion is running; refusing installation.")
        shutil.rmtree(destination)
    shutil.copytree(app, destination)
    print(f"Installed {destination}")
