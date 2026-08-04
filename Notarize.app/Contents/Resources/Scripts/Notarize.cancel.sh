#!/bin/sh
# Notarize.cancel.sh - stop a running pipeline and reset the UI (best effort)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

/usr/bin/touch "$(state_dir)/cancelled"

pidfile="$(state_dir)/run.pid"
if [ -f "$pidfile" ]; then
    pid="$(/bin/cat "$pidfile")"
    if [ -n "$pid" ]; then
        # Kill the process group first (negative pid), then the leader.
        /bin/kill -TERM "-$pid" 2>/dev/null
        /bin/kill -TERM "$pid" 2>/dev/null
    fi
    /bin/rm -f "$pidfile"
fi

# Best effort: stop a notarytool upload still running for this window's archive.
# Only ever match the zip inside this window's state directory. The pattern is a
# regular expression and the path is matched against every command line on the
# system, so a user-chosen path - a .pkg is uploaded straight from wherever it
# lives - could match more than intended. notarytool is a child of the pipeline
# anyway, so the process-group kill above already covers it; this is the backstop
# for the one path we know is ours.
/usr/bin/pkill -f "$(state_dir)/upload.zip" 2>/dev/null

show_progress 0
enable_view "$CANCEL_BTN_ID" 0
enable_view "$NOTARIZE_BTN_ID" 1
rail_enable 1
pb_set "$PB_BUSY" ""
append_log "Cancelled by user."
set_status "Cancelled."
