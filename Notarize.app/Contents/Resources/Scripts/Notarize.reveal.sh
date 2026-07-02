#!/bin/sh
# Notarize.reveal.sh - reveal the distribution archive in Finder
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

f="$(state_dir)/dist.txt"
if [ ! -f "$f" ]; then
    exit 0
fi
dist="$(/bin/cat "$f")"
if [ -e "$dist" ]; then
    /usr/bin/open -R "$dist"
fi
