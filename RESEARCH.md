# GameToMac 0.1.46 alpha (build 86): how it works

Source: `/Applications/GameToMac.app`. The bundle ships its own Swift sources, build notes,
per-game notes and the patched Wine source in `Contents/Resources/Sources/` (copied to `re/Sources/`;
Wine extracted to `re/wine/`). No disassembly was needed.

## 1. The stack

| Layer | What GameToMac uses | Open-source? |
|---|---|---|
| CPU translation | Apple Rosetta 2 (x86_64 Wine on arm64) | System component |
| Windows API | Wine 11.0 from CodeWeavers' CrossOver 26.3 public source, lightly patched | LGPL, reusable |
| DX11/12 → Metal (most games) | Apple D3DMetal (GPTK), downloaded at setup from the Sikarugir `Template-1.0.15.tar.xz` (SHA-pinned) | **Not redistributable**; download at runtime like they do |
| DX10/11 → Metal (CS2, Overwatch, Skyrim) | DXMT (v0.72 / v0.80, some with custom patches) | MIT |
| Old DirectDraw (RA2, Heroes 3) | cnc-ddraw | MIT |
| Controllers | Wine `winebus.so` built against SDL2 2.32.10 | zlib/LGPL |
| Store client | Official Windows Steam (`SteamSetup.exe`, SHA-pinned) running inside Wine; Battle.net for D2R/D4 | n/a |

## 2. Launch flow (`Core.swift`)

1. **Host check**: Apple Silicon, macOS 26+ (26.5+ for D4/PoE2/Hogwarts), Rosetta present (Intel-only `RosettaProbe`).
2. **One isolated prefix per game**: `~/Library/Application Support/Game Library/Games/<id>/`
   - `prefix/` = WINEPREFIX, `deps/Frameworks/` = D3DMetal + dylibs, `engines/<version>/` = Wine copy, `logs/`.
   - Every game gets **its own Steam install**. No shared prefix.
3. **Engine staging** (`UpdateSafety.swift: ensureCurrentEngine`): copy base `Resources/Engine` →
   overlay `Resources/<Game>/EngineOverlay/*` → add controller overlay → verify **every file's SHA-256**
   against `<Game>/engine-manifest.json` → symlink deps per `dependency-links.json`.
4. **Prefix init**: `wineboot --init`, `winecfg -v win10` (win11 for Witcher3/Heroes3), replace user-folder
   symlinks with real folders, copy D3DMetal's `dxgi/d3d11/d3d12/atidxx64.dll` into `system32`
   (or `winemetal.dll` for DXMT games), set WineBus SDL registry keys, then run per-game prep.
5. **Steam**: silent install of `SteamSetup.exe /S`, user signs in and installs the game in the default library.
6. **Play**: `wine steam.exe -cef-disable-gpu [-no-cef-sandbox] -applaunch <appid>`.
   Readiness is read from `steamapps/appmanifest_<appid>.acf` (`StateFlags == 4`);
   running state is read from Steam's `logs/gameprocess_log.txt`.

### Base environment (applied to every game)
```
WINEMSYNC=1  WINEESYNC=0  WINEDEBUG=-all  ROSETTA_ADVERTISE_AVX=1
WINEDLLPATH=<deps>/renderer/d3dmetal/wine:<engine>/lib/wine
WINEDLLOVERRIDES=winemenubuilder.exe=;mscoree,mshtml=;gameoverlayrenderer,gameoverlayrenderer64=;dxgi,d3d11,d3d12,atidxx64=n,b;nvapi64,nvngx=
AOELAB_STEAM_SINGLEPROCESS=1     # patched Wine forces steamwebhelper --single-process --disable-gpu
D3DM_ENABLE_METALFX=0  MTL_HUD_ENABLED=0|1
DYLD_FALLBACK_LIBRARY_PATH=<deps>/Frameworks:...GStreamer.../lib:/usr/lib
SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1
```
DXMT games swap the override to `dxgi,d3d11,d3d10core,winemetal=b` and set `DXMT_*` cache paths.

## 3. Why only "supported" games work: the "config" question

Your theory is close, but the gate isn't a hash allowlist:

- `games.json` lists the games, but **`GameProfile.validate()` (Catalog.swift) hardcodes every field** of each
  known profile and accepts only a fixed list of `optimization` names. A new entry only passes with
  `optimization: "none"`, and the bundle is code-signed, so users can't edit it anyway.
- **Most of the per-game "support" is Swift code**: `configure<Game>Environment`, `prepare<Game>Prefix`,
  install-path quirks (`executableRelativePath`), renderer choice, registry tweaks, redistributables.
- **`validatedSHA256` is *not* a launch gate.** The source says so (`Catalog.swift`, `Core.swift: validateGameInstallation`).
  It only enables exe-specific hacks (e.g. AoE4's x87 sidecar / code cache in `GameBridge.swift`,
  AoE3 startup prefs). Unknown builds fall back to plain Wine.
- **The engine is pinned per game** (`engineVersion` + per-game `engine-manifest.json` hashes + `EngineOverlay`).

So a game is "supported" when it has (a) a catalog entry, (b) a matching engine overlay, and (c) its prep code.

## 4. Per-game recipe table (what to replicate)

| Game (Steam ID) | Renderer | Engine overlay | Notable fixes |
|---|---|---|---|
| AoE IV (1466860) | D3DMetal | base + x87 sidecar | Code cache / soft-fault path in ntdll, exe-hash gated |
| AoE II DE (813780) | D3DMetal | `ntdll.dll` | Short-circuits a slow selection query (`AOE2_QUERY_*`) |
| AoE III DE (933110) | D3DMetal | base | Startup prefs for one known exe |
| AoM Retold (1934680) | D3DMetal | `winemac.so` (notch) | Helper rewrites GPU VendorId/DeviceId in registry by LUID |
| CoH3 (1677280) | D3DMetal | base | Native `ucrtbase.dll` from MS VC redist (protonfixes recipe) |
| CS2 (730) | DXMT (patched) | DXMT dlls + `winemetal` | Pipeline-recipe capture/prewarm, fullscreen-windowed default |
| Overwatch (2357570) | DXMT v0.80 | DXMT + ntdll + nvapi stubs | D3D12 disabled, NtQueryDirectoryObject BOOLEAN fix |
| Diablo IV (2344520) | D3DMetal | `ntdll.so` | `CX_APPLEGPTK_LIBD3DSHARED_PATH`; BOOLEAN fix |
| D4/D2R Battle.net | DXMT | DXMT + ntdll | Battle.net client instead of Steam |
| PoE2 (2694490) | D3DMetal | `ntdll.so` | NtQueryDirectoryObject BOOLEAN fix (login drive-enum loop) |
| Hogwarts (990080) | D3DMetal | `ntdll.so` | No Z: drive; guard against silent Vulkan fallback |
| Skyrim SE (489830) | DXMT v0.72 | DXMT + ntdll | Prefers native XAudio |
| RDR2 (1174180) / GTA SA DE (1547000) | D3DMetal | `kernelbase.dll` | Rockstar launcher install (`/s /f`), CEF patch |
| Witcher 3 (292030) | D3DMetal | base | win11, no Z:, requires APFS, `--launcher-skip` |
| Elden Ring (1245620) | D3DMetal | base | Steam VC++/DX June 2010 redists; `SteamAppId` env; offline only (EAC) |
| Zero Hour / RA2 / Heroes 3 | cnc-ddraw / OpenGL | base | Options.ini display defaults; CnCNet for RA2 online |

The full detail for each is in `re/Sources/<GAME>.md` and `<Game>.swift`.

## 5. Custom Wine patches (LGPL, reusable)
In `re/wine/wine/`:
- `dlls/kernelbase/process.c`: Steam CEF single-process workaround (`AOELAB_STEAM_SINGLEPROCESS`).
- `dlls/ntdll/unix/aoe_*.h`, `loader.c`, `virtual.c`, `signal_x86_64.c`: AoE4 code cache / soft-fault / x87 sidecar bridge.
- NtQueryDirectoryObject BOOLEAN ABI fix: `re/Sources/PoE2Test/ntquery-directory-boolean.patch` (likely worth upstreaming).
- AoE2 query patch: `re/Sources/AoE2RuntimeSource/`.

## 6. What you can and can't reuse when open-sourcing
- **Reusable**: Wine patches (LGPL; keep the license), DXMT forks (MIT), sidecar (MIT), ffxproxy (MIT), cnc-ddraw notes,
  and *the knowledge* in the table above (env vars, overrides, renderer choices). Those are facts you can reimplement.
- **Don't copy**: the GameToMac Swift app code (no license is granted, so it's proprietary). Write your own launcher.
- **Don't redistribute**: Apple D3DMetal/GPTK (download at runtime, as they do), and the CS2 shader pack (game-derived IR).
- `Pro.swift` is a subscription (€2.99/mo). Not relevant to the engine and not touched.

## 7. Path to the open-source launcher + Epic
- Reimplement the "per-game recipe" as **data**, not code: renderer, overlays, env, DLL overrides, winecfg version,
  redistributables, launch args. Then adding a game becomes a PR to a JSON/YAML file.
- Starting points: Whisky (archived, but a good base), Sikarugir, Heroic Games Launcher (already has Epic via `legendary`
  and runs Wine/GPTK on macOS), umu-protonfixes (per-game fixes database).
- Epic: use `legendary` (or Heroic's fork) for auth/download/launch, and point it at the per-game prefix and engine.
