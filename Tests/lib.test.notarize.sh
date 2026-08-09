#!/bin/sh
# Tests/lib.test.notarize.sh - Notarize's own test vocabulary, for omctest.
#
# Sourced by every Tests/*.test.sh file, after omctest.sh. omctest supplies the
# generic half - the scratch tree, the interposition directory, the alert and
# omc_dialog_control stubs, check/section/omctest_end - and knows nothing about
# this applet. Everything below is Notarize's own: where its per-window state
# lives, how its preferences are read back, and - the bulk of this file - the
# fake world its system tools answer from.
#
# WHY THERE IS SO MUCH FAKE WORLD HERE
#
# omctest intercepts the OMC support tools by rebuilding $OMC_OMC_SUPPORT_PATH.
# It cannot touch a binary named by absolute path, and almost everything this
# applet does is one of those: codesign, productsign, pkgutil, spctl, security,
# xcrun notarytool, xcrun stapler. Every one of them either reads the
# developer's keychain, talks to Apple, rewrites a real bundle, or asks
# Gatekeeper about the machine the suite happens to be running on. None can run
# for real, and none can simply be dropped - they are where the answers come
# from.
#
# So lib.notarize.sh names them through variables (the seam contract in
# omctest_guide.md section 8), and this file points those variables at the fakes
# in Tests/helpers. The fakes are not stubs that return a code: they are a small
# consistent world. A signature is a record, and productsign and the signer
# UPDATE that world, so a pipeline test that signs and then asks what is on disk
# gets the answer a real run would have produced rather than a contradiction.
#
# What that buys, and what it does not: every decision the applet makes about a
# signature is tested, and no claim here is evidence that codesign behaves as
# the world models it. Where the modeled behavior is a real, checkable property
# of the tool - codesign writing -dvv to stderr, pkgutil reporting an unsigned
# package as a successful query - the fake reproduces it deliberately and says
# so at the point where it matters.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

# omc_control_defaults arrived in API 2, and this window opens with two pickers
# whose options are empty until a handler fills them. Starting from a blanked
# window rather than the declared one would misrepresent what a handler sees.
if [ "${OMCTEST_API_VERSION:-0}" -lt 2 ]; then
    printf 'lib.test.notarize: needs omctest API 2 or newer, found %s\n' \
        "${OMCTEST_API_VERSION:-none}" >&2
    exit 1
fi

APP_SCRIPTS="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"
APP_RESOURCES="$OMC_APP_BUNDLE_PATH/Contents/Resources"
TEST_HELPERS="$OMCTEST_TESTS/helpers"

# The two declarative files. Nearly everything here is a behavior check against
# a running handler, but a couple of decisions live in the manifest and the
# window definition rather than in any script, and can only be asserted there.
command_json() { printf '%s/Command.json' "$APP_RESOURCES"; }
window_json() { printf '%s/Base.lproj/Notarize.json' "$APP_RESOURCES"; }

# ---------------------------------------------------------------------------
# View ids, imported from the applet rather than restated
# ---------------------------------------------------------------------------
#
# lib.notarize.sh writes them as NOTARIZE_BTN_ID=30 and RAIL_ICON_IDS="210 212".
# A second list here is a list that can disagree with the first, and it
# disagrees silently: a name that fails to import expands to the empty string,
# omc_control writes OMC_ACTIONUI_VIEW__VALUE, and every check fails one by one
# with no hint why.
#
# Two -e expressions rather than one alternation: BSD sed has no \| and would
# match it literally, importing nothing while looking correct.
omctest_import_view_ids() { # <script ...>
    local script
    for script; do
        eval "$(/usr/bin/sed -n \
            -e 's/^\([A-Z][A-Z0-9_]*_ID\)=\([0-9][0-9]*\)$/\1=\2/p' \
            -e 's/^\([A-Z][A-Z0-9_]*_IDS\)="\([0-9 ]*\)"$/\1="\2"/p' \
            "$script")"
    done
}
omctest_import_view_ids "$APP_SCRIPTS/lib.notarize.sh"

# Fail once, here, naming every id the suite drives - an id that went missing
# from the app is exactly the case this exists for.
for _required in NOTARIZE_BTN_ID CANCEL_BTN_ID CREDENTIALS_BTN_ID \
                 IDENTITY_PICKER_ID PROFILE_PICKER_ID ENTITLEMENTS_FIELD_ID \
                 ENTITLEMENTS_BROWSE_ID OUTPUT_FIELD_ID STATUS_ID PROGRESS_ID \
                 LOG_ID REVEAL_BTN_ID FETCHLOG_BTN_ID INSPECT_BTN_ID \
                 RAIL_SIGN_ID RAIL_SUBMIT_ID RAIL_STAPLE_ID RAIL_VALIDATE_ID \
                 RAIL_ICON_IDS RAIL_BTN_IDS \
                 CRED_APPLEID_ID CRED_TEAM_ID CRED_PASSWORD_ID CRED_KEYFILE_ID \
                 CRED_KEYID_ID CRED_ISSUER_ID CRED_PROFILE_ID CRED_SAVE_ID \
                 CRED_TEST_ID CRED_RESULT_ID CRED_APPLEID_GROUP_ID \
                 CRED_APIKEY_GROUP_ID CRED_STEP1_ID CRED_PICK_APPLEID_ID \
                 CRED_PICK_APIKEY_ID CRED_PICK_EXISTING_ID CRED_STEP2_ID \
                 CRED_CONTINUE_ID CRED_BACK2_ID CRED_STEP3_ID CRED_BACK3_ID \
                 CRED_HINT_CREATE_ID CRED_HINT_EXISTING_ID CRED_STEP3_TITLE_ID; do
    eval "_value=\${$_required-}"
    if [ -z "$_value" ]; then
        printf 'lib.test.notarize: %s did not import from lib.notarize.sh\n' "$_required" >&2
        exit 1
    fi
done
unset _required _value

# ---------------------------------------------------------------------------
# The seam: point the applet's system tools at the fake world
# ---------------------------------------------------------------------------

# Everything the fakes record and read lives here, wiped by fakes_reset.
NOTARIZE_FAKE_DIR="$OMCTEST_WORK/fake"
# The applet's preferences. Redirected for the obvious reason: the real ones are
# the developer's, in ~/Library/Application Support, and a suite that wrote
# known_profiles or default_identity into them would edit the machine it ran on.
NOTARIZE_PREFS_DIR="$OMCTEST_WORK/prefs"

FAKE_BIN="$OMCTEST_WORK/fakebin"

NOTARIZE_CODESIGN_TOOL="$FAKE_BIN/codesign"
NOTARIZE_PRODUCTSIGN_TOOL="$FAKE_BIN/productsign"
NOTARIZE_PKGUTIL_TOOL="$FAKE_BIN/pkgutil"
NOTARIZE_SPCTL_TOOL="$FAKE_BIN/spctl"
NOTARIZE_SECURITY_TOOL="$FAKE_BIN/security"
NOTARIZE_XCRUN_TOOL="$FAKE_BIN/xcrun"
NOTARIZE_PKILL_TOOL="$FAKE_BIN/pkill"
NOTARIZE_OPEN_TOOL="$FAKE_BIN/open"
NOTARIZE_CODESIGN_APPLET="$FAKE_BIN/codesign_applet.sh"

export NOTARIZE_FAKE_DIR NOTARIZE_PREFS_DIR
export NOTARIZE_CODESIGN_TOOL NOTARIZE_PRODUCTSIGN_TOOL NOTARIZE_PKGUTIL_TOOL
export NOTARIZE_SPCTL_TOOL NOTARIZE_SECURITY_TOOL NOTARIZE_XCRUN_TOOL
export NOTARIZE_PKILL_TOOL NOTARIZE_OPEN_TOOL NOTARIZE_CODESIGN_APPLET

# Copied rather than symlinked: each fake finds its siblings through
# "dirname $0", and a symlink would resolve that to Tests/helpers, which happens
# to work - until the day a fake wants a file next to it in the fake bin. Copies
# keep the two directories from quietly becoming one.
#
# "recorder" is installed twice under the two names it serves; $0's basename is
# what decides which log it writes.
fakes_install() {
    local tool
    /bin/mkdir -p "$FAKE_BIN" "$NOTARIZE_FAKE_DIR" "$NOTARIZE_PREFS_DIR"
    /bin/cp "$TEST_HELPERS/fake_record.sh" "$FAKE_BIN/fake_record.sh"
    for tool in codesign xcrun security pkgutil spctl productsign codesign_applet.sh; do
        /bin/cp "$TEST_HELPERS/$tool" "$FAKE_BIN/$tool"
        /bin/chmod +x "$FAKE_BIN/$tool"
    done
    for tool in pkill open; do
        /bin/cp "$TEST_HELPERS/recorder" "$FAKE_BIN/$tool"
        /bin/chmod +x "$FAKE_BIN/$tool"
    done
}

# Forget every recorded call and every scripted answer. Not the same as
# reset_document, which is about the applet's own state - a section usually
# wants both, and reset_document calls this.
fakes_reset() {
    /bin/rm -rf "$NOTARIZE_FAKE_DIR"
    /bin/mkdir -p "$NOTARIZE_FAKE_DIR"
}

# ---------------------------------------------------------------------------
# Reading the fakes back
# ---------------------------------------------------------------------------

# How many times a tool was called. Reads the counter file rather than counting
# log lines, so an argument containing a newline still counts as one call.
fake_calls() { # <tool>
    /bin/cat "$NOTARIZE_FAKE_DIR/$1.count" 2>/dev/null || printf '0'
}

# The arguments of the <n>th call, one per line. Exact - this is the record to
# assert against when the argument text is the thing under test.
fake_argv() { # <tool> [n, default 1]
    /bin/cat "$NOTARIZE_FAKE_DIR/$1.argv.${2:-1}" 2>/dev/null
}

# yes/no: was <exact-arg> among the arguments of the <n>th call?
#
# An exact line match against the argv record, not a substring of the joined
# log. The joined form answers the wrong question for the flags worth
# asserting: "--key" is a substring of "--key-id", and a check written against
# it would report a flag the applet never passed.
fake_arg() { # <tool> <exact-arg> [n, default 1]
    if fake_argv "$1" "${3:-1}" | /usr/bin/grep -q -x -F -e "$2"; then
        echo yes
    else
        echo no
    fi
}

# The argument that FOLLOWS <flag> in the <n>th call - the value of an option.
fake_arg_after() { # <tool> <flag> [n, default 1]
    fake_argv "$1" "${3:-1}" | /usr/bin/awk -v want="$2" '
        found { print; exit }
        $0 == want { found = 1 }'
}

# How many recorded calls to <tool> mention <pattern> anywhere. A regex, over
# the lossy joined log - for "was this tool ever asked about that path", where
# the exact framing does not matter.
fake_mentions() { # <tool> <pattern>
    # A tool that was never called has no log, and grep then prints nothing at
    # all. Empty is not zero to check: "expected 0, actual []" is a confusing
    # way to report "it never ran", which is usually exactly what was meant.
    if [ ! -f "$NOTARIZE_FAKE_DIR/$1.log" ]; then
        printf '0'
        return 0
    fi
    /usr/bin/grep -c -- "$2" "$NOTARIZE_FAKE_DIR/$1.log" 2>/dev/null | /usr/bin/tr -d ' '
}

# ---------------------------------------------------------------------------
# Writing the fake world: signatures
# ---------------------------------------------------------------------------

# Resolve a path's directory the way the applet does. The full rationale is in
# helpers/fake_record.sh, which carries the identical function - the two have to
# agree exactly, because one writes the records and the other reads them, and a
# disagreement shows up as a fake that silently answers with its default.
#
# It is also the right thing to build an EXPECTED value from. The pipeline
# reports the path it resolved, not the one it was handed, so a check comparing
# against the raw fixture path is asserting about a spelling the applet never
# produces.
canonical() { # <path>
    local dir base resolved
    if [ -d "$1" ]; then
        resolved="$(cd -P "$1" 2>/dev/null && /bin/pwd -P)"
        printf '%s' "${resolved:-$1}"
        return 0
    fi
    dir="$(/usr/bin/dirname "$1")"
    base="$(/usr/bin/basename "$1")"
    resolved="$(cd -P "$dir" 2>/dev/null && /bin/pwd -P)"
    if [ -z "$resolved" ]; then
        printf '%s' "$1"
        return 0
    fi
    printf '%s/%s' "$resolved" "$base"
}

fake_key() { # <path>
    printf '%s' "$(canonical "$1")" | /usr/bin/shasum | /usr/bin/cut -c1-40
}

# For a value that is not a path. See helpers/fake_record.sh for why the two
# cannot share one function.
fake_text_key() { # <text>
    printf '%s' "$1" | /usr/bin/shasum | /usr/bin/cut -c1-40
}

# Export a control's CURRENT WINDOW VALUE the way the engine would at the next
# dispatch.
#
# The harness records what a handler WROTE to a control but does not feed it
# back as OMC_ACTIONUI_VIEW_<id>_VALUE next time round; the engine does. So a
# field one handler prefilled - the wizard fills the Team ID from the signing
# identity - is invisible to the next handler unless it is bridged here, and
# every check about that field would describe a window nobody has ever seen.
sync_control() { # <view-id>
    omc_control "$1" "$(ui_value "$1")"
}

# How many times the bundled signer was asked to SIGN, as opposed to enumerate.
#
# fake_calls counts every invocation, and resign_reason and preflight_nested_code
# each call the same script with --list-code before anything is signed - so a
# check written against the raw count reads "the signer ran" for a run that only
# ever looked.
signer_runs() {
    # fake_mentions puts the pattern after grep's own "--", so a pattern that
    # starts with a dash is read as a pattern rather than as options.
    fake_mentions codesign_applet.sh '--brief'
}

sig_record() { # <path>
    printf '%s/sig/%s' "$NOTARIZE_FAKE_DIR" "$(fake_key "$1")"
}

# Give <path> a signature. The defaults describe what the notary service wants -
# a Developer ID Application certificate, the hardened runtime, a secure
# timestamp - so a test only has to name the property it is taking away.
#
#   sig_set /x/A.app                          acceptable
#   sig_set /x/A.app --authority "Developer ID Application: Other (T2)"
#   sig_set /x/A.app --no-runtime             no hardened runtime
#   sig_set /x/A.app --no-timestamp           no secure timestamp
#   sig_set /x/A.app --adhoc                  ad-hoc: seals, but no certificate
#   sig_set /x/A.app --verify-rc 1            --verify fails
#   sig_set /x/A.app --entitlements <file>    what -d --entitlements returns
#
# A path with no record at all is unsigned; that is the default and needs no
# call. sig_unsigned exists to say so explicitly after a record was set.
sig_set() { # <path> [option ...]
    local path="$1"
    shift
    local record="$(sig_record "$path")"
    local authority="Developer ID Application: Test Developer (TEAMID1234)"
    local runtime=yes timestamp=yes adhoc=no verify_rc="" entitlements=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --authority) authority="$2"; shift 2 ;;
            --no-runtime) runtime=no; shift ;;
            --no-timestamp) timestamp=no; shift ;;
            --adhoc) adhoc=yes; shift ;;
            --verify-rc) verify_rc="$2"; shift 2 ;;
            --entitlements) entitlements="$2"; shift 2 ;;
            *) printf 'sig_set: unknown option %s\n' "$1" >&2; return 1 ;;
        esac
    done

    /bin/rm -rf "$record"
    /bin/mkdir -p "$record"
    {
        printf 'Executable=%s\n' "$path"
        printf 'Identifier=fake.%s\n' "$(/usr/bin/basename "$path")"
        printf 'Format=bundle with Mach-O universal\n'
        if [ "$adhoc" = "yes" ]; then
            # An ad-hoc signature has no Authority line at all and says so on a
            # Signature= line instead. That is the whole reason
            # list_uncertified_nested_items looks for it: the seal is valid, so
            # every other check passes, and Gatekeeper still has no certificate
            # chain to match a rule against.
            printf 'Signature=adhoc\n'
        else
            printf 'Authority=%s\n' "$authority"
            printf 'Authority=Developer ID Certification Authority\n'
            printf 'Authority=Apple Root CA\n'
        fi
        [ "$timestamp" = "yes" ] && printf 'Timestamp=9 Aug 2026 at 00:00:00\n'
        if [ "$runtime" = "yes" ]; then
            printf 'CodeDirectory v=20500 flags=0x10000(runtime) hashes=42+7\n'
        else
            printf 'CodeDirectory v=20500 flags=0x0(none) hashes=42+7\n'
        fi
    } > "$record/info"

    [ -n "$verify_rc" ] && printf '%s' "$verify_rc" > "$record/verify.rc"
    [ -n "$entitlements" ] && /bin/cp "$entitlements" "$record/entitlements"
    return 0
}

# Forget a path's signature: it becomes unsigned, which is what codesign
# reports as "code object is not signed at all".
sig_unsigned() { # <path>
    /bin/rm -rf "$(sig_record "$1")"
}

# Store the entitlements plist codesign will hand back for <path>. Separate
# from sig_set because the interesting case for entitlements_match is an app
# that IS signed and whose entitlements then change.
sig_entitlements() { # <path> <plist-file>
    local record="$(sig_record "$1")"
    /bin/mkdir -p "$record"
    /bin/cp "$2" "$record/entitlements"
}

# ---------------------------------------------------------------------------
# Writing the fake world: packages, identities, Gatekeeper, the notary service
# ---------------------------------------------------------------------------

# What pkgutil --check-signature reports for a package. The full status phrase
# matters: package_is_signed refuses to match a prefix, because "signed by
# untrusted certificate" and "signed by a certificate that has since expired"
# both start the same way and are exactly what that check exists to stop.
pkg_sig_signed() { # <pkg> [leaf-identity]
    local record="$NOTARIZE_FAKE_DIR/pkgsig/$(fake_key "$1")"
    /bin/mkdir -p "$(/usr/bin/dirname "$record")"
    {
        printf 'Package "%s":\n' "$(/usr/bin/basename "$1")"
        printf '   Status: signed by a developer certificate issued by Apple for distribution\n'
        printf '   Signed with a trusted timestamp on: 2026-08-09 00:00:00 +0000\n'
        printf '   Certificate Chain:\n'
        printf '    1. %s\n' "${2:-Developer ID Installer: Test Developer (TEAMID1234)}"
    } > "$record.out"
}

# Any other status text, verbatim - for the near-miss cases.
pkg_sig_text() { # <pkg> <text>
    local record="$NOTARIZE_FAKE_DIR/pkgsig/$(fake_key "$1")"
    /bin/mkdir -p "$(/usr/bin/dirname "$record")"
    printf '%s\n' "$2" > "$record.out"
}

pkg_sig_unsigned() { # <pkg>
    pkg_sig_text "$1" "Package \"$(/usr/bin/basename "$1")\":
   Status: no signature"
}

# The identities "security find-identity -v -p <policy>" reports. Written in the
# real tool's numbered-and-quoted format so that the applet's grep and sed run
# on the shape they will meet live.
#
# The policy is part of the record on purpose: an app is looked up under
# "codesigning" and a package under "basic", because an installer certificate is
# not valid for the codesigning policy and does not appear there at all. A fake
# that answered the same for both would hide a swap of the two.
identities_set() { # <policy> [full-identity-name ...]
    local out="$NOTARIZE_FAKE_DIR/identities.$1"
    shift
    : > "$out"
    local n=1
    local name
    for name in "$@"; do
        printf '  %d) %040d "%s"\n' "$n" "$n" "$name" >> "$out"
        n=$((n + 1))
    done
    printf '     %d valid identities found\n' "$((n - 1))" >> "$out"
}

identities_none() { # <policy>
    : > "$NOTARIZE_FAKE_DIR/identities.$1"
}

# What spctl says about a path. rc 0 accepts; anything else rejects, and the
# TEXT is what explain_spctl_rejection reads to choose its explanation.
spctl_set() { # <path> <rc> <text>
    local record="$NOTARIZE_FAKE_DIR/spctl/$(fake_key "$1")"
    /bin/mkdir -p "$(/usr/bin/dirname "$record")"
    printf '%s\n' "$3" > "$record.out"
    printf '%s' "$2" > "$record.rc"
}

# The listing codesign_applet.sh --list-code returns for an app: the applet's
# only source of truth about what is nested inside a bundle.
#
# An EMPTY listing is not "nothing nested" to this applet - it is an
# enumeration failure, and both resign_reason_app and preflight_nested_code
# treat it as one, because failing open there is what lets an ad-hoc helper
# through. listing_fails is how a test says that on purpose.
listing_set() { # <app> [item ...]
    local record="$NOTARIZE_FAKE_DIR/listing/$(fake_key "$1")"
    local app="$1"
    shift
    /bin/mkdir -p "$(/usr/bin/dirname "$record")"
    {
        printf '%s\n' "$app"
        local item
        for item in "$@"; do
            printf '%s\n' "$item"
        done
    } > "$record.out"
}

listing_fails() { # <app>
    local record="$NOTARIZE_FAKE_DIR/listing/$(fake_key "$1")"
    /bin/mkdir -p "$(/usr/bin/dirname "$record")"
    : > "$record.out"
    printf '1' > "$record.rc"
}

# Make the bundled signer fail, so the pipeline's signing-failed branch can be
# reached without a real certificate.
# Name nested items the signer will leave alone even when it succeeds.
#
# Without this the preflight cannot be tested as the backstop it is: resign_reason
# already refuses an ad-hoc nested item, so the pipeline signs, and the fake
# signer - like the real one - then fixes everything it was given. The case the
# preflight exists for is the one where signing reports success and an item is
# still ad-hoc afterwards, which is what this describes.
signer_skips() { # <item ...>
    local item
    : > "$NOTARIZE_FAKE_DIR/codesign_applet.skip"
    for item; do
        printf '%s\n' "$item" >> "$NOTARIZE_FAKE_DIR/codesign_applet.skip"
    done
}

signer_fails() { # [message]
    printf '%s' "${1:-codesign: cannot sign: no identity found}" \
        > "$NOTARIZE_FAKE_DIR/codesign_applet.sign.out"
    printf '1' > "$NOTARIZE_FAKE_DIR/codesign_applet.sign.rc"
}

# Make productsign fail. With --partial it leaves a half-written output behind
# first, which is the only way sign_package's cleanup of its temporary neighbor
# can be shown to do anything.
productsign_fails() { # [--partial]
    printf '1' > "$NOTARIZE_FAKE_DIR/productsign.rc"
    if [ "$1" = "--partial" ]; then
        : > "$NOTARIZE_FAKE_DIR/productsign.partial"
    fi
}

# What the applet fed notarytool over stdin on the last store-credentials call.
notary_store_stdin() {
    /bin/cat "$NOTARIZE_FAKE_DIR/notarytool.store.stdin" 2>/dev/null
}

# --- notarytool and stapler ---------------------------------------------------

# The JSON "notarytool submit --wait --output-format json" leaves behind. The
# applet reads /id and /status out of it with plister, so this has to be real
# JSON rather than a marker string.
notary_submit_result() { # <status> [id]
    printf '{"id":"%s","status":"%s","message":"Processing complete"}\n' \
        "${2:-11111111-2222-3333-4444-555555555555}" "$1" \
        > "$NOTARIZE_FAKE_DIR/notarytool.submit.out"
    printf '0' > "$NOTARIZE_FAKE_DIR/notarytool.submit.rc"
}

notary_submit_fails() {
    : > "$NOTARIZE_FAKE_DIR/notarytool.submit.out"
    printf '1' > "$NOTARIZE_FAKE_DIR/notarytool.submit.rc"
}

# The log "notarytool log <id> ... <destination>" writes to the destination
# file. print_issues reads /statusSummary and walks /issues out of it.
notary_log_issues() { # <summary> [severity:message:path ...]
    local summary="$1"
    shift
    {
        printf '{"statusSummary":"%s","issues":[' "$summary"
        local first=1 spec severity message path
        for spec in "$@"; do
            severity="${spec%%:*}"
            spec="${spec#*:}"
            message="${spec%%:*}"
            path="${spec#*:}"
            [ "$first" = "1" ] || printf ','
            first=0
            printf '{"severity":"%s","message":"%s","path":"%s"}' \
                "$severity" "$message" "$path"
        done
        printf ']}\n'
    } > "$NOTARIZE_FAKE_DIR/notarytool.log.out"
    printf '0' > "$NOTARIZE_FAKE_DIR/notarytool.log.rc"
}

notary_log_fails() {
    printf '1' > "$NOTARIZE_FAKE_DIR/notarytool.log.rc"
}

# How "notarytool history --keychain-profile <name>" answers for ONE name.
# notary_profile_exists asks exactly this, one name at a time, because
# notarytool's profiles live in Apple's data protection keychain and cannot be
# enumerated - so a per-name answer is the only shape that models it.
notary_history_for() { # <profile> <rc> [text]
    local slot="$NOTARIZE_FAKE_DIR/notarytool.history.$(fake_text_key "$1")"
    printf '%s' "$2" > "$slot.rc"
    printf '%s\n' "${3:-}" > "$slot.out"
}

# The one failure that means "this profile does not exist". Anything else - bad
# credentials, no network - has to count as "exists or cannot be ruled out",
# because being wrong the other way overwrites credentials without asking.
notary_history_absent() { # <profile>
    notary_history_for "$1" 69 \
        "Error: No Keychain password item found for profile: $1"
}

notary_history_default() { # <rc> [text]
    printf '%s' "$1" > "$NOTARIZE_FAKE_DIR/notarytool.history.rc"
    printf '%s\n' "${2:-}" > "$NOTARIZE_FAKE_DIR/notarytool.history.out"
}

notary_store_fails() { # [message]
    printf '%s\n' "${1:-Error: HTTP status code: 401. Invalid credentials.}" \
        > "$NOTARIZE_FAKE_DIR/notarytool.store.out"
    printf '1' > "$NOTARIZE_FAKE_DIR/notarytool.store.rc"
}

stapler_fails() { # [which: staple|validate] [message]
    local which="${1:-staple}"
    printf '%s\n' "${2:-CloudKit query for ... failed}" \
        > "$NOTARIZE_FAKE_DIR/stapler.$which.out"
    printf '1' > "$NOTARIZE_FAKE_DIR/stapler.$which.rc"
}

# ---------------------------------------------------------------------------
# The applet's own state
# ---------------------------------------------------------------------------

# lib.notarize.sh: document_uuid="${parent_uuid:-$window_uuid}". Factored out
# because the state directory AND both pasteboard keys hang off it, and the two
# disagreeing fails silently - a wrong key reads back empty, and several checks
# here assert that a value IS empty.
document_uuid() { printf '%s' "${OMC_PARENT_DIALOG_GUID:-$OMC_ACTIONUI_WINDOW_UUID}"; }

# state_dir() in the applet is "${TMPDIR:-/tmp}/notarize-state-${document_uuid}"
# - a shell interpolation, which does NOT collapse the trailing slash macOS puts
# on TMPDIR, so the real path can carry an interior "//". Reproduced character
# for character rather than normalized, because the applet's own writes land at
# that spelling.
state_dir_path() {
    printf '%s/notarize-state-%s' "${TMPDIR:-/tmp}" "$(document_uuid)"
}

target_file()      { printf '%s/target.txt' "$(state_dir_path)"; }
release_file()     { printf '%s/release.txt' "$(state_dir_path)"; }
identities_map()   { printf '%s/identities.txt' "$(state_dir_path)"; }
profiles_map()     { printf '%s/profiles.txt' "$(state_dir_path)"; }
prefs_key_cache()  { printf '%s/prefs_key.txt' "$(state_dir_path)"; }
run_log_file()     { printf '%s/run.log' "$(state_dir_path)"; }
upload_path_file() { printf '%s/upload_path.txt' "$(state_dir_path)"; }
submission_id_file()     { printf '%s/submission_id.txt' "$(state_dir_path)"; }
submission_status_file() { printf '%s/submission_status.txt' "$(state_dir_path)"; }

stored_target() { /bin/cat "$(target_file)" 2>/dev/null; }
stored_release() { /bin/cat "$(release_file)" 2>/dev/null; }
run_log() { /bin/cat "$(run_log_file)" 2>/dev/null; }

# yes/no: does the run log contain <pattern>? A regex.
log_says() { # <pattern>
    if run_log | /usr/bin/grep -q -- "$1"; then echo yes; else echo no; fi
}

# --- preferences ---------------------------------------------------------------

prefs_file_path() { printf '%s/prefs.plist' "$NOTARIZE_PREFS_DIR"; }

# Read a value out of the applet's prefs with the same tool the applet writes
# them with, reached through the interposition directory exactly as a handler
# reaches it.
prefs_value() { # <keypath, e.g. /default_profile>
    "$OMC_OMC_SUPPORT_PATH/plister" get value "$(prefs_file_path)" "$1" 2>/dev/null
}

prefs_count() { # <keypath>
    "$OMC_OMC_SUPPORT_PATH/plister" get count "$(prefs_file_path)" "$1" 2>/dev/null
}

# --- pasteboard ------------------------------------------------------------------
#
# The real tool, reached through the interposition directory as the handlers
# reach it. The keys are constructed the way lib.notarize.sh constructs them,
# interpolating the uuid rather than hardcoding one.
pb_get() { # <key>
    "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" get 2>/dev/null
}
pb_set() { # <key> <value>
    printf '%s' "$2" | "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" set
}

pb_busy_key()       { printf 'ntz_busy_%s' "$(document_uuid)"; }
pb_submission_key() { printf 'ntz_submission_%s' "$(document_uuid)"; }
# Wizard state hangs off the CREDENTIAL window itself, not the document, so
# these interpolate the window uuid even inside a sheet.
pb_cred_method_key() { printf 'ntz_credmethod_%s' "$OMC_ACTIONUI_WINDOW_UUID"; }
pb_cred_saved_key()  { printf 'ntz_credsaved_%s' "$OMC_ACTIONUI_WINDOW_UUID"; }

busy() { pb_get "$(pb_busy_key)"; }
cred_method() { pb_get "$(pb_cred_method_key)"; }

# --- the step rail -----------------------------------------------------------
#
# rail_set says "done" and writes an SF Symbol name. Mapped back here so a check
# reads the vocabulary the applet uses rather than "checkmark.circle.fill",
# which says nothing about what the developer is being told.
#
# "untouched" is deliberately distinct from "pending": a stage the run never
# reached has no property set at all, and that is a different claim from a stage
# that was explicitly reset to pending.
rail_state() { # <rail-icon-view-id>
    local symbol="$(ui_prop "$1" systemName)"
    case "$symbol" in
        arrow.clockwise.circle.fill) echo running ;;
        checkmark.circle.fill) echo done ;;
        xmark.circle.fill) echo failed ;;
        minus.circle) echo skipped ;;
        circle) echo pending ;;
        "") echo untouched ;;
        *) echo "unknown[$symbol]" ;;
    esac
}

# ---------------------------------------------------------------------------
# Calling into the applet's library
# ---------------------------------------------------------------------------

# Run a library function in a subshell with lib.notarize.sh loaded.
#
# The subshell keeps the library's own globals out of the test file and stops a
# function that calls exit from taking the whole file with it. Arguments are
# expanded by the CALLING shell, so a call that has to name one of the library's
# own constants needs ntz_eval instead.
ntz_call() { # <function> [argument ...]
    (
        . "$APP_SCRIPTS/lib.notarize.sh" >/dev/null 2>&1
        "$@"
    )
}

ntz_eval() { # <shell-text evaluated inside the subshell>
    (
        . "$APP_SCRIPTS/lib.notarize.sh" >/dev/null 2>&1
        eval "$1"
    )
}

# yes/no for a library function that answers a question by exit status.
#
# It answers "no" for a function that fails to load too, so a check whose
# expected value happens to BE "no" could pass on a broken library. Every such
# check in this suite is paired with its opposite, which cannot pass that way.
ntz_is() { # <function> [argument ...]
    if ntz_call "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# ---------------------------------------------------------------------------
# Fixtures, synthesized rather than committed
# ---------------------------------------------------------------------------

# A minimal app bundle: a directory with an Info.plist carrying a bundle
# identifier and an executable. Nothing here is signed - signatures live in the
# fake world, not on disk - so this is only as much bundle as app_prefs_key,
# detect_entitlements and the path logic actually read.
make_app() { # <name.app> [bundle-identifier] [dest-dir] -> prints the path
    local name="$1"
    local identifier="${2:-com.example.$(printf '%s' "${1%.app}" | /usr/bin/tr 'A-Z' 'a-z')}"
    local dest="${3:-$OMCTEST_WORK}"
    local app="$dest/$name"
    /bin/rm -rf "$app"
    /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0"><dict>\n'
        printf '<key>CFBundleIdentifier</key><string>%s</string>\n' "$identifier"
        printf '<key>CFBundleExecutable</key><string>%s</string>\n' "${name%.app}"
        printf '</dict></plist>\n'
    } > "$app/Contents/Info.plist"
    printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/${name%.app}"
    /bin/chmod +x "$app/Contents/MacOS/${name%.app}"
    printf '%s' "$app"
}

# A real flat installer package: a xar archive holding a PackageInfo member.
#
# Built for real, with the tool the applet reads it with, because
# package_identifier's whole job is to pull an identifier out of a xar archive
# without expanding its payload. A stub file would leave that function untested
# while every assertion about it still passed.
make_pkg() { # <name.pkg> [identifier] [dest-dir] -> prints the path
    local name="$1"
    local identifier="${2:-com.example.${1%.pkg}.pkg}"
    local dest="${3:-$OMCTEST_WORK}"
    local pkg="$dest/$name"
    local stage="$OMCTEST_WORK/.stage-${name%.pkg}"
    check "fixture precondition: /usr/bin/xar is present" "yes" \
        "$([ -x /usr/bin/xar ] && echo yes || echo no)"
    /bin/rm -rf "$stage" "$pkg"
    /bin/mkdir -p "$stage"
    {
        printf '<?xml version="1.0" encoding="utf-8"?>\n'
        printf '<pkg-info overwrite-permissions="true" relocatable="false" '
        printf 'identifier="%s" postinstall-action="none" version="1.0" format-version="2">\n' "$identifier"
        printf '  <payload numberOfFiles="1" installKBytes="1"/>\n'
        printf '</pkg-info>\n'
    } > "$stage/PackageInfo"
    ( cd "$stage" && /usr/bin/xar -c -f "$pkg" PackageInfo ) || return 1
    printf '%s' "$pkg"
}

# A productbuild-style package, whose identifier lives in a Distribution member
# instead. package_identifier prefers this one, so both branches need a fixture.
make_distribution_pkg() { # <name.pkg> [identifier] [dest-dir] -> prints the path
    local name="$1"
    local identifier="${2:-com.example.${1%.pkg}.dist}"
    local dest="${3:-$OMCTEST_WORK}"
    local pkg="$dest/$name"
    local stage="$OMCTEST_WORK/.stage-dist-${name%.pkg}"
    /bin/rm -rf "$stage" "$pkg"
    /bin/mkdir -p "$stage"
    {
        printf '<?xml version="1.0" encoding="utf-8"?>\n'
        printf '<installer-gui-script minSpecVersion="1">\n'
        printf '  <pkg-ref id="%s"/>\n' "$identifier"
        printf '</installer-gui-script>\n'
    } > "$stage/Distribution"
    ( cd "$stage" && /usr/bin/xar -c -f "$pkg" Distribution ) || return 1
    printf '%s' "$pkg"
}

# An entitlements plist with the given keys, all boolean true.
make_entitlements() { # <file-name> [key ...] -> prints the path
    local file="$OMCTEST_WORK/$1"
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        local key
        for key; do
            printf '\t<key>%s</key>\n\t<true/>\n' "$key"
        done
        printf '</dict>\n</plist>\n'
    } > "$file"
    printf '%s' "$file"
}

# Assert-then-wipe. ui_reset DELETES unknown_ids.log, suspect_writes.log and
# errors.log, so a single check at the end of a file only ever sees whatever the
# last section wrote - which is how a suite ends up with a standing check that
# reads as coverage and is inert. Checking here, immediately before the wipe,
# makes every section covered by exactly one check, and the one at the end of
# the file covers the final section.
ui_hygiene_check() {
    check "no writes to a view id the window does not declare" "" "$(ui_unknown_writes)"
    check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
    check "the harness detected no misuse" "" "$(ui_errors)"
}

# ---------------------------------------------------------------------------
# Resetting between sections
# ---------------------------------------------------------------------------

# Put everything back to a freshly-opened window: the applet's per-window state,
# its preferences, the fake world, the recorded window writes, and the alert,
# notification and chain records.
#
# The pasteboard clear is not optional. It lives in the per-login server and
# outlives the process, so a key left set by an earlier section silently answers
# the next section's question about a document that no longer exists.
#
# Chain history is cumulative across the whole file, so a section asserting "the
# handler did not chain" would otherwise inherit an earlier section's legitimate
# chain.
reset_document() {
    reset_window
    /bin/rm -rf "$NOTARIZE_PREFS_DIR"
    /bin/mkdir -p "$NOTARIZE_PREFS_DIR"
}

# Everything reset_document does EXCEPT the preferences, which survive.
#
# This is "the developer closed the window and opened a new one", and it is the
# only way to state what per-app preferences are for: a setting is remembered
# when it outlives the window that made it. A section that used reset_document
# for that would wipe the very thing it meant to assert had survived, and the
# check would read as a bug in the applet.
reset_window() {
    /bin/rm -rf "$(state_dir_path)"
    pb_set "$(pb_busy_key)" ""
    pb_set "$(pb_submission_key)" ""
    pb_set "$(pb_cred_method_key)" ""
    pb_set "$(pb_cred_saved_key)" ""
    fakes_reset
    omc_control_defaults Notarize
    omc_object ""
    ui_hygiene_check
    ui_reset
    alerts_reset
    alert_answers_reset
    chains_reset
}

fakes_install
