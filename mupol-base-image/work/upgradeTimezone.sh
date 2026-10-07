#!/bin/bash

set -e

TARGET_TZ_VERSION=43

echo "============================================================"
echo "MUPOL - Oracle Database Time Zone upgrade"
echo "Target version: ${TARGET_TZ_VERSION}"
echo "============================================================"

CURRENT_TZ_VERSION=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT version FROM v\$timezone_file;
EXIT;
EOF
)

CURRENT_TZ_VERSION=$(echo "$CURRENT_TZ_VERSION" | xargs)

echo "Current database time zone version: ${CURRENT_TZ_VERSION}"

if [ "$CURRENT_TZ_VERSION" = "$TARGET_TZ_VERSION" ]; then
    echo "Database is already using time zone version ${TARGET_TZ_VERSION}."
    exit 0
fi

LATEST_TZ_VERSION=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT DBMS_DST.GET_LATEST_TIMEZONE_VERSION FROM dual;
EXIT;
EOF
)

LATEST_TZ_VERSION=$(echo "$LATEST_TZ_VERSION" | xargs)

echo "Latest time zone version available in Oracle Home: ${LATEST_TZ_VERSION}"

if [ "$LATEST_TZ_VERSION" != "$TARGET_TZ_VERSION" ]; then
    echo "ERROR: Oracle Home does not expose TZ version ${TARGET_TZ_VERSION}."
    exit 1
fi

echo "Starting DBMS_DST BEGIN_UPGRADE..."

sqlplus / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE

SHUTDOWN IMMEDIATE;
STARTUP UPGRADE;

SET SERVEROUTPUT ON

DECLARE
    l_version PLS_INTEGER := ${TARGET_TZ_VERSION};
BEGIN
    DBMS_DST.BEGIN_UPGRADE(l_version);
    DBMS_OUTPUT.PUT_LINE(
        'BEGIN_UPGRADE completed for TZ ' || l_version
    );
END;
/

SHUTDOWN IMMEDIATE;
STARTUP;

EXIT;
EOF

echo "Running DBMS_DST.UPGRADE_DATABASE..."

sqlplus / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE

SET SERVEROUTPUT ON

DECLARE
    l_failures PLS_INTEGER;
BEGIN
    DBMS_DST.UPGRADE_DATABASE(l_failures);

    DBMS_OUTPUT.PUT_LINE(
        'UPGRADE_DATABASE failures: ' || l_failures
    );

    IF l_failures <> 0 THEN
        RAISE_APPLICATION_ERROR(
            -20001,
            'DBMS_DST.UPGRADE_DATABASE reported failures: ' || l_failures
        );
    END IF;
END;
/

EXIT;
EOF

echo "Finishing DBMS_DST upgrade..."

sqlplus / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE

SET SERVEROUTPUT ON

DECLARE
    l_failures PLS_INTEGER;
BEGIN
    DBMS_DST.END_UPGRADE(l_failures);

    DBMS_OUTPUT.PUT_LINE(
        'END_UPGRADE failures: ' || l_failures
    );

    IF l_failures <> 0 THEN
        RAISE_APPLICATION_ERROR(
            -20002,
            'DBMS_DST.END_UPGRADE reported failures: ' || l_failures
        );
    END IF;
END;
/

EXIT;
EOF

echo "Validating final DBMS_DST state..."

FINAL_TZ_VERSION=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT version FROM v\$timezone_file;
EXIT;
EOF
)

FINAL_TZ_VERSION=$(echo "$FINAL_TZ_VERSION" | xargs)

DST_STATE=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT property_value
FROM database_properties
WHERE property_name = 'DST_UPGRADE_STATE';
EXIT;
EOF
)

DST_STATE=$(echo "$DST_STATE" | xargs)

DST_SECONDARY=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF
SELECT property_value
FROM database_properties
WHERE property_name = 'DST_SECONDARY_TT_VERSION';
EXIT;
EOF
)

DST_SECONDARY=$(echo "$DST_SECONDARY" | xargs)

echo "Final TZ version: ${FINAL_TZ_VERSION}"
echo "DST_UPGRADE_STATE: ${DST_STATE}"
echo "DST_SECONDARY_TT_VERSION: ${DST_SECONDARY}"

if [ "$FINAL_TZ_VERSION" != "$TARGET_TZ_VERSION" ]; then
    echo "ERROR: Final time zone version is not ${TARGET_TZ_VERSION}."
    exit 1
fi

if [ "$DST_STATE" != "NONE" ]; then
    echo "ERROR: DST_UPGRADE_STATE is ${DST_STATE}, expected NONE."
    exit 1
fi

if [ "$DST_SECONDARY" != "0" ]; then
    echo "ERROR: DST_SECONDARY_TT_VERSION is ${DST_SECONDARY}, expected 0."
    exit 1
fi

echo "============================================================"
echo "MUPOL - Time Zone upgrade completed successfully."
echo "Oracle Database TZ version: ${FINAL_TZ_VERSION}"
echo "============================================================"

exit 0