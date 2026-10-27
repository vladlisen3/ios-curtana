#!/bin/bash
# Build Mesa Freedreno (Adreno 618 ir3 + softpipe) + AIR-to-NIR Metal translator + EAGL bridge
# for Xiaomi Redmi Note 9S / Pro (curtana, SM7125, chip_id 0x06010800) running XNU / iOS 16.
#
# Outputs in build/mesa/out/:
#   - libOSMesa.8.dylib      (/redwood/lib/libOSMesa.8.dylib — Freedreno + ir3 + AIR2NIR)
#   - libhakios.gl.dylib     (/redwood/lib/libhakios.gl.dylib — EAGLContext / OpenGLES bridge)
#   - gl_test                (/redwood/bin/gl_test — offscreen/onscreen Adreno 618 GLES test)
#   - air_run                (/redwood/bin/air_run — Metal .metallib AIR -> NIR -> Adreno 618 ir3 runner)
#   - metal_test             (/redwood/bin/metal_test — CoreImage / Metal / EAGL diagnostic)
#
# Usage:
#   tools/mk-curtana-mesa.sh [--install <MOUNTED_IOS_ROOT>]

set -euo pipefail

VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
B="${BUILD_DIR:-$REPO_ROOT/build/mesa}"
SDK="${IOS_SDK:-${THEOS:-$HOME/theos}/sdks/iPhoneOS16.5.sdk}"
CC_BIN="${XNU_CLANG:-clang}"
CPP_BIN="${XNU_CPP:-${CC_BIN}++}"

AR_BIN="${AR_BIN:-$(command -v llvm-ar 2>/dev/null || command -v ar)}"
RANLIB_BIN="${RANLIB_BIN:-$(command -v llvm-ranlib 2>/dev/null || command -v ranlib)}"
STRIP_BIN="${STRIP_BIN:-$(command -v llvm-strip 2>/dev/null || command -v strip)}"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	echo "Usage: $0 [--install <MOUNTED_IOS_ROOT>]"
	exit 0
fi

INSTALL_ROOT=""
if [ "${1:-}" = "--install" ] && [ -n "${2:-}" ]; then
	INSTALL_ROOT="$2"
fi

mkdir -p "$B/out"
cd "$B"

PATCHES=$(cat "$REPO_ROOT"/tools/mesa/*.patch | shasum -a 256 | cut -d' ' -f1)
if [ ! -d "mesa-$VERSION" ] || [ "$(cat "mesa-$VERSION/.curtana-patches" 2>/dev/null || true)" != "$PATCHES" ]; then
	[ -f "mesa-$VERSION.tar.xz" ] || curl -sL --fail -o "mesa-$VERSION.tar.xz" "https://archive.mesa3d.org/mesa-$VERSION.tar.xz"
	echo "$SHA256  mesa-$VERSION.tar.xz" | shasum -a 256 -c
	rm -rf "mesa-$VERSION" build-*
	tar xJf "mesa-$VERSION.tar.xz"
	for p in "$REPO_ROOT"/tools/mesa/*.patch; do
		patch -s --no-backup-if-mismatch -d "mesa-$VERSION" -p1 < "$p"
	done
	echo "$PATCHES" > "mesa-$VERSION/.curtana-patches"
fi

# Fix C11 timespec redefinition on Darwin / iOS SDK
python3 -c "
import os
p = 'mesa-$VERSION/src/c11/time.h'
if os.path.exists(p):
    c = open(p).read()
    if 'struct timespec {' in c and '#if !defined(__APPLE__)' not in c:
        open(p, 'w').write(c.replace('struct timespec {', '#if !defined(__APPLE__) && !defined(HAVE_STRUCT_TIMESPEC)
struct timespec {'))
" 2>/dev/null || true

rm -rf "mesa-$VERSION/src/hakios-drm" "mesa-$VERSION/src/compiler/air"
cp -r "$REPO_ROOT/tools/mesa/hakios-drm" "mesa-$VERSION/src/hakios-drm"
cp -r "$REPO_ROOT/tools/mesa/air" "mesa-$VERSION/src/compiler/air"

if [ ! -x venv/bin/python3 ]; then
	python3 -m venv venv
	venv/bin/pip -q install mako pyyaml packaging
fi
export PATH="$B/venv/bin:$PATH"

IS_DARWIN=0
if [ "$(uname -s)" = "Darwin" ]; then
	IS_DARWIN=1
fi

if [ "$IS_DARWIN" = "1" ]; then
cat > cross.ini <<INI
[binaries]
c = ['$CC_BIN', '-arch', 'arm64', '-isysroot', '$SDK', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
cpp = ['$CPP_BIN', '-arch', 'arm64', '-isysroot', '$SDK', '-fuse-cxa-atexit', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
objc = ['$CC_BIN', '-arch', 'arm64', '-isysroot', '$SDK', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
ar = '$AR_BIN'
ranlib = '$RANLIB_BIN'
strip = '$STRIP_BIN'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI
else
cat > cross.ini <<INI
[binaries]
c = ['$CC_BIN', '-target', 'arm64-apple-ios16.5', '-isysroot', '$SDK', '-fuse-ld=lld', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
cpp = ['$CPP_BIN', '-target', 'arm64-apple-ios16.5', '-isysroot', '$SDK', '-fuse-ld=lld', '-fuse-cxa-atexit', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
objc = ['$CC_BIN', '-target', 'arm64-apple-ios16.5', '-isysroot', '$SDK', '-fuse-ld=lld', '-D_DARWIN_C_SOURCE=1', '-DHAVE_STRUCT_TIMESPEC=1']
ar = '$AR_BIN'
ranlib = '$RANLIB_BIN'
strip = '$STRIP_BIN'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
INI
fi

DRIVERS="${DRIVERS:-softpipe,freedreno}"
BUILD="build-${DRIVERS//,/-}"
if [ ! -f "$BUILD/build.ninja" ]; then
	meson setup "$BUILD" "mesa-$VERSION" --cross-file cross.ini --wrap-mode=nofallback 		--prefix=/redwood --libdir=lib --buildtype=release -Db_ndebug=true 		-Dplatforms= -Dgallium-drivers="$DRIVERS" -Dfreedreno-kmds=msm -Dvulkan-drivers= 		-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dosmesa=true -Dllvm=disabled 		-Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true 		-Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=disabled 		-Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= 		-Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled 		-Dlmsensors=disabled -Dbuild-tests=false
fi

ninja -C "$BUILD"
ninja -C "$BUILD" src/gallium/drivers/freedreno/air_run
cp "$BUILD/src/gallium/drivers/freedreno/air_run" out/air_run

"$STRIP_BIN" -x -o out/libOSMesa.8.dylib "$BUILD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
if [ "$IS_DARWIN" = "1" ]; then
	install_name_tool -id /redwood/lib/libOSMesa.8.dylib out/libOSMesa.8.dylib
fi
nm -gU out/libOSMesa.8.dylib | awk '$3 ~ /^_gl/ { print substr($3, 2) }' > out/exported-gl.txt
cp "mesa-$VERSION/src/mapi/glapi/registry/gl.xml" out/gl.xml

# Build EAGL bridge (libhakios.gl.dylib) and test binaries
EAGL_DIR="$REPO_ROOT/tools/mesa/eagl"
python3 "$EAGL_DIR/mkeagl.py" "$EAGL_DIR/eagl_slots.txt" out/gl.xml out/exported-gl.txt "$EAGL_DIR/eagl.c" > out/eagl_gen.h

if [ "$IS_DARWIN" = "1" ]; then
	DYN="$CC_BIN -arch arm64 -isysroot $SDK -O2 -D_DARWIN_C_SOURCE=1"
else
	DYN="$CC_BIN -target arm64-apple-ios16.5 -isysroot $SDK -fuse-ld=lld -O2 -D_DARWIN_C_SOURCE=1"
fi

$DYN -dynamiclib -install_name /redwood/lib/libhakios.gl.dylib -Iout -I"$EAGL_DIR" 	-framework CoreFoundation -framework IOKit -framework IOSurface -lobjc 	out/libOSMesa.8.dylib -o out/libhakios.gl.dylib "$EAGL_DIR/eagl.c" "$EAGL_DIR/gl_osmesa.c"
$DYN -I"$EAGL_DIR" -framework CoreFoundation -framework IOKit out/libOSMesa.8.dylib -o out/gl_test "$EAGL_DIR/gl_test.c"
$DYN -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework CoreGraphics 	-framework CoreImage -framework IOKit -framework Metal -framework OpenGLES 	-lMobileGestalt -o out/metal_test "$EAGL_DIR/metal_test.m"

if [ -n "$INSTALL_ROOT" ] && [ -d "$INSTALL_ROOT" ]; then
	echo "[*] Installing Mesa Freedreno + EAGL + AIR2NIR into $INSTALL_ROOT/redwood/ ..."
	mkdir -p "$INSTALL_ROOT/redwood/lib" "$INSTALL_ROOT/redwood/bin"
	cp -v out/libOSMesa.8.dylib out/libhakios.gl.dylib "$INSTALL_ROOT/redwood/lib/"
	cp -v out/gl_test out/air_run out/metal_test "$INSTALL_ROOT/redwood/bin/"
fi

echo "[✓] Built Adreno 618 Mesa Freedreno + EAGL + AIR2NIR in $B/out"
