#!/bin/sh
# Notarize.drop.sh - an app dropped on the window becomes the target
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

ctx="$OMC_ACTIONUI_TRIGGER_CONTEXT"
if [ -z "$ctx" ]; then
    exit 0
fi

# Pull file:// URLs out of the drop context and pick the first supported target.
# Remember the first rejected path too, so the alert can say why it was no good
# rather than repeating the generic hint.
urls="$(printf '%s' "$ctx" | /usr/bin/grep -oE 'file://[^"]+')"
target=""
rejected=""
old_ifs="$IFS"
IFS='
'
for u in $urls; do
    p="$(url_to_path "$u")"
    is_supported_target "$p"
    if [ "$?" = "0" ]; then
        target="$p"
        break
    fi
    if [ -z "$rejected" ]; then
        rejected="$p"
    fi
done
IFS="$old_ifs"

if [ -n "$target" ]; then
    set_target "$target"
    refresh_target_ui
elif [ -n "$rejected" ]; then
    "$alert_tool" --level caution --title "Notarize" "$(unsupported_target_reason "$rejected")"
else
    "$alert_tool" --level caution --title "Notarize" "Drop a single .app bundle or .pkg installer package to notarize."
fi
