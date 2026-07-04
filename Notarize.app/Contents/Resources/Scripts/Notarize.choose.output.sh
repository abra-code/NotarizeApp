#!/bin/sh
# Notarize.choose.output.sh - output folder picked via the panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

first="$OMC_DLG_CHOOSE_FOLDER_PATH"
if [ -n "$first" ]; then
    set_value "$OUTPUT_FIELD_ID" "$first"
    app_pref_set output_dir "$first"
fi
