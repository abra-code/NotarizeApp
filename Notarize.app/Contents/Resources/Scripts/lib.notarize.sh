#!/bin/sh
# lib.notarize.sh - Shared functions and variables for Notarize

# --- OMC environment ---
support_path="$OMC_OMC_SUPPORT_PATH"
app_bundle="$OMC_APP_BUNDLE_PATH"
window_uuid="$OMC_ACTIONUI_WINDOW_UUID"
parent_uuid="$OMC_PARENT_DIALOG_GUID"
cmd_guid="$OMC_CURRENT_COMMAND_GUID"
# Document window UUID: the parent when running inside a child sheet, else self.
document_uuid="${parent_uuid:-$window_uuid}"

# --- OMC support tools (lowercase vars, as in the other applets) ---
dialog_tool="$support_path/omc_dialog_control"
next_cmd="$support_path/omc_next_command"
pasteboard_tool="$support_path/pasteboard"
alert_tool="$support_path/alert"
notify_tool="$support_path/notify"
plister="$support_path/plister"

# --- System tools that have to be substitutable ------------------------------
# Most system tools are called by absolute path inline (/usr/bin/sed, /bin/rm)
# and stay that way. The ones below are named through a variable instead,
# because every one of them reaches outside this process in a way a test cannot
# allow: the keychain, the notary service, Gatekeeper's assessment cache, the
# signature on a real bundle, another process, the Finder.
#
# omctest intercepts the OMC support tools by rebuilding $OMC_OMC_SUPPORT_PATH,
# which cannot reach an absolute path, so this variable is the only seam
# available (omctest_guide.md section 8). One variable per binary, holding
# exactly one word: a multi-word invocation keeps its subcommand at the call
# site, as in "$xcrun_tool" notarytool submit.
#
# Nothing sets these in normal use - the defaults are the real tools, and the
# environment overrides exist for the test suite in ../Tests.
codesign_tool="${NOTARIZE_CODESIGN_TOOL:-/usr/bin/codesign}"
productsign_tool="${NOTARIZE_PRODUCTSIGN_TOOL:-/usr/bin/productsign}"
pkgutil_tool="${NOTARIZE_PKGUTIL_TOOL:-/usr/sbin/pkgutil}"
spctl_tool="${NOTARIZE_SPCTL_TOOL:-/usr/sbin/spctl}"
security_tool="${NOTARIZE_SECURITY_TOOL:-/usr/bin/security}"
xcrun_tool="${NOTARIZE_XCRUN_TOOL:-/usr/bin/xcrun}"
pkill_tool="${NOTARIZE_PKILL_TOOL:-/usr/bin/pkill}"
open_tool="${NOTARIZE_OPEN_TOOL:-/usr/bin/open}"
# The bundled signer, which is itself a wrapper around codesign. It is inside
# the bundle rather than in /usr/bin, but it is no more substitutable for that -
# running it for real would sign whatever it was pointed at.
codesign_applet="${NOTARIZE_CODESIGN_APPLET:-$app_bundle/Contents/Resources/Scripts/codesign_applet.sh}"

# --- View IDs (match Notarize.json) ---
# Toolbar
NOTARIZE_BTN_ID=30
CANCEL_BTN_ID=32
CREDENTIALS_BTN_ID=33
# Settings group
IDENTITY_PICKER_ID=50
PROFILE_PICKER_ID=51
ENTITLEMENTS_FIELD_ID=52
ENTITLEMENTS_BROWSE_ID=53
OUTPUT_FIELD_ID=54
OUTPUT_BROWSE_ID=55

# Progress + log
STATUS_ID=60
PROGRESS_ID=61
LOG_ID=62
REVEAL_BTN_ID=63
FETCHLOG_BTN_ID=64
INSPECT_BTN_ID=65
# Step rail (status Image + run Button per pipeline stage)
RAIL_SIGN_ID=210
RAIL_SUBMIT_ID=212
RAIL_STAPLE_ID=213
RAIL_VALIDATE_ID=215
RAIL_ICON_IDS="210 212 213 215"
RAIL_BTN_IDS="220 222 223 225"
# Credential window (3-step wizard)
CRED_APPLEID_ID=71
CRED_TEAM_ID=72
CRED_PASSWORD_ID=73
CRED_KEYFILE_ID=74
CRED_KEYID_ID=75
CRED_ISSUER_ID=76
CRED_PROFILE_ID=77
CRED_SAVE_ID=78
CRED_TEST_ID=79
CRED_RESULT_ID=80
CRED_APPLEID_GROUP_ID=700
CRED_APIKEY_GROUP_ID=710
CRED_STEP1_ID=800
CRED_PICK_APPLEID_ID=801
CRED_PICK_APIKEY_ID=802
CRED_PICK_EXISTING_ID=803
CRED_STEP2_ID=810
CRED_CONTINUE_ID=811
CRED_BACK2_ID=814
CRED_STEP3_ID=820
CRED_BACK3_ID=824
CRED_HINT_CREATE_ID=821
CRED_HINT_EXISTING_ID=822
CRED_STEP3_TITLE_ID=823

# --- Preferences (persist across launches) ---
# Overridable for the same reason the system tools above are: these are the
# developer's real settings, and a test that wrote known_profiles or
# default_identity into them would edit the machine it runs on.
prefs_dir="${NOTARIZE_PREFS_DIR:-$HOME/Library/Application Support/Notarize}"
prefs_file="$prefs_dir/prefs.plist"

# --- Per-document pasteboard keys ---
PB_BUSY="ntz_busy_${document_uuid}"
PB_SUBMISSION="ntz_submission_${document_uuid}"
# Credential wizard state, keyed to the credential window itself
PB_CRED_METHOD="ntz_credmethod_${window_uuid}"
# The profile this wizard has just written credentials into. Only used to keep
# the collision hint from contradicting the success message still on screen.
PB_CRED_SAVED="ntz_credsaved_${window_uuid}"

# --- Debug logging (gated on a flag file) ---
DEBUG=false
_log() {
    [ "$DEBUG" = "true" ] && printf '%s\n' "$*" >> /tmp/notarize_debug.log
}

# --- State directory --------------------------------------------------------
# Per-window scratch: target.txt, workdir/, submission.json, notary-log.json,
# run.log, run.pid. Created lazily on first use.
state_dir() {
    local dir="${TMPDIR:-/tmp}/notarize-state-${document_uuid}"
    /bin/mkdir -p "$dir"
    printf '%s' "$dir"
}

# --- Pasteboard -------------------------------------------------------------
# Read a pasteboard value (empty string if unset). Arguments: key
pb_get() {
    "$pasteboard_tool" "$1" get 2>/dev/null
}

# Write a pasteboard value via stdin, never argv, so secrets never reach `ps`.
# Empty value clears the entry. Arguments: key, value
pb_set() {
    printf '%s' "$2" | "$pasteboard_tool" "$1" set
}

# --- UI helpers -------------------------------------------------------------
# Set a view's text value. Arguments: view_id, value
set_value() {
    "$dialog_tool" "$window_uuid" "$1" "$2"
}

# Set an ActionUI view property. Arguments: view_id, property, value (string/JSON)
set_property() {
    "$dialog_tool" "$window_uuid" "$1" omc_set_property "$2" "$3"
}

# Enable (1) or disable (0) a view. Arguments: view_id, flag
enable_view() {
    if [ "$2" = "1" ]; then
        "$dialog_tool" "$window_uuid" "$1" omc_enable
    else
        "$dialog_tool" "$window_uuid" "$1" omc_disable
    fi
}

# Show (1) or hide (0) a view. Arguments: view_id, flag
show_view() {
    if [ "$2" = "1" ]; then
        "$dialog_tool" "$window_uuid" "$1" omc_show
    else
        "$dialog_tool" "$window_uuid" "$1" omc_hide
    fi
}

# Set the status line. Arguments: message
set_status() {
    set_value "$STATUS_ID" "$1"
}

# Show (1) or hide (0) the progress spinner. Arguments: flag
show_progress() {
    show_view "$PROGRESS_ID" "$1"
}

# --- Step rail ---------------------------------------------------------------
# Set a rail stage's status icon. Arguments: icon_view_id, state
# (pending | running | done | failed | skipped)
rail_set() {
    local img color
    case "$2" in
        running) img="arrow.clockwise.circle.fill"; color="blue" ;;
        done)    img="checkmark.circle.fill"; color="green" ;;
        failed)  img="xmark.circle.fill"; color="red" ;;
        skipped) img="minus.circle"; color="gray" ;;
        *)       img="circle"; color="gray" ;;
    esac
    set_property "$1" systemName "$img"
    set_property "$1" foregroundStyle "$color"
}

# Reset every rail stage to pending.
rail_reset() {
    local id
    for id in $RAIL_ICON_IDS; do
        rail_set "$id" pending
    done
}

# Enable (1) or disable (0) all step-run buttons, plus the Inspect Signature
# and Fetch Log diagnostics. Arguments: flag
rail_enable() {
    local id
    for id in $RAIL_BTN_IDS $INSPECT_BTN_ID $FETCHLOG_BTN_ID; do
        enable_view "$id" "$1"
    done
}

# Reset the run log (file and view).
clear_log() {
    local f="$(state_dir)/run.log"
    : > "$f"
    set_value "$LOG_ID" ""
}

# Append a line to the run log and mirror the whole log into the log view.
# Arguments: message
append_log() {
    local f="$(state_dir)/run.log"
    printf '%s\n' "$1" >> "$f"
    set_value "$LOG_ID" "$(/bin/cat "$f")"
}

# --- Preferences (read/written with plister) --------------------------------
# Ensure the prefs file exists with a root dictionary.
prefs_ensure() {
    /bin/mkdir -p "$prefs_dir"
    if [ ! -f "$prefs_file" ]; then
        "$plister" set dict "$prefs_file" /
    fi
}

# Print a top-level prefs string value (empty if unset). Arguments: key
prefs_get() {
    "$plister" get value "$prefs_file" "/$1" 2>/dev/null
}

# Upsert a top-level prefs string value. Arguments: key, value
prefs_set() {
    prefs_ensure
    "$plister" remove "$prefs_file" "/$1" 2>/dev/null
    "$plister" insert "$1" string "$2" "$prefs_file" /
}

# --- Per-app preferences ------------------------------------------------------
# Settings are remembered per target app under the /apps dict, keyed by the
# bundle identifier (falls back to the bundle name for apps without one).
# Fields: output_dir, entitlements, and - only when they differ from the
# global defaults - identity and profile.

# Print an installer package's identifier without expanding its payload: xar
# pulls out the single metadata member and the identifier is read from it.
# productbuild packages carry a Distribution, bare pkgbuild ones a PackageInfo.
# Prints nothing if neither can be read. Arguments: pkg_path
package_identifier() {
    local work="$(state_dir)/pkgid"
    # Set in either of two branches below, or in neither.
    local id
    /bin/rm -rf "$work"
    /bin/mkdir -p "$work" || return 0

    (cd "$work" && /usr/bin/xar -x -f "$1" Distribution 2>/dev/null)
    if [ -f "$work/Distribution" ]; then
        id="$(/usr/bin/sed -n 's/.*<pkg-ref id="\([^"]*\)".*/\1/p' "$work/Distribution" | /usr/bin/head -n 1)"
    fi
    if [ -z "$id" ]; then
        (cd "$work" && /usr/bin/xar -x -f "$1" PackageInfo 2>/dev/null)
        if [ -f "$work/PackageInfo" ]; then
            id="$(/usr/bin/sed -n 's/.*identifier="\([^"]*\)".*/\1/p' "$work/PackageInfo" | /usr/bin/head -n 1)"
        fi
    fi

    /bin/rm -rf "$work"
    printf '%s' "$id"
}

# Print the prefs key for the current target (empty if no target). Keyed by
# bundle identifier for an app and package identifier for a package, so settings
# follow the product rather than a file name that carries a version number.
# Falls back to the file name when no identifier can be read.
app_prefs_key() {
    local target="$(get_target)"
    if [ -z "$target" ]; then
        return 0
    fi
    # Cached, because apply_app_settings and save_app_settings each call this
    # once per remembered field. For a package the answer costs an xar read of
    # the archive's table of contents, so without this a single target switch
    # would open the package half a dozen times. Two lines: the target it was
    # computed for, then the key. A target path containing a newline simply
    # never matches and is recomputed, which is the safe way to be wrong.
    local cache="$(state_dir)/prefs_key.txt"
    if [ -f "$cache" ] && [ "$(/usr/bin/sed -n 1p "$cache")" = "$target" ]; then
        /usr/bin/sed -n 2p "$cache"
        return 0
    fi

    # Set in one branch or the other, so it is declared before either.
    local key
    if [ "$(target_kind_of "$target")" = "pkg" ]; then
        key="$(package_identifier "$target")"
    else
        key="$("$plister" get value "$target/Contents/Info.plist" /CFBundleIdentifier 2>/dev/null)"
    fi
    if [ -z "$key" ]; then
        key="$(/usr/bin/basename "$target")"
    fi

    printf '%s\n%s\n' "$target" "$key" > "$cache"
    printf '%s' "$key"
}

# Print a per-app prefs value for the current target (empty if unset). Arguments: field
app_pref_get() {
    local key="$(app_prefs_key)"
    if [ -n "$key" ]; then
        "$plister" get value "$prefs_file" "/apps/$key/$1" 2>/dev/null
    fi
}

# Upsert a per-app prefs value for the current target; an empty value removes
# the entry. No-op when no target is chosen. Arguments: field, value
app_pref_set() {
    local key="$(app_prefs_key)"
    if [ -z "$key" ]; then
        return 0
    fi
    prefs_ensure
    "$plister" get type "$prefs_file" /apps >/dev/null 2>&1 \
        || "$plister" insert apps dict "$prefs_file" /
    "$plister" get type "$prefs_file" "/apps/$key" >/dev/null 2>&1 \
        || "$plister" insert "$key" dict "$prefs_file" /apps
    "$plister" remove "$prefs_file" "/apps/$key/$1" 2>/dev/null
    if [ -n "$2" ]; then
        "$plister" insert "$1" string "$2" "$prefs_file" "/apps/$key"
    fi
}

# Append a profile name to known_profiles[] (no duplicates). Arguments: name
known_profiles_add() {
    prefs_ensure
    "$plister" get type "$prefs_file" /known_profiles >/dev/null 2>&1
    if [ "$?" != "0" ]; then
        "$plister" insert known_profiles array "$prefs_file" /
    fi
    local found="$("$plister" find string "$1" "$prefs_file" /known_profiles 2>/dev/null)"
    if [ -n "$found" ]; then
        return 0
    fi
    "$plister" append string "$1" "$prefs_file" /known_profiles
}

# Print known profile names, one per line.
known_profiles_list() {
    "$plister" iterate "$prefs_file" /known_profiles get value / 2>/dev/null
}

# Answer whether this app has already registered a profile of this name. Free
# and offline, but only as complete as this app's own history. Arguments: name
#
# The pattern goes after -e, not as a bare operand: profile names are typed by
# the developer, and one starting with a dash would otherwise be read as grep's
# own options. That is not a hypothetical - "grep -q -x -F -v" leaves grep with
# no pattern at all, so it prints a usage error and exits 2, which reads here as
# a confident "no".
known_profile() {
    [ -n "$1" ] || return 1
    # An embedded newline is a pattern separator to grep -F, not a literal, so a
    # name containing one would be answered about either half of itself. Such a
    # name is refused before it can be saved; refuse to claim knowledge of it too.
    local newline='
'
    case "$1" in
        *"$newline"*) return 1 ;;
    esac
    known_profiles_list | /usr/bin/grep -q -x -F -e "$1"
}

# Print why a profile name cannot be used, or nothing at all when it can.
# Arguments: name
profile_name_problem() {
    if [ -z "$1" ]; then
        printf 'Enter a profile name.'
        return 0
    fi
    # Not empty, but nothing a person could tell from empty in the picker or in
    # default_profile.
    if ! printf '%s' "$1" | /usr/bin/grep -q '[^[:space:]]'; then
        printf 'Enter a profile name that is more than spaces.'
        return 0
    fi
    local newline='
'
    case "$1" in
        *"$newline"*)
            printf 'A profile name cannot contain a line break.'
            return 0
            ;;
        -*)
            # notarytool reads a leading dash as one of its own options and
            # answers "Missing value for '--keychain-profile'", so a name like
            # this can never be stored or used - better to say so than to let
            # the developer discover it as a parse error.
            printf 'A profile name cannot start with a dash.'
            return 0
            ;;
    esac
    return 1
}

# Answer whether a notary keychain profile of this name already exists, so that
# "notarytool store-credentials" would overwrite it rather than create it. The
# tool documents that argument as "the profile name to create or update" and has
# no flag to refuse an update, so this is the only place the question can be
# asked. Arguments: profile_name
# Returns 0 when the profile exists or cannot be shown not to, 1 when it does not.
notary_profile_exists() {
    # Profiles this app registered are known offline and for certain, and that
    # is the common case - a name reused from an earlier run of this wizard - so
    # it is asked first and costs nothing.
    if known_profile "$1"; then
        return 0
    fi
    # Otherwise notarytool has to be asked. Its profiles live in Apple's data
    # protection keychain (access group com.apple.gke.notary), which other
    # processes cannot enumerate - "security find-generic-password" does not see
    # them at all - so existence has to be probed one name at a time.
    #
    # A missing profile is answered locally and immediately, before any network
    # call: exit 69 and "Error: No Keychain password item found for profile: X".
    # Anything else - a working profile, expired credentials, no network - means
    # the keychain item is there or cannot be ruled out, and both have to count
    # as "exists". Being wrong that way costs a confirmation the developer did
    # not need; being wrong the other way destroys credentials without asking.
    #
    # Declared apart from its assignment so the next line reads notarytool's exit
    # status and not local's, which is always 0.
    local probe
    probe="$("$xcrun_tool" notarytool history --keychain-profile "$1" 2>&1)"
    local rc=$?
    # Absence is the only answer that permits an overwrite, so both halves have
    # to agree: the command failed, and it failed in the one way that means this.
    # The message alone could be produced by a profile that does exist - "history"
    # prints a "name:" line per submission, so notarizing a file named after the
    # error would put the text in a successful listing - and that false negative
    # is precisely the one that costs credentials.
    [ "$rc" != "0" ] || return 0
    case "$probe" in
        *"Error: No Keychain password item found for profile:"*) return 1 ;;
    esac
    return 0
}

# --- Discovery --------------------------------------------------------------
# The last row of the signing identity picker, which stands for "leave the
# existing signature alone". Re-signing is a replacement, not an amendment, and
# an app assembled by a build system that this window cannot reproduce - nested
# code signed with entitlements of its own, a designated requirement that has to
# survive - comes out of a re-sign subtly different from what was tested. That
# is the developer's call to make, so it is offered as a choice rather than
# guessed at.
NO_SIGN_OPTION="Don't Code-sign"
# What that choice is remembered as, per target, in prefs. It cannot collide
# with a real identity: list_signing_identities only ever yields names holding
# "Developer ID Application" or "Developer ID Installer".
NO_SIGN_PREF="none"

# Print the signing identities usable for a target kind, one full name per line.
#
# An app needs a "Developer ID Application" certificate and a package needs a
# "Developer ID Installer" one - productsign rejects the other. The policy
# differs too: an installer certificate is not valid for the codesigning policy
# and does not appear under "-p codesigning" at all, so packages are looked up
# under "-p basic". Arguments: kind ("app" or "pkg")
list_signing_identities() {
    local certificate_class policy
    if [ "$1" = "pkg" ]; then
        certificate_class="Developer ID Installer"
        policy="basic"
    else
        certificate_class="Developer ID Application"
        policy="codesigning"
    fi
    "$security_tool" find-identity -v -p "$policy" 2>/dev/null \
        | /usr/bin/grep "$certificate_class" \
        | /usr/bin/sed 's/.*"\(.*\)".*/\1/'
}

# Print why nothing is being signed, given that no identity is selected: either
# the developer picked the "Don't Code-sign" row, or there is no certificate of
# the right class to pick. The outcome is the same but the situations are not,
# and a log that does not say which leaves the developer guessing.
#
# Takes no argument on purpose. It used to accept a kind for the lookup while
# naming the class through required_certificate_class, which reads the current
# target - so a caller passing anything else would have searched one certificate
# class and reported the other. One source for both settles it.
not_signing_reason() {
    if [ -n "$(list_signing_identities "$(current_kind)")" ]; then
        printf '"%s" is selected in the signing identity picker' "$NO_SIGN_OPTION"
    else
        printf 'no %s certificate is available in your keychain' "$(required_certificate_class)"
    fi
}

# Print the certificate class the current target needs, for error messages.
required_certificate_class() {
    if [ "$(current_kind)" = "pkg" ]; then
        printf '%s' "Developer ID Installer"
    else
        printf '%s' "Developer ID Application"
    fi
}

# Extract the team id (trailing parenthesized token) from an identity name.
# Arguments: identity_name
team_from_identity() {
    printf '%s' "$1" | /usr/bin/sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))[^()]*$/\1/p'
}

# Convert newline-separated stdin into a JSON array string (quotes/backslashes
# escaped). Used to fill Picker options.
json_array_from_lines() {
    /usr/bin/awk '
        BEGIN { printf "[" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); if (NR > 1) printf ","; printf "\"%s\"", $0 }
        END { printf "]" }'
}

# --- Target kind -------------------------------------------------------------
# Notarize accepts two kinds of target and they differ at every step that
# touches a signature or an upload:
#
#   app  a .app bundle. Signed with codesign (hardened runtime, entitlements),
#        uploaded inside a ditto zip, assessed with spctl --type execute.
#   pkg  a flat installer package. Signed with productsign using a Developer ID
#        *Installer* identity, uploaded as-is because the notary service accepts
#        .pkg directly, assessed with spctl --type install.
#
# Stapling is the only stage that is identical for both.

# Print "app", "pkg", or nothing at all. Arguments: path
target_kind_of() {
    case "$1" in
        *.app) if [ -d "$1" ]; then printf 'app'; fi ;;
        # Only flat packages. Old bundle-style .pkg/.mpkg are directories and the
        # notary service does not accept them; is_supported_target reports that
        # case rather than letting it fail later at upload time.
        *.pkg|*.mpkg) if [ -f "$1" ]; then printf 'pkg'; fi ;;
    esac
}

# Print the kind of the current target.
current_kind() {
    target_kind_of "$(get_target)"
}

# --- Target -----------------------------------------------------------------
# Succeed (0) if the path is something this app can notarize. Arguments: path
is_supported_target() {
    [ -n "$(target_kind_of "$1")" ]
}

# Print the reason a path was rejected, for the alert shown to the user.
# Arguments: path
unsupported_target_reason() {
    case "$1" in
        *.pkg|*.mpkg)
            if [ -d "$1" ]; then
                printf '%s' "That is an old bundle-style installer package. The notary service only accepts flat packages, which is what productbuild creates."
                return 0
            fi
            ;;
    esac
    printf '%s' "Choose an application bundle (.app) or a flat installer package (.pkg)."
}

# Canonicalize a file or directory path, resolving symlinks all the way down.
# Prints nothing and returns 1 on failure. Arguments: path
#
# "cd -P" into a directory resolves symlinks in the whole path including the
# last component, which is what the .app branch relies on. A file cannot be
# cd'd into, so its final component has to be resolved by hand - otherwise the
# two branches disagree, and prepare_release_copy's same-folder guard can be
# walked straight past by a symlink whose name matches its target's: the guard
# compares directories, decides they differ, and rm -rf's the real file the
# symlink points at.
canonical_path() {
    # "dir" is declared apart from its assignments because they are guarded by
    # "|| return 1": written as "local dir=$(...) || return 1" the guard would
    # test local's own status, which is always 0, and a failed cd would go
    # unnoticed. "link" is set only while the loop runs.
    local dir link
    if [ -d "$1" ]; then
        dir="$(cd -P "$1" 2>/dev/null && /bin/pwd -P)" || return 1
        [ -n "$dir" ] || return 1
        printf '%s' "$dir"
        return 0
    fi

    local target="$1"
    local hops=0
    while [ -L "$target" ] && [ "$hops" -lt 40 ]; do
        link="$(/usr/bin/readlink "$target")"
        [ -n "$link" ] || break
        case "$link" in
            /*) target="$link" ;;
            *) target="$(/usr/bin/dirname "$target")/$link" ;;
        esac
        hops=$((hops + 1))
    done
    # Still a symlink means a loop, or a chain longer than the loop allows.
    # Returning the last hop would be a confidently wrong path feeding a
    # destructive guard, so report failure instead.
    [ -L "$target" ] && return 1

    dir="$(/usr/bin/dirname "$target")"
    local base="$(/usr/bin/basename "$target")"
    # "cd -P", not plain "cd": a relative link like "../c/pkg" leaves a ".." in
    # the path above, and logical cd collapses that lexically, before resolving
    # any symlink in the prefix. With "b" a symlink to "a/b", logical cd turns
    # "x/b/../c" into "x/c" while the real location is "a/c" - a wrong answer
    # that would let prepare_release_copy's same-folder guard through.
    dir="$(cd -P "$dir" 2>/dev/null && /bin/pwd -P)" || return 1
    [ -n "$dir" ] || return 1
    printf '%s/%s' "$dir" "$base"
}

# Store the target app path. Called exactly once per window, from
# Notarize.main.init, with the object OMC opened the window on.
#
# The window is a single-document window and must stay bound to that one target.
# OMC sets the window's representedURL - the proxy icon, the command-click path
# menu, the Recent Documents entry - from the opened object once, in the
# associated-object branch of window creation (OMCActionUIWindowController), and
# never again. The runtime title verb sets a title string only, so it cannot
# even paper over the difference. A second target adopted mid-window therefore
# leaves the title naming one app while every field describes another, and the
# applet has no way to reconcile them. That is why there is no in-window drop
# target and no chooser button - a new target means a new window, opened from
# the Notarize icon or the app's own Open panel. Keep it that way; the resets
# below are only belt and braces.
#
# Arguments: path
set_target() {
    printf '%s' "$1" > "$(state_dir)/target.txt"
    /bin/rm -f "$(state_dir)/release.txt"
    /bin/rm -f "$(state_dir)/prefs_key.txt"
}

# Print the stored target app path (empty if none).
get_target() {
    local f="$(state_dir)/target.txt"
    if [ -f "$f" ]; then
        /bin/cat "$f"
    fi
}

# Succeed (0) if the last prepare_release_copy actually made a copy. Callers
# use this rather than comparing its result against the chosen target, which no
# longer works now that it returns a resolved path: a symlinked target differs
# from its resolved form without any copy having been made.
made_release_copy() {
    [ -f "$(state_dir)/release.txt" ]
}

# Print the path the pipeline operates on: the release copy when one was made
# (and still exists), else the chosen target.
work_target() {
    local f="$(state_dir)/release.txt"
    if [ -f "$f" ]; then
        local p="$(/bin/cat "$f")"
        if [ -e "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    fi
    get_target
}

# Print the path of an entitlements file living next to an app: prefer
# <AppName>.entitlements, else the first *.entitlements in the app's folder.
# Arguments: app_path
detect_entitlements() {
    local dir="$(/usr/bin/dirname "$1")"
    local base="$(/usr/bin/basename "$1" .app)"
    if [ -f "$dir/$base.entitlements" ]; then
        printf '%s' "$dir/$base.entitlements"
        return 0
    fi
    local f
    for f in "$dir"/*.entitlements; do
        if [ -f "$f" ]; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 0
}

# Fill the settings fields for the current target from its remembered per-app
# prefs, falling back to auto-detection (entitlements) and the global defaults
# (identity, profile). Call after set_target with the pickers already populated.
apply_app_settings() {
    local target="$(get_target)"
    if [ -z "$target" ]; then
        return 0
    fi

    # Output folder is remembered per target only (empty = next to the target).
    set_value "$OUTPUT_FIELD_ID" "$(app_pref_get output_dir)"

    # Entitlements: the remembered file, else one found next to the app. A
    # package has no entitlements; its row is hidden by refresh_target_ui.
    if [ "$(target_kind_of "$target")" != "pkg" ]; then
        local ent="$(app_pref_get entitlements)"
        if [ -z "$ent" ] || [ ! -f "$ent" ]; then
            ent="$(detect_entitlements "$target")"
        fi
        set_value "$ENTITLEMENTS_FIELD_ID" "$ent"
    fi

    # Identity and profile: per-target override, else the global default for
    # this kind. refresh_identity_picker repopulates the options first, because
    # the two kinds draw from different certificate classes. A remembered
    # NO_SIGN_PREF selects the "Don't Code-sign" row, so a target that must not
    # be re-signed stays that way across relaunches.
    refresh_identity_picker "$(app_pref_get identity)"
    refresh_profile_picker "$(app_pref_get profile)"
}

# Persist the current settings: output folder and entitlements per app;
# identity and profile as global defaults, with a per-app override recorded
# only when the choice differs from the global default. Call when a pipeline
# action runs, so manual field edits are captured too.
save_app_settings() {
    local target="$(get_target)"
    if [ -z "$target" ]; then
        return 0
    fi

    app_pref_set output_dir "$(view_value "$OUTPUT_FIELD_ID")"
    if [ "$(target_kind_of "$target")" != "pkg" ]; then
        app_pref_set entitlements "$(view_value "$ENTITLEMENTS_FIELD_ID")"
    fi

    local identity_key="$(default_identity_key "$(target_kind_of "$target")")"
    local identity="$(selected_identity)"
    local def_identity
    if [ -n "$identity" ]; then
        def_identity="$(prefs_get "$identity_key")"
        if [ -z "$def_identity" ]; then
            prefs_set "$identity_key" "$identity"
            def_identity="$identity"
        fi
        if [ "$identity" = "$def_identity" ]; then
            app_pref_set identity ""
        else
            app_pref_set identity "$identity"
        fi
    elif signing_declined_by_choice; then
        # "Don't Code-sign" is remembered for this target only, never promoted to
        # the global default. It is a statement about one artifact that re-signing
        # would damage, not a preference about signing in general, and a target
        # that has never been seen before should still default to signing.
        #
        # Only when it was chosen, though - see signing_declined_by_choice. An
        # empty identity that was forced, or that came out of a lookup going
        # wrong, says nothing, so nothing is written and any earlier real choice
        # stands rather than being overwritten by it.
        app_pref_set identity "$NO_SIGN_PREF"
    fi

    local profile="$(selected_profile)"
    local def_profile
    if [ -n "$profile" ]; then
        def_profile="$(prefs_get default_profile)"
        if [ -z "$def_profile" ]; then
            prefs_set default_profile "$profile"
            def_profile="$profile"
        fi
        if [ "$profile" = "$def_profile" ]; then
            app_pref_set profile ""
        else
            app_pref_set profile "$profile"
        fi
    fi
}

# Enable or disable the entitlements field and its Browse button for a target
# kind, clearing the field when it does not apply. Arguments: kind
set_entitlements_enabled() {
    if [ "$1" = "pkg" ]; then
        set_value "$ENTITLEMENTS_FIELD_ID" ""
        enable_view "$ENTITLEMENTS_FIELD_ID" 0
        enable_view "$ENTITLEMENTS_BROWSE_ID" 0
    else
        enable_view "$ENTITLEMENTS_FIELD_ID" 1
        enable_view "$ENTITLEMENTS_BROWSE_ID" 1
    fi
}

# Reflect the current target in the window: path label, status, button state,
# and the rows that only apply to one kind of target.
refresh_target_ui() {
    local target="$(get_target)"
    if [ -n "$target" ]; then
        local kind="$(target_kind_of "$target")"
        # A package has no entitlements and no hardened runtime, so the field
        # cannot affect the outcome. Disable it rather than hiding it: ActionUI
        # maps "hidden" to SwiftUI's .hidden(), which is visual only and keeps
        # the row's space, so hiding would leave an unexplained gap.
        set_entitlements_enabled "$kind"
        apply_app_settings
        enable_view "$NOTARIZE_BTN_ID" 1
        rail_enable 1
        if [ "$kind" = "pkg" ]; then
            set_status "Ready: $(/usr/bin/basename "$target") (installer package)"
        else
            set_status "Ready: $(/usr/bin/basename "$target")"
        fi
    else
        # Reachable only when the window was opened on something unsupported -
        # the Info.plist claims every document type, so anything can be dropped
        # on the app icon. There is no in-window recovery by design (the window
        # is bound to one target), so the status line has to name the way out.
        #
        # Every setting is disabled too, not just the actions. The settings are
        # stored per product and app_prefs_key is empty with no target, so
        # app_pref_set returns early: a path typed or browsed into either field
        # here is silently thrown away. Better to refuse the input than to take
        # it and lose it.
        set_value "$ENTITLEMENTS_FIELD_ID" ""
        enable_view "$ENTITLEMENTS_FIELD_ID" 0
        enable_view "$ENTITLEMENTS_BROWSE_ID" 0
        set_value "$OUTPUT_FIELD_ID" ""
        enable_view "$OUTPUT_FIELD_ID" 0
        enable_view "$OUTPUT_BROWSE_ID" 0
        enable_view "$NOTARIZE_BTN_ID" 0
        rail_enable 0
        set_status "Nothing to notarize. Drop a .app or a flat .pkg on the Notarize icon."
    fi
}

# Print the prefs key holding the default identity for a kind. The two
# certificate classes are not interchangeable, so each kind remembers its own.
# Arguments: kind ("app" or "pkg")
default_identity_key() {
    if [ "$1" = "pkg" ]; then
        printf '%s' "default_installer_identity"
    else
        printf '%s' "default_identity"
    fi
}

# Refill the identity picker with the identities valid for the current target
# kind plus the trailing "Don't Code-sign" row, and select one: the given name
# when it is installed, else the remembered default for that kind. The ordered
# option list is persisted so handlers can resolve the picker's 1-based index
# back to a name (OMC pickers deliver and accept the index, never the title).
# Arguments: identity_name, NO_SIGN_PREF, or empty
refresh_identity_picker() {
    local kind="$(current_kind)"
    local ids="$(list_signing_identities "$kind")"
    local identities_file="$(state_dir)/identities.txt"

    # identities.txt is the index-to-name map, so the "Don't Code-sign" row has
    # to occupy a line in it too - an empty one. selected_identity then resolves
    # that row to the empty identity every downstream step already reads as "not
    # signing", and no certificate name can ever collide with it. The row goes
    # last so that index 1, the fallback whenever nothing is remembered, lands on
    # a real certificate when there is one and on this row when there is not.
    local titles
    if [ -n "$ids" ]; then
        printf '%s\n\n' "$ids" > "$identities_file"
        titles="$(printf '%s\n%s' "$ids" "$NO_SIGN_OPTION")"
    else
        printf '\n' > "$identities_file"
        titles="$NO_SIGN_OPTION"
    fi
    "$dialog_tool" "$document_uuid" "$IDENTITY_PICKER_ID" omc_set_property options "$(printf '%s\n' "$titles" | json_array_from_lines)"

    local sel="$1"
    if [ -z "$sel" ]; then
        sel="$(prefs_get "$(default_identity_key "$kind")")"
    fi

    # Always write an explicit index, never leave the previous one standing.
    # A Picker is bound to the 1-based position in its option list, so swapping
    # the list leaves the old index pointing at whatever now occupies that slot.
    # Switching a window between an app and a package swaps the list for one
    # drawn from a different certificate class entirely, and an unresolved name
    # would silently leave a stale index selected - and selected_identity would
    # then hand that wrong identity to the signing step.
    local index=""
    if [ "$sel" = "$NO_SIGN_PREF" ]; then
        # Counted from the file rather than from "$ids" so the index and the map
        # cannot disagree about where the last row is.
        index="$(/usr/bin/grep -c '' "$identities_file")"
    elif [ -n "$sel" ]; then
        index="$(printf '%s\n' "$ids" | /usr/bin/grep -n -x -F -e "$sel" | /usr/bin/head -n 1 | /usr/bin/cut -d : -f 1)"
    fi
    # A remembered per-target certificate that is no longer installed falls back
    # to the default for this kind, not to whatever happens to be first. Landing
    # on position 1 would hand the target a certificate nobody picked, and
    # save_app_settings would then write it back as a per-target override.
    if [ -z "$index" ]; then
        local default_identity="$(prefs_get "$(default_identity_key "$kind")")"
        if [ -n "$default_identity" ] && [ "$default_identity" != "$sel" ]; then
            index="$(printf '%s\n' "$ids" | /usr/bin/grep -n -x -F -e "$default_identity" | /usr/bin/head -n 1 | /usr/bin/cut -d : -f 1)"
        fi
    fi
    if [ -z "$index" ]; then
        index=1
    fi
    "$dialog_tool" "$document_uuid" "$IDENTITY_PICKER_ID" "$index"
}

# Fill the identity and profile pickers from discovery + prefs, and persist the
# ordered option lists so handlers can resolve a picker's 1-based index to a name
# (OMC pickers deliver the 1-based index, not the title).
populate_pickers() {
    refresh_identity_picker ""
    refresh_profile_picker ""
}

# Refill the document window's profile picker from prefs.known_profiles and
# select a profile: the given name if present, else the default profile.
# Targets the document window (the parent when called from the credential
# window), so a save there updates the main window immediately.
# Note: notarytool keeps profiles in Apple's data protection keychain (access
# group com.apple.gke.notary); other apps cannot enumerate them, so this list
# only ever holds names registered through this app. Arguments: profile_name
refresh_profile_picker() {
    local profs="$(known_profiles_list)"
    printf '%s\n' "$profs" > "$(state_dir)/profiles.txt"
    "$dialog_tool" "$document_uuid" "$PROFILE_PICKER_ID" omc_set_property options "$(printf '%s' "$profs" | json_array_from_lines)"

    local sel="$1"
    if [ -z "$sel" ]; then
        sel="$(prefs_get default_profile)"
    fi
    # Always write an explicit index, as refresh_identity_picker does. A Picker
    # is bound to the 1-based position in its option list, so replacing the list
    # and leaving the index alone points it at whatever now occupies that slot -
    # a different profile than the one named, chosen silently.
    # -e, because a profile name is whatever the developer typed and one starting
    # with a dash would otherwise be taken for grep's own options.
    local idx=""
    if [ -n "$sel" ]; then
        idx="$(printf '%s\n' "$profs" | /usr/bin/grep -n -x -F -e "$sel" | /usr/bin/head -n 1 | /usr/bin/cut -d : -f 1)"
    fi
    if [ -z "$idx" ]; then
        idx=1
    fi
    "$dialog_tool" "$document_uuid" "$PROFILE_PICKER_ID" "$idx"
}

# --- Control value helpers --------------------------------------------------
# Read an ActionUI view's current value from the environment. Arguments: view_id
view_value() {
    eval "printf '%s' \"\${OMC_ACTIONUI_VIEW_${1}_VALUE}\""
}

# Print the Nth (1-based) line of a file, or nothing when there is no such line.
# A missing file is one of the ways there is no such line, so sed's complaint
# about it is noise on stderr rather than news. Arguments: file, index
nth_line() {
    /usr/bin/sed -n "${2}p" "$1" 2>/dev/null
}

# Resolve the identity picker's 1-based index to the identity name. Prints
# nothing when the "Don't Code-sign" row is selected: refresh_identity_picker
# gives that row an empty line in the map, so it arrives here as the empty
# identity that sign_target, resign_reason and the pipeline already understand.
selected_identity() {
    local idx="$(view_value "$IDENTITY_PICKER_ID")"
    if [ -z "$idx" ]; then
        idx=1
    fi
    nth_line "$(state_dir)/identities.txt" "$idx"
}

# Answer whether the developer actually chose "Don't Code-sign" from a picker
# that was also offering at least one certificate. Only then is an empty identity
# a decision worth remembering.
#
# selected_identity returning nothing is not enough to conclude that. It is also
# what a missing map file or an out-of-range index produces, and recording either
# as a decline would pin a target to "Don't Code-sign" over a lookup that simply
# went wrong. The question is answered from the map the picker was built from -
# the one the developer was actually looking at - rather than by asking the
# keychain again: the picker is populated when the window opens or the target
# changes and is not rebuilt when the keychain changes underneath it, so a fresh
# "security find-identity" at save time answers about a list that was never on
# screen. That drifts in both directions - a certificate unlocked mid-session
# makes a forced decline look chosen, and a certificate that disappears makes a
# deliberate one look forced and drops it.
# Returns 0 when the decline row was chosen from a picker that offered more.
signing_declined_by_choice() {
    local map="$(state_dir)/identities.txt"
    [ -f "$map" ] || return 1
    # One row means the decline row was the only thing on offer, so selecting it
    # was not a choice - it was the absence of one.
    local rows="$(/usr/bin/grep -c '' "$map")"
    [ "$rows" -gt 1 ] 2>/dev/null || return 1
    local index="$(view_value "$IDENTITY_PICKER_ID")"
    [ -n "$index" ] || index=1
    # refresh_identity_picker always puts the decline row last, so any other
    # index that resolved to no identity is a broken lookup, not this row.
    [ "$index" = "$rows" ]
}

# Resolve the profile picker's 1-based index to the profile name.
selected_profile() {
    local idx="$(view_value "$PROFILE_PICKER_ID")"
    if [ -z "$idx" ]; then
        idx=1
    fi
    nth_line "$(state_dir)/profiles.txt" "$idx"
}

# --- Pipeline building blocks ----------------------------------------------
# Package an app bundle into a zip for the NOTARY UPLOAD ONLY (Apple's
# documented command; preserves symlinks and the bundle root the notary
# service expects). Never hand this zip to users: without --sequesterRsrc,
# ditto stores each extended attribute (e.g. com.apple.provenance) as an
# inline AppleDouble "._" entry next to its file, and Archive Utility
# extracts those as literal files inside the bundle - "unsealed contents"
# that break the code signature. Arguments: app_path, dest_zip
package_app() {
    /bin/rm -f "$2"
    /usr/bin/ditto -c -k --keepParent "$1" "$2"
}

# Work out what to upload for the target and record it in upload_path.txt.
# An app bundle has to be zipped; the notary service accepts a flat .pkg
# directly, and zipping one would only slow the upload down. Returns 0 on
# success, 1 if the archive could not be created. Arguments: path
#
# The path goes to a state file rather than stdout so a failing ditto cannot be
# mistaken for an empty-but-successful result by a caller using $( ).
prepare_upload() {
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        printf '%s' "$1" > "$(state_dir)/upload_path.txt"
        return 0
    fi

    local upload_zip="$(state_dir)/upload.zip"
    package_app "$1" "$upload_zip"
    if [ "$?" != "0" ] || [ ! -f "$upload_zip" ]; then
        /bin/rm -f "$(state_dir)/upload_path.txt"
        return 1
    fi
    printf '%s' "$upload_zip" > "$(state_dir)/upload_path.txt"
    return 0
}

# Print the artifact prepare_upload chose (empty if none).
upload_path() {
    local f="$(state_dir)/upload_path.txt"
    if [ -f "$f" ]; then
        /bin/cat "$f"
    fi
}

# Copy the target to the output folder so release signing never happens in
# place (the development copy keeps its ad-hoc signature). Prints the path the
# pipeline should operate on: the copy, or the target itself when no distinct
# output folder is set. Returns non-zero if the copy fails.
# Arguments: target_path, output_dir (may be empty)
prepare_release_copy() {
    local app="$1"
    local outdir="$2"
    local statef="$(state_dir)/release.txt"
    # Canonicalize both folders (trailing slashes, "..", symlinks) before the
    # same-folder test: comparing raw strings could route the rm -rf below at
    # the original app (e.g. an output dir of "/Apps/" for an app in "/Apps").
    # "cd -P" for the same reason canonical_path uses it - this is a path the
    # user typed, so it can hold ".." and symlinked components.
    if [ -n "$outdir" ]; then
        /bin/mkdir -p "$outdir" || return 1
        outdir="$(cd -P "$outdir" 2>/dev/null && /bin/pwd -P)"
        if [ -z "$outdir" ]; then
            return 1
        fi
    fi
    # Canonicalize the target as well (a symlinked target could otherwise alias
    # something that really lives in the output folder). canonical_path handles
    # a .pkg file as well as a .app directory.
    local real_app="$(canonical_path "$app")"
    if [ -z "$real_app" ]; then
        return 1
    fi
    local app_dir="$(/usr/bin/dirname "$real_app")"
    if [ -z "$outdir" ] || [ "$outdir" = "$app_dir" ]; then
        /bin/rm -f "$statef"
        # The resolved path, not the one that was passed in. Signing a package
        # replaces it by renaming a temporary over it, and renaming over a
        # symlink would replace the link itself with a regular file, leaving the
        # real package untouched and unsigned somewhere else.
        printf '%s' "$real_app"
        return 0
    fi
    local dest="$outdir/$(/usr/bin/basename "$app")"
    /bin/rm -rf "$dest"
    /usr/bin/ditto "$app" "$dest" || return 1
    printf '%s' "$dest" > "$statef"
    printf '%s' "$dest"
    return 0
}

# Sign an installer package with productsign. Arguments: pkg_path, identity.
# Returns 0 on success, 1 on failure.
#
# productsign cannot write in place, so it signs to a temporary neighbor which
# then replaces the original. The temporary lives in the same directory as the
# package on purpose: rename within one filesystem is atomic, so an interrupted
# run leaves either the old package or the new one, never a half-written file.
sign_package() {
    local pkg="$1"
    local identity="$2"
    local pkg_dir="$(/usr/bin/dirname "$pkg")"
    local pkg_name="$(/usr/bin/basename "$pkg")"
    local temp_pkg="$pkg_dir/.$pkg_name.notarize-signing"

    append_log "Signing $pkg_name with $identity..."
    /bin/rm -f "$temp_pkg"

    # Declared before the assignment, not with it: "local out=$(...)" would make
    # the next line read local's own exit status instead of productsign's.
    local out
    out="$("$productsign_tool" --sign "$identity" "$pkg" "$temp_pkg" 2>&1)"
    local rc=$?
    if [ -n "$out" ]; then
        append_log "$out"
    fi
    if [ "$rc" != "0" ] || [ ! -f "$temp_pkg" ]; then
        /bin/rm -f "$temp_pkg"
        append_log "ERROR: productsign failed (rc=$rc)."
        return 1
    fi

    /bin/mv -f "$temp_pkg" "$pkg"
    if [ "$?" != "0" ]; then
        /bin/rm -f "$temp_pkg"
        append_log "ERROR: could not replace $pkg_name with the signed package."
        return 1
    fi

    append_log "Signed installer package."
    return 0
}

# Write the entitlements embedded in an app's current signature to dest.
# Returns 0 and leaves the file in place when the app carries entitlements;
# returns 1 and removes it when the app carries none or is not signed.
# Arguments: app_path, dest_path
extract_entitlements() {
    local app="$1"
    local dest="$2"
    # Declared apart from its assignment so the "$?" test below reads
    # entitlement_count's status rather than local's.
    local count

    /bin/rm -f "$dest"
    "$codesign_tool" -d --entitlements - --xml "$app" > "$dest" 2>/dev/null
    if [ "$?" != "0" ] || [ ! -s "$dest" ]; then
        /bin/rm -f "$dest"
        return 1
    fi
    # An app with no entitlements still yields a well-formed but empty plist,
    # so emptiness has to be judged by the contents, not the file size.
    count="$(entitlement_count "$dest")"
    if [ "$?" != "0" ] || [ "$count" = "0" ]; then
        /bin/rm -f "$dest"
        return 1
    fi
    return 0
}

# Print the number of <key> elements in an entitlements plist, counting keys
# inside nested dictionaries too, and return 0. Return 1 without printing when
# the file is not a readable plist.
#
# "Unreadable" has to stay distinguishable from "empty". Collapsing the two
# would let a malformed or unreadable file read as "no entitlements wanted",
# which matches an app that has none - so a typo in the entitlements field would
# silently skip signing instead of failing.
# Arguments: entitlements_file
entitlement_count() {
    local norm="$(state_dir)/count-norm.plist"
    # plutil turns a whitespace-only file into an empty dictionary, which would
    # sail through the root check below and read as "no entitlements wanted".
    # codesign rejects such a file anyway, but with an opaque error partway
    # through signing rather than the clear one this function exists to give.
    if ! /usr/bin/grep -q '[^[:space:]]' "$1" 2>/dev/null; then
        return 1
    fi
    # codesign parses entitlements with its own XML reader, not plutil's, and
    # rejects the old-style ASCII syntax that plutil accepts - "{a = b;}" is a
    # valid one-key dictionary to plutil and "syntax error near line 1" to
    # codesign. Accepting it here would mean the check meant to produce a clear
    # message passes the file straight to an opaque failure.
    case "$(/usr/bin/head -c 16 "$1" 2>/dev/null)" in
        bplist*) ;;
        *'<'*) ;;
        *) return 1 ;;
    esac
    if ! /usr/bin/plutil -convert xml1 -o "$norm" "$1" 2>/dev/null; then
        return 1
    fi
    # Parsing is not enough: plutil accepts any property-list root, and an
    # old-style ASCII plist makes a bare word like "garbage" a perfectly valid
    # string. That would convert cleanly, count zero keys, and so compare equal
    # to an app carrying no entitlements. Entitlements are always a dictionary,
    # and only the root one starts at column 0 - nested dicts are indented. The
    # bracket set covers <dict>, <dict/> and <dict attr=...> alike.
    if ! /usr/bin/grep -q '^<dict[ />]' "$norm"; then
        return 1
    fi
    /usr/bin/grep -c '<key>' "$norm"
    return 0
}

# Answer whether an app's embedded entitlements are the ones in a given file.
# Comparison is over canonical XML. plutil sorts dictionary keys on conversion,
# so two plists that differ only in key order compare equal; anything plutil
# cannot read compares as different, which re-signs rather than skipping.
# Arguments: app_path, entitlements_file
# Returns 0 when they match, 1 when they differ or the file is unreadable.
entitlements_match() {
    local app="$1"
    local wanted="$2"
    local current="$(state_dir)/cmp-current.entitlements"
    local current_norm="$(state_dir)/cmp-current-norm.plist"
    local wanted_norm="$(state_dir)/cmp-wanted-norm.plist"

    if ! extract_entitlements "$app" "$current"; then
        # The app carries none, so only a readable and empty file can match.
        # Declared apart from its assignment: with "local wanted_count=$(...)"
        # the "||" would guard local's status, which is always 0, and an
        # unreadable file would be counted as a match.
        local wanted_count
        wanted_count="$(entitlement_count "$wanted")" || return 1
        [ "$wanted_count" = "0" ]
        return $?
    fi
    /usr/bin/plutil -convert xml1 -o "$current_norm" "$current" 2>/dev/null || return 1
    /usr/bin/plutil -convert xml1 -o "$wanted_norm" "$wanted" 2>/dev/null || return 1
    /usr/bin/cmp -s "$current_norm" "$wanted_norm"
}

# Answer whether one signed item carries the signature the notary service wants:
# the right certificate, a secure timestamp, and - only where it applies - the
# hardened runtime. An unsigned or ad-hoc item has no Authority line and so
# fails the first test.
#
# The runtime is asked for by the caller rather than always, because the flag
# does not mean anything on most nested code. It is a property of the process a
# main executable starts, so a framework or a loadable library that is only ever
# mapped into someone else's process does not carry it - and Apple notarizes
# apps that way every day. On this machine 15 of the 61 apps in /Applications
# that ship frameworks have at least one without the flag, Xcode, Brave and the
# whole Office suite among them, all of them Gatekeeper-accepted and stapled.
# Demanding it from every nested item would call those apps unacceptable.
# Arguments: path, identity (empty means any Developer ID Application),
# require_runtime ("yes" to insist on the hardened runtime flag)
# Returns 0 when it matches, 1 when it does not.
signed_item_matches() {
    local info="$("$codesign_tool" -dvv "$1" 2>&1)"
    local authority="$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1)"
    if [ -n "$2" ]; then
        [ "$authority" = "$2" ] || return 1
    else
        case "$authority" in
            "Developer ID Application: "*) ;;
            *) return 1 ;;
        esac
    fi
    if [ "$3" = "yes" ]; then
        case "$(printf '%s\n' "$info" | /usr/bin/sed -n 's/.*flags=\([^ ]*\).*/\1/p' | /usr/bin/head -1)" in
            *runtime*) ;;
            *) return 1 ;;
        esac
    fi
    printf '%s\n' "$info" | /usr/bin/grep -q '^Timestamp='
}

# Print the reason the target still needs signing, or nothing at all when its
# existing signature already matches every setting the window would apply.
#
# Only the full pipeline consults this. An explicit Sign Only click always
# signs: the developer asked for that specific action, and silently doing
# nothing in response to a button press is its own kind of bug.
#
# An empty identity asks a slightly different question - "is this acceptable to
# the notary service at all", rather than "does this match what was selected" -
# which is what the pipeline needs when the keychain holds no usable certificate.
# Arguments: path, identity (empty means any Developer ID), entitlements_file
# (may be empty; apps only)
# Returns 0 when signing is needed (a reason was printed), 1 when it can be
# skipped.
resign_reason() {
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        resign_reason_pkg "$1" "$2"
    else
        resign_reason_app "$1" "$2" "$3"
    fi
}

# Arguments: app_path, identity, entitlements_file (may be empty)
resign_reason_app() {
    local app="$1"
    local identity="$2"
    local entitlements="$3"
    # Set by "read" once the listing loop is reached.
    local item

    if ! "$codesign_tool" --verify --deep --strict "$app" >/dev/null 2>&1; then
        printf 'the existing signature is missing or does not verify'
        return 0
    fi
    # The notary service rejects anything without a Developer ID certificate,
    # the hardened runtime, or a secure timestamp, so a signature lacking any of
    # them has to be replaced no matter who made it.
    if ! signed_item_matches "$app" "$identity" yes; then
        local authority="$("$codesign_tool" -dvv "$app" 2>&1 | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1)"
        if [ -z "$authority" ]; then
            printf 'the outer bundle carries no Developer ID signature'
        elif [ -n "$identity" ] && [ "$authority" != "$identity" ]; then
            printf 'it is signed by "%s" rather than the selected "%s"' "$authority" "$identity"
        elif [ -z "$identity" ]; then
            printf 'it is signed by "%s", which is not a Developer ID Application certificate, or lacks the hardened runtime or a secure timestamp' "$authority"
        else
            printf 'it is not signed with the hardened runtime, or carries no secure timestamp'
        fi
        return 0
    fi
    # A valid outer signature says nothing about what is nested inside it.
    # --verify --deep --strict only confirms each seal is self-consistent, and
    # codesign -dvv on the bundle reports the outer signature alone - so an
    # ad-hoc helper, or an unsigned .dylib dropped in Resources, passes both
    # while the notary service rejects the upload. Nested code is precisely what
    # codesign_applet.sh exists to fix, so this has to cover the same set:
    # --list-code enumerates it from the signer's own discovery rather than a
    # second copy of the rules that could drift out of step with it.
    local listing="$(state_dir)/code-listing.txt"
    /bin/rm -f "$listing"
    "$codesign_applet" --list-code "$app" > "$listing" 2>/dev/null
    # An empty listing has to count as a failure, not as "nothing to check".
    # Every app bundle contains at least its own main executable, so an empty
    # result means the enumeration did not work - and treating that as all-clear
    # is exactly the fail-open this check exists to close.
    if [ "$?" != "0" ] || [ ! -s "$listing" ]; then
        printf 'the bundle contents could not be enumerated'
        return 0
    fi
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        [ "$item" = "$app" ] && continue
        # No runtime requirement here: see signed_item_matches. The outer bundle
        # is the main executable and is checked for it above.
        if ! signed_item_matches "$item" "$identity" no; then
            # Strip the bundle prefix with parameter expansion, not sed: a path
            # containing the delimiter or a regex metacharacter would otherwise
            # either error out or fail to strip.
            printf 'nested code is not signed to match: %s' "${item#"$app"/}"
            return 0
        fi
    done < "$listing"
    # An empty field means the entitlements already in the bundle are carried
    # over verbatim, so by definition nothing would change.
    if [ -n "$entitlements" ]; then
        if [ ! -f "$entitlements" ]; then
            printf 'the entitlements file "%s" is missing' "$entitlements"
            return 0
        fi
        if ! entitlement_count "$entitlements" >/dev/null; then
            printf 'the entitlements file "%s" is not a readable plist' "$entitlements"
            return 0
        fi
        if ! entitlements_match "$app" "$entitlements"; then
            printf 'its entitlements differ from those in "%s"' "$entitlements"
            return 0
        fi
    fi
    return 1
}

# Arguments: pkg_path, identity
resign_reason_pkg() {
    local pkg="$1"
    local identity="$2"
    local info="$("$pkgutil_tool" --check-signature "$pkg" 2>&1)"

    case "$info" in
        *'Status: signed by a developer certificate issued by Apple for distribution'*) ;;
        *)
            printf 'it is not signed for distribution with a Developer ID Installer certificate'
            return 0
            ;;
    esac
    if ! printf '%s\n' "$info" | /usr/bin/grep -q 'Signed with a trusted timestamp on:'; then
        printf 'its signature carries no trusted timestamp'
        return 0
    fi
    # With no identity to compare against, the distribution status above is the
    # whole question: the package is acceptable to the notary service whoever
    # signed it.
    if [ -n "$identity" ]; then
        local leaf="$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^ *1\. *//p' | /usr/bin/head -1)"
        if [ "$leaf" != "$identity" ]; then
            printf 'it is signed by "%s" rather than the selected "%s"' "$leaf" "$identity"
            return 0
        fi
    fi
    return 1
}

# Sign the target for release, dispatching on its kind. Arguments: path,
# identity, entitlements_file (ignored for a package).
# Returns 0 on success, 1 on failure.
sign_target() {
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        sign_package "$1" "$2"
    else
        sign_app "$1" "$2" "$3"
    fi
}

# Sign the target app for release by delegating to the bundled
# codesign_applet.sh (copied from OMC Distribution/Scripts): it signs nested
# executables in Contents/Helpers|Library|Support, each framework's Support
# tools, the frameworks, and the bundle itself, then verifies. It is invoked
# with --brief, so its output is a compact summary by design (no per-file
# signing chatter, banners, or dividers); that output is captured to
# state_dir/sign.log and mirrored verbatim into the UI log.
#
# The entitlements field in the window decides what gets applied, and the signer
# is called with --no-entitlements-search so nothing the developer cannot see on
# screen can creep in. When the field is empty the entitlements already in the
# bundle are carried over: signing is a replacement, not an amendment, so a
# sandboxed app re-signed with none would come out unsandboxed carrying a
# perfectly valid signature that the notary service would happily accept.
# Arguments: app_path, identity, entitlements_file (may be empty).
# Returns 0 on success, 1 on failure.
sign_app() {
    local app="$1"
    local identity="$2"
    local entitlements="$3"

    if [ -n "$entitlements" ]; then
        if [ ! -f "$entitlements" ]; then
            append_log "ERROR: entitlements file not found: $entitlements"
            return 1
        fi
        if ! entitlement_count "$entitlements" >/dev/null; then
            append_log "ERROR: the entitlements file is not a readable plist: $entitlements"
            return 1
        fi
        append_log "Entitlements: $entitlements ($(entitlement_count "$entitlements") keys)."
    else
        local inherited="$(state_dir)/inherited.entitlements"
        if extract_entitlements "$app" "$inherited"; then
            entitlements="$inherited"
            append_log "Entitlements: none set in the window - carrying over the entitlements already in the signature ($(entitlement_count "$inherited") keys), which re-signing would otherwise drop."
        else
            append_log "Entitlements: none set in the window, and the existing signature carries none."
        fi
    fi

    local signlog="$(state_dir)/sign.log"
    append_log "Signing $(/usr/bin/basename "$app") (log: sign.log)..."
    "$codesign_applet" --brief --no-entitlements-search "$app" "$identity" "$entitlements" > "$signlog" 2>&1
    local rc=$?

    # Brief output is already curated; mirror every line into the UI log.
    # Set by "read", so declared rather than initialized.
    local line
    while IFS= read -r line; do
        append_log "$line"
    done < "$signlog"

    if [ "$rc" != "0" ]; then
        append_log "ERROR: signing failed (rc=$rc)."
        return 1
    fi
    append_log "Signed for release."
    return 0
}

# Verify the app's code signature; append the result to the log. Args: app_path
run_codesign_verify() {
    append_log "Verifying code signature..."
    local out
    out="$("$codesign_tool" --verify --strict --verbose=2 "$1" 2>&1)"
    local rc=$?
    _log "$out"
    if [ "$rc" = "0" ]; then
        append_log "Code signature is valid."
        return 0
    fi
    append_log "Code signature verification FAILED:"
    append_log "$out"
    return 1
}

# Succeed (0) if an installer package is signed with a Developer ID Installer
# certificate. Used to let a pre-signed package through when signing is turned
# off. Arguments: pkg_path
#
# The full phrase matters. pkgutil reports plenty of other statuses that also
# begin "signed by" - "signed by untrusted certificate", "signed by a
# certificate that has since expired", "signed by a developer certificate
# issued by Apple (Development)" - and matching the prefix would wave through
# exactly the packages this check exists to stop, only for the notary service
# to reject them after the upload.
package_is_signed() {
    "$pkgutil_tool" --check-signature "$1" 2>/dev/null \
        | /usr/bin/grep -q "Status: signed by a developer certificate issued by Apple for distribution"
}

# Report an installer package's signature; append the result to the log.
# Arguments: pkg_path
#
# The verdict comes from the reported status rather than pkgutil's exit code:
# an unsigned package is a successful query with a "no signature" answer, not a
# tool failure, and only the former should be treated as a signature problem.
run_pkg_signature_check() {
    append_log "Checking installer package signature..."
    local out="$("$pkgutil_tool" --check-signature "$1" 2>&1)"
    append_log "$out"
    if package_is_signed "$1"; then
        return 0
    fi
    append_log "The package is not signed with a Developer ID Installer certificate."
    return 1
}

# Verify the target's signature, dispatching on its kind. Arguments: path
run_signature_verify() {
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        run_pkg_signature_check "$1"
    else
        run_codesign_verify "$1"
    fi
}

# The one line list_uncertified_nested_items emits that is not an item: the
# enumeration itself failed, so nothing can be concluded about the bundle.
# Callers match on it to say so rather than blaming the contents.
nested_enum_failed="  (the bundle contents could not be enumerated)"

# Print every nested code item that carries no certificate chain, one indented
# line each. Prints nothing when they are all properly signed.
#
# Enumeration comes from the signer's own --list-code, exactly as resign_reason
# does, so this cannot check a narrower set than codesign_applet.sh would fix.
# Arguments: app_path
list_uncertified_nested_items() {
    local app="$1"
    local listing="$(state_dir)/preflight-listing.txt"
    /bin/rm -f "$listing"
    "$codesign_applet" --list-code "$app" > "$listing" 2>/dev/null
    local rc=$?
    # Every app bundle holds at least its own main executable, so an empty
    # listing means the enumeration failed. Reporting that beats reporting
    # all-clear, which is the fail-open this check exists to close. The exit
    # status matters too: a bundle path the signer rejects outright produces a
    # short listing that would otherwise be walked as if it held item paths.
    if [ "$rc" != "0" ] || [ ! -s "$listing" ]; then
        printf '%s\n' "$nested_enum_failed"
        return 0
    fi
    local item info authority
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        info="$("$codesign_tool" -dvv "$item" 2>&1)"
        case "$info" in
            *"code object is not signed at all"*)
                printf '  %s - not signed\n' "${item#"$app"/}"
                continue
                ;;
        esac
        authority="$(printf '%s\n' "$info" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1)"
        if [ -n "$authority" ]; then
            continue
        fi
        if printf '%s\n' "$info" | /usr/bin/grep -q '^Signature=adhoc'; then
            printf '  %s - ad-hoc signature, no certificate\n' "${item#"$app"/}"
        else
            printf '  %s - no signing authority\n' "${item#"$app"/}"
        fi
    done < "$listing"
}

# Preflight the one defect that survives every other check in this pipeline:
# nested code carrying an ad-hoc signature, or none at all.
#
# codesign --verify --deep --strict accepts an ad-hoc nested signature - the
# seal is self-consistent - and so does the notary service, which enforces
# Developer ID, the hardened runtime and a secure timestamp on Mach-O code only.
# An app can therefore sign, notarize and staple cleanly and still be refused by
# Gatekeeper, which evaluates EVERY nested item against its policy rules and
# finds an ad-hoc signature has no certificate chain to match one with.
#
# Catching it here rather than after stapling saves an upload and a round trip
# through the notary service. Arguments: path
# Returns 0 when every nested item is properly signed, 1 otherwise.
preflight_nested_code() {
    # A flat package has no nested code to walk; pkgutil already covers it.
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        return 0
    fi
    local offenders="$(list_uncertified_nested_items "$1")"
    if [ -z "$offenders" ]; then
        append_log "Preflight: all nested code carries a certificate chain."
        return 0
    fi
    if [ "$offenders" = "$nested_enum_failed" ]; then
        append_log "Preflight FAILED: the bundle's contents could not be enumerated, so its nested code cannot be cleared for Gatekeeper. Check that the path is a readable app bundle."
        return 1
    fi
    append_log "Preflight FAILED: nested code without a usable certificate chain:"
    append_log "$offenders"
    append_log "Gatekeeper rejects the whole app when any nested item is ad-hoc signed or unsigned, even after notarization and stapling succeed."
    append_log "Sign the app with this window's Sign step (or Actions > Sign Only), which signs every nested item including non-code files in Contents/Helpers."
    return 1
}

# Explain a Gatekeeper rejection. spctl reports a bare "rejected" with no reason
# when a nested item matches no policy rule, so the log needs the reason spelled
# out. Arguments: path, spctl_output
explain_spctl_rejection() {
    case "$2" in
        *"Unnotarized Developer ID"*)
            append_log "Reason: the signature is a valid Developer ID but this exact build has no notarization ticket. Re-signing after notarizing invalidates the ticket - notarize and staple this copy."
            return 0
            ;;
        *"no usable signature"*)
            append_log "Reason: the bundle's signature is missing or unreadable. Note that stripping extended attributes (xattr -c) destroys the signatures of non-code files in Contents/Helpers and similar nested-code directories."
            return 0
            ;;
    esac
    # A flat package has no nested code to walk, but it still deserves a reason
    # line rather than a bare "rejected" - fall through to the fallback below.
    local offenders=""
    if [ "$(target_kind_of "$1")" != "pkg" ]; then
        offenders="$(list_uncertified_nested_items "$1")"
        # An enumeration failure is not a list of offending items; presenting it
        # as one would blame the contents for a walk that never happened.
        if [ "$offenders" = "$nested_enum_failed" ]; then
            offenders=""
        fi
    fi
    if [ -n "$offenders" ]; then
        append_log "Reason: these nested items carry no certificate chain, so Gatekeeper can match no policy rule for them:"
        append_log "$offenders"
        append_log "Console shows one \"rejecting due to lack of matching active rule\" from syspolicyd per item. Re-sign the app to fix them."
    else
        append_log "Reason: not determined here. Check Console for syspolicyd messages from com.apple.securityd:gk during the assessment."
    fi
}

# Gatekeeper assessment; append the result to the log and return spctl's
# exit code. An installer package is assessed against the install policy, an
# app against the execute policy - passing the wrong one reports a failure that
# says nothing about the artifact. Arguments: path
run_spctl() {
    # Set in one branch or the other; "out" is declared apart from its
    # assignment so the next line reads spctl's exit status, not local's.
    local assessment_type out
    if [ "$(target_kind_of "$1")" = "pkg" ]; then
        assessment_type="install"
    else
        assessment_type="execute"
    fi
    append_log "Gatekeeper assessment (--type $assessment_type):"
    out="$("$spctl_tool" --assess --type "$assessment_type" --verbose=4 "$1" 2>&1)"
    local rc=$?
    append_log "$out"
    if [ "$rc" != "0" ]; then
        explain_spctl_rejection "$1" "$out"
    fi
    return $rc
}

# Submit a zip to the notary service and wait for a terminal status. Writes the
# submission id and status to state files. Arguments: zip_path, profile_name.
# Returns 0 if a terminal status was obtained.
submit_and_wait() {
    local out="$(state_dir)/notary-submit.json"
    append_log "Uploading to the Apple notary service (this can take several minutes)..."
    "$xcrun_tool" notarytool submit "$1" --keychain-profile "$2" --wait --output-format json --timeout 30m > "$out" 2>> "$(state_dir)/run.log"
    local rc=$?
    local id="$("$plister" get value "$out" /id 2>/dev/null)"
    local status="$("$plister" get value "$out" /status 2>/dev/null)"
    printf '%s' "$id" > "$(state_dir)/submission_id.txt"
    printf '%s' "$status" > "$(state_dir)/submission_status.txt"
    if [ -z "$status" ]; then
        append_log "ERROR: no status returned from the notary service (rc=$rc)."
        return 1
    fi
    append_log "Notary service status: $status (submission id $id)"
    return 0
}

# Print the stored submission id (empty if none).
submission_id() {
    local f="$(state_dir)/submission_id.txt"
    if [ -f "$f" ]; then
        /bin/cat "$f"
    fi
}

# Print the stored submission status (empty if none).
submission_status() {
    local f="$(state_dir)/submission_status.txt"
    if [ -f "$f" ]; then
        /bin/cat "$f"
    fi
}

# Fetch the notarization log for a submission id into state_dir/notary-log.json.
# Arguments: submission_id, profile_name
fetch_log() {
    local logf="$(state_dir)/notary-log.json"
    "$xcrun_tool" notarytool log "$1" --keychain-profile "$2" "$logf" 2>> "$(state_dir)/run.log"
    return $?
}

# Append the issues from the fetched notary log to the run log.
print_issues() {
    local logf="$(state_dir)/notary-log.json"
    if [ ! -f "$logf" ]; then
        return 0
    fi
    local summary="$("$plister" get value "$logf" /statusSummary 2>/dev/null)"
    if [ -n "$summary" ]; then
        append_log "Summary: $summary"
    fi
    local n="$("$plister" get count "$logf" /issues 2>/dev/null)"
    if [ -z "$n" ]; then
        return 0
    fi
    append_log "Issues ($n):"
    local i=0
    while [ "$i" -lt "$n" ]; do
        local sev="$("$plister" get value "$logf" "/issues/$i/severity" 2>/dev/null)"
        local msg="$("$plister" get value "$logf" "/issues/$i/message" 2>/dev/null)"
        local path="$("$plister" get value "$logf" "/issues/$i/path" 2>/dev/null)"
        append_log "  [$sev] $msg ($path)"
        i=$((i + 1))
    done
}

# Staple the notarization ticket to the app and validate. Arguments: app_path
staple_app() {
    append_log "Stapling notarization ticket..."
    "$xcrun_tool" stapler staple "$1"
    if [ "$?" != "0" ]; then
        append_log "ERROR: stapling failed."
        return 1
    fi
    "$xcrun_tool" stapler validate "$1"
    if [ "$?" != "0" ]; then
        append_log "WARNING: staple validation reported a problem."
    fi
    append_log "Stapled."
    return 0
}
