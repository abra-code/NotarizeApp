#!/bin/sh
# Notarize.creds.init.sh - reset the credential wizard to step 1
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

# No method chosen yet.
pb_set "$PB_CRED_METHOD" ""

# Show the method chooser, hide the other panels.
show_view "$CRED_STEP1_ID" 1
show_view "$CRED_STEP2_ID" 0
show_view "$CRED_STEP3_ID" 0

# Panel defaults for the create flows.
show_view "$CRED_APPLEID_GROUP_ID" 1
show_view "$CRED_APIKEY_GROUP_ID" 0
show_view "$CRED_HINT_CREATE_ID" 1
show_view "$CRED_HINT_EXISTING_ID" 0

# Prefill the team id from the default identity, if discoverable.
def_id="$(prefs_get default_identity)"
if [ -z "$def_id" ]; then
    def_id="$(list_signing_identities app | /usr/bin/head -n 1)"
fi
team="$(team_from_identity "$def_id")"
if [ -n "$team" ]; then
    set_value "$CRED_TEAM_ID" "$team"
fi

# Action buttons stay disabled until their fields are complete.
enable_view "$CRED_CONTINUE_ID" 0
enable_view "$CRED_SAVE_ID" 0
enable_view "$CRED_TEST_ID" 0
set_value "$CRED_RESULT_ID" ""
