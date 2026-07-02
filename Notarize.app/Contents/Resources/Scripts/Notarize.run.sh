#!/bin/sh
# Notarize.run.sh - full pipeline: sign, package, submit, wait, log, staple, zip
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app to notarize first."
    exit 0
fi
is_app_bundle "$target"
if [ "$?" != "0" ]; then
    "$alert_tool" --level caution --title "Notarize" "The chosen item is not a .app bundle."
    exit 0
fi

profile="$(selected_profile)"
if [ -z "$profile" ]; then
    "$alert_tool" --level caution --title "Notarize" "Set up notary credentials first (Credentials button), then pick a profile."
    exit 0
fi

entitlements="$(view_value "$ENTITLEMENTS_FIELD_ID")"
output_dir="$(view_value "$OUTPUT_FIELD_ID")"
identity="$(selected_identity)"

toggle_on "$SIGN_TOGGLE_ID"
sign_on=$?
toggle_on "$STAPLE_TOGGLE_ID"
staple_on=$?
toggle_on "$DISTZIP_TOGGLE_ID"
zip_on=$?

if [ "$sign_on" = "0" ] && [ -z "$identity" ]; then
    "$alert_tool" --level caution --title "Notarize" "No Developer ID Application identity is available. Turn off 'Sign for release first' to notarize the existing signature, or install a Developer ID certificate."
    exit 0
fi

# Reset the per-run UI/state, in a private function so every exit path restores it.
finish() {
    show_progress 0
    enable_view "$CANCEL_BTN_ID" 0
    enable_view "$NOTARIZE_BTN_ID" 1
    enable_view "$ACTIONS_MENU_ID" 1
    pb_set "$PB_BUSY" ""
    /bin/rm -f "$(state_dir)/run.pid"
}

pb_set "$PB_BUSY" 1
printf '%s' "$$" > "$(state_dir)/run.pid"
/bin/rm -f "$(state_dir)/cancelled"
enable_view "$NOTARIZE_BTN_ID" 0
enable_view "$ACTIONS_MENU_ID" 0
show_view "$REVEAL_BTN_ID" 0
enable_view "$CANCEL_BTN_ID" 1
show_progress 1
clear_log
append_log "=== Notarize: $(/usr/bin/basename "$target") ==="

# 1. Sign for release (optional).
if [ "$sign_on" = "0" ]; then
    set_status "Signing for release..."
    sign_app "$target" "$identity" "$entitlements"
    if [ "$?" != "0" ]; then
        set_status "Signing failed."
        "$alert_tool" --level stop --title "Notarize" "Code signing failed. See the log."
        finish
        exit 0
    fi
    run_codesign_verify "$target"
else
    append_log "Using the app's existing signature (signing step skipped)."
fi

# 2. Package for upload.
set_status "Packaging for upload..."
append_log "Packaging for upload..."
upload_zip="$(state_dir)/upload.zip"
package_app "$target" "$upload_zip"
if [ "$?" != "0" ]; then
    set_status "Packaging failed."
    "$alert_tool" --level stop --title "Notarize" "Could not create the upload archive."
    finish
    exit 0
fi

# 3. Submit and wait for the notary service.
set_status "Submitting to the notary service..."
submit_and_wait "$upload_zip" "$profile"
if [ "$?" != "0" ]; then
    set_status "Submission failed."
    "$alert_tool" --level stop --title "Notarize" "Notarization submission failed. See the log."
    finish
    exit 0
fi

status="$(submission_status)"
if [ "$status" != "Accepted" ]; then
    set_status "Notarization $status. Fetching log..."
    append_log "Notarization not accepted ($status). Fetching log..."
    fetch_log "$(submission_id)" "$profile"
    print_issues
    "$alert_tool" --level stop --title "Notarize" "Notarization $status. See the issues in the log."
    finish
    exit 0
fi

# 4. Staple the ticket (optional).
if [ "$staple_on" = "0" ]; then
    set_status "Stapling notarization ticket..."
    staple_app "$target"
    if [ "$?" != "0" ]; then
        set_status "Stapling failed."
        "$alert_tool" --level stop --title "Notarize" "Stapling the ticket failed. See the log."
        finish
        exit 0
    fi
fi

# 5. Distribution archive (optional).
if [ "$zip_on" = "0" ]; then
    set_status "Creating distribution archive..."
    dist="$(dist_zip_path "$target" "$output_dir")"
    append_log "Creating distribution archive: $dist"
    package_app "$target" "$dist"
    if [ "$?" != "0" ]; then
        set_status "Distribution packaging failed."
        "$alert_tool" --level stop --title "Notarize" "Could not create the distribution archive."
        finish
        exit 0
    fi
    printf '%s' "$dist" > "$(state_dir)/dist.txt"
    show_view "$REVEAL_BTN_ID" 1
fi

# 6. Final Gatekeeper assessment.
run_spctl "$target"
append_log "Done. Accepted, stapled, and packaged for distribution."
set_status "Done. Notarized and ready for distribution."
"$notify_tool" --title "Notarize" "$(/usr/bin/basename "$target") is notarized and ready."
finish
