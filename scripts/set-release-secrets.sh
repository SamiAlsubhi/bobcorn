#!/bin/bash
# Gives the release workflow what it needs to sign and notarize, as secrets of
# the repository. Run it yourself: it reads your certificate and key, asks for
# the certificate's password, and sends them to GitHub, nowhere else.
#
#   scripts/set-release-secrets.sh <Developer ID .p12> <AuthKey_ID.p8> <issuer ID>
#
# The .p12 is your Developer ID Application certificate exported from
# Keychain Access with a password. The .p8 is an App Store Connect API key
# (Users and Access → Integrations → Team Keys, Developer role or higher); the
# key ID is read from its file name, and the issuer ID is on the same page.
set -euo pipefail

[ $# -eq 3 ] || { sed -n '6p' "$0" | sed 's/^# *//'; exit 2; }
p12="$1"
p8="$2"
issuer="$3"
repo="SamiAlsubhi/bobcorn"
key_id="$(basename "$p8" .p8)"
key_id="${key_id#AuthKey_}"

[ -f "$p12" ] || { echo "No file at $p12"; exit 1; }
[ -f "$p8" ] || { echo "No file at $p8"; exit 1; }
read -rsp "Password of $(basename "$p12"): " password
echo

# Check the password and the certificate before anything leaves this Mac.
if ! openssl pkcs12 -in "$p12" -passin "pass:$password" -nokeys 2>/dev/null | grep -q "Developer ID Application" \
   && ! openssl pkcs12 -legacy -in "$p12" -passin "pass:$password" -nokeys 2>/dev/null | grep -q "Developer ID Application"; then
    echo "That isn't a Developer ID Application certificate, or the password is wrong."
    exit 1
fi

base64 -i "$p12" | gh secret set DEVELOPER_ID_P12 --repo "$repo"
printf '%s' "$password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo"
gh secret set NOTARY_KEY --repo "$repo" < "$p8"
printf '%s' "$key_id" | gh secret set NOTARY_KEY_ID --repo "$repo"
printf '%s' "$issuer" | gh secret set NOTARY_ISSUER_ID --repo "$repo"
echo "Done: the next v* tag is signed and notarized."
