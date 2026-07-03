#!/bin/sh
# Notarize.creds.back.sh - go back one wizard step (field values are kept)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    "$CRED_BACK2_ID")
        # Step 2 -> step 1.
        show_view "$CRED_STEP2_ID" 0
        show_view "$CRED_STEP1_ID" 1
        ;;
    "$CRED_BACK3_ID")
        # Final panel -> step 2 for the create flows, step 1 for the
        # existing-profile flow (which has no credentials panel).
        method="$(pb_get "$PB_CRED_METHOD")"
        show_view "$CRED_STEP3_ID" 0
        if [ "$method" = "3" ]; then
            show_view "$CRED_STEP1_ID" 1
        else
            show_view "$CRED_STEP2_ID" 1
        fi
        ;;
esac
