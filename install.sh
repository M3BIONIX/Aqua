#!/bin/bash
# Installs the latest Aqua release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/M3BIONIX/Aqua/main/install.sh | bash
#
# Aqua isn't notarized by Apple, so a DMG downloaded in a browser gets the "Apple could not verify"
# warning. Files downloaded with curl aren't flagged, so installing this way opens without it.
# The download is checked against the release's SHA-256 file before anything is installed.
#
# AQUA_INSTALL_DIR=<folder> installs somewhere else; AQUA_NO_OPEN=1 skips opening Aqua afterwards.
set -euo pipefail

REPO="M3BIONIX/Aqua"
DEST="${AQUA_INSTALL_DIR:-/Applications}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Aqua runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Aqua needs an Apple Silicon Mac (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Aqua needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  say "Installing Rosetta 2 (needed to run Windows games built for Intel)..."
  softwareupdate --install-rosetta --agree-to-license || fail "Rosetta 2 didn't install. Run: softwareupdate --install-rosetta --agree-to-license"
fi

say "Finding the latest Aqua release..."
# github.com redirects /releases/latest to the newest tag; unlike the API it has no rate limit.
latest=$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest") \
  || fail "Couldn't reach GitHub. Check your connection and try again."
tag=${latest##*/}
[[ "${tag}" == v* ]] || fail "Couldn't find the latest release (got ${latest})."
dmg_name="Aqua-${tag}.dmg"
dmg_url="https://github.com/${REPO}/releases/download/${tag}/${dmg_name}"
sum_url="https://github.com/${REPO}/releases/download/${tag}/Aqua-${tag}.sha256"

work=$(mktemp -d)
mount=""
cleanup() {
  [[ -n "${mount}" ]] && hdiutil detach -quiet "${mount}" 2>/dev/null || true
  rm -rf "${work}"
}
trap cleanup EXIT

say "Downloading ${dmg_name}..."
curl -fL --retry 3 --retry-delay 2 --progress-bar -o "${work}/${dmg_name}" "${dmg_url}" || fail "Download failed. Please try again."
curl -fsSL --retry 3 --retry-delay 2 -o "${work}/sums" "${sum_url}" || fail "Couldn't download the checksum file."

expected=$(grep " ${dmg_name}\$" "${work}/sums" | cut -d' ' -f1)
actual=$(shasum -a 256 "${work}/${dmg_name}" | cut -d' ' -f1)
[[ -n "${expected}" && "${expected}" == "${actual}" ]] || fail "Checksum mismatch, nothing was installed. Please try again."

say "Installing Aqua to ${DEST}..."
mount=$(hdiutil attach -nobrowse -readonly "${work}/${dmg_name}" | tail -1 | awk -F'\t' '{print $NF}')
[[ -d "${mount}/Aqua.app" ]] || fail "The DMG doesn't contain Aqua.app."

if [[ -d "${DEST}/Aqua.app" ]] && pgrep -xq Aqua; then
  say "Quitting the running Aqua..."
  osascript -e 'quit app "Aqua"' >/dev/null 2>&1 || true
  sleep 2
fi

mkdir -p "${DEST}"
if [[ -w "${DEST}" ]]; then
  rm -rf "${DEST}/Aqua.app"
  ditto "${mount}/Aqua.app" "${DEST}/Aqua.app"
else
  say "${DEST} needs your password to write to."
  sudo rm -rf "${DEST}/Aqua.app"
  sudo ditto "${mount}/Aqua.app" "${DEST}/Aqua.app"
fi
xattr -dr com.apple.quarantine "${DEST}/Aqua.app" 2>/dev/null || true

say "Aqua is installed in ${DEST}."
if [[ -z "${AQUA_NO_OPEN:-}" ]]; then
  open "${DEST}/Aqua.app"
fi
