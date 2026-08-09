#!/bin/sh
# Tests/10-window.test.sh - the document window: opening it on a target, and the
# two Browse panels that fill in the settings around that target.
#
# The window is a single-document window. Its one target arrives as OMC_OBJ_PATH
# and is stored by window init; nothing in the window can replace it afterwards.
#
# Everything here is about what the developer sees before anything is signed.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.notarize.sh"

APP_IDENTITY="Developer ID Application: Test Developer (TEAMID1234)"
PKG_IDENTITY="Developer ID Installer: Test Developer (TEAMID1234)"

section "the window opens with no target at all"
reset_document
identities_set codesigning "$APP_IDENTITY"
identities_set basic "$PKG_IDENTITY"
omc_run Notarize.main.init
check_status "init ran" 0
# The window has no target field of its own: it is a single-document window, so
# the title bar names the object it was opened on and nothing repeats it inside.
# That makes the status line the ONLY place a no-target window can say so, and
# the only place it can say how to get one - by opening a new window.
check "the status line names the way out" \
    "Nothing to notarize. Drop a .app or a flat .pkg on the Notarize icon." \
    "$(ui_value "$STATUS_ID")"
check "Notarize is disabled with no target" "0" "$(ui_enabled "$NOTARIZE_BTN_ID")"
check "Stop is disabled"                    "0" "$(ui_enabled "$CANCEL_BTN_ID")"
check "the progress spinner is hidden"      "0" "$(ui_visible "$PROGRESS_ID")"
check "Reveal in Finder is hidden"          "0" "$(ui_visible "$REVEAL_BTN_ID")"
# The settings are off as well, not just the actions. They are stored per
# product, and with no target app_prefs_key is empty and app_pref_set returns
# early - so anything typed or browsed into these two fields would be accepted
# and then silently dropped. A window that cannot keep a setting must not offer
# to take one.
check "the entitlements field is disabled" "0" "$(ui_enabled "$ENTITLEMENTS_FIELD_ID")"
check "its Browse button too"              "0" "$(ui_enabled "$ENTITLEMENTS_BROWSE_ID")"
check "the output folder field is disabled" "0" "$(ui_enabled "$OUTPUT_FIELD_ID")"
check "its Browse button too"               "0" "$(ui_enabled "$OUTPUT_BROWSE_ID")"
# Every step button, and both diagnostics, are off until there is something to
# act on. Named individually rather than as a count: rail_enable walks a list,
# and a list that lost an entry would still "enable some buttons".
for _rail_btn in $RAIL_BTN_IDS $INSPECT_BTN_ID $FETCHLOG_BTN_ID; do
    check "step/diagnostic button $_rail_btn is disabled" "0" "$(ui_enabled "$_rail_btn")"
done

section "init fills the pickers from the keychain and from prefs"
# The identity picker draws from the CODESIGNING policy while no target is
# chosen, because current_kind is empty and only a package uses "basic".
check "the identity picker was asked for the codesigning policy" "yes" \
    "$(fake_arg security codesigning 1)"
check "its options carry the certificate and the decline row" \
    "[\"$APP_IDENTITY\",\"$(ntz_eval 'printf %s "$NO_SIGN_OPTION"')\"]" \
    "$(ui_prop "$IDENTITY_PICKER_ID" options)"
# The map the picker's 1-based index resolves through. The decline row occupies
# an empty line so that no certificate name can ever collide with it.
check "the index-to-name map has a row per option" "2" \
    "$(/usr/bin/grep -c '' "$(identities_map)")"
check "the first row is the certificate" "$APP_IDENTITY" \
    "$(/usr/bin/sed -n 1p "$(identities_map)")"
check "the decline row resolves to no identity" "" \
    "$(/usr/bin/sed -n 2p "$(identities_map)")"
check "index 1 is selected when nothing is remembered" "1" \
    "$(ui_value "$IDENTITY_PICKER_ID")"
check "the profile picker has no options yet" "[]" \
    "$(ui_prop "$PROFILE_PICKER_ID" options)"

section "with no certificate at all, the decline row is the only option"
reset_document
identities_none codesigning
omc_run Notarize.main.init
check "the picker offers only the decline row" \
    "[\"$(ntz_eval 'printf %s "$NO_SIGN_OPTION"')\"]" \
    "$(ui_prop "$IDENTITY_PICKER_ID" options)"
check "the map has exactly one row" "1" "$(/usr/bin/grep -c '' "$(identities_map)")"
# The distinction save_app_settings depends on: selecting the only row on offer
# is not a choice, so it must not be remembered as one.
omc_control "$IDENTITY_PICKER_ID" 1
check "declining is not a CHOICE when nothing else was offered" "no" \
    "$(ntz_is signing_declined_by_choice)"

section "opening an app seeds the target"
reset_document
identities_set codesigning "$APP_IDENTITY"
app="$(make_app Sample.app com.example.sample)"
omc_object "$app"
omc_run Notarize.main.init
check "the target was stored"        "$app" "$(stored_target)"
# The stored target is the full path, because that is what the pipeline acts on.
# The window shows only the basename, in the status line - the full path belongs
# to the title bar, which OMC fills from the opened object.
check "the status line names it"     "Ready: Sample.app" "$(ui_value "$STATUS_ID")"
check "Notarize is enabled"          "1"    "$(ui_enabled "$NOTARIZE_BTN_ID")"
check "the entitlements field is usable for an app" "1" \
    "$(ui_enabled "$ENTITLEMENTS_FIELD_ID")"
check "and so is its Browse button" "1" "$(ui_enabled "$ENTITLEMENTS_BROWSE_ID")"

section "opening a package seeds it too, and says which kind it is"
reset_document
identities_set codesigning "$APP_IDENTITY"
identities_set basic "$PKG_IDENTITY"
pkg="$(make_pkg Sample.pkg com.example.sample.pkg)"
omc_object "$pkg"
omc_run Notarize.main.init
check "the target was stored" "$pkg" "$(stored_target)"
check "the status line says installer package" \
    "Ready: Sample.pkg (installer package)" "$(ui_value "$STATUS_ID")"
# A package has no entitlements and no hardened runtime, so the field cannot
# affect the outcome. Disabled rather than hidden - ActionUI's "hidden" keeps
# the row's space, which would leave an unexplained gap.
check "the entitlements field is disabled" "0" "$(ui_enabled "$ENTITLEMENTS_FIELD_ID")"
check "its Browse button too"              "0" "$(ui_enabled "$ENTITLEMENTS_BROWSE_ID")"
check "and the field was cleared"          ""  "$(ui_value "$ENTITLEMENTS_FIELD_ID")"
# The certificate classes are not interchangeable: productsign rejects an
# Application certificate, and an Installer one does not appear under the
# codesigning policy at all. Asking the wrong policy is a bug that looks like
# an empty keychain, so the policy itself is asserted.
check "a package's identities come from the basic policy" "yes" \
    "$(fake_arg security basic "$(fake_calls security)")"
check "the picker offers the installer certificate" \
    "[\"$PKG_IDENTITY\",\"$(ntz_eval 'printf %s "$NO_SIGN_OPTION"')\"]" \
    "$(ui_prop "$IDENTITY_PICKER_ID" options)"

section "opening something unsupported leaves the window empty"
reset_document
identities_set codesigning "$APP_IDENTITY"
plain="$OMCTEST_WORK/notes.txt"
printf 'not an app\n' > "$plain"
omc_object "$plain"
omc_run Notarize.main.init
check "no target was stored" "" "$(stored_target)"
# Not just "nothing happened": the window has to SAY it is empty, because its
# title bar names the file it was opened on and would otherwise be the only
# thing on screen, implying that file is loaded.
check "the status line says the window is empty" \
    "Nothing to notarize. Drop a .app or a flat .pkg on the Notarize icon." \
    "$(ui_value "$STATUS_ID")"
check "Notarize stays disabled" "0" "$(ui_enabled "$NOTARIZE_BTN_ID")"

section "the window is bound to the one target it was opened on"
# OMC takes the window's title and its proxy icon from the object the window was
# opened with, and no handler can update either afterwards. So a window that
# adopts a second target ends up with a title naming one app and fields
# describing another - which is exactly what an in-window drop target and a
# "Choose..." button used to produce here.
#
# Both are gone, and this section is what keeps them gone. These are assertions
# about the declarative files rather than about a running handler, which is
# unusual for this suite; they are here because a behavior check cannot express
# "and nothing else may set the target". Re-adding either affordance turns them
# red before it reaches a person.
check "the window declares no drop target" "0" \
    "$(/usr/bin/grep -c 'onDrop' "$(window_json)")"
check "no command routes a drop"           "0" \
    "$(/usr/bin/grep -c '"Notarize\.drop"' "$(command_json)")"
check "no command opens a target chooser"  "0" \
    "$(/usr/bin/grep -c '"Notarize\.choose\.app"' "$(command_json)")"
# The two Browse panels stay - they choose an entitlements file and an output
# folder, neither of which is the target. This is their positive control: a
# grep that had stopped matching anything would pass all three checks above.
check "the settings choosers are still declared" "2" \
    "$(/usr/bin/grep -c 'CHOOSE_FILE_DIALOG\|CHOOSE_FOLDER_DIALOG' "$(command_json)")"
# And the invariant those three checks exist to protect: exactly one call site.
#
# Counted rather than listed by filename, and counted across lib.notarize.sh as
# well as the handlers. Listing the handler files that call it looks equivalent
# and is not: pulling the two-line seeding sequence into a lib helper - the
# ordinary refactor here - would add a second writer that every handler could
# reach while the file list still read "Notarize.main.init.sh".
#
# "^[^#]*set_target " excludes the definition (no space after the name) and the
# one comment in the lib that mentions it, and unlike a quote-anchored pattern
# it still catches an unquoted "set_target $x".
check "there is exactly one call site that stores a target" "1" \
    "$(cd "$APP_SCRIPTS" && /usr/bin/grep -c '^[^#]*set_target ' Notarize.*.sh lib.notarize.sh \
       | /usr/bin/awk -F: '{ n += $2 } END { print n + 0 }')"
check "and it is window init" "Notarize.main.init.sh" \
    "$(cd "$APP_SCRIPTS" && /usr/bin/grep -l '^[^#]*set_target ' Notarize.*.sh lib.notarize.sh)"

section "the Browse panels fill their fields and remember the choice"
reset_document
identities_set codesigning "$APP_IDENTITY"
# In a subdirectory of its own, away from the *.entitlements files the fixtures
# leave in $OMCTEST_WORK. apply_app_settings falls back to detect_entitlements
# whenever the remembered path is empty or gone, and detect_entitlements takes
# the first *.entitlements sitting NEXT TO the app - so with the app and the
# entitlements file in one directory the fallback returns the same path the
# preference holds, and "the entitlements file came back" below passes whether
# the preference is read or not. Verified: with both in $OMCTEST_WORK, deleting
# the preference read outright left the whole file green.
apps_dir="$OMCTEST_WORK/apps"
browse_app="$(make_app Browse.app com.example.browse "$apps_dir")"
omc_object "$browse_app"
omc_run Notarize.main.init

outdir="$OMCTEST_WORK/Release"
/bin/mkdir -p "$outdir"
omc_dialog_answer choose_folder "$outdir"
omc_run Notarize.choose.output
check "the output field shows the folder" "$outdir" "$(ui_value "$OUTPUT_FIELD_ID")"
check "and it was remembered for this app" "$outdir" \
    "$(prefs_value "/apps/com.example.browse/output_dir")"

ent="$(make_entitlements Browse.entitlements com.apple.security.app-sandbox)"
omc_dialog_answer choose_file "$ent"
omc_run Notarize.choose.entitlements
check "the entitlements field shows the file" "$ent" \
    "$(ui_value "$ENTITLEMENTS_FIELD_ID")"
check "and it was remembered too" "$ent" \
    "$(prefs_value "/apps/com.example.browse/entitlements")"

# The positive control for the two absence checks below: this key IS there, so
# a prefs_value that silently read the wrong file would fail here rather than
# passing quietly everywhere.
check "the prefs file is where the test thinks it is" "yes" \
    "$([ -f "$(prefs_file_path)" ] && echo yes || echo no)"

section "canceling a Browse panel leaves the field alone"
omc_dialog_answer choose_folder ""
omc_run Notarize.choose.output
check "the output field is unchanged" "$outdir" "$(ui_value "$OUTPUT_FIELD_ID")"
omc_dialog_answer choose_file ""
omc_run Notarize.choose.entitlements
check "the entitlements field is unchanged" "$ent" "$(ui_value "$ENTITLEMENTS_FIELD_ID")"

section "settings come back when the same app is opened in a new window"
# reset_window, not reset_document: the preferences written above are exactly
# what this section is asserting survived, and reset_document would delete them
# and make the applet look broken.
reset_window
# Asserted before init runs, so that "the folder came back" below cannot be
# satisfied by a value the previous window left standing.
check "the new window starts with empty fields" "" "$(ui_value "$OUTPUT_FIELD_ID")"
identities_set codesigning "$APP_IDENTITY"
omc_object "$browse_app"
omc_run Notarize.main.init
# Keyed by CFBundleIdentifier rather than by path, so the settings follow the
# product even when the build lands somewhere else.
check "the output folder came back"     "$outdir" "$(ui_value "$OUTPUT_FIELD_ID")"
check "the entitlements file came back" "$ent"    "$(ui_value "$ENTITLEMENTS_FIELD_ID")"

section "a different app does not inherit them"
reset_window
identities_set codesigning "$APP_IDENTITY"
# Same subdirectory, for the same reason - and here it is load-bearing in the
# other direction: an Other.app sitting beside Browse.entitlements really would
# come up with that file in its field, because detect_entitlements' fallback
# matches any *.entitlements next to the app. That is the applet behaving as
# designed, but it would make this section assert the opposite of its name.
other="$(make_app Other.app com.example.other "$apps_dir")"
omc_object "$other"
omc_run Notarize.main.init
check "the output folder is its own (empty)"     "" "$(ui_value "$OUTPUT_FIELD_ID")"
check "and so is the entitlements field"         "" "$(ui_value "$ENTITLEMENTS_FIELD_ID")"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
