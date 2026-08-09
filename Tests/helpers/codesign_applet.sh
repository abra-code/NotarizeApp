#!/bin/sh
# helpers/codesign_applet.sh - a fake for the bundled signer.
#
# The real script is a 862-line wrapper around codesign that walks a bundle and
# signs every nested item. It is inside the app rather than in /usr/bin, but
# that makes it no more runnable here: pointed at a fixture it would sign it for
# real, and pointed at anything else it would fail for reasons that have nothing
# to do with the applet's logic.
#
# Two invocations are modeled, and they are the only two the applet makes:
#
#   --list-code <app>
#       Enumerate the bundle's code items, one path per line. This is the
#       applet's single source of truth for "what is nested inside" - both
#       resign_reason_app and list_uncertified_nested_items walk it - so the
#       listing is scriptable per app path.
#
#   --brief --no-entitlements-search <app> <identity> <entitlements>
#       Sign. On success the fake registers a matching signature for the app
#       AND for every item in its listing, so that a later resign_reason or
#       preflight sees the world a real signing run would have left. Without
#       that, a pipeline test would sign and then immediately report the app as
#       still unsigned.

. "$(/usr/bin/dirname "$0")/fake_record.sh"

if [ "$1" = "--list-code" ]; then
    app="$2"
    record="$fake_dir/listing/$(fake_key "$app")"
    if [ -f "$record.out" ]; then
        /bin/cat "$record.out"
        exit "$(fake_rc "$record.rc" 0)"
    fi
    # Every app bundle holds at least its own main executable, and the applet
    # treats an EMPTY listing as an enumeration failure rather than as
    # "nothing nested". So the unscripted default is the bundle itself: one
    # line, which is what a bundle with no nested code really produces.
    printf '%s\n' "$app"
    exit 0
fi

# The signing form.
app=""
identity=""
for arg in "$@"; do
    case "$arg" in
        --*) continue ;;
    esac
    if [ -z "$app" ]; then
        app="$arg"
    elif [ -z "$identity" ]; then
        identity="$arg"
    fi
done

fake_emit "$fake_dir/codesign_applet.sign.out"
rc="$(fake_rc "$fake_dir/codesign_applet.sign.rc" 0)"
[ "$rc" = "0" ] || exit "$rc"

# Register the resulting signature for the bundle and everything under it.
# The nested items deliberately get NO hardened-runtime flag: the flag is a
# property of a process's main executable, and demanding it from a framework
# would describe a world Apple's own notarized apps do not live in - which is
# exactly the distinction signed_item_matches draws with its third argument.
register() { # <path> <extra-flag-text>
    record="$fake_dir/sig/$(fake_key "$1")"
    /bin/mkdir -p "$record"
    {
        printf 'Executable=%s\n' "$1"
        printf 'Identifier=fake.%s\n' "$(/usr/bin/basename "$1")"
        printf 'Signature size=9000\n'
        printf 'Authority=%s\n' "$identity"
        printf 'Authority=Developer ID Certification Authority\n'
        printf 'Authority=Apple Root CA\n'
        printf 'Timestamp=9 Aug 2026 at 00:00:00\n'
        # 0x10000 IS the runtime bit, so it cannot also spell "none". The
        # applet matches on the parenthesised text, so this was harmless - and
        # a fake that contradicts itself is one nobody can reason from.
        if [ "$2" = "runtime" ]; then
            printf 'CodeDirectory v=20500 flags=0x10000(runtime) hashes=42+7\n'
        else
            printf 'CodeDirectory v=20500 flags=0x0(none) hashes=42+7\n'
        fi
    } > "$record/info"
}

register "$app" "runtime"

listing="$fake_dir/listing/$(fake_key "$app")"
if [ -f "$listing.out" ]; then
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        [ "$item" = "$app" ] && continue
        # An item the test declared the signer leaves alone: it keeps whatever
        # signature it had, which is how a run can report success and still be
        # carrying something Gatekeeper will refuse.
        if [ -f "$fake_dir/codesign_applet.skip" ] &&
           /usr/bin/grep -q -x -F -e "$item" "$fake_dir/codesign_applet.skip"; then
            continue
        fi
        register "$item" "none"
    done < "$listing.out"
fi
exit 0
