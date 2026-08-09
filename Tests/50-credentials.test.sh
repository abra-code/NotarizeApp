#!/bin/sh
# Tests/50-credentials.test.sh - the credential wizard.
#
# Two things make this window worth testing hard. It is a three-panel wizard
# with three entry paths, so most of its behavior is which panel is on screen
# and which button is live - state no screenshot proves and no human checks
# twice. And its Save button calls "notarytool store-credentials", which
# CREATES OR UPDATES: an existing profile of the same name is overwritten in
# place, without a prompt, and the credentials it replaces cannot be read back
# out of the keychain by anyone. There is no undo and no backup to take, so the
# confirmation in front of it is the only thing standing between a mistyped name
# and someone else's CI setup.
#
# The wizard is a CHILD SHEET: the engine moves the current dialog's uuid into
# OMC_PARENT_DIALOG_GUID before opening a window-carrying command, and the
# applet keys its document state off "${parent_uuid:-$window_uuid}". So the
# wizard's own controls live in the sheet's window and its writes to the profile
# picker land in the PARENT's - which is what makes a save show up in the main
# window immediately, and is asserted below rather than assumed.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.notarize.sh"

IDENTITY="Developer ID Application: Test Developer (TEAMID1234)"

# Open the main window, then the wizard on top of it.
open_wizard() {
    reset_document
    identities_set codesigning "$IDENTITY"
    omc_run Notarize.main.init
    omc_child_sheet creds
    # The sheet's uuid is derived from its name, so its pasteboard keys are the
    # same ones the previous section used. They outlive the process, so they are
    # cleared explicitly - creds.init clears the method, but not the
    # just-saved-profile exemption.
    pb_set "$(pb_cred_method_key)" ""
    pb_set "$(pb_cred_saved_key)" ""
    omc_control_defaults CredentialSheet
    omc_run Notarize.creds.init
}

# The parent document window, for assertions about what the wizard pushed there.
parent() { printf '%s' "$OMC_PARENT_DIALOG_GUID"; }

section "the wizard opens on the method chooser"
open_wizard
check_status "init ran" 0
check "step 1 is showing"        "1" "$(ui_visible "$CRED_STEP1_ID")"
check "step 2 is hidden"         "0" "$(ui_visible "$CRED_STEP2_ID")"
check "the final panel is hidden" "0" "$(ui_visible "$CRED_STEP3_ID")"
check "no method has been chosen" "" "$(cred_method)"
check "Continue is disabled until the fields are filled" "0" \
    "$(ui_enabled "$CRED_CONTINUE_ID")"
check "so are Save and Test" "0" "$(ui_enabled "$CRED_SAVE_ID")"
check "and Test"            "0" "$(ui_enabled "$CRED_TEST_ID")"
check "the result line is empty" "" "$(ui_value "$CRED_RESULT_ID")"
# The Team ID is the 10-character token in the identity's trailing parentheses.
# Prefilling it saves a trip to developer.apple.com for the common case.
check "the team id was prefilled from the signing identity" "TEAMID1234" \
    "$(ui_value "$CRED_TEAM_ID")"

section "with no identity to read, nothing is prefilled"
reset_document
identities_none codesigning
omc_run Notarize.main.init
omc_child_sheet creds
omc_control_defaults CredentialSheet
omc_run Notarize.creds.init
check "the team id is left for the developer to type" "" "$(ui_value "$CRED_TEAM_ID")"

section "the Apple ID path"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
check "method 1 was recorded"    "1" "$(cred_method)"
check "the chooser is hidden"    "0" "$(ui_visible "$CRED_STEP1_ID")"
check "the credentials panel is showing" "1" "$(ui_visible "$CRED_STEP2_ID")"
check "with the Apple ID fields" "1" "$(ui_visible "$CRED_APPLEID_GROUP_ID")"
check "and not the API key ones" "0" "$(ui_visible "$CRED_APIKEY_GROUP_ID")"
# Button enablement is recomputed by a separate command, so that one piece of
# logic serves both the panel switch and every keystroke.
check "it asked for the button state to be recomputed" "1" \
    "$(chain_asked Notarize.creds.fields)"

section "the API key path"
open_wizard
chains_reset
omc_trigger "$CRED_PICK_APIKEY_ID"
omc_run Notarize.creds.pick
check "method 2 was recorded"    "2" "$(cred_method)"
check "the API key fields are showing" "1" "$(ui_visible "$CRED_APIKEY_GROUP_ID")"
check "and not the Apple ID ones"      "0" "$(ui_visible "$CRED_APPLEID_GROUP_ID")"

section "the existing-profile path skips the credentials panel"
open_wizard
chains_reset
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
check "method 3 was recorded"     "3" "$(cred_method)"
check "the credentials panel is skipped" "0" "$(ui_visible "$CRED_STEP2_ID")"
check "and the name panel is showing"    "1" "$(ui_visible "$CRED_STEP3_ID")"
# There is nothing to enter but the name, so the wizard is two steps here and
# says so rather than claiming to be on step 3 of 3.
check "the panel calls itself step 2 of 2" "Step 2 of 2 - Register the profile" \
    "$(ui_value "$CRED_STEP3_TITLE_ID")"
check "the hint is the one about registering, not creating" "1" \
    "$(ui_visible "$CRED_HINT_EXISTING_ID")"
check "and the create hint is hidden" "0" "$(ui_visible "$CRED_HINT_CREATE_ID")"

section "an unrecognized Continue does nothing at all"
open_wizard
chains_reset
omc_trigger 99999
omc_run Notarize.creds.pick
check_status "the handler exited cleanly" 0
check "no method was recorded" "" "$(cred_method)"
check "and nothing was chained" "0" "$(chain_asked Notarize.creds.fields)"

section "Continue is only live once every field of the method is filled"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_run Notarize.creds.fields
check "two of three is not enough" "0" "$(ui_enabled "$CRED_CONTINUE_ID")"
# The Team ID was PREFILLED by creds.init rather than typed, so it exists in the
# window and not yet in the environment. The engine would export it at the next
# dispatch; the harness does not, so it is bridged.
sync_control "$CRED_TEAM_ID"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_run Notarize.creds.fields
check "all three, and it goes live" "1" "$(ui_enabled "$CRED_CONTINUE_ID")"
omc_control "$CRED_APPLEID_ID" ""
omc_run Notarize.creds.fields
check "clearing one takes it away again" "0" "$(ui_enabled "$CRED_CONTINUE_ID")"

section "the API key method asks for its own three fields"
open_wizard
omc_trigger "$CRED_PICK_APIKEY_ID"
omc_run Notarize.creds.pick
# The Apple ID fields are filled and the API key ones are not: the method
# decides which three count, so this must NOT enable Continue.
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_run Notarize.creds.fields
check "the other method's fields do not count" "0" "$(ui_enabled "$CRED_CONTINUE_ID")"
omc_control "$CRED_KEYFILE_ID" "/keys/AuthKey_ABC123.p8"
omc_control "$CRED_KEYID_ID" "ABC123"
omc_control "$CRED_ISSUER_ID" "11111111-2222-3333-4444-555555555555"
omc_run Notarize.creds.fields
check "its own three do" "1" "$(ui_enabled "$CRED_CONTINUE_ID")"

section "Continue suggests a profile name and moves to the final panel"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
chains_reset
omc_run Notarize.creds.next
check "the name was suggested from the team id" "notary-TEAMID1234" \
    "$(ui_value "$CRED_PROFILE_ID")"
check "the credentials panel is hidden" "0" "$(ui_visible "$CRED_STEP2_ID")"
check "the name panel is showing"       "1" "$(ui_visible "$CRED_STEP3_ID")"
check "which calls itself step 3 of 3"  "Step 3 of 3 - Name and save the profile" \
    "$(ui_value "$CRED_STEP3_TITLE_ID")"
check "and the create hint is back"     "1" "$(ui_visible "$CRED_HINT_CREATE_ID")"
check "button state was recomputed, since the name just appeared" "1" \
    "$(chain_asked Notarize.creds.fields)"

section "the API key method suggests its own name"
open_wizard
omc_trigger "$CRED_PICK_APIKEY_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_KEYFILE_ID" "/keys/AuthKey_ABC123.p8"
omc_control "$CRED_KEYID_ID" "ABC123"
omc_control "$CRED_ISSUER_ID" "11111111-2222-3333-4444-555555555555"
omc_run Notarize.creds.next
check "a name that does not pretend to be a team" "notary-api" \
    "$(ui_value "$CRED_PROFILE_ID")"

section "Continue re-checks the fields even though the button was live"
# Programmatic updates can fire actions, so the guard is not redundant with the
# button's enabled state.
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" ""
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_run Notarize.creds.next
check "the wizard did not advance" "0" "$(ui_visible "$CRED_STEP3_ID")"
check "and the credentials panel is still up" "1" "$(ui_visible "$CRED_STEP2_ID")"

section "Back keeps what was typed"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_trigger "$CRED_BACK2_ID"
omc_run Notarize.creds.back
check "step 2 is hidden"          "0" "$(ui_visible "$CRED_STEP2_ID")"
check "the chooser is back"       "1" "$(ui_visible "$CRED_STEP1_ID")"

section "Back from the name panel goes where the method came from"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_run Notarize.creds.next
omc_trigger "$CRED_BACK3_ID"
omc_run Notarize.creds.back
check "a create flow goes back to the credentials panel" "1" \
    "$(ui_visible "$CRED_STEP2_ID")"
check "not to the chooser" "0" "$(ui_visible "$CRED_STEP1_ID")"

open_wizard
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_trigger "$CRED_BACK3_ID"
omc_run Notarize.creds.back
# The existing-profile flow has no credentials panel, so going back to it would
# show an empty step the developer never saw.
check "the existing-profile flow goes back to the chooser" "1" \
    "$(ui_visible "$CRED_STEP1_ID")"
check "and not to a panel it skipped" "0" "$(ui_visible "$CRED_STEP2_ID")"

section "a name already in use is flagged while it is being typed"
open_wizard
ntz_call known_profiles_add notary-team >/dev/null
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-team"
omc_run Notarize.creds.fields
check "Save and Test go live with a name" "1" "$(ui_enabled "$CRED_SAVE_ID")"
check "the collision is on screen before Save is ever clicked" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c "already exists")"
# Each keystroke is a fresh process, so a warning left standing would name a
# profile the developer has since typed past. The line is a live readout of the
# current name, not a log.
omc_control "$CRED_PROFILE_ID" "notary-team-2"
omc_run Notarize.creds.fields
check "typing past it clears the warning" "" "$(ui_value "$CRED_RESULT_ID")"
omc_control "$CRED_PROFILE_ID" ""
omc_run Notarize.creds.fields
check "an empty name disables Save" "0" "$(ui_enabled "$CRED_SAVE_ID")"
check "and Test"                    "0" "$(ui_enabled "$CRED_TEST_ID")"

section "the existing-profile flow is never warned about a known name"
open_wizard
ntz_call known_profiles_add notary-team >/dev/null
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-team"
omc_run Notarize.creds.fields
# This path registers a profile rather than writing one, so nothing is at risk -
# and the name being known is exactly what it wants.
check "no warning" "" "$(ui_value "$CRED_RESULT_ID")"

section "registering an existing keychain profile"
open_wizard
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-existing"
notary_history_default 0 '{"history":[]}'
omc_run Notarize.creds.save
check "the developer is told it worked" "Registered existing profile: notary-existing" \
    "$(ui_value "$CRED_RESULT_ID")"
check "it was remembered"       "yes" "$(ntz_is known_profile notary-existing)"
check "and made the default"    "notary-existing" "$(prefs_value /default_profile)"
# The wizard writes the profile picker into the PARENT window, which is what
# makes the save visible in the main window without reopening it.
check "the main window's picker was refilled" '["notary-existing"]' \
    "$(ui_prop "$PROFILE_PICKER_ID" options "$(parent)")"
# Nothing was created, so store-credentials must never have run.
check "no credentials were stored" "0" \
    "$(fake_mentions xcrun 'store-credentials')"

section "a profile the notary service does not know is refused"
open_wizard
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-nope"
notary_history_default 69 "Error: No Keychain password item found for profile: notary-nope"
omc_run Notarize.creds.save
check "the failure is reported" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c '^Failed: Error: No Keychain password item')"
check "and it was not remembered" "no" "$(ntz_is known_profile notary-nope)"
check "nor made the default"      "" "$(prefs_value /default_profile)"

section "a name notarytool could never use is refused before anything runs"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "-p"
omc_run Notarize.creds.save
check "the reason is on screen" "A profile name cannot start with a dash." \
    "$(ui_value "$CRED_RESULT_ID")"
check "and notarytool was never asked anything" "0" "$(fake_calls xcrun)"

section "saving a NEW profile does not stop to confirm anything"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_control "$CRED_PROFILE_ID" "notary-fresh"
# The one failure that means "no such profile". Anything else has to count as
# "exists, or cannot be ruled out".
notary_history_absent notary-fresh
omc_run Notarize.creds.save
check "nobody was asked to confirm" "0" "$(alerts_count)"
check "the result says it was created, not replaced" \
    "Saved and validated profile: notary-fresh" "$(ui_value "$CRED_RESULT_ID")"
check "the credentials were stored" "1" "$(fake_mentions xcrun 'store-credentials')"
check "under the profile name"      "yes" "$(fake_arg xcrun "notary-fresh" "$(fake_calls xcrun)")"
check "with the Apple ID"           "dev@example.com" \
    "$(fake_arg_after xcrun --apple-id "$(fake_calls xcrun)")"
check "and the team id"             "TEAMID1234" \
    "$(fake_arg_after xcrun --team-id "$(fake_calls xcrun)")"
# The app-specific password goes to notarytool over STDIN, never argv, because
# argv is what "ps" shows to every other process on the machine. BOTH halves are
# asserted: that it is absent from the command line, and that it was actually
# delivered. The negative alone is satisfied by not sending the password at all,
# so a refactor that dropped the pipe would report "Saved and validated profile"
# and pass.
check "the password never appeared on the command line" "0" \
    "$(fake_mentions xcrun 'abcd-efgh-ijkl-mnop')"
check "but it did reach notarytool, over stdin" "abcd-efgh-ijkl-mnop" \
    "$(notary_store_stdin)"
check "it was made the default profile" "notary-fresh" "$(prefs_value /default_profile)"
check "and the main window's picker shows it" '["notary-fresh"]' \
    "$(ui_prop "$PROFILE_PICKER_ID" options "$(parent)")"

section "the name just saved is not then warned about"
# Registering it makes it "known", and warning about a profile the developer
# created a moment ago would contradict the success message right above it.
#
# The result line is a live readout of the name in the field, not a log, so the
# next keystroke clears it either way - the assertion is that it is EMPTY rather
# than carrying a collision warning.
omc_run Notarize.creds.fields
check "no collision warning for the name just saved" "" "$(ui_value "$CRED_RESULT_ID")"
# ...but only for that name. Typing a different known one warns again.
ntz_call known_profiles_add notary-other >/dev/null
omc_control "$CRED_PROFILE_ID" "notary-other"
omc_run Notarize.creds.fields
check "a different known name still warns" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c 'already exists')"

section "the exemption lapses when a new attempt is started"
# Saving the same name again under a different authentication method really
# would overwrite what the last attempt stored, and that is the collision most
# worth warning about - the wizard's own suggested name survives backing out.
omc_trigger "$CRED_PICK_APIKEY_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-fresh"
omc_run Notarize.creds.fields
check "the just-saved name is warned about again" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c 'already exists')"

section "overwriting an existing profile has to be confirmed"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_control "$CRED_PROFILE_ID" "notary-taken"
notary_history_for notary-taken 0 '{"history":[]}'
# Escape reaches the alert tool's alternate button, which this alert wires to
# Cancel - so the key people press to get out of a dialog they did not read is
# the one that does nothing.
alert_answer 1
omc_run Notarize.creds.save
check "the developer was asked"  "1" "$(alerts_count)"
check "and the alert says what is at stake" "1" \
    "$(alerts_mention 'The old ones cannot be recovered')"
check "the result says nothing changed" \
    "Canceled. The profile 'notary-taken' was left as it was." \
    "$(ui_value "$CRED_RESULT_ID")"
check "and nothing was stored" "0" "$(fake_mentions xcrun 'store-credentials')"

section "confirming it goes through, and says which of the two happened"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_control "$CRED_PROFILE_ID" "notary-taken"
notary_history_for notary-taken 0 '{"history":[]}'
alert_answer 0
omc_run Notarize.creds.save
check "the credentials were stored" "1" "$(fake_mentions xcrun 'store-credentials')"
# "Saved" reads the same either way, and someone who has just overwritten a
# profile should see that in the result line, not only in a dialog they have
# already dismissed.
check "the result says replaced, not saved" \
    "Replaced the credentials in profile: notary-taken" "$(ui_value "$CRED_RESULT_ID")"

section "a confirmation that could not be shown is not a decision"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_control "$CRED_PROFILE_ID" "notary-taken"
notary_history_for notary-taken 0 '{"history":[]}'
# 3 is the alert tool's "timed out". A missing or unrunnable alert answers 126
# or 127, and .gitignore keeps Contents/Frameworks out of the repo, so a fresh
# clone really is in that state until appletbuilder has run.
alert_answer 3
omc_run Notarize.creds.save
check "nothing was stored" "0" "$(fake_mentions xcrun 'store-credentials')"
check "and the result does not report a decision nobody made" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c 'Could not show the confirmation dialog')"

section "a name this app already registered needs no keychain probe"
open_wizard
ntz_call known_profiles_add notary-known >/dev/null
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "abcd-efgh-ijkl-mnop"
omc_control "$CRED_PROFILE_ID" "notary-known"
alert_answer 1
omc_run Notarize.creds.save
check "the confirmation was still raised" "1" "$(alerts_count)"
# Profiles this app registered are known offline and for certain, and that is
# the common case - a name reused from an earlier run of this wizard - so it
# costs no network call at all.
check "and notarytool was never asked" "0" "$(fake_mentions xcrun 'history')"

section "a failed store-credentials reports what Apple said"
open_wizard
omc_trigger "$CRED_PICK_APPLEID_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_APPLEID_ID" "dev@example.com"
omc_control "$CRED_TEAM_ID" "TEAMID1234"
omc_control "$CRED_PASSWORD_ID" "wrong-password"
omc_control "$CRED_PROFILE_ID" "notary-bad"
notary_history_absent notary-bad
notary_store_fails "Error: HTTP status code: 401. Invalid credentials."
omc_run Notarize.creds.save
check "the failure is on screen" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c 'Invalid credentials')"
check "nothing was remembered" "no" "$(ntz_is known_profile notary-bad)"
check "and no default was set"  "" "$(prefs_value /default_profile)"

section "the API key method passes a key file, not a password"
open_wizard
omc_trigger "$CRED_PICK_APIKEY_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_KEYFILE_ID" "/keys/AuthKey_ABC123.p8"
omc_control "$CRED_KEYID_ID" "ABC123"
omc_control "$CRED_ISSUER_ID" "11111111-2222-3333-4444-555555555555"
omc_control "$CRED_PROFILE_ID" "notary-apikey"
notary_history_absent notary-apikey
omc_run Notarize.creds.save
last="$(fake_calls xcrun)"
check "the key file was passed"  "/keys/AuthKey_ABC123.p8" "$(fake_arg_after xcrun --key "$last")"
check "the key id too"           "ABC123" "$(fake_arg_after xcrun --key-id "$last")"
check "and the issuer"           "11111111-2222-3333-4444-555555555555" \
    "$(fake_arg_after xcrun --issuer "$last")"
check "no Apple ID was sent"     "0" "$(fake_mentions xcrun 'apple-id')"
check "and nothing was fed over stdin" "" "$(notary_store_stdin)"

section "Test Profile proves a profile works, and adopts it"
open_wizard
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-works"
notary_history_default 0 '{"history":[]}'
omc_run Notarize.creds.test
check "the result says so"   "Profile 'notary-works' works." "$(ui_value "$CRED_RESULT_ID")"
check "it was remembered"    "yes" "$(ntz_is known_profile notary-works)"
check "and adopted as the default, since there was none" "notary-works" \
    "$(prefs_value /default_profile)"
check "the main window's picker shows it" '["notary-works"]' \
    "$(ui_prop "$PROFILE_PICKER_ID" options "$(parent)")"

section "Test Profile does not steal an existing default"
ntz_call prefs_set default_profile notary-established >/dev/null
omc_control "$CRED_PROFILE_ID" "notary-second"
omc_run Notarize.creds.test
check "the new profile is remembered" "yes" "$(ntz_is known_profile notary-second)"
check "but the default is left alone"  "notary-established" \
    "$(prefs_value /default_profile)"

section "Test Profile reports a failure without remembering anything"
open_wizard
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" "notary-broken"
notary_history_default 69 "Error: No Keychain password item found for profile: notary-broken"
omc_run Notarize.creds.test
check "the failure is reported" "1" \
    "$(ui_value "$CRED_RESULT_ID" | /usr/bin/grep -c "Profile 'notary-broken' failed")"
check "and it was not remembered" "no" "$(ntz_is known_profile notary-broken)"

section "Test Profile falls back to the default when the field is empty"
open_wizard
ntz_call prefs_set default_profile notary-fallback >/dev/null
omc_trigger "$CRED_PICK_EXISTING_ID"
omc_run Notarize.creds.pick
omc_control "$CRED_PROFILE_ID" ""
notary_history_default 0 '{"history":[]}'
omc_run Notarize.creds.test
check "the default was tested" "notary-fallback" "$(fake_arg_after xcrun --keychain-profile 1)"

open_wizard
omc_control "$CRED_PROFILE_ID" ""
omc_run Notarize.creds.test
check "with neither, it asks for a name" "Enter a profile name to test." \
    "$(ui_value "$CRED_RESULT_ID")"
check "and asks the notary service nothing" "0" "$(fake_calls xcrun)"

omc_leave_sheet

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
