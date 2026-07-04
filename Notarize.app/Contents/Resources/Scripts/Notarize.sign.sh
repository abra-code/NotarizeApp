#!/bin/sh
# Notarize.sign.sh - copy the target app to the output folder and sign the copy
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
output_dir="$(view_value "$OUTPUT_FIELD_ID")"

save_app_settings

show_progress 1
clear_log
rail_set "$RAIL_SIGN_ID" running
set_status "Signing for release..."
work="$(prepare_release_copy "$target" "$output_dir")"
if [ "$?" != "0" ] || [ -z "$work" ]; then
    rail_set "$RAIL_SIGN_ID" failed
    set_status "Copy to the output folder failed."
    show_progress 0
    exit 0
fi
if [ "$work" != "$target" ]; then
    append_log "Copied to output folder: $work"
fi
sign_app "$work" "$identity" "$entitlements"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SIGN_ID" failed
    set_status "Signing failed."
    show_progress 0
    exit 0
fi
rail_set "$RAIL_SIGN_ID" done
set_status "Signed for release."
show_progress 0
