#!/bin/sh
# Notarize.creds.fields.sh - recompute wizard button enablement as fields change
# (valueChangeActionID of every credential field; also chained after pick/next)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

method="$(pb_get "$PB_CRED_METHOD")"

# Continue on the credentials panel: all three of the method's fields filled.
if [ "$method" = "2" ]; then
    if [ -n "$(view_value "$CRED_KEYFILE_ID")" ] && [ -n "$(view_value "$CRED_KEYID_ID")" ] && [ -n "$(view_value "$CRED_ISSUER_ID")" ]; then
        enable_view "$CRED_CONTINUE_ID" 1
    else
        enable_view "$CRED_CONTINUE_ID" 0
    fi
else
    if [ -n "$(view_value "$CRED_APPLEID_ID")" ] && [ -n "$(view_value "$CRED_TEAM_ID")" ] && [ -n "$(view_value "$CRED_PASSWORD_ID")" ]; then
        enable_view "$CRED_CONTINUE_ID" 1
    else
        enable_view "$CRED_CONTINUE_ID" 0
    fi
fi

# Save and Test on the name panel: profile name filled.
if [ -n "$(view_value "$CRED_PROFILE_ID")" ]; then
    enable_view "$CRED_SAVE_ID" 1
    enable_view "$CRED_TEST_ID" 1
else
    enable_view "$CRED_SAVE_ID" 0
    enable_view "$CRED_TEST_ID" 0
fi
