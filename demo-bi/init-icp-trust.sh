#!/usr/bin/env bash
set -euo pipefail

ICP_HOST="${ICP_HOST:-icp}"
ICP_PORT="${ICP_PORT:-9743}"

OUT_DIR="/app/resources"
ICP_TS="${OUT_DIR}/icp-truststore.p12"
ICP_PASS="ballerina"
ICP_ALIAS="icp-cert"

KS="${OUT_DIR}/ballerinaKeystore.p12"
TS="${OUT_DIR}/ballerinaTruststore.p12"
STORE_PASS="ballerina"
KEY_ALIAS="ballerina"

mkdir -p "${OUT_DIR}"

echo "[BI] Waiting for ICP TLS endpoint ${ICP_HOST}:${ICP_PORT} ..."
for i in $(seq 1 90); do
  if keytool -printcert -sslserver "${ICP_HOST}:${ICP_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "[BI] Fetching ICP certificate ..."
keytool -printcert -rfc -sslserver "${ICP_HOST}:${ICP_PORT}" > /tmp/icp-cert.pem

echo "[BI] Creating ICP truststore ${ICP_TS}"
rm -f "${ICP_TS}" || true
keytool -importcert -noprompt \
  -alias "${ICP_ALIAS}" \
  -file /tmp/icp-cert.pem \
  -keystore "${ICP_TS}" \
  -storetype PKCS12 \
  -storepass "${ICP_PASS}"

# --- Create keystore for BI management API (HTTPS) if missing ---
if [ ! -f "${KS}" ]; then
  echo "[BI] Creating management keystore ${KS}"
  keytool -genkeypair \
    -alias "${KEY_ALIAS}" \
    -keyalg RSA \
    -keysize 2048 \
    -dname "CN=bi, OU=Demo, O=WSO2, L=Local, ST=Local, C=BR" \
    -validity 3650 \
    -storetype PKCS12 \
    -keystore "${KS}" \
    -storepass "${STORE_PASS}" \
    -keypass "${STORE_PASS}"
fi

# --- Create truststore containing the public cert from the keystore ---
echo "[BI] Creating management truststore ${TS}"
rm -f "${TS}" || true
keytool -exportcert -rfc \
  -alias "${KEY_ALIAS}" \
  -keystore "${KS}" \
  -storetype PKCS12 \
  -storepass "${STORE_PASS}" > /tmp/bi-public.pem

keytool -importcert -noprompt \
  -alias "${KEY_ALIAS}" \
  -file /tmp/bi-public.pem \
  -keystore "${TS}" \
  -storetype PKCS12 \
  -storepass "${STORE_PASS}"

echo "[BI] Trust bootstrap complete."