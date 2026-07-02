#!/bin/sh
# Notarize.staple.sh - staple the notarization ticket to the target app
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi

show_progress 1
set_status "Stapling notarization ticket..."
staple_app "$target"
if [ "$?" != "0" ]; then
    set_status "Stapling failed."
    show_progress 0
    exit 0
fi
set_status "Stapled."
show_progress 0
