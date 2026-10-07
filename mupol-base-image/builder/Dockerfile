ARG ORACLE_BASE_IMAGE=oracle/database:19.3.0-ee
FROM ${ORACLE_BASE_IMAGE}

USER root

COPY work/createDB.sh /opt/oracle/createDB.sh
COPY work/upgradeTimezone.sh /opt/oracle/upgradeTimezone.sh
COPY work/crea_objetos_previo_imp.sql /opt/oracle/crea_objetos_previo_imp.sql
COPY work/dbca.rsp.tmpl /opt/oracle/dbca.rsp.tmpl
COPY work/checkDBStatus.sh /opt/oracle/checkDBStatus.sh
COPY work/startDB.sh /opt/oracle/startDB.sh
COPY resources/timezone_43.dat /tmp/mupol-tz43/timezone_43.dat
COPY resources/timezlrg_43.dat /tmp/mupol-tz43/timezlrg_43.dat

RUN set -eux; \
    chmod 755 /opt/oracle/createDB.sh /opt/oracle/upgradeTimezone.sh /opt/oracle/checkDBStatus.sh /opt/oracle/startDB.sh; \
    chown oracle:oinstall /opt/oracle/createDB.sh /opt/oracle/upgradeTimezone.sh /opt/oracle/crea_objetos_previo_imp.sql /opt/oracle/dbca.rsp.tmpl /opt/oracle/checkDBStatus.sh /opt/oracle/startDB.sh; \
    for d in "$ORACLE_HOME/oracore/zoneinfo" "$ORACLE_HOME/oracore/zoneinfo/big" "$ORACLE_HOME/oracore/zoneinfo/little"; do \
      mkdir -p "$d"; \
      cp /tmp/mupol-tz43/timezone_43.dat "$d/timezone_43.dat"; \
      cp /tmp/mupol-tz43/timezlrg_43.dat "$d/timezlrg_43.dat"; \
      chown oracle:oinstall "$d/timezone_43.dat" "$d/timezlrg_43.dat"; \
      chmod 644 "$d/timezone_43.dat" "$d/timezlrg_43.dat"; \
    done; \
    rm -rf /tmp/mupol-tz43

USER oracle
