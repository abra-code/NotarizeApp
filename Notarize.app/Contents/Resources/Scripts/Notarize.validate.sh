#!/bin/sh
# Notarize.validate.sh - validate the stapled ticket and Gatekeeper assessment
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi

clear_log
set_status "Validating..."
append_log "stapler validate:"
out="$(/usr/bin/xcrun stapler validate "$target" 2>&1)"
append_log "$out"
run_spctl "$target"
set_status "Validation complete."
