## Install

You need an Apple Silicon Mac with macOS 14 or later.

1. Install Rosetta 2 if you haven't: `softwareupdate --install-rosetta --agree-to-license`
2. Download **Aqua-<version>.dmg** below, open it and drag **Aqua** onto **Applications**.
3. Open Aqua. It isn't notarized by Apple yet, so the first time macOS says it can't check the app. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Aqua.app` in Terminal.
4. Sign in to Steam, Epic Games or both. Aqua downloads its Wine engine (about 160 MB) once in the background.

Games with kernel anti-cheat (Valorant and similar) won't run. If a game doesn't work, please [open an issue](https://github.com/M3BIONIX/Aqua/issues).

`Aqua-<version>.sha256` has the checksums for the DMG and zip.
