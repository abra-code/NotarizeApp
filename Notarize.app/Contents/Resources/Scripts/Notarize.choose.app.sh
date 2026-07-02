#!/bin/sh
# Notarize.choose.app.sh - app picked via the Choose App panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

first="$(printf '%s' "$OMC_OBJ_PATH" | /usr/bin/head -n 1)"
if [ -z "$first" ]; then
    exit 0
fi
is_app_bundle "$first"
if [ "$?" != "0" ]; then
    "$alert_tool" --level caution --title "Notarize" "Please choose a .app bundle."
    exit 0
fi
set_target "$first"
refresh_target_ui
