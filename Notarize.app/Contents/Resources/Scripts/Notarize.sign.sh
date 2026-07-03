#!/bin/sh
# Notarize.sign.sh - sign the target app for release only
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi
identity="$(selected_identity)"
if [ -z "$identity" ]; then
    "$alert_tool" --level caution --title "Notarize" "No Developer ID Application identity is available."
    exit 0
fi
entitlements="$(view_value "$ENTITLEMENTS_FIELD_ID")"

show_progress 1
clear_log
rail_set "$RAIL_SIGN_ID" running
set_status "Signing for release..."
sign_app "$target" "$identity" "$entitlements"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SIGN_ID" failed
    set_status "Signing failed."
    show_progress 0
    exit 0
fi
run_codesign_verify "$target"
rail_set "$RAIL_SIGN_ID" done
set_status "Signed for release."
show_progress 0
