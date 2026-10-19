#!/bin/sh
set -eu
# The release archive includes configure and Makefiles; no Homebrew/autotools needed.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
archive="$SRCROOT/Vendor/wimlib-1.14.5.tar.gz"
build="$DERIVED_FILE_DIR/wimlib-1.14.5-$NATIVE_ARCH_ACTUAL"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
expected=84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194
actual=$(/usr/bin/shasum -a 256 "$archive")
case "$actual" in
    "$expected "*) ;;
    *) echo "Bundled wimlib source checksum mismatch" >&2; exit 1 ;;
esac
mkdir -p "$build" "$resources"
# configure expands $PKG_CONFIG as a command without quoting. Use a local
# filename through /bin/sh so project-path spaces and ZIP execute bits do not matter.
cp "$SRCROOT/Scripts/no-pkg-config.sh" "$build/no-pkg-config.sh"
if [ ! -f "$build/Makefile" ] || [ ! -f "$build/.usbforge-config-v2" ]; then
    tar -xzf "$archive" -C "$build" --strip-components=1
    cd "$build"
    CC="$(xcrun -f clang)" CFLAGS="-O2 -arch $NATIVE_ARCH_ACTUAL -mmacosx-version-min=13.0" \
    LDFLAGS="-arch $NATIVE_ARCH_ACTUAL -mmacosx-version-min=13.0" PKG_CONFIG="/bin/sh ./no-pkg-config.sh" \
    ./configure --disable-shared --enable-static --without-ntfs-3g --without-fuse
    touch .usbforge-config-v2
fi
cd "$build"
make -j4 wimlib-imagex
cp wimlib-imagex "$resources/wimlib-imagex"
chmod 755 "$resources/wimlib-imagex"
mkdir -p "$resources/ThirdPartyLicenses"
cp COPYING* "$resources/ThirdPartyLicenses/"
