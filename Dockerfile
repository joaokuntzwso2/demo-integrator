ARG MI_IMAGE=wso2/wso2mi:4.5.0

# ---------- Stage 1: build CAR + fetch JMS client jars ----------
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /workspace

# Build the CAR
COPY demo-mi /workspace/demo-mi
RUN cd demo-mi && mvn -DskipTests clean package

# Download ActiveMQ client/JNDI jars WITHOUT needing a pom.xml
RUN set -eux; \
    mkdir -p /workspace/jms-libs; \
    \
    mvn -q -DskipTests dependency:get -Dtransitive=true  -Dartifact=org.apache.activemq:activemq-client:5.18.3; \
    mvn -q -DskipTests dependency:get -Dtransitive=false -Dartifact=javax.jms:javax.jms-api:2.0.1; \
    mvn -q -DskipTests dependency:get -Dtransitive=false -Dartifact=org.fusesource.hawtbuf:hawtbuf:1.11; \
    \
    cp -v /root/.m2/repository/org/apache/activemq/activemq-client/5.18.3/activemq-client-5.18.3.jar /workspace/jms-libs/; \
    cp -v /root/.m2/repository/javax/jms/javax.jms-api/2.0.1/javax.jms-api-2.0.1.jar /workspace/jms-libs/; \
    cp -v /root/.m2/repository/org/fusesource/hawtbuf/hawtbuf/1.11/hawtbuf-1.11.jar /workspace/jms-libs/ || true; \
    \
    jar tf /workspace/jms-libs/activemq-client-5.18.3.jar | grep -F "org/apache/activemq/jndi/ActiveMQInitialContextFactory.class"; \
    jar tf /workspace/jms-libs/javax.jms-api-2.0.1.jar | grep -F "javax/jms/JMSContext.class"; \
    ls -lah /workspace/jms-libs

# ---------- Stage 2: MI runtime ----------
FROM ${MI_IMAGE}

USER root

RUN mkdir -p /tmp/deploy /tmp/jms-libs

COPY --from=builder /workspace/demo-mi/target/*.car /tmp/deploy/
COPY demo-mi/deployment/deployment.toml /tmp/deploy/deployment.toml
COPY demo-mi/deployment/docker/resources/wso2carbon.jks /tmp/deploy/wso2carbon.jks
COPY demo-mi/deployment/docker/resources/client-truststore.jks /tmp/deploy/client-truststore.jks

# Trust bootstrap script (NEW)
COPY demo-mi/deployment/docker/resources/init-icp-trust.sh /tmp/deploy/init-icp-trust.sh

# Copy JMS libs from builder
COPY --from=builder /workspace/jms-libs/*.jar /tmp/jms-libs/

RUN set -eux; \
    echo "WSO2_SERVER_HOME=${WSO2_SERVER_HOME}"; \
    \
    mkdir -p "${WSO2_SERVER_HOME}/repository/deployment/server/carbonapps"; \
    mkdir -p "${WSO2_SERVER_HOME}/repository/components/lib"; \
    mkdir -p "${WSO2_SERVER_HOME}/lib"; \
    \
    cp -v /tmp/deploy/*.car "${WSO2_SERVER_HOME}/repository/deployment/server/carbonapps/"; \
    cp -v /tmp/deploy/deployment.toml "${WSO2_SERVER_HOME}/conf/deployment.toml"; \
    cp -v /tmp/deploy/wso2carbon.jks "${WSO2_SERVER_HOME}/repository/resources/security/wso2carbon.jks"; \
    cp -v /tmp/deploy/client-truststore.jks "${WSO2_SERVER_HOME}/repository/resources/security/client-truststore.jks"; \
    \
    cp -v /tmp/jms-libs/*.jar "${WSO2_SERVER_HOME}/lib/"; \
    cp -v /tmp/jms-libs/*.jar "${WSO2_SERVER_HOME}/repository/components/lib/"; \
    \
    cp -v /tmp/deploy/init-icp-trust.sh /home/wso2carbon/init-icp-trust.sh; \
    chmod +x /home/wso2carbon/init-icp-trust.sh; \
    \
    MI_UID="$(id -u wso2carbon)"; \
    MI_GID="$(id -g wso2carbon)"; \
    chown -R "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/repository/deployment/server"; \
    chown -R "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/repository/components/lib"; \
    chown -R "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/lib"; \
    chown "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/conf/deployment.toml"; \
    chown "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/repository/resources/security/wso2carbon.jks"; \
    chown "${MI_UID}:${MI_GID}" "${WSO2_SERVER_HOME}/repository/resources/security/client-truststore.jks"; \
    chown "${MI_UID}:${MI_GID}" /home/wso2carbon/init-icp-trust.sh

USER wso2carbon

EXPOSE 8290 8253 9201 9164

ENTRYPOINT ["/bin/bash", "-lc", "/home/wso2carbon/init-icp-trust.sh && /home/wso2carbon/docker-entrypoint.sh"]