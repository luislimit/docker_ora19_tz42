WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON FEEDBACK OFF VERIFY OFF

DECLARE
  l_open_mode       VARCHAR2(30);
  l_role            VARCHAR2(30);
  l_cdb             VARCHAR2(3);
  l_tz              VARCHAR2(30);
  l_dst_primary     VARCHAR2(30);
  l_dst_secondary   VARCHAR2(30);
  l_dst_state       VARCHAR2(30);
  l_charset         VARCHAR2(30);
  l_nchar           VARCHAR2(30);
  l_count           NUMBER;
  l_dir             VARCHAR2(4000);

  PROCEDURE assert_eq(
    p_name     VARCHAR2,
    p_actual   VARCHAR2,
    p_expected VARCHAR2
  ) IS
  BEGIN
    IF NVL(TRIM(p_actual), '<NULL>') <> p_expected THEN
      RAISE_APPLICATION_ERROR(
        -20000,
        p_name || '=[' || NVL(TRIM(p_actual), '<NULL>') || '] expected [' || p_expected || ']'
      );
    END IF;

    DBMS_OUTPUT.PUT_LINE('OK  ' || RPAD(p_name, 32) || ' = ' || p_expected);
  END assert_eq;
BEGIN
  SELECT open_mode, database_role, cdb
    INTO l_open_mode, l_role, l_cdb
    FROM v$database;

  assert_eq('OPEN_MODE', l_open_mode, 'READ WRITE');
  assert_eq('DATABASE_ROLE', l_role, 'PRIMARY');
  assert_eq('CDB', l_cdb, 'NO');

  SELECT TO_CHAR(version)
    INTO l_tz
    FROM v$timezone_file;

  assert_eq('TIMEZONE_FILE_VERSION', l_tz, '43');

  SELECT property_value
    INTO l_dst_primary
    FROM database_properties
   WHERE property_name = 'DST_PRIMARY_TT_VERSION';

  SELECT property_value
    INTO l_dst_secondary
    FROM database_properties
   WHERE property_name = 'DST_SECONDARY_TT_VERSION';

  SELECT property_value
    INTO l_dst_state
    FROM database_properties
   WHERE property_name = 'DST_UPGRADE_STATE';

  assert_eq('DST_PRIMARY_TT_VERSION', l_dst_primary, '43');
  assert_eq('DST_SECONDARY_TT_VERSION', l_dst_secondary, '0');
  assert_eq('DST_UPGRADE_STATE', l_dst_state, 'NONE');

  SELECT value
    INTO l_charset
    FROM nls_database_parameters
   WHERE parameter = 'NLS_CHARACTERSET';

  SELECT value
    INTO l_nchar
    FROM nls_database_parameters
   WHERE parameter = 'NLS_NCHAR_CHARACTERSET';

  assert_eq('NLS_CHARACTERSET', l_charset, 'AL32UTF8');
  assert_eq('NLS_NCHAR_CHARACTERSET', l_nchar, 'AL16UTF16');

  SELECT COUNT(*)
    INTO l_count
    FROM dba_users
   WHERE username IN ('GIMS', 'USRGIMSC1', 'LIQUIBASE');

  IF l_count <> 3 THEN
    RAISE_APPLICATION_ERROR(
      -20001,
      'Expected users GIMS, USRGIMSC1 and LIQUIBASE are not all present'
    );
  END IF;

  DBMS_OUTPUT.PUT_LINE('OK  Core MUPOL users present');

  SELECT COUNT(*)
    INTO l_count
    FROM dba_tablespaces
   WHERE tablespace_name IN ('TS_GIMS_DAT', 'TS_GIMS_IDX', 'TS_LIQUIBASE_DAT');

  IF l_count <> 3 THEN
    RAISE_APPLICATION_ERROR(
      -20002,
      'Expected core MUPOL tablespaces are not all present'
    );
  END IF;

  DBMS_OUTPUT.PUT_LINE('OK  Core MUPOL tablespaces present');

  SELECT MAX(directory_path)
    INTO l_dir
    FROM dba_directories
   WHERE directory_name = 'MUPOL_DATA_PUMP_DIR';

  IF l_dir IS NULL THEN
    RAISE_APPLICATION_ERROR(-20003, 'MUPOL_DATA_PUMP_DIR does not exist');
  END IF;

  assert_eq('MUPOL_DATA_PUMP_DIR', l_dir, '/opt/oracle/oradata/dpump');

  DBMS_OUTPUT.PUT_LINE('============================================================');
  DBMS_OUTPUT.PUT_LINE('MUPOL BASE VALIDATION SUCCESSFUL');
  DBMS_OUTPUT.PUT_LINE('============================================================');
END;
/
EXIT SUCCESS
