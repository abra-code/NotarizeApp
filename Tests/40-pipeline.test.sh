#!/bin/sh
# Tests/40-pipeline.test.sh - the buttons: Notarize, the four step actions, Stop,
# and the two diagnostics.
#
# The handlers are what a developer actually presses, and each of them has an
# early-exit guard, a rail stage to move, and a UI state to restore on every
# path out. The restore is the part worth testing hardest: a handler that leaves
# Notarize disabled and Stop enabled has bricked the window, and that only
# happens on the error paths nobody walks by hand.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.notarize.sh"

IDENTITY="Developer ID Application: Test Developer (TEAMID1234)"
INSTALLER_ID="Developer ID Installer: Test Developer (TEAMID1234)"

# The window as it is the instant before the developer clicks Notarize: a
# certificate in the keychain, one registered profile, a target chosen, and both
# pickers resolved to their first row.
#
# The notary service is scripted to accept by default, so a section only has to
# describe the ONE thing it is taking away.
arm_window() { # <target>
    reset_document
    identities_set codesigning "$IDENTITY"
    identities_set basic "$INSTALLER_ID"
    ntz_call known_profiles_add notary-team >/dev/null
    omc_object "$1"
    omc_run Notarize.main.init
    omc_control "$IDENTITY_PICKER_ID" 1
    omc_control "$PROFILE_PICKER_ID" 1
    notary_submit_result Accepted
}

# Give <app> a nested helper and the exact signature the window would produce,
# so the pipeline's "already signed as requested" branch is reachable.
#
# Called AFTER arm_window, never before: arm_window resets the fake world, so a
# signature described first is wiped before the run ever asks about it - and the
# run then signs, which looks like the applet ignoring its own skip logic.
sign_world_ok() { # <app>
    local helper="$1/Contents/Helpers/tool"
    /bin/mkdir -p "$1/Contents/Helpers"
    printf 'x\n' > "$helper"
    listing_set "$1" "$helper"
    sig_set "$1"
    sig_set "$helper"
}

# Every control the run disables while it works, back the way it started.
check_window_is_idle() { # <label>
    check "$1: Notarize is usable again" "1" "$(ui_enabled "$NOTARIZE_BTN_ID")"
    check "$1: Stop is disabled"         "0" "$(ui_enabled "$CANCEL_BTN_ID")"
    check "$1: the spinner is hidden"    "0" "$(ui_visible "$PROGRESS_ID")"
    check "$1: the step buttons are usable again" "1" \
        "$(ui_enabled "$(printf '%s' "$RAIL_BTN_IDS" | /usr/bin/cut -d' ' -f1)")"
    check "$1: the busy flag was cleared" "" "$(busy)"
    check_absent "$1: the pid file was removed" "$(state_dir_path)/run.pid"
}

section "Notarize refuses to start without a target"
reset_document
identities_set codesigning "$IDENTITY"
omc_run Notarize.main.init
omc_run Notarize.run
check_status "the handler exited cleanly" 0
check "the developer was told to choose something" "1" \
    "$(alerts_mention 'Choose an app or installer package to notarize first')"
check "nothing was uploaded" "0" "$(fake_calls xcrun)"

section "Notarize refuses to start without a credential profile"
app="$(make_app Ready.app)"
reset_document
identities_set codesigning "$IDENTITY"
omc_object "$app"
omc_run Notarize.main.init
omc_control "$IDENTITY_PICKER_ID" 1
# No profile was ever registered, so the picker has no options and
# selected_profile resolves to nothing.
omc_run Notarize.run
check "the developer was pointed at the Credentials button" "1" \
    "$(alerts_mention 'Set up notary credentials first')"
check "nothing was uploaded" "0" "$(fake_calls xcrun)"
check "and the rail was never even reset" "untouched" "$(rail_state "$RAIL_SIGN_ID")"

section "the full run, on an app that already carries the right signature"
app="$(make_app Happy.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 0 "$app: accepted"
omc_run Notarize.run
check_status "the run completed" 0
# Signing is a replacement: repeating it when every setting already matches
# would produce a byte-for-byte equivalent result, so the pipeline leaves it be.
check "the signing stage was skipped, not run" "skipped" "$(rail_state "$RAIL_SIGN_ID")"
check "and the signer was never asked to sign" "0" "$(signer_runs)"
check "the log explains the skip" "yes" "$(log_says 'already matches every setting')"
check "and points at Sign Only for signing anyway" "yes" \
    "$(log_says 'Actions > Sign Only, which never skips')"
check "submission succeeded" "done" "$(rail_state "$RAIL_SUBMIT_ID")"
check "the ticket was stapled" "done" "$(rail_state "$RAIL_STAPLE_ID")"
check "Gatekeeper accepted the result" "done" "$(rail_state "$RAIL_VALIDATE_ID")"
check "the status line says it is ready" "Done. Notarized and ready for distribution." \
    "$(ui_value "$STATUS_ID")"
check "and the log names where the result is" "yes" \
    "$(log_says 'Accepted, stapled, and ready at')"
check "Reveal in Finder appeared" "1" "$(ui_visible "$REVEAL_BTN_ID")"
check "the developer was notified" "1" "$(notify_mention 'Happy.app is notarized and ready')"
check "and never interrupted with an alert" "0" "$(alerts_count)"
check_window_is_idle "after a clean run"

section "the upload really was the archive, submitted under the chosen profile"
check "an archive was built for the app" "$(state_dir_path)/upload.zip" \
    "$(ntz_call upload_path)"
check "notarytool was asked to submit it" "yes" \
    "$(fake_arg xcrun "$(state_dir_path)/upload.zip" 1)"
check "under the profile the picker resolved to" "notary-team" \
    "$(fake_arg_after xcrun --keychain-profile 1)"
check "and told to wait for a terminal status" "yes" "$(fake_arg xcrun --wait 1)"
check "the submission id was recorded for Fetch Log" \
    "11111111-2222-3333-4444-555555555555" "$(ntz_call submission_id)"

section "an unsigned app is signed first, and then goes through"
app="$(make_app Unsigned.app)"
listing_set "$app"
sig_unsigned "$app"
arm_window "$app"
spctl_set "$app" 0 "accepted"
omc_run Notarize.run
check "the signing stage ran"  "done" "$(rail_state "$RAIL_SIGN_ID")"
check "the signer signed once" "1" "$(signer_runs)"
check "with the identity the picker resolved to" "1" \
    "$(fake_mentions codesign_applet.sh "$IDENTITY")"
# --no-entitlements-search, so nothing the developer cannot see on screen can
# creep into the signature.
check "and told not to go looking for entitlements" "1" \
    "$(fake_mentions codesign_applet.sh '--no-entitlements-search')"
check "the log says why it signed" "yes" "$(log_says 'Signing because')"
check "the whole run succeeded" "done" "$(rail_state "$RAIL_VALIDATE_ID")"

section "signing failure stops the run before anything is uploaded"
app="$(make_app Failing.app)"
listing_set "$app"
sig_unsigned "$app"
arm_window "$app"
signer_fails
omc_run Notarize.run
check "the signing stage failed" "failed" "$(rail_state "$RAIL_SIGN_ID")"
check "the developer was told"   "1" "$(alerts_mention 'Signing failed')"
check "nothing was uploaded"     "0" "$(fake_calls xcrun)"
check "the submit stage was never reached" "pending" "$(rail_state "$RAIL_SUBMIT_ID")"
check_window_is_idle "after a signing failure"

section "the nested-code preflight blocks the upload"
# This is the defect that survives every other check: an ad-hoc nested item lets
# the bundle seal, passes the notary service, staples cleanly - and is then
# refused by Gatekeeper on every Mac it reaches. Catching it here costs a
# directory walk; catching it after stapling costs a release.
#
# The scenario has to be one where SIGNING DOES NOT FIX IT, or the preflight is
# never the thing that catches anything: resign_reason already refuses an ad-hoc
# nested item, so the pipeline signs, and a signer that fixes everything leaves
# nothing to preflight. signer_skips describes the case the check exists for -
# the signer reports success and the item is still ad-hoc afterwards.
app="$(make_app Adhoc.app)"
arm_window "$app"
sign_world_ok "$app"
sig_set "$app/Contents/Helpers/tool" --adhoc
signer_skips "$app/Contents/Helpers/tool"
omc_run Notarize.run
check "the run stopped at the signing stage" "failed" "$(rail_state "$RAIL_SIGN_ID")"
check "the alert says Gatekeeper would reject it" "1" \
    "$(alerts_mention 'Gatekeeper would reject this app even after notarization')"
check "nothing was uploaded" "0" "$(fake_calls xcrun)"
check "and the log names the offending item" "yes" \
    "$(log_says 'Contents/Helpers/tool - ad-hoc signature')"
check_window_is_idle "after a preflight failure"

# The signer ran and reported success. The preflight is what refused the result,
# which is the whole reason it runs after signing rather than instead of it.
check "the signer did run, and said it succeeded" "1" "$(signer_runs)"

section "the preflight runs even when the signing stage was skipped"
# The skip means the signature already matches the window, not that the artifact
# has been looked at - so the preflight has to run anyway. What it CANNOT do is
# be the first to catch an ad-hoc nested item: resign_reason walks the same
# listing and refuses one before the preflight is ever reached. So the claim
# here is the reachable one - that the walk happened - and the section that
# proves the preflight blocks an upload is the one above, where signing
# succeeded and left the item alone.
app="$(make_app SkipPreflight.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 0 "accepted"
omc_run Notarize.run
check "nothing was signed" "0" "$(signer_runs)"
check "but the nested code was still walked" "yes" \
    "$(log_says 'Preflight: all nested code carries a certificate chain')"
check "and the run went through" "done" "$(rail_state "$RAIL_VALIDATE_ID")"

section "a rejected notarization fetches the log and shows the issues"
app="$(make_app Invalid.app)"
arm_window "$app"
sign_world_ok "$app"
notary_submit_result Invalid
notary_log_issues "Archive contains critical validation errors" \
    "error:The binary is not signed with a valid Developer ID certificate.:Invalid.app/Contents/MacOS/Invalid" \
    "error:The signature does not include a secure timestamp.:Invalid.app"
omc_run Notarize.run
check "the submit stage failed"      "failed" "$(rail_state "$RAIL_SUBMIT_ID")"
check "the ticket was never stapled" "pending" "$(rail_state "$RAIL_STAPLE_ID")"
check "the log summary is shown"     "yes" \
    "$(log_says 'Summary: Archive contains critical validation errors')"
check "both issues are listed"       "yes" "$(log_says 'Issues (2):')"
check "with severity, message and path" "yes" \
    "$(log_says '\[error\] The signature does not include a secure timestamp')"
check "the developer was told to look at them" "1" \
    "$(alerts_mention 'See the issues in the log')"
check_window_is_idle "after a rejected notarization"

section "a submission that never returns a status fails cleanly"
app="$(make_app NoStatus.app)"
arm_window "$app"
sign_world_ok "$app"
notary_submit_fails
omc_run Notarize.run
check "the submit stage failed" "failed" "$(rail_state "$RAIL_SUBMIT_ID")"
check "the log says no status came back" "yes" "$(log_says 'no status returned')"
check "the developer was told" "1" "$(alerts_mention 'Notarization submission failed')"
check_window_is_idle "after a failed submission"

section "stapling failure is reported, and the run stops there"
app="$(make_app Staple.app)"
arm_window "$app"
sign_world_ok "$app"
stapler_fails staple
omc_run Notarize.run
check "the submit stage still succeeded" "done" "$(rail_state "$RAIL_SUBMIT_ID")"
check "the staple stage failed"          "failed" "$(rail_state "$RAIL_STAPLE_ID")"
check "Reveal in Finder stayed hidden"   "0" "$(ui_visible "$REVEAL_BTN_ID")"
check "the developer was told"           "1" "$(alerts_mention 'Stapling the ticket failed')"
check_window_is_idle "after a stapling failure"

section "stapled but rejected by Gatekeeper does not claim success"
app="$(make_app Rejected.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 3 "$app: rejected"
omc_run Notarize.run
check "the staple stage succeeded"     "done" "$(rail_state "$RAIL_STAPLE_ID")"
check "the validate stage failed"      "failed" "$(rail_state "$RAIL_VALIDATE_ID")"
# Saying "ready for distribution" here would contradict the log and the red rail
# icon, and this is exactly the outcome someone needs to be told about.
check "the status line says so plainly" "Stapled, but Gatekeeper rejected it." \
    "$(ui_value "$STATUS_ID")"
check "and so does the notification"   "1" \
    "$(notify_mention 'Rejected.app was stapled, but Gatekeeper rejected it')"
# The phrase the happy path DOES write to the log - "ready for distribution"
# never reaches it at all, so a check against that string could not fail either
# way.
check "the log does not claim the result is ready" "no" \
    "$(log_says 'Accepted, stapled, and ready at')"

section "a package goes through its own path"
pkg="$(make_pkg Suite.pkg com.example.suite)"
# AFTER arm_window: it resets the fake world, so a signature described first is
# wiped before the run ever asks about it - and the package then goes down the
# unsigned path this section was written to skip.
arm_window "$pkg"
pkg_sig_signed "$pkg" "$INSTALLER_ID"
spctl_set "$pkg" 0 "accepted"
omc_run Notarize.run
check "the run succeeded" "done" "$(rail_state "$RAIL_VALIDATE_ID")"
# The notary service accepts a flat .pkg directly; zipping one would only slow
# the upload down.
check "the package itself was uploaded" "$(canonical "$pkg")" "$(ntz_call upload_path)"
check "no archive was built"            "no" \
    "$([ -f "$(state_dir_path)/upload.zip" ] && echo yes || echo no)"
check "the log says no archive was needed" "yes" "$(log_says 'no archive needed')"
check "codesign was never consulted about a package" "0" "$(fake_calls codesign)"

section "with no identity selected, an acceptable signature still goes through"
app="$(make_app NoIdentity.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 0 "accepted"
# The last row is "Don't Code-sign". Notarizing does not require us to be the
# ones who signed it - only that the artifact carries a valid Developer ID
# signature - so this must not be refused outright.
omc_control "$IDENTITY_PICKER_ID" 2
omc_run Notarize.run
check "the signing stage was skipped" "skipped" "$(rail_state "$RAIL_SIGN_ID")"
check "the log says what was not signed and why" "yes" "$(log_says 'Not signing:')"
check "naming the picker row rather than blaming the keychain" "yes" \
    "$(log_says "\"$(ntz_eval 'printf %s "$NO_SIGN_OPTION"')\" is selected")"
check "and the run still finished" "done" "$(rail_state "$RAIL_VALIDATE_ID")"

section "with no identity AND an unacceptable signature, the run refuses"
app="$(make_app Bad.app)"
listing_set "$app"
sig_unsigned "$app"
arm_window "$app"
omc_control "$IDENTITY_PICKER_ID" 2
omc_run Notarize.run
check "the signing stage failed" "failed" "$(rail_state "$RAIL_SIGN_ID")"
check "nothing was uploaded"     "0" "$(fake_calls xcrun)"
check "the alert says both halves: what was not signed, and why it cannot go" "1" \
    "$(alerts_mention 'cannot be notarized as it is')"
check_window_is_idle "after refusing an unsignable target"

section "with no certificate at all, the reason blames the keychain"
app="$(make_app NoCert.app)"
listing_set "$app"
sig_unsigned "$app"
reset_document
identities_none codesigning
ntz_call known_profiles_add notary-team >/dev/null
omc_object "$app"
omc_run Notarize.main.init
omc_control "$IDENTITY_PICKER_ID" 1
omc_control "$PROFILE_PICKER_ID" 1
omc_run Notarize.run
# The advice stays the same for both reasons on purpose: "pick an identity" is
# not actionable when there is nothing to pick.
check "the log says no certificate is available" "yes" \
    "$(log_says 'no Developer ID Application certificate is available')"
check "rather than claiming a row was selected" "no" \
    "$(log_says 'is selected in the signing identity picker')"

section "Sign Only never skips a signature that already matches"
app="$(make_app SignOnly.app)"
arm_window "$app"
sign_world_ok "$app"
omc_run Notarize.sign
check_status "the handler ran" 0
# The full pipeline consults resign_reason and can skip; this handler exists
# because the developer clicked the button, and answering an explicit press by
# doing nothing would be worse than a redundant signature.
check "it signed anyway" "1" "$(signer_runs)"
check "the rail stage is done" "done" "$(rail_state "$RAIL_SIGN_ID")"
check "the status line confirms it" "Signed for release." "$(ui_value "$STATUS_ID")"
check "the spinner is hidden again" "0" "$(ui_visible "$PROGRESS_ID")"

section "Sign Only says which of the two reasons stopped it"
app="$(make_app WhyNot.app)"
arm_window "$app"
sign_world_ok "$app"
omc_control "$IDENTITY_PICKER_ID" 2
omc_run Notarize.sign
check "a chosen decline names the picker row" "1" \
    "$(alerts_mention 'is selected. Pick a signing identity')"
check "and nothing was signed" "0" "$(signer_runs)"

reset_document
identities_none codesigning
app="$(make_app NoCertSign.app)"
omc_object "$app"
omc_run Notarize.main.init
omc_control "$IDENTITY_PICKER_ID" 1
omc_run Notarize.sign
check "an empty keychain names the certificate class" "1" \
    "$(alerts_mention 'No Developer ID Application certificate is available')"

section "Submit and Wait, on its own"
app="$(make_app Submit.app)"
arm_window "$app"
sign_world_ok "$app"
omc_run Notarize.submit
check "the stage succeeded" "done" "$(rail_state "$RAIL_SUBMIT_ID")"
check "the status line points at the next step" "Accepted. Run Staple Ticket next." \
    "$(ui_value "$STATUS_ID")"
check_window_is_idle "after a standalone submit"

section "Staple Ticket, on its own"
app="$(make_app StapleOnly.app)"
arm_window "$app"
sign_world_ok "$app"
omc_run Notarize.staple
check "the stage succeeded" "done" "$(rail_state "$RAIL_STAPLE_ID")"
check "Reveal in Finder appeared" "1" "$(ui_visible "$REVEAL_BTN_ID")"
check "stapler was asked to staple" "yes" "$(fake_arg xcrun staple 1)"
check "the spinner is hidden again" "0" "$(ui_visible "$PROGRESS_ID")"

reset_document
omc_run Notarize.staple
check "with no target it asks for one instead" "1" \
    "$(alerts_mention 'Choose an app or installer package first')"

section "Validate Result reports both halves of the assessment"
app="$(make_app Validate.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 0 "accepted"
omc_run Notarize.validate
check "the stage succeeded" "done" "$(rail_state "$RAIL_VALIDATE_ID")"
check "the log has the stapler output" "yes" "$(log_says 'stapler validate:')"
check "and the Gatekeeper assessment" "yes" "$(log_says 'Gatekeeper assessment')"

arm_window "$app"
spctl_set "$app" 3 "$app: rejected"
omc_run Notarize.validate
check "a rejection fails the stage" "failed" "$(rail_state "$RAIL_VALIDATE_ID")"

section "Inspect Signature is a diagnostic, not a pipeline stage"
app="$(make_app Inspect.app)"
arm_window "$app"
sign_world_ok "$app"
spctl_set "$app" 0 "accepted"
omc_run Notarize.check
check "it reported the code signature"   "yes" "$(log_says 'codesign -dv --verbose=4')"
check "it verified it"                   "yes" "$(log_says 'Code signature is valid')"
check "it ran the nested-code preflight" "yes" \
    "$(log_says 'all nested code carries a certificate chain')"
check "it asked Gatekeeper"              "yes" "$(log_says 'Gatekeeper assessment')"
check "and reported the staple status"   "yes" "$(log_says 'Staple status:')"
# It is not a pipeline stage, so it must not move the rail - a green Sign icon
# after an inspection would claim something that never happened.
check "the sign stage was never marked at all" "untouched" "$(rail_state "$RAIL_SIGN_ID")"

section "Inspect Signature uses pkgutil for a package, not codesign"
pkg="$(make_pkg Inspect.pkg com.example.inspectpkg)"
arm_window "$pkg"
pkg_sig_signed "$pkg" "$INSTALLER_ID"
spctl_set "$pkg" 0 "accepted"
omc_run Notarize.check
check "the package signature was checked" "yes" \
    "$(log_says 'Checking installer package signature')"
# codesign knows nothing about a flat package, so asking it would produce an
# error that reads like a broken package.
check "codesign was not asked" "0" "$(fake_calls codesign)"

section "Fetch Log needs a submission and a profile"
reset_document
identities_set codesigning "$IDENTITY"
omc_run Notarize.main.init
omc_run Notarize.log
check "with no submission it says so" "1" \
    "$(alerts_mention 'No previous submission in this window')"
check "and nothing was fetched" "0" "$(fake_calls xcrun)"

app="$(make_app FetchLog.app)"
arm_window "$app"
sign_world_ok "$app"
omc_run Notarize.submit
alerts_reset
notary_log_issues "Package Approved"
omc_run Notarize.log
check "the log was fetched for the recorded submission" "yes" \
    "$(fake_arg xcrun "$(ntz_call submission_id)" "$(fake_calls xcrun)")"
check "and its summary reached the window" "yes" "$(log_says 'Summary: Package Approved')"
check "the spinner is hidden again" "0" "$(ui_visible "$PROGRESS_ID")"

section "Stop cancels a run in progress and gives the window back"
app="$(make_app Cancel.app)"
arm_window "$app"
sign_world_ok "$app"
# A real child process, so the kill is a real kill rather than an assertion
# about a number in a file. It is a sleep this test owns, in this test's own
# process group, and the handler is only ever given its pid.
#
# The pid file is written by the test rather than by a run, and that is a gap
# stated rather than papered over: every exit path of Notarize.run calls finish,
# which removes it, so a run's own pid write is not observable once the handler
# has returned. What is tested here is that Stop acts correctly on a pid file
# that exists - not that the pipeline created one.
/bin/sleep 30 &
victim=$!
printf '%s' "$victim" > "$(state_dir_path)/run.pid"
pb_set "$(pb_busy_key)" 1
# Put the window into the state a RUN leaves it in, or "Stop gave the window
# back" asserts about controls that were already that way and the check cannot
# fail. main.init leaves Notarize enabled and Stop disabled - the opposite.
ntz_call enable_view "$NOTARIZE_BTN_ID" 0
ntz_call enable_view "$CANCEL_BTN_ID" 1
check "the window really is mid-run to begin with" "0" "$(ui_enabled "$NOTARIZE_BTN_ID")"
omc_run Notarize.cancel
check_status "the handler ran" 0
check_exists "the canceled marker was written" "$(state_dir_path)/canceled"
check "the process was signalled" "yes" \
    "$(omc_wait_for "! /bin/kill -0 $victim 2>/dev/null" && echo yes || echo no)"
check_absent "the pid file was removed" "$(state_dir_path)/run.pid"
check "the busy flag was cleared" "" "$(busy)"
check "Notarize is usable again"  "1" "$(ui_enabled "$NOTARIZE_BTN_ID")"
check "Stop is disabled again"    "0" "$(ui_enabled "$CANCEL_BTN_ID")"
check "the status line says so"   "Canceled." "$(ui_value "$STATUS_ID")"
check "and the log records it"    "yes" "$(log_says 'Canceled by user')"
# pkill matches every command line on the system, so it is only ever handed the
# one path this window owns.
check "pkill was aimed at this window's archive alone" "$(state_dir_path)/upload.zip" \
    "$(fake_arg_after pkill -f)"
wait "$victim" 2>/dev/null

section "Reveal in Finder opens the artifact the pipeline produced"
app="$(make_app Reveal.app)"
arm_window "$app"
sign_world_ok "$app"
omc_run Notarize.reveal
check "the Finder was asked to reveal it" "yes" "$(fake_arg open "$app" 1)"
check "with -R, not -a"                   "yes" "$(fake_arg open -R 1)"

reset_document
omc_run Notarize.reveal
check "with nothing chosen it does nothing" "0" "$(fake_calls open)"

section "closing the window sweeps its state"
app="$(make_app Close.app)"
arm_window "$app"
sign_world_ok "$app"
pb_set "$(pb_busy_key)" 1
pb_set "$(pb_submission_key)" some-id
check_exists "the state directory is there to begin with" "$(target_file)"
omc_run Notarize.window.close
check_absent "the whole state directory is gone" "$(state_dir_path)"
check "the busy flag was cleared"       "" "$(busy)"
check "the submission key was cleared"  "" "$(pb_get "$(pb_submission_key)")"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
