# Bundled third-party component

wimlib 1.14.5, by Eric Biggers and contributors.
Source: https://wimlib.net/downloads/wimlib-1.14.5.tar.gz
SHA-256: 84221a3abd5b91228f15f8e6065c335a336237b5738197b75bf419eea561a194

The original release source archive is supplied here. It includes COPYING,
COPYING.GPLv3 and COPYING.LGPL with the applicable notices and licenses.
The wimlib-imagex command-line program is licensed under GPLv3 or later;
see the archive's COPYING for library and individual-file terms.

USBForge builds the separate wimlib-imagex executable using Apple's toolchain,
static libwim, and no NTFS-3G/FUSE integrations. The executable depends only
on macOS system libraries. The licenses are also copied into the app's
Contents/Resources/ThirdPartyLicenses directory. Source and the build scripts
are provided in this project so that the bundled executable can be rebuilt.

No modifications are made to the upstream source. The supplied pkg-config
shim satisfies only configure's mandatory version probe. It is copied into the
build directory and run through /bin/sh using a relative filename to tolerate
spaces in project paths and missing executable bits after ZIP extraction. All package probes
fail; both optional integrations are explicitly disabled.
