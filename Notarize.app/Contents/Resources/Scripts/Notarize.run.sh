#!/bin/sh
# Notarize.run.sh - full pipeline: copy to output, sign, submit, wait, staple, validate
source "${OMC_APP_BUNDLE_PATH}/Contents/Resources/Scripts/lib.notarize.sh"

target="$(get_target)"
if [ -z "$target" ]; then
    "$alert_tool" --level caution --title "Notarize" "Choose an app or installer package to notarize first."
    exit 0
fi
is_supported_target "$target"
if [ "$?" != "0" ]; then
    "$alert_tool" --level caution --title "Notarize" "$(unsupported_target_reason "$target")"
    exit 0
fi
kind="$(target_kind_of "$target")"

profile="$(selected_profile)"
if [ -z "$profile" ]; then
    "$alert_tool" --level caution --title "Notarize" "Set up notary credentials first (Credentials button), then pick a profile."
    exit 0
fi

entitlements="$(view_value "$ENTITLEMENTS_FIELD_ID")"
output_dir="$(view_value "$OUTPUT_FIELD_ID")"
identity="$(selected_identity)"

# An empty identity is not fatal here, and it means one of two things: the
# developer picked the "Don't Code-sign" row, or the keychain holds no
# certificate of the class this target needs. Either way notarizing requires the
# artifact to be signed, not for us to be the ones who signed it, so a target
# that already carries a valid Developer ID signature can go straight to the
# notary service. The sign stage decides, once it can see what is on disk.

save_app_settings

# Reset the per-run UI/state, in a private function so every exit path restores it.
finish() {
    show_progress 0
    enable_view "$CANCEL_BTN_ID" 0
    enable_view "$NOTARIZE_BTN_ID" 1
    rail_enable 1
    pb_set "$PB_BUSY" ""
    /bin/rm -f "$(state_dir)/run.pid"
}

pb_set "$PB_BUSY" 1
printf '%s' "$$" > "$(state_dir)/run.pid"
/bin/rm -f "$(state_dir)/cancelled"
enable_view "$NOTARIZE_BTN_ID" 0
rail_enable 0
show_view "$REVEAL_BTN_ID" 0
enable_view "$CANCEL_BTN_ID" 1
show_progress 1
clear_log
rail_reset
append_log "=== Notarize: $(/usr/bin/basename "$target") ==="

# 1. Copy to the output folder (never release-sign the development copy in
# place), then sign the copy.
rail_set "$RAIL_SIGN_ID" running
set_status "Preparing..."
work="$(prepare_release_copy "$target" "$output_dir")"
if [ "$?" != "0" ] || [ -z "$work" ]; then
	rail_set "$RAIL_SIGN_ID" failed
	set_status "Copy to the output folder failed."
	"$alert_tool" --level stop --title "Notarize" "Could not copy the target to the output folder."
	finish
	exit 0
fi
if made_release_copy; then
	append_log "Copied to output folder: $work"
fi

if [ -z "$identity" ]; then
	# Nothing to sign with, or nothing the developer wants signed. Notarizing
	# does not require a certificate here - only a target already signed with a
	# Developer ID does - so check what is there rather than refusing outright.
	set_status "Checking the existing signature..."
	append_log "--- Signing skipped ---"
	append_log "Not signing: $(not_signing_reason). The existing signature has to stand on its own."
	# Same check as the matching case, asked without an identity: not "does this
	# match what was selected" but "would the notary service accept this at all".
	unsigned_why="$(resign_reason "$work" "" "")"
	if [ -n "$unsigned_why" ]; then
		rail_set "$RAIL_SIGN_ID" failed
		set_status "The target is not properly signed."
		append_log "ERROR: $unsigned_why."
		# The advice stays the same for both reasons on purpose: "pick an
		# identity" is not actionable when there is no certificate to pick, and
		# not_signing_reason has already said which of the two applies.
		"$alert_tool" --level stop --title "Notarize" "Nothing was signed because $(not_signing_reason), and this cannot be notarized as it is: $unsigned_why. It has to carry a valid Developer ID signature before the notary service will take it."
		finish
		exit 0
	fi
	rail_set "$RAIL_SIGN_ID" skipped
	append_log "The existing signature is valid for distribution; nothing was re-signed."
	append_log "-----------------------"
else
	# Signing is a replacement, not an amendment: it discards the existing
	# signature and, for a package, the notarization ticket stapled to it. When
	# every setting in this window already matches what is on disk, repeating it
	# would produce a byte-for-byte equivalent result, so the pipeline leaves it
	# alone. Only the pipeline does this - Actions > Sign Only always signs.
	set_status "Checking the existing signature..."
	sign_why="$(resign_reason "$work" "$identity" "$entitlements")"
	if [ -z "$sign_why" ]; then
		rail_set "$RAIL_SIGN_ID" skipped
		set_status "Already signed as requested; not re-signing."
		append_log "--- Signing skipped ---"
		append_log "The existing signature already matches every setting in this window, so re-signing would change nothing:"
		append_log "  identity: $identity"
		if [ "$kind" = "pkg" ]; then
			append_log "  trusted timestamp: present"
		else
			append_log "  hardened runtime: present"
			append_log "  secure timestamp: present"
			if [ -n "$entitlements" ]; then
				append_log "  entitlements: identical to $entitlements"
			else
				append_log "  entitlements: unchanged (none specified in this window)"
			fi
		fi
		append_log "To sign anyway, use Actions > Sign Only, which never skips."
		append_log "-----------------------"
	else
		set_status "Signing for release..."
		append_log "Signing because $sign_why."
		sign_target "$work" "$identity" "$entitlements"
		if [ "$?" != "0" ]; then
			rail_set "$RAIL_SIGN_ID" failed
			set_status "Signing failed."
			"$alert_tool" --level stop --title "Notarize" "Signing failed. See the log."
			finish
			exit 0
		fi
		# For an app, codesign_applet.sh already verified the signature
		# (--deep --strict) and failed the step on any problem. For a package,
		# confirm productsign's result actually landed on disk.
		if [ "$kind" = "pkg" ]; then
			run_pkg_signature_check "$work"
			if [ "$?" != "0" ]; then
				rail_set "$RAIL_SIGN_ID" failed
				set_status "Signing did not produce a signed package."
				"$alert_tool" --level stop --title "Notarize" "The package is still unsigned after productsign. See the log."
				finish
				exit 0
			fi
		fi
		rail_set "$RAIL_SIGN_ID" done
	fi
fi

# 2. Prepare the upload. An app has to be zipped; the notary service takes a
# flat package as it is.
rail_set "$RAIL_SUBMIT_ID" running
if [ "$kind" = "pkg" ]; then
    set_status "Preparing the upload..."
    append_log "Uploading the package itself; no archive needed."
else
    set_status "Packaging for upload..."
    append_log "Packaging for upload..."
fi
prepare_upload "$work"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Packaging failed."
    "$alert_tool" --level stop --title "Notarize" "Could not create the upload archive."
    finish
    exit 0
fi

# 3. Submit and wait for the notary service.
set_status "Submitting to the notary service..."
submit_and_wait "$(upload_path)" "$profile"
if [ "$?" != "0" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Submission failed."
    "$alert_tool" --level stop --title "Notarize" "Notarization submission failed. See the log."
    finish
    exit 0
fi

status="$(submission_status)"
if [ "$status" != "Accepted" ]; then
    rail_set "$RAIL_SUBMIT_ID" failed
    set_status "Notarization $status. Fetching log..."
    append_log "Notarization not accepted ($status). Fetching log..."
    fetch_log "$(submission_id)" "$profile"
    print_issues
    "$alert_tool" --level stop --title "Notarize" "Notarization $status. See the issues in the log."
    finish
    exit 0
fi
rail_set "$RAIL_SUBMIT_ID" done

# 4. Staple the ticket
rail_set "$RAIL_STAPLE_ID" running
set_status "Stapling notarization ticket..."
staple_app "$work"
if [ "$?" != "0" ]; then
	rail_set "$RAIL_STAPLE_ID" failed
	set_status "Stapling failed."
	"$alert_tool" --level stop --title "Notarize" "Stapling the ticket failed. See the log."
	finish
	exit 0
fi
rail_set "$RAIL_STAPLE_ID" done
show_view "$REVEAL_BTN_ID" 1

# 5. Final Gatekeeper assessment.
rail_set "$RAIL_VALIDATE_ID" running
run_spctl "$work"
if [ "$?" = "0" ]; then
    rail_set "$RAIL_VALIDATE_ID" done
    append_log "Done. Accepted, stapled, and ready at: $work"
    set_status "Done. Notarized and ready for distribution."
    "$notify_tool" --title "Notarize" "$(/usr/bin/basename "$target") is notarized and ready."
else
    # The ticket is stapled but Gatekeeper still refused the result. Saying
    # "ready for distribution" here would contradict the log and the red rail
    # icon, and this is exactly the outcome someone needs to be told about.
    rail_set "$RAIL_VALIDATE_ID" failed
    append_log "WARNING: stapled, but Gatekeeper did not accept the result. See the assessment above."
    set_status "Stapled, but Gatekeeper rejected it."
    "$notify_tool" --title "Notarize" "$(/usr/bin/basename "$target") was stapled, but Gatekeeper rejected it."
fi
finish
