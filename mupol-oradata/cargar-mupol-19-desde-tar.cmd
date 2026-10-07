@echo off
setlocal EnableExtensions EnableDelayedExpansion
title MUPOL 19 - Desplegar desde TAR

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "FINAL_TAR=%ROOT%\mupol_19_imp.tar"
set "FINAL_IMAGE=mupol_19_imp:latest"
set "FINAL_CONTAINER=mupol_19"
set "FINAL_VOLUME=mupol_19_oradata"
set "VALIDATE_SQL=_mupol_validate_final.sql"

echo.
echo ============================================================
echo   MUPOL 19 - DESPLIEGUE DESDE TAR
echo ============================================================
echo.

where docker >nul 2>&1 || goto :ERROR
docker info >nul 2>&1 || goto :ERROR
if not exist "%FINAL_TAR%" (
  echo [ERROR] No existe %FINAL_TAR%
  goto :ERROR
)

echo [1/3] Cargando imagen desde mupol_19_imp.tar...
docker rm -f "%FINAL_CONTAINER%" >nul 2>&1
docker image rm -f "%FINAL_IMAGE%" >nul 2>&1
docker load -i "%FINAL_TAR%" || goto :ERROR
docker image inspect "%FINAL_IMAGE%" >nul 2>&1 || goto :ERROR
docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Env}}" | findstr /C:"ORACLE_SID=ORACLE" >nul 2>&1 || goto :ERROR
docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Entrypoint}}" | findstr /C:"/opt/oracle/seed-oradata.sh" >nul 2>&1 || goto :ERROR
docker run --rm --entrypoint bash "%FINAL_IMAGE%" -lc "test \"$ORACLE_SID\" = 'ORACLE' && test -s /opt/oracle/oradata-base.tar.gz" || goto :ERROR
echo [OK] Imagen cargada y validada.

echo.
echo [2/3] Creando volumen limpio y arrancando Oracle...
docker volume rm -f "%FINAL_VOLUME%" >nul 2>&1
docker volume create "%FINAL_VOLUME%" >nul || goto :ERROR
docker run -d ^
  --name "%FINAL_CONTAINER%" ^
  --restart unless-stopped ^
  -e ORACLE_SID=ORACLE ^
  -p 1523:1521 ^
  -p 5501:5500 ^
  -v "%FINAL_VOLUME%:/opt/oracle/oradata" ^
  "%FINAL_IMAGE%" >nul || goto :ERROR
call :WAIT_SQL "%FINAL_CONTAINER%" 1200 || goto :ERROR
call :VALIDATE_IDENTITY "%FINAL_CONTAINER%" || goto :ERROR

echo.
echo [3/3] Validando base importada...
call :CREATE_VALIDATE_SQL || goto :ERROR
docker cp "%ROOT%\%VALIDATE_SQL%" "%FINAL_CONTAINER%:/tmp/%VALIDATE_SQL%" >nul || goto :ERROR
docker exec "%FINAL_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/tmp/%VALIDATE_SQL%" || goto :ERROR
del /q "%ROOT%\%VALIDATE_SQL%" >nul 2>&1

>"%ROOT%\_mupol_register.sql" echo WHENEVER SQLERROR EXIT SQL.SQLCODE
>>"%ROOT%\_mupol_register.sql" echo ALTER SYSTEM REGISTER;
>>"%ROOT%\_mupol_register.sql" echo EXIT
docker cp "%ROOT%\_mupol_register.sql" "%FINAL_CONTAINER%:/tmp/_mupol_register.sql" >nul || goto :ERROR
docker exec "%FINAL_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/tmp/_mupol_register.sql" >nul || goto :ERROR
del /q "%ROOT%\_mupol_register.sql" >nul 2>&1

set "LISTENER_OK=0"
for /L %%L in (1,1,12) do (
  if "!LISTENER_OK!"=="0" (
    docker exec "%FINAL_CONTAINER%" bash -lc "/opt/oracle/product/19c/dbhome_1/bin/lsnrctl status" > "%ROOT%\_listener_status.txt" 2>&1
    findstr /R /I "Service.*ORACLE" "%ROOT%\_listener_status.txt" >nul 2>&1
    if not errorlevel 1 (set "LISTENER_OK=1") else (if %%L LSS 12 timeout /t 5 /nobreak >nul)
  )
)
if "!LISTENER_OK!"=="0" (
  echo [ERROR] El listener no publica ORACLE.
  type "%ROOT%\_listener_status.txt"
  goto :ERROR
)
del /q "%ROOT%\_listener_status.txt" >nul 2>&1

echo.
echo ============================================================
echo   MUPOL 19 DESPLEGADO CORRECTAMENTE
echo ============================================================
echo Imagen:      %FINAL_IMAGE%
echo Contenedor:  %FINAL_CONTAINER%
echo Volumen:     %FINAL_VOLUME%
echo SQL:         localhost:1523
echo JDBC SID:    jdbc:oracle:thin:@localhost:1523:ORACLE
echo EM:          localhost:5501
echo.
echo.
echo [LIMPIEZA] Eliminando ficheros temporales...
del /q "%ROOT%\_mupol_validate_final.sql" >nul 2>&1
del /q "%ROOT%\_mupol_register.sql" >nul 2>&1
del /q "%ROOT%\_listener_status.txt" >nul 2>&1
echo [OK] Temporales eliminados.
echo.
pause
exit /b 0

:WAIT_SQL
set "WC=%~1"
set /a MAX_WAIT=%~2
set /a ELAPSED=0
set /a NEXT_MSG=0
echo [INFO] Esperando conexion SQL en %WC%...
:WAIT_LOOP
set "RUNNING="
for /f "delims=" %%S in ('docker inspect --format "{{.State.Running}}" "%WC%" 2^>nul') do set "RUNNING=%%S"
if /I not "!RUNNING!"=="true" (
  echo [ERROR] El contenedor %WC% se ha detenido.
  docker logs --tail 200 "%WC%"
  exit /b 1
)

docker exec "%WC%" bash -lc "printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\nselect 1 from dual;\nexit\n' | sqlplus -s '/ as sysdba' >/dev/null 2>&1" >nul 2>&1
if not errorlevel 1 (
  echo [OK] Oracle acepta conexiones SQL.
  exit /b 0
)

if !ELAPSED! GEQ !NEXT_MSG! (
  echo [INFO] Esperando Oracle... !ELAPSED! segundos
  set /a NEXT_MSG+=30
)
if !ELAPSED! GEQ !MAX_WAIT! (
  echo [ERROR] Timeout esperando Oracle despues de !MAX_WAIT! segundos.
  docker logs --tail 200 "%WC%"
  exit /b 1
)
timeout /t 10 /nobreak >nul
set /a ELAPSED+=10
goto :WAIT_LOOP

:VALIDATE_IDENTITY
set "VC=%~1"
docker exec "%VC%" bash -lc "test \"$ORACLE_SID\" = 'ORACLE'" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] ORACLE_SID del contenedor no es ORACLE.
  exit /b 1
)
docker exec "%VC%" bash -lc "printf 'show parameter db_name\nexit\n' | sqlplus -s '/ as sysdba' | grep -Eiq 'db_name[[:space:]]+string[[:space:]]+ORACLE'" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] DB_NAME no es ORACLE.
  exit /b 1
)
docker exec "%VC%" bash -lc "printf 'show parameter service_names\nexit\n' | sqlplus -s '/ as sysdba' | grep -Eiq 'service_names[[:space:]]+string[[:space:]]+ORACLE'" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] SERVICE_NAMES no contiene ORACLE.
  exit /b 1
)
echo [OK] SID=ORACLE, DB_NAME=ORACLE, SERVICE_NAMES=ORACLE.
exit /b 0

:CREATE_VALIDATE_SQL
rem Se genera mediante PowerShell linea a linea para que CMD no interprete
rem parentesis, pipes, operadores ni v$ de Oracle.
powershell -NoProfile -Command ^
 "$p='%ROOT%\%VALIDATE_SQL%';" ^
 "$l=@(" ^
 "'WHENEVER SQLERROR EXIT SQL.SQLCODE'," ^
 "'SET SERVEROUTPUT ON'," ^
 "'DECLARE'," ^
 "'  v_open VARCHAR2(30);'," ^
 "'  v_role VARCHAR2(30);'," ^
 "'  v_cdb VARCHAR2(3);'," ^
 "'  v_charset VARCHAR2(100);'," ^
 "'  v_nchar VARCHAR2(100);'," ^
 "'  v_tz NUMBER;'," ^
 "'  v_tables NUMBER;'," ^
 "'  v_instance VARCHAR2(128);'," ^
 "'BEGIN'," ^
 "'  SELECT open_mode, database_role, cdb INTO v_open, v_role, v_cdb FROM v$database;'," ^
 "'  SELECT value INTO v_charset FROM nls_database_parameters WHERE parameter=''NLS_CHARACTERSET'';'," ^
 "'  SELECT value INTO v_nchar FROM nls_database_parameters WHERE parameter=''NLS_NCHAR_CHARACTERSET'';'," ^
 "'  SELECT version INTO v_tz FROM v$timezone_file;'," ^
 "'  SELECT COUNT(*) INTO v_tables FROM dba_objects WHERE owner LIKE ''GIMS%%'' AND object_type=''TABLE'';'," ^
 "'  v_instance := SYS_CONTEXT(''USERENV'',''INSTANCE_NAME'');'," ^
 "'  IF v_open <> ''READ WRITE'' THEN RAISE_APPLICATION_ERROR(-20011,''OPEN_MODE=''||v_open); END IF;'," ^
 "'  IF v_role <> ''PRIMARY'' THEN RAISE_APPLICATION_ERROR(-20012,''DATABASE_ROLE=''||v_role); END IF;'," ^
 "'  IF v_cdb <> ''NO'' THEN RAISE_APPLICATION_ERROR(-20013,''CDB=''||v_cdb); END IF;'," ^
 "'  IF v_charset <> ''AL32UTF8'' THEN RAISE_APPLICATION_ERROR(-20014,''CHARSET=''||v_charset); END IF;'," ^
 "'  IF v_nchar <> ''AL16UTF16'' THEN RAISE_APPLICATION_ERROR(-20015,''NCHAR_CHARSET=''||v_nchar); END IF;'," ^
 "'  IF v_tz <> 43 THEN RAISE_APPLICATION_ERROR(-20016,''TIMEZONE=''||v_tz); END IF;'," ^
 "'  IF v_tables <= 0 THEN RAISE_APPLICATION_ERROR(-20017,''No existen tablas GIMS''); END IF;'," ^
 "'  IF UPPER(v_instance) <> ''ORACLE'' THEN RAISE_APPLICATION_ERROR(-20018,''INSTANCE_NAME=''||v_instance); END IF;'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''OPEN_MODE=''||v_open);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''DATABASE_ROLE=''||v_role);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''CDB=''||v_cdb);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''CHARSET=''||v_charset);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''NCHAR_CHARSET=''||v_nchar);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''TIMEZONE=''||v_tz);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''INSTANCE_NAME=''||v_instance);'," ^
 "'  DBMS_OUTPUT.PUT_LINE(''TABLAS_GIMS=''||v_tables);'," ^
 "'END;'," ^
 "'/'," ^
 "'EXIT');" ^
 "[IO.File]::WriteAllLines($p,$l,[Text.Encoding]::ASCII)"
if errorlevel 1 (
  echo [ERROR] No se pudo generar el SQL de validacion.
  exit /b 1
)
exit /b 0
:ERROR
echo.
echo [ERROR] No se pudo desplegar MUPOL 19.
echo Se conservan los recursos para diagnostico.
pause
exit /b 1
