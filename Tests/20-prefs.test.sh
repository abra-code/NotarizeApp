#!/bin/sh
# Tests/20-prefs.test.sh - what the window remembers, and how a picker's 1-based
# index gets back to a name.
#
# Both halves are places where being subtly wrong is invisible. A picker is
# bound to a POSITION in its option list, so replacing the list without
# rewriting the index silently selects whatever now occupies that slot - and the
# thing selected is the certificate an artifact gets signed with. The prefs half
# decides which settings follow a product and which are global defaults.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.notarize.sh"

IDENTITY_A="Developer ID Application: Test Developer (TEAMID1234)"
IDENTITY_B="Developer ID Application: Other Developer (OTHER56789)"
INSTALLER_ID="Developer ID Installer: Test Developer (TEAMID1234)"
NO_SIGN_OPTION="$(ntz_eval 'printf %s "$NO_SIGN_OPTION"')"
NO_SIGN_PREF="$(ntz_eval 'printf %s "$NO_SIGN_PREF"')"

section "the settings key follows the product, not the file name"
reset_document
app="$(make_app Widget.app com.example.widget)"
ntz_call set_target "$app"
check "an app is keyed by its bundle identifier" "com.example.widget" \
    "$(ntz_call app_prefs_key)"

# The identifier is read out of a real xar archive with the tool the applet
# uses, because pulling it out without expanding the payload is the whole job of
# package_identifier. A stub file would leave that function untested while every
# assertion about it still passed.
pkg="$(make_pkg Widget.pkg com.example.widget.installer)"
ntz_call set_target "$pkg"
check "a bare pkgbuild package is keyed by its PackageInfo identifier" \
    "com.example.widget.installer" "$(ntz_call app_prefs_key)"

dist="$(make_distribution_pkg Suite.pkg com.example.suite.dist)"
ntz_call set_target "$dist"
check "a productbuild package is keyed by its Distribution pkg-ref" \
    "com.example.suite.dist" "$(ntz_call app_prefs_key)"

nameless="$OMCTEST_WORK/Nameless.app"
/bin/rm -rf "$nameless"
/bin/mkdir -p "$nameless/Contents"
ntz_call set_target "$nameless"
check "an app with no Info.plist falls back to its file name" "Nameless.app" \
    "$(ntz_call app_prefs_key)"

section "the key is cached, and set_target invalidates the cache"
reset_document
ntz_call set_target "$app"
ntz_call app_prefs_key >/dev/null
check_exists "the cache file was written" "$(prefs_key_cache)"
check "it records the target it was computed for" "$app" \
    "$(/usr/bin/sed -n 1p "$(prefs_key_cache)")"
# Switching targets has to drop it. Without that, a package's settings would be
# written under the previous target's key - the cache is two lines precisely so
# a stale one can be detected rather than trusted.
ntz_call set_target "$pkg"
check_absent "switching the target dropped the cache" "$(prefs_key_cache)"
check "and the key is recomputed for the new target" "com.example.widget.installer" \
    "$(ntz_call app_prefs_key)"

section "known profiles: added once, and answered about exactly"
reset_document
ntz_call known_profiles_add notary-team >/dev/null
ntz_call known_profiles_add notary-team >/dev/null
ntz_call known_profiles_add notary-ci >/dev/null
check "a repeated name is not appended twice" "2" "$(prefs_count /known_profiles)"
check "the first is remembered"  "yes" "$(ntz_is known_profile notary-team)"
check "the second too"           "yes" "$(ntz_is known_profile notary-ci)"
check "an unknown name is not"   "no"  "$(ntz_is known_profile notary-nope)"
# A name starting with a dash would be read as grep's own options: "grep -q -x
# -F -v" leaves grep with no pattern at all, so it exits 2 - which reads here as
# a confident "no". The -e in the applet is what stops that.
ntz_call known_profiles_add -weird >/dev/null
check "a name starting with a dash is still answered correctly" "yes" \
    "$(ntz_is known_profile -weird)"
check "and an unknown dashed name is still no" "no" \
    "$(ntz_is known_profile -other)"

section "a profile name has to be usable by notarytool"
check "an empty name is refused"     "Enter a profile name." \
    "$(ntz_call profile_name_problem "")"
check "so is one made only of spaces" "Enter a profile name that is more than spaces." \
    "$(ntz_call profile_name_problem "   ")"
check "a line break is refused"      "A profile name cannot contain a line break." \
    "$(ntz_call profile_name_problem "a
b")"
# notarytool reads a leading dash as one of its own options and answers "Missing
# value for '--keychain-profile'", so such a name can never be stored or used.
check "a leading dash is refused"    "A profile name cannot start with a dash." \
    "$(ntz_call profile_name_problem "-p")"
check "an ordinary name has no problem" "" "$(ntz_call profile_name_problem "notary-team")"

section "the identity picker resolves an index to a name"
reset_document
identities_set codesigning "$IDENTITY_A" "$IDENTITY_B"
ntz_call set_target "$app"
ntz_call refresh_identity_picker "" >/dev/null
check "both certificates plus the decline row are offered" \
    "[\"$IDENTITY_A\",\"$IDENTITY_B\",\"$NO_SIGN_OPTION\"]" \
    "$(ui_prop "$IDENTITY_PICKER_ID" options)"
omc_control "$IDENTITY_PICKER_ID" 1
check "index 1 is the first certificate"  "$IDENTITY_A" "$(ntz_call selected_identity)"
omc_control "$IDENTITY_PICKER_ID" 2
check "index 2 is the second"             "$IDENTITY_B" "$(ntz_call selected_identity)"
omc_control "$IDENTITY_PICKER_ID" 3
check "index 3 - the decline row - is no identity" "" "$(ntz_call selected_identity)"
# The decline row's line in the map is empty, so it can never collide with a
# certificate name however that name is spelled.
check "and that row IS a deliberate choice here" "yes" \
    "$(ntz_is signing_declined_by_choice)"

section "a remembered certificate that is gone falls back to the default, not to position 1"
reset_document
identities_set codesigning "$IDENTITY_A" "$IDENTITY_B"
ntz_call set_target "$app"
ntz_call prefs_set default_identity "$IDENTITY_B" >/dev/null
# The per-target override names a certificate that is no longer installed.
ntz_call refresh_identity_picker "Developer ID Application: Vanished (GONE12345)" >/dev/null
check "the default for this kind was selected" "2" "$(ui_value "$IDENTITY_PICKER_ID")"
omc_control "$IDENTITY_PICKER_ID" "$(ui_value "$IDENTITY_PICKER_ID")"
check "which resolves to the remembered default" "$IDENTITY_B" \
    "$(ntz_call selected_identity)"
# Landing on position 1 would hand the target a certificate nobody picked, and
# save_app_settings would then write it back as a per-target override - so the
# wrong answer here is sticky.
check "not the first certificate in the list" "no" \
    "$([ "$(ntz_call selected_identity)" = "$IDENTITY_A" ] && echo yes || echo no)"

section "the two target kinds draw from different certificate classes"
reset_document
identities_set codesigning "$IDENTITY_A"
identities_set basic "$INSTALLER_ID"
ntz_call set_target "$app"
ntz_call refresh_identity_picker "" >/dev/null
check "an app offers the Application certificate" \
    "[\"$IDENTITY_A\",\"$NO_SIGN_OPTION\"]" "$(ui_prop "$IDENTITY_PICKER_ID" options)"
ntz_call set_target "$pkg"
ntz_call refresh_identity_picker "" >/dev/null
check "a package offers the Installer certificate" \
    "[\"$INSTALLER_ID\",\"$NO_SIGN_OPTION\"]" "$(ui_prop "$IDENTITY_PICKER_ID" options)"
check "the certificate class a package needs is named for error messages" \
    "Developer ID Installer" "$(ntz_call required_certificate_class)"
ntz_call set_target "$app"
check "and an app names the other one" \
    "Developer ID Application" "$(ntz_call required_certificate_class)"

section "each kind remembers its own default identity"
check "an app's default lives under default_identity" "default_identity" \
    "$(ntz_call default_identity_key app)"
check "a package's under default_installer_identity" "default_installer_identity" \
    "$(ntz_call default_identity_key pkg)"

section "\"Don't Code-sign\" is selected when it is what was remembered"
reset_document
identities_set codesigning "$IDENTITY_A" "$IDENTITY_B"
ntz_call set_target "$app"
ntz_call refresh_identity_picker "$NO_SIGN_PREF" >/dev/null
check "the last row is selected" "3" "$(ui_value "$IDENTITY_PICKER_ID")"
omc_control "$IDENTITY_PICKER_ID" 3
check "which is the decline row" "" "$(ntz_call selected_identity)"

section "declining is only remembered when it was actually chosen"
reset_document
identities_set codesigning "$IDENTITY_A"
ntz_call set_target "$app"
ntz_call refresh_identity_picker "" >/dev/null
omc_control "$IDENTITY_PICKER_ID" 2
ntz_call save_app_settings >/dev/null
check "the decline was recorded for this target" "$NO_SIGN_PREF" \
    "$(prefs_value "/apps/com.example.widget/identity")"
# It is a statement about one artifact that re-signing would damage, not a
# preference about signing in general, so it must never become the global
# default - a target never seen before should still default to signing.
check "but never promoted to the global default" "" "$(prefs_value /default_identity)"

section "an empty identity that was NOT chosen records nothing"
reset_document
identities_none codesigning
ntz_call set_target "$app"
ntz_call refresh_identity_picker "" >/dev/null
# The picker offered one row, so selecting it was the absence of a choice
# rather than a choice. Recording it would pin the target to "Don't Code-sign"
# over a keychain that simply had nothing in it at that moment.
omc_control "$IDENTITY_PICKER_ID" 1
ntz_call save_app_settings >/dev/null
check "nothing was written for this target" "" \
    "$(prefs_value "/apps/com.example.widget/identity")"

section "the first identity used becomes the global default"
reset_document
identities_set codesigning "$IDENTITY_A" "$IDENTITY_B"
ntz_call set_target "$app"
ntz_call refresh_identity_picker "" >/dev/null
omc_control "$IDENTITY_PICKER_ID" 1
ntz_call save_app_settings >/dev/null
check "it was promoted to the global default" "$IDENTITY_A" \
    "$(prefs_value /default_identity)"
check "and NOT duplicated as a per-target override" "" \
    "$(prefs_value "/apps/com.example.widget/identity")"

section "a target that differs from the default gets an override"
omc_control "$IDENTITY_PICKER_ID" 2
ntz_call save_app_settings >/dev/null
check "the global default is unchanged" "$IDENTITY_A" "$(prefs_value /default_identity)"
check "and this target records its own"  "$IDENTITY_B" \
    "$(prefs_value "/apps/com.example.widget/identity")"

section "the profile picker resolves an index the same way"
reset_document
ntz_call known_profiles_add notary-team >/dev/null
ntz_call known_profiles_add notary-ci >/dev/null
ntz_call set_target "$app"
ntz_call refresh_profile_picker "" >/dev/null
check "both profiles are offered" '["notary-team","notary-ci"]' \
    "$(ui_prop "$PROFILE_PICKER_ID" options)"
omc_control "$PROFILE_PICKER_ID" 2
check "index 2 resolves to the second" "notary-ci" "$(ntz_call selected_profile)"
ntz_call refresh_profile_picker notary-ci >/dev/null
check "naming a profile selects its position" "2" "$(ui_value "$PROFILE_PICKER_ID")"
# A name that is not in the list must not leave the previous index standing:
# the list can be replaced under it, and the index would then point at whichever
# profile now occupies that slot.
ntz_call refresh_profile_picker notary-gone >/dev/null
check "an unknown name falls back to position 1, explicitly" "1" \
    "$(ui_value "$PROFILE_PICKER_ID")"

section "with no profiles at all the picker is empty and resolves to nothing"
reset_document
ntz_call set_target "$app"
ntz_call refresh_profile_picker "" >/dev/null
check "no options" "[]" "$(ui_prop "$PROFILE_PICKER_ID" options)"
omc_control "$PROFILE_PICKER_ID" 1
check "and nothing is selected" "" "$(ntz_call selected_profile)"

section "the output folder and entitlements are per target only"
reset_document
ntz_call set_target "$app"
omc_control "$OUTPUT_FIELD_ID" "$OMCTEST_WORK/Release"
ent="$(make_entitlements Widget.entitlements com.apple.security.app-sandbox)"
omc_control "$ENTITLEMENTS_FIELD_ID" "$ent"
ntz_call save_app_settings >/dev/null
check "the output folder is stored under the app's key" "$OMCTEST_WORK/Release" \
    "$(prefs_value "/apps/com.example.widget/output_dir")"
check "the entitlements file too" "$ent" \
    "$(prefs_value "/apps/com.example.widget/entitlements")"
check "neither becomes a global default" "" "$(prefs_value /output_dir)"

section "a package never stores an entitlements setting"
reset_document
ntz_call set_target "$pkg"
omc_control "$ENTITLEMENTS_FIELD_ID" "$ent"
omc_control "$OUTPUT_FIELD_ID" "$OMCTEST_WORK/Release"
ntz_call save_app_settings >/dev/null
check "the output folder is still remembered" "$OMCTEST_WORK/Release" \
    "$(prefs_value "/apps/com.example.widget.installer/output_dir")"
# A package has no entitlements, so a value left in the field by a previous app
# must not be written against it - it would come back the next time the package
# was chosen and mean nothing.
check "but no entitlements were written for it" "" \
    "$(prefs_value "/apps/com.example.widget.installer/entitlements")"

section "with no target chosen, nothing is written at all"
reset_document
omc_control "$OUTPUT_FIELD_ID" "$OMCTEST_WORK/Release"
ntz_call save_app_settings >/dev/null
check "no per-app dictionary was created" "" "$(prefs_count /apps)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
