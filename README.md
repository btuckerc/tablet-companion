# Tablet Companion

Set up your Wacom tablet and change its drawing shortcut on your Mac.

## Install

Requires macOS 26 or newer and an Apple Silicon Mac. For the supported signed and notarized distribution, download the latest **Tablet Companion** ZIP from [GitHub Releases](https://github.com/btuckerc/tablet-companion/releases), unzip it, move **Tablet Companion.app** to your **Applications** folder, and open it. The release is distributed directly by GitHub, not through the Mac App Store; no developer certificate or xattr bypass is required.

### Local development

For local development, Xcode, Python 3, and an Apple signing certificate are required. Run this command in this folder:

```sh
python3 scripts/build-app.py --install
```

Open **Tablet Companion** in your home folder’s **Applications** folder.

The local build is development-signed and is not an Apple-notarized download.

## Developer ID release build

Release mode requires an installed **Developer ID Application** certificate and does not modify the local development signing pin or install the app. It packages the native host architecture only:

```sh
python3 scripts/build-app.py --release \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --version 1.0.1 --build-number 3 --output /absolute/path/Tablet-Companion.app
```

The output path must not already exist. This command signs only; it does not notarize or publish. The shared sibling checkout `mac-releases` supplies `python3 ../mac-releases/release.py --help` and the `build tablet-companion`, `notarize`, `verify`, `draft`, and `publish` commands. It requires clean committed source, keeps credentials in Keychain, and refuses public delivery before notarization, stapling, signature/Gatekeeper checks, and checksum verification. Creating and pushing the release tag remain explicit maintainer actions.

## Set up

1. Connect your tablet.
2. If needed, click **Download driver**, then **Open Installer**. Finish installing and return to the app.
3. Approve **Automation** only when Tablet Companion asks. Automation controls the app's driver control channel; it is separate from access to Wacom's protected settings file.
4. Click **Allow** beside Tablet settings and approve macOS access.
5. Use **Hide Wacom button overlay** to suppress Wacom's on-screen button labels.
6. Choose **Use suggested layout**, then **Apply layout**: Annotate, Color, Stroke width, Clear. Change any button’s menu to swap actions.
7. If a pen button does not reach StreamApp, choose its click assignment under **Pen buttons**. Middle click defaults to Straighten; Secondary click opens Tools. These are global changes, with hover activation and a separate Restore button.

The overlay setting is stored by the Wacom driver and is not maintained by polling. If the saved XML is missing or ambiguous, Companion fails closed without writing it.

The other buttons stay unchanged. **Restore prior assignment** puts the original shortcut back.

Wacom Center comes with the driver, but you don’t need to open it. Use **Disable autostart** to stop it opening automatically. The Wacom driver is still required.

**Show Tablet Companion in the menu bar** is on by default under **General**. With it on, closing the window keeps Companion in the menu bar and removes its Dock icon. Choose **Open Tablet Companion…** or **Settings…** from the menu to bring the window and Dock icon back. With it off, closing the window quits the app. This preference is remembered across launches.

The menu shows whether the driver is running and which tablets are connected, plus the last-read first-key assignment when available. **Refresh Status** only queries the running driver; it does not read or save the protected preferences file or restart the driver. Automatic status checks run about every 15 seconds while the menu icon is enabled and pause during sleep and settings operations.

Use **Quit Tablet Companion** to exit from either mode. An in-progress settings operation finishes before quitting. The Wacom driver runs separately and your saved shortcuts remain active.

If access is denied or later revoked, open **System Settings → Privacy & Security → Files & Folders → Tablet Companion**, enable **Data shared by Wacom Center and affiliated apps**, then choose **Recheck**. If the switch is already enabled, Recheck is sufficient. The label may vary with the Wacom driver version. The app keeps only that access was requested, not a claim that it remains granted, and disables configuration writes until a fresh settings read succeeds. macOS 27 may deny access to another developer's app-data container without showing a prompt. Missing preferences indicate a Wacom driver/setup problem, not consent. Automation remains separate from this file access. See Apple's [Accessing App Group Containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) documentation.

Signing and notarization do not replace this user-granted permission. GitHub release users must complete the same consent flow on their own Mac; no developer-machine permission is bundled into the download.

## Supported tablet

Tested with **Intuos BT S** and Wacom driver **6.4.14-1**. Other tablets are not supported yet. Changing a setting briefly restarts the driver.

Verified locally: the installed app's initial settings-access gate, denied-access recovery, Files & Folders link, successful Recheck, and ExpressKey overlay Off after driver restart and app relaunch. Production Swift smoke checks covered permission-error classification and overlay XML preservation/rejection. Physical ExpressKey presses and a clean-Mac GitHub download remain separate release checks.

## Your settings

Backups stay on your Mac in **Library → Application Support → WacomCompanion**. They are not uploaded. Builds, downloads, and local signing details stay out of Git.

Companion lists discovered controls rather than assuming four tablet keys or two pen buttons. Only recognized Wacom preference layouts with a unique tablet match are writable. Unsupported layouts fail closed. StreamApp can learn delivered button events independently of tablet vendor; buttons consumed by a driver must be configured there first.

Setup help and driver details stay collapsed once access works. Apply confirmations show the changes and warn that they affect all apps. Restore retains the original assignments across repeated edits, not just the last edit.

The driver download comes directly from Wacom. The app checks it before opening the installer. It never installs silently.
