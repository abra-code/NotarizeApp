#!/bin/sh
# Notarize.main.init.sh - window initialization (runs before the window appears)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

prefs_ensure
populate_pickers

# Default the toggles on (sign, staple, create distribution zip).
set_value "$SIGN_TOGGLE_ID" 1
set_value "$STAPLE_TOGGLE_ID" 1
set_value "$DISTZIP_TOGGLE_ID" 1

# Prefill the output folder from prefs, if set.
out_default="$(prefs_get default_output_dir)"
if [ -n "$out_default" ]; then
    set_value "$OUTPUT_FIELD_ID" "$out_default"
fi

# Seed the target from the opened/dropped object, if any.
first="$(printf '%s' "$OMC_OBJ_PATH" | /usr/bin/head -n 1)"
if [ -n "$first" ]; then
    is_app_bundle "$first"
    if [ "$?" = "0" ]; then
        set_target "$first"
    fi
fi

refresh_target_ui
show_progress 0
enable_view "$CANCEL_BTN_ID" 0
show_view "$REVEAL_BTN_ID" 0
