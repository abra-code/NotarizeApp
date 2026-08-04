#!/bin/sh
# Notarize.main.init.sh - window initialization (runs before the window appears)
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

prefs_ensure
populate_pickers

# Seed the target from the opened/dropped object, if any.
first="$(printf '%s' "$OMC_OBJ_PATH" | /usr/bin/head -n 1)"
if [ -n "$first" ]; then
    is_supported_target "$first"
    if [ "$?" = "0" ]; then
        set_target "$first"
    fi
fi

refresh_target_ui
show_progress 0
enable_view "$CANCEL_BTN_ID" 0
show_view "$REVEAL_BTN_ID" 0
