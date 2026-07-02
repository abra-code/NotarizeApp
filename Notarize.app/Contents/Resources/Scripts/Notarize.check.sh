#!/bin/sh
# Notarize.check.sh - show signature, Gatekeeper, and staple status for the target
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi

clear_log
set_status "Checking signature..."
append_log "codesign -dv --verbose=4:"
out="$(/usr/bin/codesign -dv --verbose=4 "$target" 2>&1)"
append_log "$out"
run_codesign_verify "$target"
run_spctl "$target"
append_log "Staple status:"
sout="$(/usr/bin/xcrun stapler validate "$target" 2>&1)"
append_log "$sout"
set_status "Signature check complete."
