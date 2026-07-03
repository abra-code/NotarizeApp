#!/bin/sh
# Notarize.choose.entitlements.sh - entitlements file picked via the panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

env | sort 

# Fall back to the object-panel variable in case a stale pre-relaunch manifest presented CHOOSE_OBJECT_DIALOG.
first="${OMC_DLG_CHOOSE_FILE_PATH:-$OMC_DLG_CHOOSE_OBJECT_PATH}"
if [ -n "$first" ]; then
    set_value "$ENTITLEMENTS_FIELD_ID" "$first"
fi
