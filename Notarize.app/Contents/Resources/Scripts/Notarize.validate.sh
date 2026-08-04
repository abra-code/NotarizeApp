#!/bin/sh
# Notarize.validate.sh - validate the stapled ticket and Gatekeeper assessment
# on the release copy when one was made, else the chosen target
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(work_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app or installer package first."
    exit 0
fi

clear_log
rail_set "$RAIL_VALIDATE_ID" running
set_status "Validating..."
append_log "stapler validate:"
out="$(/usr/bin/xcrun stapler validate "$target" 2>&1)"
staple_rc=$?
append_log "$out"
run_spctl "$target"
spctl_rc=$?
if [ "$staple_rc" = "0" ] && [ "$spctl_rc" = "0" ]; then
    rail_set "$RAIL_VALIDATE_ID" done
else
    rail_set "$RAIL_VALIDATE_ID" failed
fi
set_status "Validation complete."
