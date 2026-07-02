#!/bin/sh
# Notarize.creds.init.sh - populate the credential window
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

# Method options: 1 = Apple ID, 2 = App Store Connect API key,
# 3 = existing keychain profile (created with notarytool outside this app).
set_property "$CRED_METHOD_ID" options '["Apple ID","App Store Connect API key","Existing keychain profile"]'

# Prefill the team id from the default identity, if discoverable.
def_id="$(prefs_get default_identity)"
if [ -z "$def_id" ]; then
    def_id="$(list_developer_id_identities | /usr/bin/head -n 1)"
fi
team="$(team_from_identity "$def_id")"
if [ -n "$team" ]; then
    set_value "$CRED_TEAM_ID" "$team"
fi

# Default to the Apple ID method: show its fields, hide the other groups.
show_view 700 1
show_view 710 0
show_view 720 0
set_value "$CRED_RESULT_ID" ""
