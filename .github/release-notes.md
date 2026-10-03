## Install

You need an Apple Silicon Mac with macOS 14 or later.

**Easiest:** paste this in Terminal. It installs the latest version without the "Apple could not verify" warning:

```sh
curl -fsSL https://raw.githubusercontent.com/M3BIONIX/Aqua/main/install.sh | bash
```

Apple charges $99 a year to notarize apps and I'm poor, so a downloaded DMG shows that warning instead.

**With the DMG:** download **Aqua-<version>.dmg** below, open it and drag **Aqua** onto **Applications**. The first time you open it, click **Done** on the warning, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Aqua.app` in Terminal. You also need Rosetta 2: `softwareupdate --install-rosetta --agree-to-license`.

Then sign in to Steam, Epic Games or both. Aqua downloads its Wine engine (about 160 MB) once in the background.

Games with kernel anti-cheat (Valorant and similar) won't run. If a game doesn't work, please [open an issue](https://github.com/M3BIONIX/Aqua/issues).

`Aqua-<version>.sha256` has the checksums for the DMG and zip.
