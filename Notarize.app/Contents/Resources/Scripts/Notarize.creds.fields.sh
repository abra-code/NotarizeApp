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
profile="$(view_value "$CRED_PROFILE_ID")"
if [ -n "$profile" ]; then
    enable_view "$CRED_SAVE_ID" 1
    enable_view "$CRED_TEST_ID" 1
else
    enable_view "$CRED_SAVE_ID" 0
    enable_view "$CRED_TEST_ID" 0
fi

# Warn about a name collision while the name is being typed, not only once Save
# has been clicked. store-credentials overwrites an existing profile in place,
# and the wizard's own suggested name is a likely collision, so the sooner this
# is on screen the less likely anyone is to reach the confirmation at all.
#
# Only this app's own record of registered profiles is consulted here: it is a
# plist read, cheap enough for a handler that runs on every keystroke, and it
# needs no keychain probe and no network. It is not complete - a profile created
# outside this app is not in it - which is why the save path asks notarytool as
# well. This warning is an early hint; the confirmation there is the real gate.
#
# The result line is rewritten either way, never only when there is something to
# say. Each keystroke is a fresh process, so leaving it alone would leave the
# previous keystroke's warning on screen naming a profile the developer has
# since typed past - and a stale warning about the wrong name reads as a live
# claim about the name now in the field. That makes this line a live readout of
# the current name rather than a log, so a save or test result stands only until
# the next keystroke.
#
# Two exemptions. Path 3 registers an existing profile rather than writing one,
# so nothing is at risk and the name being known is exactly what it wants. And a
# name this wizard has just saved is "known" only because the developer created
# it a moment ago - warning about that would contradict the success message
# sitting right above it.
if [ "$method" != "3" ] \
    && [ "$profile" != "$(pb_get "$PB_CRED_SAVED")" ] \
    && known_profile "$profile"; then
    set_value "$CRED_RESULT_ID" "A profile named '$profile' already exists. Saving will replace the credentials stored under that name."
else
    set_value "$CRED_RESULT_ID" ""
fi
