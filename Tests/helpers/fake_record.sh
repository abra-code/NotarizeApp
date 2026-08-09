#!/bin/sh
# helpers/fake_record.sh - argv recording, shared by every fake system tool.
#
# Sourced, not executed, as the first thing each fake does. It records the
# invocation and leaves $fake_dir and $fake_name set for the behavior that
# follows.
#
# Two records are kept, because neither alone is both readable and exact:
#
#   <name>.log        one line per invocation, arguments joined by tabs. This
#                     is for reading and for grep. It is LOSSY: an argument
#                     containing a tab or a newline is indistinguishable from
#                     two arguments, or from two invocations.
#   <name>.argv.<n>   one file per invocation, one argument per line, in order.
#                     Exact for everything except an argument containing a
#                     newline - and no assertion in this suite passes one.
#   <name>.count      how many times the tool was called.
#
# The count is its own file rather than a line count of the log, so that a call
# whose arguments contain a newline still counts as one call. "Did the handler
# invoke notarytool at all" is the assertion this suite makes most often, and it
# has to stay correct for exactly the inputs worth testing.

fake_name="$(/usr/bin/basename "$0")"
fake_dir="${NOTARIZE_FAKE_DIR:?fake tool invoked with no NOTARIZE_FAKE_DIR}"
/bin/mkdir -p "$fake_dir"

# The readable, lossy record.
{
    fake_first=1
    for fake_arg in "$@"; do
        if [ "$fake_first" = "1" ]; then
            printf '%s' "$fake_arg"
            fake_first=0
        else
            printf '\t%s' "$fake_arg"
        fi
    done
    printf '\n'
} >> "$fake_dir/$fake_name.log"

fake_n=$(( $(/bin/cat "$fake_dir/$fake_name.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$fake_n" > "$fake_dir/$fake_name.count"

: > "$fake_dir/$fake_name.argv.$fake_n"
for fake_arg in "$@"; do
    printf '%s\n' "$fake_arg" >> "$fake_dir/$fake_name.argv.$fake_n"
done
unset fake_first fake_arg

# Resolve a path's DIRECTORY the way the applet does, so that two spellings of
# the same location file under one record.
#
# This is not fussiness. The pipeline canonicalizes its target with "cd -P"
# before anything acts on it, and under the harness TMPDIR that changes the
# spelling twice over: /var is a symlink to /private/var, and TMPDIR's trailing
# slash leaves an interior "//" that pwd -P normalizes away. A test setting a
# signature on the path it built and the applet asking about the path it
# resolved would otherwise never meet - the record would sit unread and the fake
# would answer with its default, which is the quietest possible way to make a
# whole section prove nothing.
#
# The FINAL component is deliberately left alone. The applet resolves a
# symlinked target before acting on it, so it never asks about the link; and
# leaving it unresolved keeps a test able to say that a link and its target are
# different things.
fake_canonical() { # <path>
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

# The key under which a per-path record is filed. A path is not a filename, so
# it is hashed. shasum rather than a sanitizing substitution: two different
# paths must never collide, and any scheme that strips characters eventually
# lets them.
fake_key() { # <path>
    printf '%s' "$(fake_canonical "$1")" | /usr/bin/shasum | /usr/bin/cut -c1-40
}

# The same, for a value that is not a path - a keychain profile name.
#
# It must NOT go through fake_canonical: a bare word has no directory, so
# canonicalization would resolve it against the CURRENT working directory, and
# the test file and the handler it dispatches do not share one. The record would
# be written under one key and looked up under another, and the fake would
# quietly answer with its default.
fake_text_key() { # <text>
    printf '%s' "$1" | /usr/bin/shasum | /usr/bin/cut -c1-40
}

# Print a record file if it exists; succeed either way.
fake_emit() { # <file>
    [ -f "$1" ] && /bin/cat "$1"
    return 0
}

# The exit code stored in a file, defaulting to <default>.
fake_rc() { # <file> <default>
    if [ -f "$1" ]; then
        /bin/cat "$1"
    else
        printf '%s' "$2"
    fi
}
