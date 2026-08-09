#!/bin/sh
# Notarize.creds.save.sh - store a notary keychain profile with notarytool.
# The app-specific password is fed to notarytool over stdin, never on argv, so
# it never appears in `ps`.
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

profile="$(view_value "$CRED_PROFILE_ID")"
name_problem="$(profile_name_problem "$profile")"
if [ -n "$name_problem" ]; then
    set_value "$CRED_RESULT_ID" "$name_problem"
    exit 0
fi

method="$(pb_get "$PB_CRED_METHOD")"

if [ "$method" = "3" ]; then
    # Existing keychain profile, created with notarytool outside this app.
    # notarytool profiles live in Apple's data protection keychain (access
    # group com.apple.gke.notary) and cannot be enumerated by other apps, so
    # the user supplies the name and notarytool itself verifies it exists.
    set_value "$CRED_RESULT_ID" "Checking profile '$profile' with the notary service..."
    out="$("$xcrun_tool" notarytool history --keychain-profile "$profile" --output-format json 2>&1)"
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

# store-credentials creates OR UPDATES. An existing profile of the same name is
# overwritten in place, without a prompt and without keeping anything of what it
# held - and the credentials it replaces cannot be read back out of the keychain
# by anyone, so there is no undo and no backup to take. That makes this the only
# point at which the developer can be asked, and the answer has to be explicit.
#
# The name is easy to collide with by accident: the wizard suggests one, and the
# suggestion survives backing out and choosing a different authentication method,
# so an API-key save can land on the name an Apple ID profile is already using.
replacing=""
set_value "$CRED_RESULT_ID" "Checking whether '$profile' is already in use..."
if notary_profile_exists "$profile"; then
    # Replace is the default button and Cancel the alternate, which puts the
    # destructive choice on Return and the safe one on Escape. That is the way
    # round to have it: the alert tool maps button 0 to CFUserNotification's
    # default response and button 1 to the alternate, and Escape reaches the
    # alternate - so one of the two keys has to carry Replace, and Escape is the
    # one people press to get out of a dialog they did not read. Someone who
    # presses Return has just clicked Save and gets the overwrite they asked
    # for; someone who presses Escape means "stop", and must be obeyed.
    "$alert_tool" --level caution --title "Notarize" \
        --ok "Replace credentials" --cancel "Cancel" \
        "A notary profile named \"$profile\" already exists.

Saving replaces the credentials stored under that name. The old ones cannot be recovered, and anything else that notarizes with this profile - other apps, scripts, CI - starts using the new ones.

To keep both, cancel and choose a different name."
    answer=$?
    if [ "$answer" = "1" ]; then
        set_value "$CRED_RESULT_ID" "Canceled. The profile '$profile' was left as it was."
        exit 0
    fi
    if [ "$answer" != "0" ]; then
        # The dialog never appeared. A missing or unrunnable alert answers 127 or
        # 126, and .gitignore keeps Contents/Frameworks out of the repo, so a
        # fresh clone really is in that state until appletbuilder has run. Still
        # refuse - but do not report a decision the developer never made.
        set_value "$CRED_RESULT_ID" "Could not show the confirmation dialog (alert exited $answer), so nothing was changed. The profile '$profile' was left as it was."
        exit 0
    fi
    replacing="yes"
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
    out="$("$xcrun_tool" notarytool store-credentials "$profile" --key "$keyfile" --key-id "$keyid" --issuer "$issuer" 2>&1)"
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
    out="$(printf '%s' "$password" | "$xcrun_tool" notarytool store-credentials "$profile" --apple-id "$appleid" --team-id "$team" 2>&1)"
    rc=$?
fi

if [ "$rc" = "0" ]; then
    known_profiles_add "$profile"
    prefs_set default_profile "$profile"
    refresh_profile_picker "$profile"
    # Registering the name makes it "known", which would otherwise have the next
    # keystroke warn that the profile just created already exists.
    pb_set "$PB_CRED_SAVED" "$profile"
    # Say which of the two happened. "Saved" reads the same either way, and a
    # developer who has just overwritten a profile should see that in the result
    # line, not only in the dialog they have already dismissed.
    if [ "$replacing" = "yes" ]; then
        set_value "$CRED_RESULT_ID" "Replaced the credentials in profile: $profile"
    else
        set_value "$CRED_RESULT_ID" "Saved and validated profile: $profile"
    fi
else
    set_value "$CRED_RESULT_ID" "Failed: $(printf '%s' "$out" | /usr/bin/tail -n 3 | /usr/bin/tr '\n' ' ')"
fi
