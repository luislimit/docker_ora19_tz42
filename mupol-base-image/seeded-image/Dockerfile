ARG BUILDER_IMAGE=mupol-oracle:19.3.0-noncdb-tz43-builder
FROM ${BUILDER_IMAGE}

USER root
COPY work/oradata-base.tar.gz /opt/oracle/oradata-base.tar.gz
COPY seeded-image/seed-oradata.sh /opt/oracle/seed-oradata.sh
RUN chown oracle:oinstall /opt/oracle/oradata-base.tar.gz /opt/oracle/seed-oradata.sh \
    && chmod 755 /opt/oracle/seed-oradata.sh \
    && chmod 644 /opt/oracle/oradata-base.tar.gz
USER oracle

ENTRYPOINT ["/opt/oracle/seed-oradata.sh"]
