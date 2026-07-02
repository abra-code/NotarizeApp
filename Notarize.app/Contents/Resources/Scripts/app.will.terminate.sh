#!/bin/sh
# app.will.terminate.sh - sweep all per-window state directories on quit
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

/bin/rm -rf "${TMPDIR:-/tmp}"/notarize-state-* 2>/dev/null
