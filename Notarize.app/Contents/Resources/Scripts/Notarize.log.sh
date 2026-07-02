#!/bin/sh
# Notarize.log.sh - fetch and show the notary log for the last submission
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

id="$(submission_id)"
if [ -z "$id" ]; then
    "$alert_tool" --level caution --title "Notarize" "No previous submission in this window."
    exit 0
fi
profile="$(selected_profile)"
if [ -z "$profile" ]; then
    "$alert_tool" --level caution --title "Notarize" "Pick a credential profile first."
    exit 0
fi

show_progress 1
set_status "Fetching notarization log..."
fetch_log "$id" "$profile"
if [ "$?" != "0" ]; then
    set_status "Could not fetch the log."
    show_progress 0
    exit 0
fi
append_log "--- Notarization log for $id ---"
print_issues
set_status "Log fetched."
show_progress 0
