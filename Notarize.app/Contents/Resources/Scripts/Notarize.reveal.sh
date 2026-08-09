#!/bin/sh
# Notarize.reveal.sh - reveal the notarized app in Finder
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

app="$(work_target)"
if [ -n "$app" ] && [ -e "$app" ]; then
    "$open_tool" -R "$app"
fi
