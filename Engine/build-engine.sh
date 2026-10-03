#!/bin/zsh
# Builds Aqua's Wine engine from CodeWeavers' CrossOver source plus Aqua's patches.
#
#   Engine/build-engine.sh            # full build → $WORK/aqua-wine-<version>.tar.xz
#   AQUA_ENGINE_WORK=/path ./build-engine.sh
#
# Needs: Xcode, Homebrew bison/flex and the freetype/gnutls/sdl2 headers, and an installed
# Aqua runtime (its x86_64 dylibs are what Wine links and runs against).
set -euo pipefail

ENGINE_DIR=${0:A:h}
WORK=${AQUA_ENGINE_WORK:-/Volumes/Personal/AquaEngineBuild}
FRAMEWORKS=${AQUA_FRAMEWORKS:-$HOME/Library/Application Support/Aqua/Runtime/Frameworks}
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}

CX_VERSION=26.3.0
CX_URL=https://media.codeweavers.com/pub/crossover/source/crossover-sources-$CX_VERSION.tar.gz
CX_SHA256=ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872
INOTIFY_TAG=20240724
INOTIFY_HEADER_URL=https://raw.githubusercontent.com/libinotify-kqueue/libinotify-kqueue/$INOTIFY_TAG/sys/inotify.h
MINGW=llvm-mingw-20260826-ucrt-macos-universal
MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260826/$MINGW.tar.xz
MINGW_SHA256=48bedd161f14ae25a3646cb750b57ee3188e97e34bd3c52240c1810aa74d6a7f
ENGINE_NAME=aqua-wine-cx$CX_VERSION-r$(cat "$ENGINE_DIR/REVISION")

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

fetch() { # url sha256 file
  [[ -f $3 ]] && [[ $(shasum -a 256 "$3" | cut -d' ' -f1) == $2 ]] && return
  curl -fL --retry 2 -o "$3.partial" "$1"
  [[ $(shasum -a 256 "$3.partial" | cut -d' ' -f1) == $2 ]] || { echo "checksum mismatch: $3" >&2; exit 1; }
  mv "$3.partial" "$3"
}

mkdir -p "$WORK"/{downloads,toolchain,include,lib,pkgconfig}
fetch "$CX_URL" $CX_SHA256 "$WORK/downloads/crossover-sources-$CX_VERSION.tar.gz"
fetch "$MINGW_URL" $MINGW_SHA256 "$WORK/downloads/$MINGW.tar.xz"
[[ -d $WORK/toolchain/$MINGW ]] || tar -xf "$WORK/downloads/$MINGW.tar.xz" -C "$WORK/toolchain"

# Fresh, patched source tree.
rm -rf "$WORK/src" && mkdir -p "$WORK/src"
tar -xzf "$WORK/downloads/crossover-sources-$CX_VERSION.tar.gz" -C "$WORK/src"
WINE_SRC=$WORK/src/sources/wine
for patch in "$ENGINE_DIR"/patches/*.patch(N); do
  echo "Applying ${patch:t}"
  patch -d "$WINE_SRC" -p1 --forward < "$patch"
done

# Only these headers and libraries are visible to configure, so Homebrew's arm64 libraries
# can't be picked up for an x86_64 build.
brew_include=$(brew --prefix)/include
rm -rf "$WORK/include"/*(N) "$WORK/lib"/*(N)
cp -RL "$brew_include/freetype2" "$brew_include/gnutls" "$brew_include/SDL2" "$WORK/include/"
# libinotify-kqueue: the runtime ships the dylib; Wine needs its header to use it.
mkdir -p "$WORK/include/sys" && curl -fsSL -o "$WORK/include/sys/inotify.h" "$INOTIFY_HEADER_URL"
for lib in libfreetype libgnutls libSDL2 libvulkan libMoltenVK libinotify; do
  ln -sf "$FRAMEWORKS/$lib.dylib" "$WORK/lib/$lib.dylib"
done

# llvm-mingw also ships a `clang`; the Mac side must use Xcode's (via the /usr/bin shim) with its SDK.
XCODE_CLANG=/usr/bin/clang
export SDKROOT=$(xcrun --show-sdk-path)
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:/usr/bin:/bin:/usr/sbin:/sbin:$WORK/toolchain/$MINGW/bin"
export PKG_CONFIG_LIBDIR=$WORK/pkgconfig
export CC="$XCODE_CLANG -arch x86_64" CXX="${XCODE_CLANG}++ -arch x86_64" CFLAGS="-O2" CXXFLAGS="-O2"
export CPPFLAGS="-I$WORK/include" LDFLAGS="-L$WORK/lib"
export FREETYPE_CFLAGS="-I$WORK/include/freetype2" FREETYPE_LIBS="-L$WORK/lib -lfreetype"
export GNUTLS_CFLAGS="-I$WORK/include" GNUTLS_LIBS="-L$WORK/lib -lgnutls"
export SDL2_CFLAGS="-I$WORK/include/SDL2" SDL2_LIBS="-L$WORK/lib -lSDL2"
export INOTIFY_CFLAGS="-I$WORK/include" INOTIFY_LIBS="-L$WORK/lib -linotify"

BUILD=$WORK/build INSTALL=$WORK/install
rm -rf "$BUILD" "$INSTALL" && mkdir -p "$BUILD"
# Build tools (sfnt2fon) run against these x86_64 dylibs; Apple's make strips DYLD_* variables,
# but dyld also looks in the working directory for bare install names.
for dylib in "$FRAMEWORKS"/*.dylib; do ln -sf "$dylib" "$BUILD/"; done
# FreeType's own dependencies use @rpath, so the tools need a copy that carries one.
for name in libfreetype.dylib libfreetype.6.dylib; do
  rm -f "$BUILD/$name" && cp "$FRAMEWORKS/$name" "$BUILD/$name"
  install_name_tool -add_rpath "$FRAMEWORKS" "$BUILD/$name" 2>/dev/null
  codesign --force --sign - "$BUILD/$name" 2>/dev/null
done
cd "$BUILD"
"$WINE_SRC/configure" \
  --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
  --enable-archs=i386,x86_64 --disable-tests \
  --without-x --without-gstreamer --without-capi --without-gphoto --without-sane \
  --without-krb5 --without-netapi --without-pcap --without-usb --without-v4l2 --without-pulse \
  --prefix="$INSTALL" \
  ac_cv_lib_soname_SDL2=libSDL2-2.0.0.dylib \
  ac_cv_lib_soname_freetype=libfreetype.6.dylib \
  ac_cv_lib_soname_gnutls=libgnutls.30.dylib \
  ac_cv_lib_soname_vulkan=libvulkan.1.dylib \
  ac_cv_lib_soname_MoltenVK=libMoltenVK.dylib 2>&1 | tee configure.log
# Library names are baked in from configure; fail early if any came out mangled.
grep -E '^#define SONAME_' include/config.h
! grep -E '^#define SONAME_.*(compatibility|\t)' include/config.h
grep -E "^configure: (WARNING|libfreetype|libgnutls|libSDL2|libvulkan|libMoltenVK)" configure.log || true

make -j"$JOBS" 2>&1 | tail -20
make install 2>&1 | tail -3

# Package the runtime parts only, with debug info stripped from Windows DLLs.
PACKAGE=$WORK/package/AquaWine
rm -rf "$WORK/package" && mkdir -p "$PACKAGE"
cp -R "$INSTALL/bin" "$INSTALL/lib" "$INSTALL/share" "$PACKAGE/"
rm -rf "$PACKAGE/share/man" "$PACKAGE/share/applications" "$PACKAGE/lib/wine/"*/lib*.a(N)
find "$PACKAGE/lib/wine" -name "*.dll" -o -name "*.exe" -o -name "*.drv" -o -name "*.sys" | \
  xargs "$WORK/toolchain/$MINGW/bin/llvm-strip" --strip-debug 2>/dev/null || true
echo "$ENGINE_NAME" > "$PACKAGE/version"
cp "$ENGINE_DIR"/patches/*.patch "$PACKAGE/" 2>/dev/null || true
codesign --force --sign - "$PACKAGE/bin/wine" "$PACKAGE/bin/wineserver" "$PACKAGE"/bin/wine-preloader(N) 2>/dev/null || true

tar -C "$WORK/package" -cJf "$WORK/$ENGINE_NAME.tar.xz" AquaWine
shasum -a 256 "$WORK/$ENGINE_NAME.tar.xz"
du -sh "$PACKAGE" "$WORK/$ENGINE_NAME.tar.xz"
