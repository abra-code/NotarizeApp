#!/bin/sh
# Notarize.submit.sh - package and submit to the notary service, wait for result.
# Operates on the release copy when one was made by the sign step.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(work_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app or installer package first."
    exit 0
fi
profile="$(selected_profile)"
if [ -z "$profile" ]; then
    "$alert_tool" --level caution --title "Notarize" "Set up and pick a credential profile first."
    exit 0
fi

save_app_settings

# The upload can take minutes: enable Cancel and block other actions meanwhile.
finish() {
    show_progress 0
    enable_view "$CANCEL_BTN_ID" 0
    enable_view "$NOTARIZE_BTN_ID" 1
    rail_enable 1
    pb_set "$PB_BUSY" ""
    /bin/rm -f "$(state_dir)/run.pid"
}

pb_set "$PB_BUSY" 1
printf '%s' "$$" > "$(state_dir)/run.pid"
enable_view "$NOTARIZE_BTN_ID" 0
rail_enable 0
enable_view "$CANCEL_BTN_ID" 1
show_progress 1
clear_log
rail_set "$RAIL_SUBMIT_ID" running
set_status "Preparing the upload..."
prepare_upload "$target"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Packaging failed."
    finish
    exit 0
fi

set_status "Submitting to the notary service..."
submit_and_wait "$(upload_path)" "$profile"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Submission failed."
    finish
    exit 0
fi

status="$(submission_status)"
if [ "$status" != "Accepted" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Notarization $status. Fetching log..."
    fetch_log "$(submission_id)" "$profile"
    print_issues
else
    rail_set "$RAIL_SUBMIT_ID" done
    set_status "Accepted. Run Staple Ticket next."
fi
finish
