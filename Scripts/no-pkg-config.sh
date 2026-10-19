#!/bin/sh
# configure insists on a pkg-config version check even when both optional
# integrations are disabled. No external packages are supplied by this build.
case "${1:-}" in
    --atleast-pkgconfig-version) exit 0 ;;
    *) exit 1 ;;
esac
