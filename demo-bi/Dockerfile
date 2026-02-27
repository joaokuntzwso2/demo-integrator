# --------- Stage 1: build ----------
FROM ballerina/ballerina:2201.12.0 AS builder

USER root
WORKDIR /workspace

COPY . .
RUN rm -rf target && bal build

# Export the default Ballerina keystore from the builder image into /workspace/bre/security
# (This avoids guessing a hard-coded BAL_HOME path by discovering it in the image.)
RUN set -euo pipefail; \
    mkdir -p /workspace/bre/security; \
    KS="$(find / -type f -path '*/bre/security/ballerinaKeystore.p12' 2>/dev/null | head -n 1 || true)"; \
    if [ -z "$KS" ]; then \
      echo "ERROR: Could not find ballerinaKeystore.p12 inside the builder image"; \
      exit 1; \
    fi; \
    echo "Found default keystore at: $KS"; \
    cp -v "$KS" /workspace/bre/security/ballerinaKeystore.p12

# --------- Stage 2: runtime ----------
FROM eclipse-temurin:21-jre

WORKDIR /app

# App executable
COPY --from=builder /workspace/target/bin/*.jar /app/bi_order_intelligence.jar

# Default Ballerina keystore where the runtime expects it
COPY --from=builder /workspace/bre /app/bre

# ICP trust bootstrap script + directory
COPY init-icp-trust.sh /app/init-icp-trust.sh
RUN chmod +x /app/init-icp-trust.sh && mkdir -p /app/resources

EXPOSE 9090 9264

ENTRYPOINT ["/bin/bash","-lc", "\
set -euo pipefail; \
/app/init-icp-trust.sh; \
echo '[BI] sanity check: keystore path:'; \
ls -la /app/bre/security || true; \
cd /app; \
java -jar /app/bi_order_intelligence.jar \
"]