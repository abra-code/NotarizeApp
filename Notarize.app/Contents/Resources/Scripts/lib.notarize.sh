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

# System tools are called by absolute path inline (e.g. /usr/bin/codesign).

# --- View IDs (match Notarize.json) ---
# Toolbar
NOTARIZE_BTN_ID=30
CANCEL_BTN_ID=32
CREDENTIALS_BTN_ID=33
# Application group
APP_PATH_ID=40
CHOOSE_APP_BTN_ID=41
# Settings group
IDENTITY_PICKER_ID=50
PROFILE_PICKER_ID=51
ENTITLEMENTS_FIELD_ID=52
ENTITLEMENTS_BROWSE_ID=53
OUTPUT_FIELD_ID=54
OUTPUT_BROWSE_ID=55
SIGN_TOGGLE_ID=56
STAPLE_TOGGLE_ID=57
DISTZIP_TOGGLE_ID=58
# Progress + log
STATUS_ID=60
PROGRESS_ID=61
LOG_ID=62
REVEAL_BTN_ID=63
FETCHLOG_BTN_ID=64
# Step rail (status Image + run Button per pipeline stage)
RAIL_SIGN_ID=210
RAIL_CHECK_ID=211
RAIL_SUBMIT_ID=212
RAIL_STAPLE_ID=213
RAIL_PACKAGE_ID=214
RAIL_VALIDATE_ID=215
RAIL_ICON_IDS="210 211 212 213 214 215"
RAIL_BTN_IDS="220 221 222 223 224 225"
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
prefs_dir="$HOME/Library/Application Support/Notarize"
prefs_file="$prefs_dir/prefs.plist"

# --- Per-document pasteboard keys ---
PB_BUSY="ntz_busy_${document_uuid}"
PB_SUBMISSION="ntz_submission_${document_uuid}"
# Credential wizard state, keyed to the credential window itself
PB_CRED_METHOD="ntz_credmethod_${window_uuid}"

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

# Enable (1) or disable (0) all step-run buttons, incl. Fetch Log. Arguments: flag
rail_enable() {
    local id
    for id in $RAIL_BTN_IDS $FETCHLOG_BTN_ID; do
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

# --- Discovery --------------------------------------------------------------
# Print available "Developer ID Application" identities, one full name per line.
list_developer_id_identities() {
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/grep "Developer ID Application" \
        | /usr/bin/sed 's/.*"\(.*\)".*/\1/'
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

# --- Target app -------------------------------------------------------------
# Succeed (0) if the path is a .app bundle directory. Arguments: path
is_app_bundle() {
    case "$1" in
        *.app) [ -d "$1" ] ;;
        *) return 1 ;;
    esac
}

# Strip the file:// scheme (and optional host) and percent-decode a file URL.
# Arguments: url
url_to_path() {
    local raw="$(printf '%s' "$1" | /usr/bin/sed 's|^file://[^/]*||')"
    printf '%b' "$(printf '%s' "$raw" | /usr/bin/sed 's/%/\\x/g')"
}

# Store the target app path. Arguments: path
set_target() {
    printf '%s' "$1" > "$(state_dir)/target.txt"
}

# Print the stored target app path (empty if none).
get_target() {
    local f="$(state_dir)/target.txt"
    if [ -f "$f" ]; then
        /bin/cat "$f"
    fi
}

# Reflect the current target in the window: path label, status, button state.
refresh_target_ui() {
    local target="$(get_target)"
    if [ -n "$target" ]; then
        set_value "$APP_PATH_ID" "$target"
        enable_view "$NOTARIZE_BTN_ID" 1
        rail_enable 1
        set_status "Ready: $(/usr/bin/basename "$target")"
    else
        set_value "$APP_PATH_ID" "No app chosen - drop a .app on the log area or click Choose App."
        enable_view "$NOTARIZE_BTN_ID" 0
        rail_enable 0
        set_status "Drop an app to notarize, or choose one."
    fi
}

# Fill the identity and profile pickers from discovery + prefs, and persist the
# ordered option lists so handlers can resolve a picker's 1-based index to a name
# (OMC pickers deliver the 1-based index, not the title).
populate_pickers() {
    local ids="$(list_developer_id_identities)"
    printf '%s\n' "$ids" > "$(state_dir)/identities.txt"
    set_property "$IDENTITY_PICKER_ID" options "$(printf '%s' "$ids" | json_array_from_lines)"

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
    if [ -n "$sel" ]; then
        # Resolve the name to its 1-based index (pickers are set by index).
        local idx="$(printf '%s\n' "$profs" | /usr/bin/grep -n -x -F "$sel" | /usr/bin/head -n 1 | /usr/bin/cut -d : -f 1)"
        if [ -n "$idx" ]; then
            "$dialog_tool" "$document_uuid" "$PROFILE_PICKER_ID" "$idx"
        fi
    fi
}

# --- Control value helpers --------------------------------------------------
# Read an ActionUI view's current value from the environment. Arguments: view_id
view_value() {
    eval "printf '%s' \"\${OMC_ACTIONUI_VIEW_${1}_VALUE}\""
}

# Print the Nth (1-based) line of a file. Arguments: file, index
nth_line() {
    /usr/bin/sed -n "${2}p" "$1"
}

# Resolve the identity picker's 1-based index to the identity name.
selected_identity() {
    local idx="$(view_value "$IDENTITY_PICKER_ID")"
    if [ -z "$idx" ]; then
        idx=1
    fi
    nth_line "$(state_dir)/identities.txt" "$idx"
}

# Resolve the profile picker's 1-based index to the profile name.
selected_profile() {
    local idx="$(view_value "$PROFILE_PICKER_ID")"
    if [ -z "$idx" ]; then
        idx=1
    fi
    nth_line "$(state_dir)/profiles.txt" "$idx"
}

# Succeed (0) if a toggle is on. Treats 0/false/no/off as off, anything else
# (including empty/default) as on. Arguments: view_id
toggle_on() {
    local v="$(view_value "$1")"
    case "$v" in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) return 0 ;;
    esac
}

# --- Pipeline building blocks ----------------------------------------------
# Package an app bundle into a zip with ditto (the correct tool for bundles -
# preserves symlinks and the bundle root the notary service expects).
# Arguments: app_path, dest_zip
package_app() {
    /bin/rm -f "$2"
    /usr/bin/ditto -c -k --keepParent "$1" "$2"
}

# Sign the target app for release, inside-out (nested executables and frameworks
# first, then the bundle), with the hardened runtime and a secure timestamp.
# Mirrors AppletBuilder's codesign_applet.sh. Arguments: app_path, identity,
# entitlements_file (may be empty). Returns 0 on success.
sign_app() {
    local app="$1"
    local identity="$2"
    local entitlements="$3"

    # Identity comes from the Developer ID Application list, so enable the
    # hardened runtime and a secure timestamp (both required for notarization).
    local sign_options="--options runtime"
    local timestamp="--timestamp"
    local ent_arg=""
    if [ -n "$entitlements" ] && [ -f "$entitlements" ]; then
        ent_arg="--entitlements $entitlements"
    fi

    append_log "Removing quarantine attribute..."
    /usr/bin/xattr -dr com.apple.quarantine "$app" 2>/dev/null

    # Nested executables first: Helpers, Library, Support.
    local dir f kind out
    for dir in "$app/Contents/Helpers" "$app/Contents/Library" "$app/Contents/Support"; do
        if [ -d "$dir" ]; then
            append_log "Signing nested executables in $(/usr/bin/basename "$dir")..."
            /usr/bin/find "$dir" -type f -perm +111 -print 2>/dev/null > "$(state_dir)/_execs.txt"
            while IFS= read -r f; do
                if [ -z "$f" ]; then
                    continue
                fi
                kind="$(/usr/bin/file -b "$f")"
                case "$kind" in
                    *Mach-O*|*executable*|*script*)
                        out="$(/usr/bin/codesign --force --verbose $sign_options $timestamp --sign "$identity" "$f" 2>&1)"
                        _log "$out"
                        ;;
                esac
            done < "$(state_dir)/_execs.txt"
        fi
    done

    # Frameworks next.
    if [ -d "$app/Contents/Frameworks" ]; then
        local fw
        for fw in "$app/Contents/Frameworks"/*.framework; do
            if [ -d "$fw" ]; then
                append_log "Signing framework: $(/usr/bin/basename "$fw")"
                out="$(/usr/bin/codesign --force --verbose $sign_options $timestamp --sign "$identity" "$fw" 2>&1)"
                _log "$out"
            fi
        done
    fi

    # The bundle itself, last.
    append_log "Signing app bundle: $(/usr/bin/basename "$app")"
    local app_id="$(/usr/bin/defaults read "$app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)"
    local id_arg=""
    if [ -n "$app_id" ]; then
        id_arg="--identifier $app_id"
    fi
    /usr/bin/codesign --force --verbose $sign_options $ent_arg $timestamp $id_arg --sign "$identity" "$app" 2>&1
    if [ "$?" != "0" ]; then
        append_log "ERROR: signing the app bundle failed."
        return 1
    fi
    append_log "Signed for release."
    return 0
}

# Verify the app's code signature; append the result to the log. Args: app_path
run_codesign_verify() {
    append_log "Verifying code signature..."
    local out
    out="$(/usr/bin/codesign --verify --strict --verbose=2 "$1" 2>&1)"
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

# Gatekeeper assessment; append the result to the log and return spctl's
# exit code. Arguments: app_path
run_spctl() {
    append_log "Gatekeeper assessment:"
    local out
    out="$(/usr/sbin/spctl --assess --type execute --verbose=4 "$1" 2>&1)"
    local rc=$?
    append_log "$out"
    return $rc
}

# Submit a zip to the notary service and wait for a terminal status. Writes the
# submission id and status to state files. Arguments: zip_path, profile_name.
# Returns 0 if a terminal status was obtained.
submit_and_wait() {
    local out="$(state_dir)/notary-submit.json"
    append_log "Uploading to the Apple notary service (this can take several minutes)..."
    /usr/bin/xcrun notarytool submit "$1" --keychain-profile "$2" --wait --output-format json --timeout 30m > "$out" 2>> "$(state_dir)/run.log"
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
    /usr/bin/xcrun notarytool log "$1" --keychain-profile "$2" "$logf" 2>> "$(state_dir)/run.log"
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
    /usr/bin/xcrun stapler staple "$1"
    if [ "$?" != "0" ]; then
        append_log "ERROR: stapling failed."
        return 1
    fi
    /usr/bin/xcrun stapler validate "$1"
    if [ "$?" != "0" ]; then
        append_log "WARNING: staple validation reported a problem."
    fi
    append_log "Stapled."
    return 0
}

# Compute the distribution zip path. Arguments: app_path, output_dir (may be empty)
dist_zip_path() {
    local app="$1"
    local outdir="$2"
    if [ -z "$outdir" ]; then
        outdir="$(/usr/bin/dirname "$app")"
    fi
    local base="$(/usr/bin/basename "$app" .app)"
    printf '%s/%s-notarized.zip' "$outdir" "$base"
}
