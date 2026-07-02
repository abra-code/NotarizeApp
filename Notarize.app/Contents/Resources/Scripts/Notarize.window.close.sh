#!/bin/sh
# Notarize.window.close.sh - per-window state cleanup
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

dir="${TMPDIR:-/tmp}/notarize-state-${document_uuid}"
/bin/rm -rf "$dir"
pb_set "$PB_BUSY" ""
pb_set "$PB_SUBMISSION" ""
