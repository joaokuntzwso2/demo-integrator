FROM wso2/wso2si:4.3.1

USER root

COPY init-icp-trust.sh /home/wso2carbon/init-icp-trust.sh
RUN chmod +x /home/wso2carbon/init-icp-trust.sh \
  && chown -R wso2carbon:wso2 /home/wso2carbon/init-icp-trust.sh

USER wso2carbon

ENTRYPOINT ["/bin/bash", "-lc", "/home/wso2carbon/init-icp-trust.sh && /home/wso2carbon/docker-entrypoint.sh"]