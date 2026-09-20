# Tablet Companion

Set up your Wacom tablet and change its drawing shortcut on your Mac.

## Install

Requires macOS 26 or newer, Xcode, Python 3, and an Apple signing certificate on your Mac. This is a local build, not an Apple-notarized download.

Run this command in this folder:

```sh
python3 scripts/build-app.py --install
```

Open **Tablet Companion** in your home folder’s **Applications** folder.

## Set up

1. Connect your tablet.
2. If needed, click **Download driver**, then **Open Installer**. Finish installing and return to the app.
3. Click **Refresh** and allow access when asked.
4. Click **Apply drawing shortcut** to set the leftmost button to **Control–Option–Command–D**.

The other buttons stay unchanged. **Restore prior assignment** puts the original shortcut back.

Wacom Center comes with the driver, but you don’t need to open it. Use **Disable autostart** to stop it opening automatically. The Wacom driver is still required.

## Supported tablet

Tested with **Intuos BT S** and Wacom driver **6.4.14-1**. Other tablets are not supported yet. Changing a setting briefly restarts the driver.

## Your settings

Backups stay on your Mac in **Library → Application Support → WacomCompanion**. They are not uploaded. Builds, downloads, and local signing details stay out of Git.

The driver download comes directly from Wacom. The app checks it before opening the installer. It never installs silently.
