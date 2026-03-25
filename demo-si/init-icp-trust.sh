#!/usr/bin/env bash
set -euo pipefail

ICP_HOST="${ICP_HOST:-icp}"
ICP_PORT="${ICP_PORT:-9743}"

SI_HOME="/home/wso2carbon/wso2si-4.3.1"
TS="${SI_HOME}/resources/security/client-truststore.jks"
TSPASS="wso2carbon"
ALIAS="icp-cert"

echo "[SI] Waiting for ICP TLS endpoint ${ICP_HOST}:${ICP_PORT} ..."
READY=false
for i in $(seq 1 60); do
  if keytool -printcert -sslserver "${ICP_HOST}:${ICP_PORT}" >/dev/null 2>&1; then
    READY=true
    break
  fi
  echo "[SI] ICP not ready yet (${i}/60)"
  sleep 2
done

if [ "${READY}" != "true" ]; then
  echo "[SI] ERROR: ICP TLS endpoint ${ICP_HOST}:${ICP_PORT} did not become ready in time."
  exit 1
fi

echo "[SI] Fetching ICP certificate using keytool ..."
keytool -printcert -rfc -sslserver "${ICP_HOST}:${ICP_PORT}" > /tmp/icp-cert.pem

if [ ! -s /tmp/icp-cert.pem ]; then
  echo "[SI] ERROR: Could not fetch ICP cert with keytool."
  exit 1
fi

echo "[SI] Importing ICP certificate into truststore ${TS}"
keytool -delete -alias "${ALIAS}" -keystore "${TS}" -storepass "${TSPASS}" >/dev/null 2>&1 || true
keytool -importcert -noprompt \
  -alias "${ALIAS}" \
  -file /tmp/icp-cert.pem \
  -keystore "${TS}" \
  -storepass "${TSPASS}"

echo "[SI] ICP trust bootstrap complete."