#!/bin/sh
# Notarize.sign.sh - copy the target app to the output folder and sign the copy
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app or installer package first."
    exit 0
fi
identity="$(selected_identity)"
if [ -z "$identity" ]; then
    # Sign Only never skips a signature that is already correct - but with no
    # identity selected there is nothing to sign with at all. Say which of the
    # two reasons applies instead of appearing to ignore the button.
    if [ -n "$(list_signing_identities "$(current_kind)")" ]; then
        "$alert_tool" --level caution --title "Notarize" "\"$NO_SIGN_OPTION\" is selected. Pick a signing identity to sign this target."
    else
        "$alert_tool" --level caution --title "Notarize" "No $(required_certificate_class) certificate is available in your keychain."
    fi
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
if made_release_copy; then
    append_log "Copied to output folder: $work"
fi
# Deliberately unconditional: the full pipeline consults resign_reason and can
# skip a signature that already matches, but this handler exists because the
# developer clicked Sign Only. Answering an explicit button press by doing
# nothing would be worse than a redundant signature.
sign_target "$work" "$identity" "$entitlements"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SIGN_ID" failed
    set_status "Signing failed."
    show_progress 0
    exit 0
fi
rail_set "$RAIL_SIGN_ID" done
set_status "Signed for release."
show_progress 0
