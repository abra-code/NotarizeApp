#!/bin/sh
# Tests/30-signing.test.sh - the decisions the applet makes about a signature.
#
# This is where a wrong answer is expensive rather than merely annoying. Saying
# "already signed correctly" when it is not sends an unsignable artifact to the
# notary service; saying it the other way round discards a signature the
# developer wanted kept. And prepare_release_copy holds an rm -rf whose target
# is decided by a path comparison.
#
# Every codesign, pkgutil, productsign and spctl answer here comes from the fake
# world in lib.test.notarize.sh. ditto, plutil, xar and the path logic run for
# real, because they are deterministic and safe, and running them for real is
# what makes these assertions worth anything.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.notarize.sh"

IDENTITY="Developer ID Application: Test Developer (TEAMID1234)"
OTHER_IDENTITY="Developer ID Application: Other Developer (OTHER56789)"
INSTALLER_ID="Developer ID Installer: Test Developer (TEAMID1234)"

section "what counts as a target"
reset_document
app="$(make_app Kind.app com.example.kind)"
pkg="$(make_pkg Kind.pkg com.example.kind.pkg)"
plain="$OMCTEST_WORK/notes.txt"
printf 'x\n' > "$plain"
bundle_pkg="$OMCTEST_WORK/Old.pkg"
/bin/mkdir -p "$bundle_pkg/Contents"
# A FILE whose name ends in .app. Without it the check below asserts about a
# path that does not exist, and passes whether target_kind_of tests -d or -e.
file_named_app="$OMCTEST_WORK/notes.txt.app"
printf 'not a bundle\n' > "$file_named_app"
check "a .app directory is an app"       "app" "$(ntz_call target_kind_of "$app")"
check "a flat .pkg file is a package"    "pkg" "$(ntz_call target_kind_of "$pkg")"
# An old bundle-style package is a DIRECTORY, and the notary service does not
# accept one. Reporting it here is what keeps it from failing at upload time.
check "a bundle-style .pkg is neither"   ""    "$(ntz_call target_kind_of "$bundle_pkg")"
check "a plain file is neither"          ""    "$(ntz_call target_kind_of "$plain")"
check "a .app name that is a FILE is neither" "" \
    "$(ntz_call target_kind_of "$file_named_app")"
check "an app is supported"     "yes" "$(ntz_is is_supported_target "$app")"
check "a package is supported"  "yes" "$(ntz_is is_supported_target "$pkg")"
check "a plain file is not"     "no"  "$(ntz_is is_supported_target "$plain")"
check "the bundle-style package gets its own explanation" "1" \
    "$(ntz_call unsupported_target_reason "$bundle_pkg" | /usr/bin/grep -c 'flat packages')"
check "everything else gets the generic one" "1" \
    "$(ntz_call unsupported_target_reason "$plain" | /usr/bin/grep -c 'application bundle')"

section "canonical_path resolves symlinks in every component"
reset_document
real_dir="$OMCTEST_WORK/real"
link_dir="$OMCTEST_WORK/linked"
/bin/rm -rf "$real_dir" "$link_dir"
/bin/mkdir -p "$real_dir"
/bin/ln -s "$real_dir" "$link_dir"
printf 'payload\n' > "$real_dir/thing.pkg"
/bin/ln -s "$real_dir/thing.pkg" "$OMCTEST_WORK/alias.pkg"
check "a directory resolves to its real path" "$(canonical "$real_dir")" \
    "$(ntz_call canonical_path "$link_dir")"
check "a symlinked file resolves to its target" \
    "$(canonical "$real_dir")/thing.pkg" \
    "$(ntz_call canonical_path "$OMCTEST_WORK/alias.pkg")"
check "a file reached through a symlinked directory resolves too" \
    "$(canonical "$real_dir")/thing.pkg" \
    "$(ntz_call canonical_path "$link_dir/thing.pkg")"
# A loop must FAIL rather than return the last hop. The answer feeds a
# destructive guard, and a confidently wrong path there is worse than no answer.
/bin/ln -s "$OMCTEST_WORK/loop-b.pkg" "$OMCTEST_WORK/loop-a.pkg"
/bin/ln -s "$OMCTEST_WORK/loop-a.pkg" "$OMCTEST_WORK/loop-b.pkg"
check "an ordinary path succeeds"      "yes" "$(ntz_is canonical_path "$real_dir")"
check "a symlink loop is a failure"    "no" "$(ntz_is canonical_path "$OMCTEST_WORK/loop-a.pkg")"
check "and prints nothing"             ""   "$(ntz_call canonical_path "$OMCTEST_WORK/loop-a.pkg" 2>/dev/null)"

section "the release copy: no output folder means sign in place"
reset_document
inplace="$(make_app InPlace.app com.example.inplace)"
work="$(ntz_call prepare_release_copy "$inplace" "")"
check "the target itself is returned" "$(ntz_call canonical_path "$inplace")" "$work"
check "and no copy was recorded"      "no" "$(ntz_is made_release_copy)"
check_absent "no release.txt was written" "$(release_file)"

section "an output folder that IS the target's folder is not a copy either"
reset_document
work="$(ntz_call prepare_release_copy "$inplace" "$OMCTEST_WORK")"
check "still the target itself" "$(ntz_call canonical_path "$inplace")" "$work"
check "still no copy"           "no" "$(ntz_is made_release_copy)"

section "and neither is one reached by a different spelling"
# The guard compares CANONICALIZED directories, because comparing raw strings
# would route the rm -rf below at the original app: an output folder spelled
# "<work>/" or reached through a symlink is the same directory.
reset_document
alias_out="$OMCTEST_WORK/out-alias"
/bin/rm -rf "$alias_out"
/bin/ln -s "$OMCTEST_WORK" "$alias_out"
work="$(ntz_call prepare_release_copy "$inplace" "$alias_out")"
check "the symlinked spelling is recognized as the same folder" \
    "$(ntz_call canonical_path "$inplace")" "$work"
check "so nothing was copied and nothing removed" "no" "$(ntz_is made_release_copy)"
check_exists "the original app is still there" "$inplace/Contents/Info.plist"

section "a real output folder gets a copy, and the pipeline works on it"
reset_document
outdir="$OMCTEST_WORK/Release30"
/bin/rm -rf "$outdir"
/bin/mkdir -p "$outdir"
# The applet canonicalizes the output folder with "cd -P" before building the
# destination, so the path it returns is the resolved one - under /private/var
# here, and without the doubled slash TMPDIR's trailing slash produces. The
# expectation is built the same way rather than from the raw string: this is the
# "compare paths as paths" rule, and the first version of this section failed on
# exactly that.
outdir_real="$(cd "$outdir" && /bin/pwd -P)"
# set_target BEFORE the copy, because set_target deliberately forgets any
# release copy of the previous target - calling it afterwards would drop the
# release.txt this section is about.
ntz_call set_target "$inplace"
work="$(ntz_call prepare_release_copy "$inplace" "$outdir")"
check "the copy's path is returned" "$outdir_real/InPlace.app" "$work"
check "a copy WAS recorded"         "yes" "$(ntz_is made_release_copy)"
check_exists "and it exists on disk" "$outdir/InPlace.app/Contents/Info.plist"
check "release.txt names it"        "$outdir_real/InPlace.app" "$(stored_release)"
# The positive control for the two check_absent calls in the sections above:
# release.txt is a path this test file computes, and if it computed it wrongly
# every absence check would pass forever.
check_exists "release.txt is where the test looks for it" "$(release_file)"
check "work_target follows the copy" "$outdir_real/InPlace.app" "$(ntz_call work_target)"
# ...but only while it exists. A copy the developer has since deleted must not
# leave the pipeline pointing at a path that is not there.
/bin/rm -rf "$outdir/InPlace.app"
check "and falls back to the chosen target when the copy is gone" "$inplace" \
    "$(ntz_call work_target)"

section "a symlinked target is resolved before anything acts on it"
reset_document
hidden="$OMCTEST_WORK/hidden"
/bin/rm -rf "$hidden"
/bin/mkdir -p "$hidden"
real_pkg="$(make_pkg Real.pkg com.example.real "$hidden")"
/bin/ln -s "$real_pkg" "$OMCTEST_WORK/Shortcut.pkg"
work="$(ntz_call prepare_release_copy "$OMCTEST_WORK/Shortcut.pkg" "")"
# Signing a package replaces it by renaming a temporary over it. Renaming over a
# SYMLINK would replace the link with a regular file and leave the real package
# untouched and unsigned somewhere else - so the resolved path is what comes
# back, even though no copy was made.
check "the resolved package is returned, not the link" \
    "$(ntz_call canonical_path "$real_pkg")" "$work"

section "entitlement_count tells an empty plist from an unreadable one"
reset_document
two="$(make_entitlements Two.entitlements com.apple.security.app-sandbox com.apple.security.cs.allow-jit)"
none="$(make_entitlements None.entitlements)"
check "two keys are counted"  "2" "$(ntz_call entitlement_count "$two")"
check "an empty dictionary is zero, and readable" "0" "$(ntz_call entitlement_count "$none")"
check "and that is a SUCCESS, not a failure" "yes" "$(ntz_is entitlement_count "$none")"

blank="$OMCTEST_WORK/blank.entitlements"
printf '   \n\n' > "$blank"
# plutil turns whitespace into an empty dictionary, which would sail through as
# "no entitlements wanted" - and codesign rejects such a file with an opaque
# error partway through signing.
check "a whitespace-only file is unreadable" "no" "$(ntz_is entitlement_count "$blank")"

ascii="$OMCTEST_WORK/ascii.entitlements"
printf '{ a = b; }\n' > "$ascii"
# Old-style ASCII is a valid one-key dictionary to plutil and a syntax error to
# codesign, which parses entitlements with its own XML reader.
check "old-style ASCII is refused" "no" "$(ntz_is entitlement_count "$ascii")"

word="$OMCTEST_WORK/word.entitlements"
printf 'garbage\n' > "$word"
check "a bare word is refused" "no" "$(ntz_is entitlement_count "$word")"

stringroot="$OMCTEST_WORK/stringroot.entitlements"
{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<plist version="1.0"><string>not a dictionary</string></plist>\n'
} > "$stringroot"
# A non-dictionary root converts cleanly and counts zero keys, which would
# compare equal to an app carrying none.
check "a plist whose root is not a dictionary is refused" "no" \
    "$(ntz_is entitlement_count "$stringroot")"

missing="$OMCTEST_WORK/nope.entitlements"
check "a file that is not there is refused" "no" "$(ntz_is entitlement_count "$missing")"

section "entitlements_match compares canonical XML"
reset_document
ent_app="$(make_app Ent.app com.example.ent)"
sig_set "$ent_app" --entitlements "$two"
check "the same keys match"      "yes" "$(ntz_is entitlements_match "$ent_app" "$two")"
other_two="$(make_entitlements Other.entitlements com.apple.security.cs.allow-jit com.apple.security.app-sandbox)"
# plutil sorts dictionary keys on conversion, so two plists differing only in
# key order are the same entitlements.
check "key ORDER does not matter" "yes" "$(ntz_is entitlements_match "$ent_app" "$other_two")"
one="$(make_entitlements One.entitlements com.apple.security.app-sandbox)"
check "a different key set does not match" "no" "$(ntz_is entitlements_match "$ent_app" "$one")"

bare_app="$(make_app Bare.app com.example.bare)"
sig_set "$bare_app"
check "an app with none matches an empty file" "yes" \
    "$(ntz_is entitlements_match "$bare_app" "$none")"
check "but not a file with keys in it" "no" \
    "$(ntz_is entitlements_match "$bare_app" "$two")"
# Unreadable has to differ from empty here too: collapsing them would let a
# typo'd entitlements path silently skip signing.
check "and not an unreadable one" "no" \
    "$(ntz_is entitlements_match "$bare_app" "$ascii")"

section "signed_item_matches asks the runtime question only when it applies"
reset_document
item="$OMCTEST_WORK/Helper"
printf 'x\n' > "$item"
sig_set "$item"
check "a good signature matches any Developer ID" "yes" \
    "$(ntz_is signed_item_matches "$item" "" yes)"
check "and matches the named identity"            "yes" \
    "$(ntz_is signed_item_matches "$item" "$IDENTITY" yes)"
check "but not a different one"                   "no" \
    "$(ntz_is signed_item_matches "$item" "$OTHER_IDENTITY" yes)"
sig_set "$item" --no-runtime
check "no hardened runtime fails when it is required" "no" \
    "$(ntz_is signed_item_matches "$item" "" yes)"
# The flag is a property of the process a main executable starts, so nested code
# that is only ever mapped into someone else's process does not carry it - and
# Apple notarizes apps like that every day. Demanding it everywhere would call
# those apps unacceptable.
check "and passes when it is not"                     "yes" \
    "$(ntz_is signed_item_matches "$item" "" no)"
sig_set "$item" --no-timestamp
check "a missing secure timestamp always fails" "no" \
    "$(ntz_is signed_item_matches "$item" "" no)"
sig_set "$item" --adhoc
check "an ad-hoc signature has no authority to match" "no" \
    "$(ntz_is signed_item_matches "$item" "" no)"
sig_unsigned "$item"
check "an unsigned item fails"  "no" "$(ntz_is signed_item_matches "$item" "" no)"

section "resign_reason: a signature that already matches is left alone"
reset_document
target="$(make_app Match.app com.example.match)"
helper="$target/Contents/Helpers/tool"
/bin/mkdir -p "$target/Contents/Helpers"
printf 'x\n' > "$helper"
listing_set "$target" "$helper"
sig_set "$target"
sig_set "$helper"
check "no reason to re-sign" "" "$(ntz_call resign_reason "$target" "$IDENTITY" "")"
check "which is reported as 'can be skipped'" "no" \
    "$(ntz_is resign_reason "$target" "$IDENTITY" "")"
# The positive counterpart: the same call answers "yes" when there IS a reason,
# so the "no" above is not passing against a function that always fails.
sig_unsigned "$target"
check "and 'needs signing' when there is a reason" "yes" \
    "$(ntz_is resign_reason "$target" "$IDENTITY" "")"
sig_set "$target"

section "resign_reason: every way it can say no"
sig_set "$target" --verify-rc 1
check "the seal does not verify" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'missing or does not verify')"

sig_unsigned "$target"
# An unsigned bundle fails the very first test, so this is the reason it gets -
# the Authority branches below are only reachable once the seal itself verifies.
check "an unsigned bundle fails at the seal" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'missing or does not verify')"

# An ad-hoc bundle is the case that reaches the Authority branch: the seal is
# self-consistent, so --verify --deep --strict is happy, and there is still no
# certificate for the notary service to accept.
sig_set "$target" --adhoc
check "an ad-hoc bundle carries no Developer ID signature" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'carries no Developer ID signature')"

sig_set "$target" --authority "$OTHER_IDENTITY"
check "it names both certificates when they differ" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c "signed by \"$OTHER_IDENTITY\" rather than the selected")"

sig_set "$target" --no-runtime
check "the hardened runtime is missing" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'hardened runtime')"

# A valid outer signature says nothing about what is nested inside it:
# --verify --deep --strict accepts an ad-hoc nested seal, and codesign -dvv on
# the bundle reports only the outer signature. This is the case the notary
# service rejects after the upload.
sig_set "$target"
sig_set "$helper" --adhoc
check "nested code that does not match is named" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'nested code is not signed to match: Contents/Helpers/tool')"

sig_set "$helper"
listing_fails "$target"
# An empty listing has to count as a failure, not as "nothing to check" - that
# is the fail-open this check exists to close.
check "an enumeration failure is a reason, not an all-clear" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "" | /usr/bin/grep -c 'could not be enumerated')"

section "resign_reason: the entitlements half"
reset_document
target="$(make_app Ents.app com.example.ents)"
listing_set "$target"
sig_set "$target" --entitlements "$two"
check "identical entitlements are no reason to re-sign" "" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "$two")"
check "different ones are" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "$one" | /usr/bin/grep -c 'entitlements differ')"
check "a missing entitlements file is named" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "$OMCTEST_WORK/gone.entitlements" | /usr/bin/grep -c 'is missing')"
check "an unreadable one is distinguished from a missing one" "1" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "$ascii" | /usr/bin/grep -c 'not a readable plist')"
# An empty field means the entitlements already in the bundle are carried over
# verbatim, so by definition nothing would change.
check "an empty field is never a reason" "" \
    "$(ntz_call resign_reason "$target" "$IDENTITY" "")"

section "resign_reason for a package reads pkgutil, not codesign"
reset_document
target_pkg="$(make_pkg Signed.pkg com.example.signed)"
pkg_sig_signed "$target_pkg" "$INSTALLER_ID"
check "a distribution-signed package needs nothing" "" \
    "$(ntz_call resign_reason "$target_pkg" "$INSTALLER_ID")"
check "codesign was never asked about it" "0" "$(fake_calls codesign)"

pkg_sig_unsigned "$target_pkg"
check "an unsigned package is a reason" "1" \
    "$(ntz_call resign_reason "$target_pkg" "$INSTALLER_ID" | /usr/bin/grep -c 'not signed for distribution')"

# pkgutil reports several statuses that also begin "signed by", and matching the
# prefix would wave through exactly the packages this check exists to stop.
pkg_sig_text "$target_pkg" 'Package "Signed.pkg":
   Status: signed by untrusted certificate'
check "an untrusted certificate is still not signed for distribution" "1" \
    "$(ntz_call resign_reason "$target_pkg" "$INSTALLER_ID" | /usr/bin/grep -c 'not signed for distribution')"
check "and package_is_signed says no to it" "no" \
    "$(ntz_is package_is_signed "$target_pkg")"

pkg_sig_text "$target_pkg" 'Package "Signed.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Certificate Chain:
    1. '"$INSTALLER_ID"
check "a signature with no trusted timestamp is a reason" "1" \
    "$(ntz_call resign_reason "$target_pkg" "$INSTALLER_ID" | /usr/bin/grep -c 'no trusted timestamp')"

pkg_sig_signed "$target_pkg" "Developer ID Installer: Someone Else (ZZZZZZZZZZ)"
check "a package signed by someone else is named" "1" \
    "$(ntz_call resign_reason "$target_pkg" "$INSTALLER_ID" | /usr/bin/grep -c 'rather than the selected')"
# With no identity to compare against, the distribution status is the whole
# question: the package is acceptable to the notary service whoever signed it.
check "with no identity selected, whoever signed it is fine" "" \
    "$(ntz_call resign_reason "$target_pkg" "")"

section "the nested-code preflight"
reset_document
target="$(make_app Nested.app com.example.nested)"
/bin/mkdir -p "$target/Contents/Helpers" "$target/Contents/Frameworks"
adhoc="$target/Contents/Helpers/adhoc-tool"
naked="$target/Contents/Frameworks/naked.dylib"
good="$target/Contents/Helpers/good-tool"
printf 'x\n' > "$adhoc"; printf 'x\n' > "$naked"; printf 'x\n' > "$good"
listing_set "$target" "$adhoc" "$naked" "$good"
sig_set "$target"; sig_set "$adhoc" --adhoc; sig_set "$good"
sig_unsigned "$naked"

offenders="$(ntz_call list_uncertified_nested_items "$target")"
check "the ad-hoc item is listed with its reason" "1" \
    "$(printf '%s\n' "$offenders" | /usr/bin/grep -c 'Contents/Helpers/adhoc-tool - ad-hoc signature, no certificate')"
check "the unsigned one too"                     "1" \
    "$(printf '%s\n' "$offenders" | /usr/bin/grep -c 'Contents/Frameworks/naked.dylib - not signed')"
check "the properly signed one is not listed"    "0" \
    "$(printf '%s\n' "$offenders" | /usr/bin/grep -c 'good-tool')"
# The bundle prefix is stripped with parameter expansion rather than sed, so a
# path holding a regex metacharacter still strips.
check "paths are reported relative to the bundle" "0" \
    "$(printf '%s\n' "$offenders" | /usr/bin/grep -c "$target/")"

check "the preflight fails"  "no" "$(ntz_is preflight_nested_code "$target")"
check "and says why in the log" "yes" "$(log_says 'Preflight FAILED: nested code')"
check "naming what Gatekeeper does about it" "yes" \
    "$(log_says 'Gatekeeper rejects the whole app')"

section "a clean bundle passes the preflight and says so"
reset_document
clean="$(make_app Clean.app com.example.clean)"
/bin/mkdir -p "$clean/Contents/Helpers"
clean_helper="$clean/Contents/Helpers/tool"
printf 'x\n' > "$clean_helper"
listing_set "$clean" "$clean_helper"
sig_set "$clean"; sig_set "$clean_helper"
check "the preflight passes" "yes" "$(ntz_is preflight_nested_code "$clean")"
check "and says so"          "yes" "$(log_says 'all nested code carries a certificate chain')"

section "an enumeration failure blames the walk, not the contents"
reset_document
opaque="$(make_app Opaque.app com.example.opaque)"
listing_fails "$opaque"
check "the preflight fails"   "no" "$(ntz_is preflight_nested_code "$opaque")"
check "and says the contents could not be enumerated" "yes" \
    "$(log_says 'contents could not be enumerated')"
check "rather than naming items it never saw" "no" \
    "$(log_says 'nested code without a usable certificate chain')"

section "a package has no nested code to walk"
reset_document
some_pkg="$(make_pkg Flat.pkg com.example.flat)"
check "the preflight passes trivially" "yes" "$(ntz_is preflight_nested_code "$some_pkg")"
check "and the signer was never asked to enumerate it" "0" \
    "$(fake_calls codesign_applet.sh)"

section "a Gatekeeper rejection is explained rather than left bare"
reset_document
rejected="$(make_app Rejected.app com.example.rejected)"
listing_set "$rejected"
sig_set "$rejected"
spctl_set "$rejected" 3 "$rejected: rejected
source=Unnotarized Developer ID"
ntz_call run_spctl "$rejected" >/dev/null 2>&1
check "an unnotarized build is named as such" "yes" \
    "$(log_says 'no notarization ticket')"

reset_document
spctl_set "$rejected" 3 "$rejected: rejected
source=no usable signature"
ntz_call run_spctl "$rejected" >/dev/null 2>&1
check "a missing signature explains the xattr trap" "yes" "$(log_says 'xattr -c')"

# spctl reports a bare "rejected" with no reason when a nested item matches no
# policy rule, which is the case the log most needs spelled out.
reset_document
/bin/mkdir -p "$rejected/Contents/Helpers"
bad_helper="$rejected/Contents/Helpers/bad"
printf 'x\n' > "$bad_helper"
listing_set "$rejected" "$bad_helper"
sig_set "$rejected"; sig_set "$bad_helper" --adhoc
spctl_set "$rejected" 3 "$rejected: rejected"
ntz_call run_spctl "$rejected" >/dev/null 2>&1
check "a bare rejection names the offending nested item" "yes" \
    "$(log_says 'Contents/Helpers/bad')"
check "and points at Console for the syspolicyd messages" "yes" \
    "$(log_says 'syspolicyd')"

section "an app is assessed for execution, a package for installation"
reset_document
listing_set "$rejected"
sig_set "$rejected"
spctl_set "$rejected" 0 "accepted"
ntz_call run_spctl "$rejected" >/dev/null 2>&1
check "an app uses --type execute" "yes" "$(fake_arg spctl execute 1)"
reset_document
pkg_assess="$(make_pkg Assess.pkg com.example.assess)"
spctl_set "$pkg_assess" 0 "accepted"
ntz_call run_spctl "$pkg_assess" >/dev/null 2>&1
# Passing the wrong policy reports a failure that says nothing about the
# artifact, which is indistinguishable from a real rejection in the log.
check "a package uses --type install" "yes" "$(fake_arg spctl install 1)"

section "signing a package replaces it atomically"
reset_document
sign_pkg="$(make_pkg Sign.pkg com.example.sign)"
before="$(/usr/bin/shasum "$sign_pkg" | /usr/bin/cut -c1-40)"
check "productsign succeeded" "yes" "$(ntz_is sign_package "$sign_pkg" "$INSTALLER_ID")"
check "it was given the selected identity" "$INSTALLER_ID" \
    "$(fake_arg_after productsign --sign)"
check_exists "the package is still at its original path" "$sign_pkg"
check "and it now reports as signed for distribution" "yes" \
    "$(ntz_is package_is_signed "$sign_pkg")"
check_absent "no temporary was left behind" "$OMCTEST_WORK/.Sign.pkg.notarize-signing"

section "a failed productsign leaves the original untouched"
reset_document
sign_pkg="$(make_pkg Keep.pkg com.example.keep)"
before="$(/usr/bin/shasum "$sign_pkg" | /usr/bin/cut -c1-40)"
# --partial, so productsign leaves a half-written temporary behind before it
# fails. Without that the cleanup check cannot fail: a fake that creates nothing
# leaves nothing to survive, whatever the applet does or does not remove.
productsign_fails --partial
check "sign_package reports failure" "no" "$(ntz_is sign_package "$sign_pkg" "$INSTALLER_ID")"
check "the original package is byte-for-byte unchanged" "$before" \
    "$(/usr/bin/shasum "$sign_pkg" | /usr/bin/cut -c1-40)"
check "the temporary really was created" "1" \
    "$(fake_mentions productsign '.Keep.pkg.notarize-signing')"
check_absent "and it did not survive" "$OMCTEST_WORK/.Keep.pkg.notarize-signing"
check "the log says productsign failed" "yes" "$(log_says 'productsign failed')"

section "the upload artifact: an app is zipped, a package is not"
reset_document
up_app="$(make_app Upload.app com.example.upload)"
check "prepare_upload succeeded for the app" "yes" "$(ntz_is prepare_upload "$up_app")"
check "it chose the archive" "$(state_dir_path)/upload.zip" "$(ntz_call upload_path)"
check_exists "which ditto really created" "$(state_dir_path)/upload.zip"

reset_document
up_pkg="$(make_pkg Upload.pkg com.example.uploadpkg)"
check "prepare_upload succeeded for the package" "yes" "$(ntz_is prepare_upload "$up_pkg")"
# The notary service accepts a flat .pkg directly, and zipping one would only
# slow the upload down.
check "and chose the package itself" "$up_pkg" "$(ntz_call upload_path)"
check_absent "no archive was made" "$(state_dir_path)/upload.zip"

section "sign_app carries existing entitlements over when the field is empty"
reset_document
carry="$(make_app Carry.app com.example.carry)"
listing_set "$carry"
sig_set "$carry" --entitlements "$two"
check "signing succeeded" "yes" "$(ntz_is sign_app "$carry" "$IDENTITY" "")"
# Signing is a replacement, not an amendment: a sandboxed app re-signed with no
# entitlements comes out unsandboxed carrying a perfectly valid signature that
# the notary service would happily accept.
check "the log says the existing ones were carried over" "yes" \
    "$(log_says 'carrying over the entitlements already in the signature (2 keys)')"
check "and the signer was handed a file, not an empty argument" "yes" \
    "$(fake_arg codesign_applet.sh "$(state_dir_path)/inherited.entitlements")"

section "sign_app refuses an entitlements file it cannot read"
reset_document
listing_set "$carry"
sig_set "$carry"
check "signing fails" "no" "$(ntz_is sign_app "$carry" "$IDENTITY" "$ascii")"
check "with a message naming the problem" "yes" "$(log_says 'not a readable plist')"
check "and the signer was never invoked" "0" "$(fake_calls codesign_applet.sh)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
