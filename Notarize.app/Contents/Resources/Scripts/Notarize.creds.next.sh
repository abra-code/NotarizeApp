#!/bin/sh
# Notarize.creds.next.sh - Continue from the credentials panel to the name panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

method="$(pb_get "$PB_CRED_METHOD")"

# Belt and braces: Continue is only enabled when the fields are complete, but
# programmatic events can fire actions, so re-check before advancing.
if [ "$method" = "2" ]; then
    if [ -z "$(view_value "$CRED_KEYFILE_ID")" ] || [ -z "$(view_value "$CRED_KEYID_ID")" ] || [ -z "$(view_value "$CRED_ISSUER_ID")" ]; then
        exit 0
    fi
else
    if [ -z "$(view_value "$CRED_APPLEID_ID")" ] || [ -z "$(view_value "$CRED_TEAM_ID")" ] || [ -z "$(view_value "$CRED_PASSWORD_ID")" ]; then
        exit 0
    fi
fi

# Suggest a profile name if none was entered yet.
if [ -z "$(view_value "$CRED_PROFILE_ID")" ]; then
    if [ "$method" = "2" ]; then
        suggestion="notary-api"
    else
        team="$(view_value "$CRED_TEAM_ID")"
        suggestion="notary-${team:-default}"
    fi
    set_value "$CRED_PROFILE_ID" "$suggestion"
fi

set_value "$CRED_STEP3_TITLE_ID" "Step 3 of 3 - Name and save the profile"
show_view "$CRED_HINT_CREATE_ID" 1
show_view "$CRED_HINT_EXISTING_ID" 0
show_view "$CRED_STEP2_ID" 0
show_view "$CRED_STEP3_ID" 1

# Recompute Save/Test enablement (the suggestion may have just filled the name).
"$next_cmd" "$cmd_guid" "Notarize.creds.fields"
