#!/bin/sh

brief="no"
entitlements_search="yes"
list_code="no"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --brief)
            brief="yes"
            shift
            ;;
        --list-code)
            # Print every path this script would sign, one per line, and exit
            # without touching anything. Lets a caller check the same set.
            list_code="yes"
            shift
            ;;
        --no-entitlements-search)
            # The caller decides the entitlements and passes them explicitly.
            # Without this, a bundle signed from an arbitrary folder can pick up
            # a stray .entitlements file the user never saw. See the discovery
            # block below.
            entitlements_search="no"
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Print only in default (non-brief) mode. Used for banners, dividers, blank-line
# spacers, and per-file progress that brief mode collapses into summaries.
verbose_echo() {
    if [ "$brief" != "yes" ]; then
        echo "$@"
    fi
}

# codesign is silent on success without --verbose (errors still go to stderr);
# brief mode drops --verbose from the signing invocations.
cs_verbose="--verbose"
if [ "$brief" = "yes" ]; then
    cs_verbose=""
fi

# Run codesign; in brief mode filter its routine "replacing existing
# signature" notes from the output while preserving the exit status.
run_codesign() {
    if [ "$brief" = "yes" ]; then
        local cs_out cs_rc
        cs_out=$(/usr/bin/codesign "$@" 2>&1)
        cs_rc=$?
        cs_out=$(printf '%s\n' "$cs_out" | /usr/bin/grep -v ': replacing existing signature$')
        if [ -n "$cs_out" ]; then
            echo "$cs_out"
        fi
        return $cs_rc
    fi
    /usr/bin/codesign "$@"
}

self_dir=$(/usr/bin/dirname "$0")
app_to_sign="$1"
identity="$2"
entitlements_override="$3"

if test -z "$app_to_sign"; then
    echo "Usage: $0 [--brief] [--no-entitlements-search] <path/to/app> [identity] [entitlements_file]"
    echo ""
    echo "Deep-signs the bundle regardless of its layout, replacing the deprecated"
    echo "'codesign --deep'. It signs every standalone Mach-O executable and library"
    echo "individually (wherever they live), then every nested code bundle"
    echo "(app/appex/framework/xpc/plugin/bundle/kext/qlgenerator/mdimporter) as a"
    echo "bundle, deepest-first, and finally the app bundle itself."
    echo ""
    echo "Arguments:"
    echo "  --brief            (optional) Print a compact summary instead of full output"
    echo "  --no-entitlements-search  (optional) Use only the entitlements_file argument;"
    echo "                     never look for a .entitlements file next to the bundle"
    echo "  --list-code        (optional) Print every path that would be signed and exit"
    echo "                     without modifying anything"
    echo "  path/to/app        Path to the .app bundle to codesign"
    echo "  identity           (optional) Signing identity. Use '-' for ad-hoc signing"
    echo "  entitlements_file  (optional) Entitlements plist, overriding auto-discovery"
    echo ""
    echo "Examples:"
    echo "  $0 MyApp.app"
    echo "  $0 MyApp.app 'TEAMID123'"
    echo "  $0 --brief MyApp.app 'TEAMID123' MyApp.entitlements"
    echo ""
    exit 1
fi

# full path
app_to_sign_arg="$app_to_sign"
app_to_sign=$(/bin/realpath "$app_to_sign" 2>/dev/null)
if [ -z "$app_to_sign" ] || [ ! -d "$app_to_sign" ]; then
    echo "error: not a bundle directory: $app_to_sign_arg"
    exit 1
fi

# The two discovery passes, as functions so that everything which needs to know
# what this script would sign - phase 1, phase 2, and --list-code - agrees by
# construction. A caller that decides whether signing can be skipped has to
# inspect exactly this set; anything narrower would pass over code this script
# would have fixed.

# Every loose Mach-O anywhere in the bundle. The executable bit alone is not
# sufficient: many dynamic libraries and plugins (*.dylib, *.so, *.node) ship
# without it yet still contain Mach-O code that the notary service will flag if
# left unsigned. Executable *scripts* are filtered out - the notary service only
# inspects Mach-O, and a script's signature lives in an extended attribute that
# ordinary transport (zip, ditto, network copy) sheds anyway.
list_macho_files() {
    /usr/bin/find "$app_to_sign" -type f \( -perm +111 -o -name "*.dylib" -o -name "*.so" -o -name "*.node" \) ! -path "*/_CodeSignature/*" -print \
        | /usr/bin/sort \
        | while IFS= read -r f; do
            if /usr/bin/file -b "$f" | /usr/bin/grep -q "Mach-O"; then
                printf '%s\n' "$f"
            fi
        done
}

# Every nested code bundle, deepest-first (most path components first) so that
# children are sealed before the parents that embed them.
list_nested_bundles() {
    /usr/bin/find "$app_to_sign" -mindepth 1 -type d \( -name "*.app" -o -name "*.appex" -o -name "*.framework" -o -name "*.xpc" -o -name "*.plugin" -o -name "*.bundle" -o -name "*.kext" -o -name "*.qlgenerator" -o -name "*.mdimporter" \) -print \
        | /usr/bin/awk -F/ '{ printf "%05d\t%s\n", NF, $0 }' \
        | /usr/bin/sort -rn \
        | /usr/bin/cut -f2-
}

# The subset of the above that phase 2 will actually put a signature on, which
# is what a caller checking "is this already signed" has to look at. Matching on
# name alone is not the same question: phase 2 skips a directory with no
# Info.plist, and signs a versioned framework one version directory at a time
# rather than at its root.
#
# The difference is not academic. A resource-only *.bundle - an Apple privacy
# manifest, a localized strings bundle - is named like a bundle, contains no
# code, and is never signed. Demanding a signature from it can never succeed, so
# listing it would block the skip permanently for the many apps that ship one.
# The dispatch below deliberately mirrors phase 2's; the two must agree.
list_signed_bundles() {
    local bundle verdir versioned
    list_nested_bundles | while IFS= read -r bundle; do
        case "$bundle" in
            *.framework)
                versioned="no"
                for verdir in "$bundle"/Versions/*; do
                    if [ -f "$verdir/Resources/Info.plist" ]; then
                        versioned="yes"
                        break
                    fi
                done
                if [ "$versioned" = "yes" ]; then
                    for verdir in "$bundle"/Versions/*; do
                        if [ -d "$verdir" ] && [ ! -L "$verdir" ]; then
                            printf '%s\n' "$verdir"
                        fi
                    done
                elif [ -f "$bundle/Resources/Info.plist" ]; then
                    printf '%s\n' "$bundle"
                fi
                ;;
            *)
                if [ -f "$bundle/Contents/Info.plist" ]; then
                    printf '%s\n' "$bundle"
                fi
                ;;
        esac
    done
}

# Read-only query, handled before anything with a side effect: no quarantine
# strip, no Info.plist requirement, no signing.
if [ "$list_code" = "yes" ]; then
    list_macho_files
    list_signed_bundles
    exit 0
fi

app_id=$(/usr/bin/defaults read "$app_to_sign/Contents/Info.plist" CFBundleIdentifier)
if test "$?" != "0"; then
    echo "error: could not obtain bundle identifier for app at: $app_to_sign"
    exit 1
fi

verbose_echo "Removing quarantine xattr"
/usr/bin/xattr -dr 'com.apple.quarantine' "$app_to_sign" 2>/dev/null

app_dir=$(/usr/bin/dirname "$app_to_sign")

# Look for entitlements:
# 1. OMCApplet.entitlements next to the applet being signed
# 2. First *.entitlements file next to the applet
# 3. Default fallback in directory next to this script
#
# Steps 2 and 3 are guesses about a bundle whose folder we do not control, so
# --no-entitlements-search turns them off and makes the explicit argument the
# only source. Callers that sign arbitrary bundles should pass it: re-signing
# drops whatever entitlements the bundle already carried, and picking up an
# unrelated neighbouring file is worse than dropping them.
entitlements_file=""
if [ "$entitlements_search" = "no" ]; then
    if [ -n "$entitlements_override" ]; then
        if [ ! -f "$entitlements_override" ]; then
            echo "error: entitlements file not found: $entitlements_override"
            exit 1
        fi
        entitlements_file="$entitlements_override"
    fi
elif [ -n "$entitlements_override" ] && [ -f "$entitlements_override" ]; then
    entitlements_file="$entitlements_override"
elif [ -f "$app_dir/OMCApplet.entitlements" ]; then
    entitlements_file="$app_dir/OMCApplet.entitlements"
else
    first_ent=$(/bin/ls "$app_dir"/*.entitlements 2>/dev/null | /usr/bin/head -1)
    if [ -n "$first_ent" ] && [ -f "$first_ent" ]; then
        entitlements_file="$first_ent"
    elif [ -f "$self_dir/OMCApplet.entitlements" ]; then
        entitlements_file="$self_dir/OMCApplet.entitlements"
    fi
fi

is_developer_id="no"

if test -z "$identity" || test "$identity" = "-"; then
    identity="-"
    timestamp="--timestamp=none"
    sign_options=""
    # Ad-hoc signing has never applied entitlements to anything, discovered or
    # otherwise. The invariant used to be implicit - the --entitlements flag was
    # only ever assembled inside the else branch below - so clear the file here
    # to keep it true now that the flag is built at the call site. The nested
    # entitlements cache is skipped for the same reason, so ad-hoc runs stay
    # byte-for-byte equivalent to what this script has always done.
    entitlements_file=""
else
    if [ -n "$entitlements_file" ]; then
        echo "Using entitlements: $entitlements_file"
    elif [ "$entitlements_search" = "no" ]; then
        # Only reported for callers that opted out of discovery; staying silent
        # here otherwise keeps the output identical to the shipped version.
        echo "No entitlements file: signing the outer bundle without entitlements."
    fi

    # Check if this is an Apple-issued Developer ID certificate by resolving the
    # identity (team ID, fingerprint, or full name) to its certificate name in
    # the keychain, then checking for "Developer ID" in the result.
    full_cert_name=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep "$identity" | /usr/bin/sed 's/.*"\(.*\)".*/\1/' | /usr/bin/head -1)
    developer_id_check=$(echo "$full_cert_name" | /usr/bin/grep "Developer ID")
    if test -n "$developer_id_check"; then
        is_developer_id="yes"
        timestamp="--timestamp"
        sign_options="--options runtime"
    else
        # Self-signed or other non-Apple certs:
        # - No timestamp server (Apple's TSA won't service non-Apple certs)
        # - No hardened runtime (requires Gatekeeper trust)
        echo ""
        echo "NOTE: \"$identity\" does not appear to be an Apple Developer ID certificate."
        echo "The signed app will not pass Gatekeeper and may not launch without"
        echo "manual approval (right-click > Open, or System Settings > Privacy)."
        echo ""
        timestamp="--timestamp=none"
        sign_options=""
    fi
fi

refresh_app() {
    local app_path=$1
    verbose_echo "Refreshing bundle modification date"
    /usr/bin/touch -c "${app_path}"

    verbose_echo "Registering applet with Launch Services"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -f -R -trusted "${app_path}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Generic deep signing (layout-independent replacement for `codesign --deep`).
#
# Two passes, bottom-up:
#   Phase 1: sign every loose Mach-O file anywhere in the bundle, individually.
#   Phase 2: sign every nested code bundle as a bundle, deepest-first, so a
#            child is always sealed before the parent that contains it.
#   Phase 3: sign the outer app bundle itself.
# ---------------------------------------------------------------------------

# ---- Phase 1: sign all loose Mach-O files --------------------------------
#
# Candidate files: regular files (never symlinks) anywhere under the app,
# excluding anything already inside a _CodeSignature seal directory. The
# executable bit alone is not sufficient: many dynamic libraries and plugins
# (*.dylib, *.so, *.node) ship without it yet still contain Mach-O code that the
# notary service will flag if left unsigned - so we match those extensions too.
verbose_echo ""
verbose_echo "Signing standalone Mach-O executables and libraries"
verbose_echo "-----------------------------------"

# Compute the filtered list first so brief mode can report an accurate count
# before signing.
macho_files=$(list_macho_files)
nested_bundles=$(list_nested_bundles)

# ---- Entitlements cache --------------------------------------------------
#
# Signing replaces a signature rather than amending it, so every nested helper,
# framework and XPC service re-signed below would otherwise come out stripped of
# whatever entitlements it carried - a JIT-using helper silently losing
# allow-jit, correctly signed and notarized, crashing the first time it runs.
#
# The whole cache has to be built before any signing starts: phase 1 rewrites
# nested bundles' main executables before phase 2 reaches the bundles
# themselves, so reading entitlements lazily would read back the stripped ones.
# The outer bundle is not cached here - phase 3 applies the caller's choice.
ent_cache_dir=$(/usr/bin/mktemp -d /tmp/codesign_applet_ent.XXXXXX) || exit 1
# A signal handler that only cleans up and returns would resume signing with the
# cache gone, quietly stripping the entitlements from everything left to sign -
# and would make this script uninterruptible. Each signal cleans up and exits
# with the conventional 128+signo status.
trap '/bin/rm -rf "$ent_cache_dir"' EXIT
trap '/bin/rm -rf "$ent_cache_dir"; exit 129' HUP
trap '/bin/rm -rf "$ent_cache_dir"; exit 130' INT
trap '/bin/rm -rf "$ent_cache_dir"; exit 131' QUIT
trap '/bin/rm -rf "$ent_cache_dir"; exit 143' TERM

cache_entitlements() {
    local dest
    dest="$ent_cache_dir/$(printf '%s' "$1" | /sbin/md5 -q).entitlements"
    /usr/bin/codesign -d --entitlements - --xml "$1" > "$dest" 2>/dev/null
    if [ ! -s "$dest" ] || ! /usr/bin/grep -q '<key>' "$dest"; then
        /bin/rm -f "$dest"
    fi
}

# Print the cached entitlements file for a path, or nothing.
cached_entitlements() {
    local f
    f="$ent_cache_dir/$(printf '%s' "$1" | /sbin/md5 -q).entitlements"
    if [ -f "$f" ]; then
        printf '%s' "$f"
    fi
}

# Sign one nested item, carrying over whatever entitlements it already had.
sign_nested() {
    local target ent
    target="$1"
    ent="$(cached_entitlements "$target")"
    if [ -n "$ent" ]; then
        verbose_echo "  (carrying over entitlements from the existing signature)"
        run_codesign $cs_verbose --force $sign_options --entitlements "$ent" $timestamp --sign "$identity" "$target"
    else
        run_codesign $cs_verbose --force $sign_options $timestamp --sign "$identity" "$target"
    fi
}

# Ad-hoc signing never applied entitlements to anything, so leaving the cache
# empty keeps that path behaving exactly as it always has - cached_entitlements
# finds nothing and every sign_nested call takes the plain branch.
if [ "$identity" != "-" ]; then
    # Read line by line rather than word-splitting: bundle paths contain spaces.
    printf '%s\n%s\n' "$macho_files" "$(list_signed_bundles)" \
        | while IFS= read -r cache_path; do
            [ -n "$cache_path" ] || continue
            cache_entitlements "$cache_path"
        done
fi

if [ -z "$macho_files" ]; then
    macho_count=0
else
    macho_count=$(printf '%s\n' "$macho_files" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
fi

# Brief mode collapses the per-file log into a single summary line reporting the
# number of files that will actually be signed (the filtered Mach-O list).
if [ "$brief" = "yes" ]; then
    echo "Signing $macho_count Mach-O executables and libraries"
fi

# This pass may include each nested bundle's main executable; that is harmless
# by design - phase 2 re-signs those bundles and rewrites the seal, and an
# executable being signed twice costs nothing but a moment.
if [ -n "$macho_files" ]; then
    printf '%s\n' "$macho_files" | while IFS= read -r f; do
        verbose_echo "Signing: $f"
        sign_nested "$f"
        if test "$?" != "0"; then
            echo "warning: failed to sign $f"
        fi
    done
fi

verbose_echo "-----------------------------------"

# ---- Phase 2: sign nested code bundles, deepest-first --------------------
#
# Discover every candidate bundle directory by recognised extension, then order
# them deepest-first (most path components first) so children are sealed before
# the parents that embed them.
verbose_echo ""
verbose_echo "Signing nested code bundles (deepest-first)"
verbose_echo "-----------------------------------"

# nested_bundles was computed once, above, from list_nested_bundles.

if [ -n "$nested_bundles" ]; then
    printf '%s\n' "$nested_bundles" | while IFS= read -r bundle; do
        bundle_name=$(/usr/bin/basename "$bundle")
        case "$bundle" in
            *.framework)
                # A framework is valid if it is versioned
                # (Versions/*/Resources/Info.plist) or a flat old-style bundle
                # (Resources/Info.plist directly). Detect which before signing.
                is_versioned="no"
                for verdir in "$bundle"/Versions/*; do
                    if [ -f "$verdir/Resources/Info.plist" ]; then
                        is_versioned="yes"
                        break
                    fi
                done
                if [ "$is_versioned" = "yes" ]; then
                    echo "Signing framework: $bundle_name"
                    # Sign each real version directory; skip symlinks such as
                    # Versions/Current, which just alias a real version.
                    for verdir in "$bundle"/Versions/*; do
                        [ -d "$verdir" ] || continue
                        if [ -L "$verdir" ]; then
                            continue
                        fi
                        sign_nested "$verdir"
                        if test "$?" != "0"; then
                            echo "warning: failed to sign $verdir"
                        fi
                    done
                elif [ -f "$bundle/Resources/Info.plist" ]; then
                    # Flat old-style framework: sign the bundle root directly.
                    echo "Signing bundle: $bundle_name"
                    sign_nested "$bundle"
                    if test "$?" != "0"; then
                        echo "warning: failed to sign $bundle_name"
                    fi
                else
                    # Not a valid framework; its Mach-O contents were already
                    # signed in phase 1, so it is safe to leave the seal alone.
                    verbose_echo "Skipping invalid framework (no Info.plist): $bundle"
                fi
                ;;
            *)
                if [ -f "$bundle/Contents/Info.plist" ]; then
                    echo "Signing bundle: $bundle_name"
                    sign_nested "$bundle"
                    if test "$?" != "0"; then
                        echo "warning: failed to sign $bundle_name"
                    fi
                else
                    # Missing Contents/Info.plist: not a real code bundle. Its
                    # Mach-O contents were already signed in phase 1.
                    verbose_echo "Skipping invalid bundle (no Contents/Info.plist): $bundle"
                fi
                ;;
        esac
    done
fi

verbose_echo "-----------------------------------"

verbose_echo ""

# ---- Phase 3: sign the outer app bundle ----------------------------------
# The generic phases above have already sealed all nested code, so the outer
# bundle no longer needs (or should use) `codesign --deep`.
echo "Signing app bundle: $app_to_sign"
# The entitlements path is quoted rather than folded into one variable with the
# other flags: a browsed-to file can sit under a folder with spaces in its name.
if [ -n "$entitlements_file" ]; then
    verbose_echo "/usr/bin/codesign $cs_verbose --force $sign_options --entitlements '$entitlements_file' $timestamp --identifier $app_id --sign $identity $app_to_sign"
    run_codesign $cs_verbose --force $sign_options --entitlements "$entitlements_file" $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"
else
    verbose_echo "/usr/bin/codesign $cs_verbose --force $sign_options $timestamp --identifier $app_id --sign $identity $app_to_sign"
    run_codesign $cs_verbose --force $sign_options $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"
fi

if test "$?" != "0"; then
    verbose_echo ""
    echo "error: failed to sign app bundle"
    exit 1
fi

refresh_app "$app_to_sign"

verbose_echo ""
verbose_echo "Verifying codesigned app:"
verbose_echo "-----------------------------------------"
# --deep --strict makes the local verification approximate what the notary
# service checks: it walks every nested seal and rejects loose or invalid code.
if [ "$brief" = "yes" ]; then
    /usr/bin/codesign --verify --deep --strict "$app_to_sign" 2>&1
else
    /usr/bin/codesign --verify --deep --strict --display --verbose=4 "$app_to_sign" 2>&1
fi

if test "$?" = "0"; then
    verbose_echo "-----------------------------------------"
    echo "✓ Code signature is valid (integrity check passed)"
else
    verbose_echo "-----------------------------------------"
    echo "✗ Code signature validation failed"
    exit 1
fi

verbose_echo ""
verbose_echo "Gatekeeper assessment:"
verbose_echo "-----------------------------------------"
spctl_output=$(/usr/sbin/spctl --assess --verbose=4 --type execute "$app_to_sign" 2>&1)
spctl_status=$?

# In default mode always show the raw assessment; in brief mode only when it did
# not pass (errors/rejections are worth surfacing).
if [ "$brief" != "yes" ] || test "$spctl_status" != "0"; then
    echo "$spctl_output"
fi
verbose_echo "-----------------------------------------"

if test "$spctl_status" = "0"; then
    echo "✓ App is accepted by Gatekeeper"
elif test "$identity" = "-"; then
    echo "⚠ Ad-hoc signed apps are not accepted by Gatekeeper (expected)"
    echo "  The app will run on this Mac"
elif test "$is_developer_id" = "yes"; then
    # Check if it's just a notarization issue
    if echo "$spctl_output" | /usr/bin/grep -qi "unnotarized"; then
        echo "⚠ App is signed with Developer ID but not notarized"
        echo "  The app will run on this Mac. For distribution, notarize with:"
        echo "  xcrun notarytool submit <path> --apple-id <ID> --team-id <TEAM>"
    else
        echo "✗ App is rejected by Gatekeeper (unexpected for Developer ID)"
        echo "  Check that the certificate is valid and not expired"
        exit 1
    fi
else
    echo "⚠ App is rejected by Gatekeeper (self-signed certificate)"
    echo "  To launch: right-click the app > Open, or allow it in"
    echo "  System Settings > Privacy & Security"
fi
