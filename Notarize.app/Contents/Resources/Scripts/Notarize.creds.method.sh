#!/bin/sh
# Notarize.creds.method.sh - show the field group for the chosen auth method
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

# 1 = Apple ID (group 700), 2 = API key (group 710), 3 = existing profile (group 720)
idx="$(view_value "$CRED_METHOD_ID")"
case "$idx" in
    2)
        show_view 700 0
        show_view 710 1
        show_view 720 0
        ;;
    3)
        show_view 700 0
        show_view 710 0
        show_view 720 1
        ;;
    *)
        show_view 700 1
        show_view 710 0
        show_view 720 0
        ;;
esac
