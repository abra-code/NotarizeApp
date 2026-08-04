#!/bin/sh
# Notarize.staple.sh - staple the notarization ticket to the release copy when
# one was made, else the chosen target
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(work_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app or installer package first."
    exit 0
fi

show_progress 1
rail_set "$RAIL_STAPLE_ID" running
set_status "Stapling notarization ticket..."
staple_app "$target"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_STAPLE_ID" failed
    set_status "Stapling failed."
    show_progress 0
    exit 0
fi
rail_set "$RAIL_STAPLE_ID" done
show_view "$REVEAL_BTN_ID" 1
set_status "Stapled."
show_progress 0
