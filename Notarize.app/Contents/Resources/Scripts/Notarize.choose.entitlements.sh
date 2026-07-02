#!/bin/sh
# Notarize.choose.entitlements.sh - entitlements file picked via the panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

first="$(printf '%s' "$OMC_OBJ_PATH" | /usr/bin/head -n 1)"
if [ -n "$first" ]; then
    set_value "$ENTITLEMENTS_FIELD_ID" "$first"
fi
