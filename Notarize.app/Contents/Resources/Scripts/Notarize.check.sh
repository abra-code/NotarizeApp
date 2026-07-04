#!/bin/sh
# Notarize.check.sh - diagnostic: show signature, Gatekeeper, and staple status
# for the release copy when one was made, else the chosen target. Not a
# pipeline stage; triggered by the Inspect Signature button in the log header.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(work_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi

clear_log
set_status "Inspecting signature..."
append_log "=== Inspect: $target ==="
append_log "codesign -dv --verbose=4:"
out="$(/usr/bin/codesign -dv --verbose=4 "$target" 2>&1)"
append_log "$out"
run_codesign_verify "$target"
run_spctl "$target"
append_log "Staple status:"
sout="$(/usr/bin/xcrun stapler validate "$target" 2>&1)"
append_log "$sout"
set_status "Signature inspection complete."
