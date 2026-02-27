#!/usr/bin/env bash
set -euo pipefail

ICP_HOST="${ICP_HOST:-icp}"
ICP_PORT="${ICP_PORT:-9743}"

SI_HOME="/home/wso2carbon/wso2si-4.3.1"

# Common SI truststore location for this distribution
TS="${SI_HOME}/resources/security/client-truststore.jks"
TSPASS="wso2carbon"
ALIAS="icp-cert"

echo "[SI] Waiting for ICP TLS endpoint ${ICP_HOST}:${ICP_PORT} ..."
for i in $(seq 1 60); do
  if keytool -printcert -sslserver "${ICP_HOST}:${ICP_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "[SI] Fetching ICP certificate using keytool ..."
keytool -printcert -rfc -sslserver "${ICP_HOST}:${ICP_PORT}" > /tmp/icp-cert.pem

if [ ! -s /tmp/icp-cert.pem ]; then
  echo "[SI] ERROR: Could not fetch ICP cert with keytool."
  exit 1
fi

echo "[SI] Importing ICP certificate into truststore ${TS}"
keytool -delete -alias "${ALIAS}" -keystore "${TS}" -storepass "${TSPASS}" >/dev/null 2>&1 || true
keytool -importcert -noprompt -alias "${ALIAS}" -file /tmp/icp-cert.pem -keystore "${TS}" -storepass "${TSPASS}"

echo "[SI] ICP trust bootstrap complete."