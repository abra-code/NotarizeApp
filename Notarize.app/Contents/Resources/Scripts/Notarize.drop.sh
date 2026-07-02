#!/bin/sh
# Notarize.drop.sh - an app dropped on the window becomes the target
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

ctx="$OMC_ACTIONUI_TRIGGER_CONTEXT"
if [ -z "$ctx" ]; then
    exit 0
fi

# Pull file:// URLs out of the drop context and pick the first .app bundle.
urls="$(printf '%s' "$ctx" | /usr/bin/grep -oE 'file://[^"]+')"
target=""
old_ifs="$IFS"
IFS='
'
for u in $urls; do
    p="$(url_to_path "$u")"
    is_app_bundle "$p"
    if [ "$?" = "0" ]; then
        target="$p"
        break
    fi
done
IFS="$old_ifs"

if [ -n "$target" ]; then
    set_target "$target"
    refresh_target_ui
else
    "$alert_tool" --level caution --title "Notarize" "Drop a single .app bundle to notarize."
fi
