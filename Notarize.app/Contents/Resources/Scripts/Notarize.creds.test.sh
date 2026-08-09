#!/bin/sh
# Notarize.creds.test.sh - verify a stored profile works (notarytool history)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

profile="$(view_value "$CRED_PROFILE_ID")"
if [ -z "$profile" ]; then
    profile="$(prefs_get default_profile)"
fi
if [ -z "$profile" ]; then
    set_value "$CRED_RESULT_ID" "Enter a profile name to test."
    exit 0
fi

set_value "$CRED_RESULT_ID" "Testing profile $profile..."
out="$("$xcrun_tool" notarytool history --keychain-profile "$profile" --output-format json 2>&1)"
rc=$?
if [ "$rc" = "0" ]; then
    # The profile is proven to work - remember it and reflect it in the
    # main window's picker right away.
    known_profiles_add "$profile"
    if [ -z "$(prefs_get default_profile)" ]; then
        prefs_set default_profile "$profile"
    fi
    refresh_profile_picker "$profile"
    set_value "$CRED_RESULT_ID" "Profile '$profile' works."
else
    set_value "$CRED_RESULT_ID" "Profile '$profile' failed: $(printf '%s' "$out" | /usr/bin/tail -n 2 | /usr/bin/tr '\n' ' ')"
fi
