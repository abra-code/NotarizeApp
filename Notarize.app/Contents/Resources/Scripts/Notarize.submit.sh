#!/bin/sh
# Notarize.submit.sh - package and submit to the notary service, wait for result
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app first."
    exit 0
fi
profile="$(selected_profile)"
if [ -z "$profile" ]; then
    "$alert_tool" --level caution --title "Notarize" "Set up and pick a credential profile first."
    exit 0
fi

show_progress 1
clear_log
set_status "Packaging for upload..."
upload_zip="$(state_dir)/upload.zip"
package_app "$target" "$upload_zip"
if [ "$?" != "0" ]; then
    set_status "Packaging failed."
    show_progress 0
    exit 0
fi

set_status "Submitting to the notary service..."
submit_and_wait "$upload_zip" "$profile"
if [ "$?" != "0" ]; then
    set_status "Submission failed."
    show_progress 0
    exit 0
fi

status="$(submission_status)"
if [ "$status" != "Accepted" ]; then
    set_status "Notarization $status. Fetching log..."
    fetch_log "$(submission_id)" "$profile"
    print_issues
else
    set_status "Accepted. Use Steps > Staple Ticket next."
fi
show_progress 0
