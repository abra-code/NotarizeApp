#!/bin/sh
# Notarize.choose.output.sh - output folder picked via the panel
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

first="$OMC_DLG_CHOOSE_FOLDER_PATH"
if [ -n "$first" ]; then
    set_value "$OUTPUT_FIELD_ID" "$first"
    prefs_set default_output_dir "$first"
fi
