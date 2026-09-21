#!/usr/bin/env python3
"""Build and optionally install the signed Tablet Companion application."""
from __future__ import annotations
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--identity", help="Apple Development or Developer ID signing identity")
parser.add_argument("--install", action="store_true", help="Install into ~/Applications")
parser.add_argument("--release", action="store_true", help="Build a notarization-ready Developer ID bundle without installing or changing the local signing pin")
parser.add_argument("--version", help="Release marketing version (X.Y.Z)")
parser.add_argument("--build-number", help="Release build number (positive integer)")
parser.add_argument("--output", help="Absolute fresh .app output path for a release build")
args = parser.parse_args()
if args.release:
    if not args.version or not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("--release requires --version X.Y.Z")
    if not args.build_number or not args.build_number.isdigit() or int(args.build_number) <= 0:
        parser.error("--release requires --build-number as a positive integer")
    if not args.output or not Path(args.output).is_absolute() or not args.output.endswith(".app"):
        parser.error("--release requires an absolute --output path ending in .app")
    if args.install:
        parser.error("--install cannot be used with --release")
elif any(value is not None for value in (args.version, args.build_number, args.output)):
    parser.error("--version, --build-number, and --output require --release")
if args.release:
    if os.path.lexists(args.output):
        raise SystemExit(f"Refusing to replace existing release output: {args.output}")
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)


def run(*command: str, capture: bool = True) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None)
    return result.stdout or ""
pin = ROOT / ".local/macos-signing-identity"
requested = args.identity or os.environ.get("APPLE_SIGNING_IDENTITY")
if args.release:
    if not requested or requested == "-":
        raise SystemExit("Release builds require --identity Developer ID Application (name or SHA-1).")
    identities = re.findall(r'\) ([A-Fa-f0-9]{40}) "(Developer ID Application:[^"]+)"',
                            run("security", "find-identity", "-v", "-p", "codesigning"))
    matches = [(key, name) for key, name in identities if requested in (key, name)]
    if len(matches) != 1:
        raise SystemExit("Selected Developer ID Application identity unavailable or ambiguous.")
    identity = matches[0][0]
else:
    if requested == "-":
        raise SystemExit("Ad-hoc signing is refused; provide a persistent Apple Development identity.")
    pinned = pin.read_text().strip() if pin.exists() else None
    identities = re.findall(r'\) ([A-Fa-f0-9]{40}) "((?:Apple Development:|Developer ID Application:)[^"]+)"',
                            run("security", "find-identity", "-v", "-p", "codesigning"))
    identity = requested or pinned
    if identity:
        matches = [(key, name) for key, name in identities if identity in (key, name)]
        if len(matches) != 1:
            raise SystemExit("Signing identity unavailable or ambiguous.")
        identity = matches[0][0]
    elif identities and len({name for _, name in identities}) == 1:
        identity = sorted(key for key, _ in identities)[0]
    else:
        raise SystemExit("Select a persistent signing identity with --identity.")
    if pinned and requested and requested != pinned:
        raise SystemExit("Signing identity differs from local pin; migrate intentionally.")
    pin.parent.mkdir(exist_ok=True)
    pin.write_text(identity + "\n")

run("swift", "build", "-c", "release", capture=False)
bin_dir = Path(run("swift", "build", "-c", "release", "--show-bin-path").strip())
binary = bin_dir / "WacomCompanion"
if not binary.is_file():
    raise SystemExit(f"SwiftPM did not produce {binary}")

app = Path(args.output) if args.release else ROOT / ".build/Tablet Companion.app"
if args.release and os.path.lexists(args.output):
    raise SystemExit(f"Refusing to replace existing release output: {app}")
staging = (Path(tempfile.mkdtemp(prefix="wacom-release-", dir=ROOT / ".build")) / "Tablet Companion.app"
           if args.release else ROOT / ".build/Tablet Companion-staging.app")
for candidate in (app, staging):
    if candidate.exists():
        info_path = candidate / "Contents/Info.plist"
        if not info_path.is_file():
            raise SystemExit(f"Refusing to replace foreign bundle: {candidate}")
        with info_path.open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != "dev.tucker.wacom-companion":
                raise SystemExit(f"Refusing to replace foreign bundle: {candidate}")
if not args.release and subprocess.run(["pgrep", "-x", "WacomCompanion"], capture_output=True).returncode == 0:
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
    "CFBundleName": "Tablet Companion",
    "CFBundleExecutable": "WacomCompanion",
    "CFBundleIdentifier": "dev.tucker.wacom-companion",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": args.version if args.release else "1.0.1",
    "CFBundleVersion": args.build_number if args.release else "3",
    "CFBundleIconFile": "TabletCompanion",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "26.0",
    "NSAppleEventsUsageDescription": "Tablet Companion uses Automation to read and update Wacom tablet preferences when you ask it to.",
}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
entitlements = ROOT / ".build/WacomCompanion.entitlements.plist"
entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
signing = ["--timestamp", "--options", "runtime"] if args.release else ["--options", "runtime"]
run("codesign", "--force", *signing, "--sign", identity,
    "--entitlements", str(entitlements), str(staging), capture=False)
run("codesign", "--verify", "--deep", "--strict", str(staging), capture=False)
if args.release:
    shutil.copytree(staging, app, symlinks=True)
    shutil.rmtree(staging.parent)
else:
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
