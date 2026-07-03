#!/bin/sh
# Notarize.creds.save.sh - store a notary keychain profile with notarytool.
# The app-specific password is fed to notarytool over stdin, never on argv, so
# it never appears in `ps`.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

profile="$(view_value "$CRED_PROFILE_ID")"
if [ -z "$profile" ]; then
    set_value "$CRED_RESULT_ID" "Enter a profile name."
    exit 0
fi

method="$(pb_get "$PB_CRED_METHOD")"

if [ "$method" = "3" ]; then
    # Existing keychain profile, created with notarytool outside this app.
    # notarytool profiles live in Apple's data protection keychain (access
    # group com.apple.gke.notary) and cannot be enumerated by other apps, so
    # the user supplies the name and notarytool itself verifies it exists.
    set_value "$CRED_RESULT_ID" "Checking profile '$profile' with the notary service..."
    out="$(/usr/bin/xcrun notarytool history --keychain-profile "$profile" --output-format json 2>&1)"
    if [ "$?" = "0" ]; then
        known_profiles_add "$profile"
        prefs_set default_profile "$profile"
        refresh_profile_picker "$profile"
        set_value "$CRED_RESULT_ID" "Registered existing profile: $profile"
    else
        set_value "$CRED_RESULT_ID" "Failed: $(printf '%s' "$out" | /usr/bin/head -n 1)"
    fi
    exit 0
fi

set_value "$CRED_RESULT_ID" "Validating with Apple..."

if [ "$method" = "2" ]; then
    # App Store Connect API key.
    keyfile="$(view_value "$CRED_KEYFILE_ID")"
    keyid="$(view_value "$CRED_KEYID_ID")"
    issuer="$(view_value "$CRED_ISSUER_ID")"
    if [ -z "$keyfile" ] || [ -z "$keyid" ] || [ -z "$issuer" ]; then
        set_value "$CRED_RESULT_ID" "Fill in the API key path, Key ID, and Issuer."
        exit 0
    fi
    out="$(/usr/bin/xcrun notarytool store-credentials "$profile" --key "$keyfile" --key-id "$keyid" --issuer "$issuer" 2>&1)"
    rc=$?
else
    # Apple ID + app-specific password (password handed to stdin, never argv).
    appleid="$(view_value "$CRED_APPLEID_ID")"
    team="$(view_value "$CRED_TEAM_ID")"
    password="$(view_value "$CRED_PASSWORD_ID")"
    if [ -z "$appleid" ] || [ -z "$team" ] || [ -z "$password" ]; then
        set_value "$CRED_RESULT_ID" "Fill in the Apple ID, Team ID, and app-specific password."
        exit 0
    fi
    out="$(printf '%s' "$password" | /usr/bin/xcrun notarytool store-credentials "$profile" --apple-id "$appleid" --team-id "$team" 2>&1)"
    rc=$?
fi

if [ "$rc" = "0" ]; then
    known_profiles_add "$profile"
    prefs_set default_profile "$profile"
    refresh_profile_picker "$profile"
    set_value "$CRED_RESULT_ID" "Saved and validated profile: $profile"
else
    set_value "$CRED_RESULT_ID" "Failed: $(printf '%s' "$out" | /usr/bin/tail -n 3 | /usr/bin/tr '\n' ' ')"
fi
