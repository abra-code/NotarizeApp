#!/bin/sh
# Notarize.creds.pick.sh - method chosen on step 1; advance the wizard
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    "$CRED_PICK_APPLEID_ID")
        pb_set "$PB_CRED_METHOD" 1
        show_view "$CRED_APPLEID_GROUP_ID" 1
        show_view "$CRED_APIKEY_GROUP_ID" 0
        show_view "$CRED_STEP1_ID" 0
        show_view "$CRED_STEP2_ID" 1
        ;;
    "$CRED_PICK_APIKEY_ID")
        pb_set "$PB_CRED_METHOD" 2
        show_view "$CRED_APPLEID_GROUP_ID" 0
        show_view "$CRED_APIKEY_GROUP_ID" 1
        show_view "$CRED_STEP1_ID" 0
        show_view "$CRED_STEP2_ID" 1
        ;;
    "$CRED_PICK_EXISTING_ID")
        # Existing profile: there is nothing to enter but the name, so this
        # path skips the credentials panel and has only two steps.
        pb_set "$PB_CRED_METHOD" 3
        set_value "$CRED_STEP3_TITLE_ID" "Step 2 of 2 - Register the profile"
        show_view "$CRED_HINT_CREATE_ID" 0
        show_view "$CRED_HINT_EXISTING_ID" 1
        show_view "$CRED_STEP1_ID" 0
        show_view "$CRED_STEP3_ID" 1
        ;;
    *)
        exit 0
        ;;
esac

# Recompute button enablement for the panel we just revealed.
"$next_cmd" "$cmd_guid" "Notarize.creds.fields"
