#!/bin/sh
# Notarize.package.sh - create the distribution zip for the target app
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi

output_dir="$(view_value "$OUTPUT_FIELD_ID")"
dist="$(dist_zip_path "$target" "$output_dir")"

rail_set "$RAIL_PACKAGE_ID" running
show_progress 1
set_status "Creating distribution archive..."
append_log "Creating distribution archive: $dist"
package_app "$target" "$dist"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_PACKAGE_ID" failed
    set_status "Distribution packaging failed."
    show_progress 0
    exit 0
fi
printf '%s' "$dist" > "$(state_dir)/dist.txt"
show_view "$REVEAL_BTN_ID" 1
rail_set "$RAIL_PACKAGE_ID" done
set_status "Distribution archive created."
show_progress 0
