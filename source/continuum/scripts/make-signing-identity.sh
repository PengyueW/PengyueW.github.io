#!/bin/bash
# Creates a stable, self-signed Code Signing identity in your login keychain
# named "Continuum Local Codesign", then trusts it for code signing.
#
# Why: Continuum is normally ad-hoc signed (codesign --sign -). An ad-hoc
# signature has no stable identity - every ./build.sh produces a new code
# hash, so macOS treats each build as a different app and invalidates the
# Full Disk Access grant you gave the previous build. With a stable identity
# the grant persists across rebuilds and there is one entry for Continuum.
#
# This is a ONE-TIME setup. macOS asks once (GUI) to approve the trust
# setting - that's expected. Re-running is harmless (it recreates cleanly).
#
# Errors are printed (not hidden). If a step fails the script says which one.
set -uo pipefail

NAME="Continuum Local Codesign"
P12_PASS="continuum"
LOGINKC="$(security login-keychain | tr -d ' "')"

echo "Login keychain: ${LOGINKC}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${NAME}"; then
    echo "OK: signing identity '${NAME}' already exists and is valid."
    echo "    Just run ./build.sh - it will use it automatically."
    exit 0
fi

# Remove any stale leftover from a previous failed run so we start clean.
security delete-identity   -c "${NAME}" "${LOGINKC}" >/dev/null 2>&1 || true
security delete-certificate -c "${NAME}" "${LOGINKC}" >/dev/null 2>&1 || true

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "* Generating key + self-signed certificate"
cat > "${TMP}/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
if ! openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" -days 3650 \
        -config "${TMP}/openssl.cnf" 2>"${TMP}/err"; then
    echo "FAILED: openssl couldn't create the certificate:"; cat "${TMP}/err"; exit 1
fi

echo "* Packaging into PKCS#12"
# OpenSSL 3 defaults to a MAC/cipher Apple's keychain can't read; -legacy fixes
# that. LibreSSL / OpenSSL 1.1 don't have (or need) -legacy, so fall back.
LEGACY=""
if openssl pkcs12 -export -help 2>&1 | grep -q -- '-legacy'; then
    LEGACY="-legacy"
fi
if ! openssl pkcs12 -export ${LEGACY} -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
        -name "${NAME}" -out "${TMP}/id.p12" -passout "pass:${P12_PASS}" 2>"${TMP}/err"; then
    echo "FAILED: openssl couldn't build the PKCS#12 bundle:"; cat "${TMP}/err"; exit 1
fi

echo "* Importing into the login keychain"
if ! security import "${TMP}/id.p12" -k "${LOGINKC}" -P "${P12_PASS}" \
        -A -T /usr/bin/codesign 2>"${TMP}/err"; then
    echo "FAILED: keychain import failed:"; cat "${TMP}/err"; exit 1
fi

echo "* Trusting it for code signing"
echo "  (macOS will pop a dialog - enter your LOGIN password to allow it)"
# User trust domain (no -d, so no sudo). codesign won't use the identity until
# the leaf is trusted for the codeSign policy.
if ! security add-trusted-cert -p codeSign -k "${LOGINKC}" "${TMP}/cert.pem" 2>"${TMP}/err"; then
    echo "FAILED: couldn't set the trust setting:"; cat "${TMP}/err"
    echo "    (If you cancelled the password dialog, just re-run this script.)"
    exit 1
fi

# The trust setting can take a moment to propagate after the dialog, so the
# validity check is retried for a few seconds before declaring failure.
valid=0
for _ in 1 2 3 4 5 6 7 8; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${NAME}"; then
        valid=1; break
    fi
    sleep 1
done

if [ "${valid}" = "1" ]; then
    echo
    echo "OK: '${NAME}' is ready and valid for code signing."
    echo "    Next:"
    echo "      ./build.sh        # signs with this identity automatically"
    echo "    Then grant Full Disk Access to Continuum ONE more time (the identity"
    echo "    changed from ad-hoc to stable). After that it persists across rebuilds."
else
    echo
    echo "FAILED: created and trusted the cert, but it still isn't showing as a"
    echo "    valid codesigning identity. Create one via the GUI instead:"
    echo "      Keychain Access > Certificate Assistant > Create a Certificate..."
    echo "      Name: ${NAME}   Identity Type: Self-Signed Root   Type: Code Signing"
    echo "    build.sh will then pick it up by that name."
    exit 1
fi
