#!/bin/bash
# Notarizes and staples one Continuum artifact (.app or .dmg) with Apple's
# notary service, then verifies the stapled ticket.
#
# Prerequisites
#   1. The artifact is already signed with a "Developer ID Application:
#      Pengyue Wang" certificate, hardened runtime, and a secure timestamp
#      (./build.sh and ./scripts/make-dmg.sh do this automatically when the
#      cert is installed).
#   2. Notary credentials, supplied EITHER as a stored keychain profile…
#        export CONTINUUM_NOTARY_PROFILE="ContinuumNotary"
#        # create the profile once (interactive):
#        #   xcrun notarytool store-credentials ContinuumNotary \
#        #     --apple-id "you@example.com" --team-id "TEAMID" \
#        #     --password "app-specific-password"
#      …OR directly via environment variables:
#        export CONTINUUM_APPLE_ID="you@example.com"
#        export CONTINUUM_TEAM_ID="TEAMID"
#        export CONTINUUM_APP_PASSWORD="app-specific-password"   # appleid.apple.com → App-Specific Passwords
#
# Usage: scripts/notarize.sh <path-to-.app-or-.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:?usage: scripts/notarize.sh <path-to-.app-or-.dmg>}"
[ -e "$TARGET" ] || { echo "✗ No such file: $TARGET" >&2; exit 1; }

# Assemble notarytool authentication arguments.
AUTH=()
if [ -n "${CONTINUUM_NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$CONTINUUM_NOTARY_PROFILE")
elif [ -n "${CONTINUUM_APPLE_ID:-}" ] && [ -n "${CONTINUUM_TEAM_ID:-}" ] \
     && [ -n "${CONTINUUM_APP_PASSWORD:-}" ]; then
    AUTH=(--apple-id "$CONTINUUM_APPLE_ID" \
          --team-id "$CONTINUUM_TEAM_ID" \
          --password "$CONTINUUM_APP_PASSWORD")
else
    cat >&2 <<'EOF'
✗ Notary credentials not set. Provide either a stored profile:
      export CONTINUUM_NOTARY_PROFILE="ContinuumNotary"
  or the three direct variables:
      export CONTINUUM_APPLE_ID="you@example.com"
      export CONTINUUM_TEAM_ID="TEAMID"
      export CONTINUUM_APP_PASSWORD="app-specific-password"
  See the header of this script for how to create the profile.
EOF
    exit 2
fi

# notarytool accepts .dmg/.pkg/.zip — a bare .app must be zipped first (but the
# ticket is always stapled to the original .app, not the zip).
ext="${TARGET##*.}"
if [ "$ext" = "app" ]; then
    SUBMIT=".build/$(basename "$TARGET").zip"
    echo "• Zipping $TARGET for submission"
    rm -f "$SUBMIT"
    /usr/bin/ditto -c -k --keepParent "$TARGET" "$SUBMIT"
else
    SUBMIT="$TARGET"
fi

echo "• Submitting to the notary service (this can take a few minutes)…"
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait

echo "• Stapling the ticket to $TARGET"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
[ "$ext" = "app" ] && rm -f "$SUBMIT"
echo "✓ Notarized & stapled: $TARGET"
