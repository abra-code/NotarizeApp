#!/bin/sh
# Notarize.choose.app.sh - app picked via the Choose App panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

first="$OMC_DLG_CHOOSE_OBJECT_PATH"
if [ -z "$first" ]; then
    exit 0
fi
is_supported_target "$first"
if [ "$?" != "0" ]; then
    "$alert_tool" --level caution --title "Notarize" "$(unsupported_target_reason "$first")"
    exit 0
fi
set_target "$first"
refresh_target_ui
