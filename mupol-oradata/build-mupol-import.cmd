@echo off
setlocal EnableExtensions EnableDelayedExpansion

title MUPOL 19 - Generacion completa desde DMP

rem ============================================================
rem MUPOL 19 - PROCESO COMPLETO Y DEFINITIVO
rem ============================================================
rem Requisitos en la misma carpeta que este CMD:
rem   - mupol-oracle-base.tar
rem   - exactamente un fichero *.dmp
rem
rem Resultado:
rem   - imagen final:      mupol_19_imp:latest
rem   - TAR distribuible:  mupol_19_imp.tar
rem   - log Data Pump:     mupol_19_imp.log
rem   - contenedor final:  mupol_19
rem   - volumen final:     mupol_19_oradata
rem   - SID/DB/servicio:   ORACLE
rem   - puerto SQL host:   1523
rem   - puerto EM host:    5501
rem
rem IMPORTANTE:
rem   - El proceso borra al inicio SOLO los recursos MUPOL que usa.
rem   - No usa docker system prune.
rem   - No toca otras imagenes/volumenes ajenos al proceso.
rem   - Ante un error conserva el estado de trabajo para diagnostico.
rem ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "BASE_TAR=%ROOT%\mupol-oracle-base.tar"
set "BASE_IMAGE=mupol-oracle:19.3.0-noncdb-tz43-base"
set "WORK_CONTAINER=mupol_19_imp_build"
set "WORK_VOLUME=mupol_19_imp_oradata"
set "FINAL_IMAGE=mupol_19_imp:latest"
set "FINAL_TAR=%ROOT%\mupol_19_imp.tar"
set "FINAL_CONTAINER=mupol_19"
set "FINAL_VOLUME=mupol_19_oradata"
set "IMPORT_LOG=mupol_19_imp.log"
set "PARFILE=_mupol_import.par"
set "POST_SQL=_mupol_post_import.sql"
set "BUILD_CTX=%ROOT%\_mupol_build_ctx"
set "SEED_FILE=_mupol_oradata_imported.tar.gz"
set "DOCKERFILE=Dockerfile"
set "VALIDATE_SQL=_mupol_validate_database_step7.sql"
set "PREP_SQL=_mupol_prepare_seed.sql"
set "SHUTDOWN_SQL=_mupol_shutdown.sql"
set "REGISTER_SQL=_mupol_register.sql"
set "CURRENT_STEP=0"
set "MAX_STEPS=11"

for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "PROCESS_START=%%T"
for /L %%N in (1,1,%MAX_STEPS%) do (
    set "STEP_START_%%N="
    set "STEP_SECS_%%N="
    set "STEP_STATUS_%%N=PENDIENTE"
)

echo.
echo ============================================================
echo   MUPOL 19 - CREACION COMPLETA DESDE DMP
echo ============================================================
echo Carpeta: %ROOT%
echo SID final: ORACLE
echo.

rem ============================================================
rem PRECHECKS
rem ============================================================
where docker >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker no esta disponible en PATH.
    goto :ERROR
)

docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker no esta iniciado o no responde.
    goto :ERROR
)

if not exist "%BASE_TAR%" (
    echo [ERROR] No existe %BASE_TAR%
    goto :ERROR
)

set "DMP_COUNT=0"
set "DMP_NAME="
for %%F in ("%ROOT%\*.dmp") do (
    if exist "%%~fF" (
        set /a DMP_COUNT+=1
        set "DMP_NAME=%%~nxF"
    )
)
if not "!DMP_COUNT!"=="1" (
    echo [ERROR] Debe existir exactamente UN fichero .dmp en %ROOT%
    echo         Encontrados: !DMP_COUNT!
    goto :ERROR
)

echo [OK] Base TAR: %BASE_TAR%
echo [OK] DMP: !DMP_NAME!
echo.

rem ============================================================
rem PASO 1 - LIMPIEZA INICIAL CONTROLADA
rem ============================================================
echo [1/%MAX_STEPS%] Limpieza inicial controlada...
call :START_STEP 1

docker rm -f "%FINAL_CONTAINER%" >nul 2>&1
docker rm -f "%WORK_CONTAINER%" >nul 2>&1
docker volume rm -f "%FINAL_VOLUME%" >nul 2>&1
docker volume rm -f "%WORK_VOLUME%" >nul 2>&1
docker image rm -f "%FINAL_IMAGE%" >nul 2>&1
docker image rm -f "%BASE_IMAGE%" >nul 2>&1

if exist "%FINAL_TAR%" del /q "%FINAL_TAR%" >nul 2>&1
if exist "%ROOT%\%IMPORT_LOG%" del /q "%ROOT%\%IMPORT_LOG%" >nul 2>&1
if exist "%ROOT%\%PARFILE%" del /q "%ROOT%\%PARFILE%" >nul 2>&1
if exist "%ROOT%\%POST_SQL%" del /q "%ROOT%\%POST_SQL%" >nul 2>&1
if exist "%BUILD_CTX%" rmdir /s /q "%BUILD_CTX%" >nul 2>&1

echo [OK] Recursos MUPOL anteriores eliminados.

rem IMPORTANTE: la imagen base se carga AQUI, antes de cerrar el paso 1.
rem De esta forma el paso 3 nunca puede ejecutarse tras la limpieza sin
rem haber cargado y validado primero mupol-oracle-base.tar.
echo [INFO] Cargando inmediatamente la imagen base tras la limpieza...
docker load -i "%BASE_TAR%"
if errorlevel 1 (
    echo [ERROR] No se pudo cargar la imagen base desde %BASE_TAR%.
    goto :ERROR
)
docker image inspect "%BASE_IMAGE%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El TAR no contiene la imagen esperada %BASE_IMAGE%.
    goto :ERROR
)
echo [OK] Imagen base cargada y validada.
call :END_STEP 1

rem ============================================================
rem PASO 2 - VERIFICACION DE IMAGEN BASE
rem ============================================================
echo [2/%MAX_STEPS%] Verificando imagen base antes del arranque...
call :START_STEP 2

docker image inspect "%BASE_IMAGE%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] La imagen base no esta disponible. Se intenta recargar el TAR...
    docker load -i "%BASE_TAR%"
    if errorlevel 1 (
        echo [ERROR] No se pudo recargar la imagen base.
        goto :ERROR
    )
    docker image inspect "%BASE_IMAGE%" >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] El TAR no contiene %BASE_IMAGE%.
        goto :ERROR
    )
)
echo [OK] Imagen base disponible para el paso 3.
call :END_STEP 2

rem ============================================================
rem PASO 3 - VOLUMEN Y ORACLE BASE
rem ============================================================
echo [3/%MAX_STEPS%] Creando volumen y arrancando ORACLE base...
call :START_STEP 3

docker volume create "%WORK_VOLUME%" >nul
if errorlevel 1 goto :ERROR

rem Ultima proteccion: nunca intentar docker run si la imagen base no existe.
docker image inspect "%BASE_IMAGE%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Proteccion paso 3: %BASE_IMAGE% no existe localmente.
    echo         No se intentara docker run.
    goto :ERROR
)

docker run -d --name "%WORK_CONTAINER%" ^
  -e ORACLE_SID=ORACLE ^
  -e ORACLE_PWD=calculosa ^
  -v "%WORK_VOLUME%:/opt/oracle/oradata" ^
  -v "%ROOT%:/mupol-import" ^
  "%BASE_IMAGE%" >nul
if errorlevel 1 (
    echo [ERROR] No se pudo arrancar %WORK_CONTAINER%.
    goto :ERROR
)

call :WAIT_SQL "%WORK_CONTAINER%" 600
if errorlevel 1 goto :ERROR

call :VALIDATE_ORACLE_IDENTITY "%WORK_CONTAINER%"
if errorlevel 1 goto :ERROR

echo [OK] Oracle base disponible como ORACLE.
call :END_STEP 3

rem ============================================================
rem PASO 4 - PREPARAR DATA PUMP
rem ============================================================
echo [4/%MAX_STEPS%] Preparando Data Pump...
call :START_STEP 4

docker exec "%WORK_CONTAINER%" bash -lc "printf \"WHENEVER SQLERROR EXIT SQL.SQLCODE\nCREATE OR REPLACE DIRECTORY MUPOL_DATA_PUMP_DIR AS '/mupol-import';\nEXIT\n\" | sqlplus -s '/ as sysdba'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No se pudo crear MUPOL_DATA_PUMP_DIR.
    goto :ERROR
)

docker exec "%WORK_CONTAINER%" bash -lc "test -r '/mupol-import/!DMP_NAME!'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El DMP no es legible desde el contenedor.
    goto :ERROR
)

docker exec "%WORK_CONTAINER%" bash -lc "P=$(printf \"set heading off\\nset feedback off\\nset pagesize 0\\nselect directory_path from dba_directories where directory_name='MUPOL_DATA_PUMP_DIR';\" | sqlplus -s '/ as sysdba' | tr -d '[:space:]'); test \"$P\" = '/mupol-import'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] MUPOL_DATA_PUMP_DIR no apunta a /mupol-import.
    goto :ERROR
)

echo userid="sys/calculosa as sysdba">"%ROOT%\%PARFILE%"
echo DIRECTORY=MUPOL_DATA_PUMP_DIR>>"%ROOT%\%PARFILE%"
echo DUMPFILE=!DMP_NAME!>>"%ROOT%\%PARFILE%"
echo LOGFILE=%IMPORT_LOG%>>"%ROOT%\%PARFILE%"
echo FULL=Y>>"%ROOT%\%PARFILE%"

echo [OK] Data Pump preparado.
call :END_STEP 4

rem ============================================================
rem PASO 5 - IMPORTACION
rem ============================================================
echo [5/%MAX_STEPS%] Ejecutando impdp FULL=Y...
call :START_STEP 5
echo DMP: !DMP_NAME!
echo.

docker exec "%WORK_CONTAINER%" bash -lc "impdp parfile=/mupol-import/%PARFILE%"
set "IMPDP_RC=!ERRORLEVEL!"
if exist "%ROOT%\%PARFILE%" del /q "%ROOT%\%PARFILE%" >nul 2>&1

if not exist "%ROOT%\%IMPORT_LOG%" (
    echo [ERROR] No se ha generado %IMPORT_LOG%.
    goto :ERROR
)
findstr /I /C:"completed" "%ROOT%\%IMPORT_LOG%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] El log no indica que el job Data Pump haya finalizado.
    goto :ERROR
)
if not "!IMPDP_RC!"=="0" (
    echo [AVISO] impdp devolvio RC=!IMPDP_RC!, pero el job consta como completado.
    echo         Se continua con postproceso y validaciones.
)
echo [OK] Importacion finalizada.
call :END_STEP 5

rem ============================================================
rem PASO 6 - POSTIMPORT Y RECOMPILACION
rem ============================================================
echo [6/%MAX_STEPS%] Vistas EDITIONABLE y recompilacion...
call :START_STEP 6

>"%ROOT%\%POST_SQL%" echo WHENEVER SQLERROR EXIT SQL.SQLCODE
>>"%ROOT%\%POST_SQL%" echo BEGIN
>>"%ROOT%\%POST_SQL%" echo   FOR r IN ^(
>>"%ROOT%\%POST_SQL%" echo     SELECT owner, object_name FROM all_objects
>>"%ROOT%\%POST_SQL%" echo     WHERE object_type='VIEW' AND editionable='N' AND owner LIKE 'GIMS%%'
>>"%ROOT%\%POST_SQL%" echo   ^) LOOP
>>"%ROOT%\%POST_SQL%" echo     EXECUTE IMMEDIATE 'ALTER VIEW ' ^|^| r.owner ^|^| '.' ^|^| r.object_name ^|^| ' EDITIONABLE';
>>"%ROOT%\%POST_SQL%" echo   END LOOP;
>>"%ROOT%\%POST_SQL%" echo END;
>>"%ROOT%\%POST_SQL%" echo /
>>"%ROOT%\%POST_SQL%" echo EXIT

docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/%POST_SQL%"
set "POST_RC=!ERRORLEVEL!"
del /q "%ROOT%\%POST_SQL%" >nul 2>&1
if not "!POST_RC!"=="0" (
    echo [AVISO] No se pudieron convertir todas las vistas GIMS a EDITIONABLE.
    echo         Se continua: las vistas NON-EDITIONABLE no bloquean la imagen.
)

>"%ROOT%\_check_noneditionable.sql" echo SET HEADING OFF
>>"%ROOT%\_check_noneditionable.sql" echo SET FEEDBACK OFF
>>"%ROOT%\_check_noneditionable.sql" echo SET PAGESIZE 0
>>"%ROOT%\_check_noneditionable.sql" echo SET VERIFY OFF
>>"%ROOT%\_check_noneditionable.sql" echo PROMPT [AVISO] Numero de vistas GIMS NON-EDITIONABLE restantes:
>>"%ROOT%\_check_noneditionable.sql" echo SELECT COUNT^(*) FROM all_objects WHERE object_type='VIEW' AND editionable='N' AND owner LIKE 'GIMS%%';
>>"%ROOT%\_check_noneditionable.sql" echo EXIT

docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/_check_noneditionable.sql"
if errorlevel 1 echo [AVISO] No se pudo consultar el numero de vistas NON-EDITIONABLE. Se continua.
del /q "%ROOT%\_check_noneditionable.sql" >nul 2>&1

>"%ROOT%\_recomp.sql" echo WHENEVER SQLERROR EXIT SQL.SQLCODE
>>"%ROOT%\_recomp.sql" echo EXEC UTL_RECOMP.RECOMP_PARALLEL^(4^);
>>"%ROOT%\_recomp.sql" echo EXIT

docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/_recomp.sql"
set "RECOMP_RC=!ERRORLEVEL!"
del /q "%ROOT%\_recomp.sql" >nul 2>&1
if not "!RECOMP_RC!"=="0" (
    echo [ERROR] Fallo UTL_RECOMP.RECOMP_PARALLEL^(4^).
    goto :ERROR
)

echo.
echo Objetos invalidos restantes:
>"%ROOT%\_invalids.sql" echo SET LINESIZE 220
>>"%ROOT%\_invalids.sql" echo SET PAGESIZE 500
>>"%ROOT%\_invalids.sql" echo COLUMN owner FORMAT A25
>>"%ROOT%\_invalids.sql" echo COLUMN object_type FORMAT A25
>>"%ROOT%\_invalids.sql" echo SELECT owner, object_type, COUNT^(*) cantidad FROM dba_objects WHERE status='INVALID' AND owner NOT IN ^('SYS','SYSTEM'^) GROUP BY owner, object_type ORDER BY owner, object_type;
>>"%ROOT%\_invalids.sql" echo EXIT

docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/_invalids.sql"
set "INVALID_RC=!ERRORLEVEL!"
del /q "%ROOT%\_invalids.sql" >nul 2>&1
if not "!INVALID_RC!"=="0" echo [AVISO] No se pudo listar los objetos invalidos. Se continua.

echo [OK] Post-import finalizado.
call :END_STEP 6

rem ============================================================
rem PASO 7 - VALIDACION COMPLETA DE LA BD IMPORTADA
rem ============================================================
rem SQL exactos del script de continuacion probado.
call :P7_WRITE_B64 "%ROOT%\%VALIDATE_SQL%" "V0hFTkVWRVIgU1FMRVJST1IgRVhJVCBTUUwuU1FMQ09ERQpTRVQgU0VSVkVST1VUUFVUIE9OClNFVCBGRUVEQkFDSyBPRkYKREVDTEFSRQogIHZfb3BlbiBWQVJDSEFSMigzMCk7CiAgdl9yb2xlIFZBUkNIQVIyKDMwKTsKICB2X2NkYiBWQVJDSEFSMigzKTsKICB2X2NoYXJzZXQgVkFSQ0hBUjIoMTAwKTsKICB2X25jaGFyc2V0IFZBUkNIQVIyKDEwMCk7CiAgdl90eiBOVU1CRVI7CiAgdl90YWJsZXMgTlVNQkVSOwogIHZfaW5zdGFuY2UgVkFSQ0hBUjIoMTI4KTsKQkVHSU4KICBTRUxFQ1Qgb3Blbl9tb2RlLCBkYXRhYmFzZV9yb2xlLCBjZGIgSU5UTyB2X29wZW4sIHZfcm9sZSwgdl9jZGIgRlJPTSB2JGRhdGFiYXNlOwogIFNFTEVDVCB2YWx1ZSBJTlRPIHZfY2hhcnNldCBGUk9NIG5sc19kYXRhYmFzZV9wYXJhbWV0ZXJzIFdIRVJFIHBhcmFtZXRlcj0nTkxTX0NIQVJBQ1RFUlNFVCc7CiAgU0VMRUNUIHZhbHVlIElOVE8gdl9uY2hhcnNldCBGUk9NIG5sc19kYXRhYmFzZV9wYXJhbWV0ZXJzIFdIRVJFIHBhcmFtZXRlcj0nTkxTX05DSEFSX0NIQVJBQ1RFUlNFVCc7CiAgU0VMRUNUIHZlcnNpb24gSU5UTyB2X3R6IEZST00gdiR0aW1lem9uZV9maWxlOwogIFNFTEVDVCBDT1VOVCgqKSBJTlRPIHZfdGFibGVzIEZST00gZGJhX29iamVjdHMgV0hFUkUgb3duZXIgTElLRSAnR0lNUyUnIEFORCBvYmplY3RfdHlwZT0nVEFCTEUnOwogIHZfaW5zdGFuY2UgOj0gU1lTX0NPTlRFWFQoJ1VTRVJFTlYnLCdJTlNUQU5DRV9OQU1FJyk7CiAgSUYgdl9vcGVuIDw+ICdSRUFEIFdSSVRFJyBUSEVOIFJBSVNFX0FQUExJQ0FUSU9OX0VSUk9SKC0yMDAxMSwnQkQgbm8gUkVBRCBXUklURTogJyB8fCB2X29wZW4pOyBFTkQgSUY7CiAgSUYgdl9yb2xlIDw+ICdQUklNQVJZJyBUSEVOIFJBSVNFX0FQUExJQ0FUSU9OX0VSUk9SKC0yMDAxMiwnREFUQUJBU0VfUk9MRSBpbmNvcnJlY3RvOiAnIHx8IHZfcm9sZSk7IEVORCBJRjsKICBJRiB2X2NkYiA8PiAnTk8nIFRIRU4gUkFJU0VfQVBQTElDQVRJT05fRVJST1IoLTIwMDEzLCdCRCBubyBOT04tQ0RCOiAnIHx8IHZfY2RiKTsgRU5EIElGOwogIElGIHZfY2hhcnNldCA8PiAnQUwzMlVURjgnIFRIRU4gUkFJU0VfQVBQTElDQVRJT05fRVJST1IoLTIwMDE0LCdDaGFyc2V0IGluY29ycmVjdG86ICcgfHwgdl9jaGFyc2V0KTsgRU5EIElGOwogIElGIHZfbmNoYXJzZXQgPD4gJ0FMMTZVVEYxNicgVEhFTiBSQUlTRV9BUFBMSUNBVElPTl9FUlJPUigtMjAwMTUsJ05DSEFSIGNoYXJzZXQgaW5jb3JyZWN0bzogJyB8fCB2X25jaGFyc2V0KTsgRU5EIElGOwogIElGIHZfdHogPD4gNDMgVEhFTiBSQUlTRV9BUFBMSUNBVElPTl9FUlJPUigtMjAwMTYsJ1RpbWV6b25lIGluY29ycmVjdGE6ICcgfHwgdl90eik7IEVORCBJRjsKICBJRiB2X3RhYmxlcyA8PSAwIFRIRU4gUkFJU0VfQVBQTElDQVRJT05fRVJST1IoLTIwMDE3LCdObyBleGlzdGVuIHRhYmxhcyBHSU1TIGltcG9ydGFkYXMnKTsgRU5EIElGOwogIElGIFVQUEVSKHZfaW5zdGFuY2UpIDw+ICdPUkFDTEUnIFRIRU4gUkFJU0VfQVBQTElDQVRJT05fRVJST1IoLTIwMDE4LCdJTlNUQU5DRV9OQU1FIGluY29ycmVjdG86ICcgfHwgdl9pbnN0YW5jZSk7IEVORCBJRjsKICBEQk1TX09VVFBVVC5QVVRfTElORSgnT1BFTl9NT0RFPScgfHwgdl9vcGVuKTsKICBEQk1TX09VVFBVVC5QVVRfTElORSgnREFUQUJBU0VfUk9MRT0nIHx8IHZfcm9sZSk7CiAgREJNU19PVVRQVVQuUFVUX0xJTkUoJ0NEQj0nIHx8IHZfY2RiKTsKICBEQk1TX09VVFBVVC5QVVRfTElORSgnQ0hBUlNFVD0nIHx8IHZfY2hhcnNldCk7CiAgREJNU19PVVRQVVQuUFVUX0xJTkUoJ05DSEFSX0NIQVJTRVQ9JyB8fCB2X25jaGFyc2V0KTsKICBEQk1TX09VVFBVVC5QVVRfTElORSgnVElNRVpPTkU9JyB8fCB2X3R6KTsKICBEQk1TX09VVFBVVC5QVVRfTElORSgnSU5TVEFOQ0VfTkFNRT0nIHx8IHZfaW5zdGFuY2UpOwogIERCTVNfT1VUUFVULlBVVF9MSU5FKCdUQUJMQVNfR0lNUz0nIHx8IHZfdGFibGVzKTsKRU5EOwovCkVYSVQK" || goto :ERROR
call :P7_WRITE_B64 "%ROOT%\%PREP_SQL%" "V0hFTkVWRVIgU1FMRVJST1IgRVhJVCBTUUwuU1FMQ09ERQpDUkVBVEUgT1IgUkVQTEFDRSBESVJFQ1RPUlkgTVVQT0xfREFUQV9QVU1QX0RJUiBBUyAnL29wdC9vcmFjbGUvb3JhZGF0YS9kcHVtcCc7CkVYSVQK" || goto :ERROR
call :P7_WRITE_B64 "%ROOT%\%SHUTDOWN_SQL%" "V0hFTkVWRVIgU1FMRVJST1IgRVhJVCBTUUwuU1FMQ09ERQpTSFVURE9XTiBJTU1FRElBVEU7CkVYSVQK" || goto :ERROR
call :P7_WRITE_B64 "%ROOT%\%REGISTER_SQL%" "V0hFTkVWRVIgU1FMRVJST1IgRVhJVCBTUUwuU1FMQ09ERQpBTFRFUiBTWVNURU0gUkVHSVNURVI7CkVYSVQK" || goto :ERROR

echo [7/%MAX_STEPS%] Validando BD importada...
call :START_STEP 7
call :P7_WAIT_SQL "%WORK_CONTAINER%" 300 || goto :ERROR
call :P7_VALIDATE_IDENTITY "%WORK_CONTAINER%" || goto :ERROR
call :P7_VALIDATE_DATABASE "%WORK_CONTAINER%" || goto :ERROR
echo [OK] Paso 7 completado.
call :END_STEP 7

echo [8/%MAX_STEPS%] Shutdown limpio y congelacion de ORADATA...
call :START_STEP 8
docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/%PREP_SQL%" || goto :ERROR
docker exec "%WORK_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/%SHUTDOWN_SQL%" || goto :ERROR
docker stop -t 30 "%WORK_CONTAINER%" >nul 2>&1
docker rm -f "%WORK_CONTAINER%" >nul 2>&1
if exist "%BUILD_CTX%" rmdir /s /q "%BUILD_CTX%"
mkdir "%BUILD_CTX%" || goto :ERROR
echo [INFO] Creando seed comprimido. Puede tardar varios minutos...
docker run --rm --user root --entrypoint bash -v "%WORK_VOLUME%:/oradata:ro" -v "%BUILD_CTX%:/out" "%BASE_IMAGE%" -lc "tar -czf /out/%SEED_FILE% -C /oradata . && gzip -t /out/%SEED_FILE% && tar -tzf /out/%SEED_FILE% | grep -q '^./ORACLE/control01.ctl$' && tar -tzf /out/%SEED_FILE% | grep -q '^./dbconfig/ORACLE/spfileORACLE.ora$'" || goto :ERROR
if not exist "%BUILD_CTX%\%SEED_FILE%" goto :ERROR
for %%F in ("%BUILD_CTX%\%SEED_FILE%") do echo [OK] Seed generado: %%~zF bytes
call :END_STEP 8

rem ============================================================
rem PASO 9 - BUILD, VALIDACION DE IMAGEN Y TAR
rem ============================================================
echo [9/%MAX_STEPS%] Construyendo imagen final y generando TAR...
call :START_STEP 9

>"%BUILD_CTX%\Dockerfile" echo FROM %BASE_IMAGE%
>>"%BUILD_CTX%\Dockerfile" echo USER root
>>"%BUILD_CTX%\Dockerfile" echo COPY %SEED_FILE% /opt/oracle/oradata-base.tar.gz
>>"%BUILD_CTX%\Dockerfile" echo RUN chown oracle:oinstall /opt/oracle/oradata-base.tar.gz
>>"%BUILD_CTX%\Dockerfile" echo ENV ORACLE_SID=ORACLE
>>"%BUILD_CTX%\Dockerfile" echo USER oracle
>>"%BUILD_CTX%\Dockerfile" echo ENTRYPOINT ["/opt/oracle/seed-oradata.sh"]
docker image rm -f "%FINAL_IMAGE%" >nul 2>&1
docker build --no-cache -f "%BUILD_CTX%\Dockerfile" -t "%FINAL_IMAGE%" "%BUILD_CTX%" || goto :ERROR
docker image inspect "%FINAL_IMAGE%" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] No existe la imagen %FINAL_IMAGE%.
  goto :ERROR
)

rem Comprobacion robusta: inspeccionamos el array JSON completo y buscamos
rem ORACLE_SID=ORACLE como substring. No usamos findstr /X.
docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Env}}" | findstr /C:"ORACLE_SID=ORACLE" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] La imagen no contiene ORACLE_SID=ORACLE.
  goto :ERROR
)

docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Entrypoint}}" | findstr /C:"/opt/oracle/seed-oradata.sh" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] ENTRYPOINT no es /opt/oracle/seed-oradata.sh.
  goto :ERROR
)

docker run --rm --entrypoint bash "%FINAL_IMAGE%" -lc "test \"$ORACLE_SID\" = 'ORACLE' && test -s /opt/oracle/oradata-base.tar.gz"
if errorlevel 1 (
  echo [ERROR] La imagen no supera la comprobacion interna de SID/seed.
  goto :ERROR
)

echo [OK] Imagen validada: SID ORACLE, entrypoint correcto y seed presente.

if exist "%FINAL_TAR%" del /q "%FINAL_TAR%" >nul 2>&1
echo [INFO] Creando %FINAL_TAR%. Puede tardar varios minutos...
docker save -o "%FINAL_TAR%" "%FINAL_IMAGE%"
if errorlevel 1 (
  echo [ERROR] docker save ha fallado.
  goto :ERROR
)
if not exist "%FINAL_TAR%" (
  echo [ERROR] No se ha creado %FINAL_TAR%.
  goto :ERROR
)
for %%F in ("%FINAL_TAR%") do echo [OK] TAR final generado: %%~zF bytes
call :END_STEP 9

rem ============================================================
rem PASO 10 - BORRAR IMAGEN LOCAL Y RECARGAR DESDE EL TAR
rem ============================================================
echo [10/%MAX_STEPS%] Validando el artefacto TAR real...
call :START_STEP 10

docker image rm -f "%FINAL_IMAGE%" >nul 2>&1
docker image inspect "%FINAL_IMAGE%" >nul 2>&1
if not errorlevel 1 (
  echo [ERROR] No se pudo eliminar la imagen antes de probar el TAR.
  goto :ERROR
)

echo [INFO] Cargando exclusivamente desde %FINAL_TAR%...
docker load -i "%FINAL_TAR%"
if errorlevel 1 (
  echo [ERROR] docker load del TAR final ha fallado.
  goto :ERROR
)

docker image inspect "%FINAL_IMAGE%" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] El TAR no ha restaurado %FINAL_IMAGE%.
  goto :ERROR
)

docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Env}}" | findstr /C:"ORACLE_SID=ORACLE" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] El TAR recargado no conserva ORACLE_SID=ORACLE.
  goto :ERROR
)

docker image inspect "%FINAL_IMAGE%" --format "{{json .Config.Entrypoint}}" | findstr /C:"/opt/oracle/seed-oradata.sh" >nul 2>&1
if errorlevel 1 (
  echo [ERROR] El TAR recargado no conserva el ENTRYPOINT esperado.
  goto :ERROR
)

docker run --rm --entrypoint bash "%FINAL_IMAGE%" -lc "test \"$ORACLE_SID\" = 'ORACLE' && test -s /opt/oracle/oradata-base.tar.gz"
if errorlevel 1 (
  echo [ERROR] La imagen recargada no supera la comprobacion interna.
  goto :ERROR
)

echo [OK] TAR validado: imagen, SID, entrypoint y seed conservados.
echo [OK] Paso 10 completado.
call :END_STEP 10

rem ============================================================
rem PASO 11 - DESPLEGAR DESDE VOLUMEN VACIO Y VALIDAR
rem ============================================================
echo [11/%MAX_STEPS%] Desplegando contenedor final desde volumen vacio...
call :START_STEP 11

docker rm -f "%FINAL_CONTAINER%" >nul 2>&1
docker volume rm -f "%FINAL_VOLUME%" >nul 2>&1

docker volume create "%FINAL_VOLUME%" >nul
if errorlevel 1 (
  echo [ERROR] No se pudo crear %FINAL_VOLUME%.
  goto :ERROR
)

docker run -d ^
  --name "%FINAL_CONTAINER%" ^
  --restart unless-stopped ^
  -e ORACLE_SID=ORACLE ^
  -p 1523:1521 ^
  -p 5501:5500 ^
  -v "%FINAL_VOLUME%:/opt/oracle/oradata" ^
  "%FINAL_IMAGE%" >nul
if errorlevel 1 (
  echo [ERROR] No se pudo arrancar %FINAL_CONTAINER%.
  goto :ERROR
)

call :WAIT_SQL "%FINAL_CONTAINER%" 1200
if errorlevel 1 goto :ERROR

call :VALIDATE_IDENTITY "%FINAL_CONTAINER%"
if errorlevel 1 goto :ERROR

call :CREATE_VALIDATE_SQL
if errorlevel 1 goto :ERROR

docker cp "%ROOT%\%VALIDATE_SQL%" "%FINAL_CONTAINER%:/tmp/%VALIDATE_SQL%" >nul
if errorlevel 1 (
  echo [ERROR] No se pudo copiar el SQL de validacion al contenedor.
  goto :ERROR
)

docker exec "%FINAL_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/tmp/%VALIDATE_SQL%"
set "VAL_RC=!ERRORLEVEL!"
del /q "%ROOT%\%VALIDATE_SQL%" >nul 2>&1
if not "!VAL_RC!"=="0" (
  echo [ERROR] La validacion integral de la BD final ha fallado.
  goto :ERROR
)

echo [OK] Validacion integral de la BD final superada.

rem Registro del servicio mediante fichero SQL para evitar quoting fragil.
>"%ROOT%\_mupol_register.sql" echo WHENEVER SQLERROR EXIT SQL.SQLCODE
>>"%ROOT%\_mupol_register.sql" echo ALTER SYSTEM REGISTER;
>>"%ROOT%\_mupol_register.sql" echo EXIT
docker cp "%ROOT%\_mupol_register.sql" "%FINAL_CONTAINER%:/tmp/_mupol_register.sql" >nul
if errorlevel 1 (
  echo [ERROR] No se pudo copiar el SQL de registro del listener.
  goto :ERROR
)
docker exec "%FINAL_CONTAINER%" bash -lc "sqlplus -s '/ as sysdba' @/tmp/_mupol_register.sql" >nul
set "REG_RC=!ERRORLEVEL!"
del /q "%ROOT%\_mupol_register.sql" >nul 2>&1
if not "!REG_RC!"=="0" (
  echo [ERROR] ALTER SYSTEM REGISTER ha fallado.
  goto :ERROR
)

echo [INFO] Comprobando listener y servicio ORACLE...
set "LISTENER_OK=0"
for /L %%L in (1,1,12) do (
  if "!LISTENER_OK!"=="0" (
    docker exec "%FINAL_CONTAINER%" bash -lc "/opt/oracle/product/19c/dbhome_1/bin/lsnrctl status" > "%ROOT%\_listener_status.txt" 2>&1
    findstr /R /I "Service.*ORACLE" "%ROOT%\_listener_status.txt" >nul 2>&1
    if not errorlevel 1 (
      set "LISTENER_OK=1"
    ) else (
      if %%L LSS 12 timeout /t 5 /nobreak >nul
    )
  )
)

if "!LISTENER_OK!"=="0" (
  echo [ERROR] El listener no publica el servicio ORACLE tras 60 segundos.
  type "%ROOT%\_listener_status.txt"
  goto :ERROR
)

echo [OK] Listener publica el servicio ORACLE.
del /q "%ROOT%\_listener_status.txt" >nul 2>&1

call :END_STEP 11
call :PRINT_TIMES

echo.
echo ============================================================
echo   PROCESO 1-11 FINALIZADO CORRECTAMENTE
echo ============================================================
echo Imagen:       %FINAL_IMAGE%
echo TAR:          %FINAL_TAR%
echo Contenedor:   %FINAL_CONTAINER%
echo Volumen:      %FINAL_VOLUME%
echo SID:          ORACLE
echo DB_NAME:      ORACLE
echo Servicio:     ORACLE
echo SQL:          localhost:1523
echo JDBC SID:     jdbc:oracle:thin:@localhost:1523:ORACLE
echo EM:           localhost:5501
echo Log impdp:    %ROOT%\%IMPORT_LOG%
echo DMP:          !DMP_NAME!
echo.
echo La base queda arrancada y OPEN READ WRITE.
echo El volumen de trabajo %WORK_VOLUME% se conserva por seguridad.
echo.
echo.
echo [LIMPIEZA] Eliminando ficheros temporales...
del /q "%ROOT%\_mupol_prepare_seed.sql" >nul 2>&1
del /q "%ROOT%\_mupol_shutdown.sql" >nul 2>&1
del /q "%ROOT%\_mupol_register.sql" >nul 2>&1
del /q "%ROOT%\_mupol_validate_database_step7.sql" >nul 2>&1
del /q "%ROOT%\_mupol_validate_final.sql" >nul 2>&1
del /q "%ROOT%\_mupol_validate_database.sql" >nul 2>&1
del /q "%ROOT%\_check_noneditionable.sql" >nul 2>&1
del /q "%ROOT%\_recomp.sql" >nul 2>&1
del /q "%ROOT%\_invalids.sql" >nul 2>&1
del /q "%ROOT%\_listener_status.txt" >nul 2>&1
if exist "%BUILD_CTX%" rmdir /s /q "%BUILD_CTX%" >nul 2>&1
echo [OK] Temporales eliminados.
echo.
pause
exit /b 0

rem ============================================================
rem SUBRUTINAS
rem ============================================================
:START_STEP
set "CURRENT_STEP=%~1"
for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "STEP_START_%~1=%%T"
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format HH:mm:ss"') do set "STEP_CLOCK_%~1=%%T"
echo Inicio: !STEP_CLOCK_%~1!
exit /b 0

:END_STEP
set "N=%~1"
for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "STEP_END=%%T"
set /a STEP_SECS_%~1=!STEP_END!-!STEP_START_%~1!
set "STEP_STATUS_%~1=OK"
for /f "delims=" %%D in ('powershell -NoProfile -Command "$d=[TimeSpan]::FromSeconds([int64]!STEP_SECS_%~1!);'{0:00}:{1:00}:{2:00}' -f [math]::Floor($d.TotalHours),$d.Minutes,$d.Seconds"') do set "STEP_FMT=%%D"
echo Duracion paso %~1: !STEP_FMT!
echo.
exit /b 0

:FAIL_CURRENT_STEP
if "%CURRENT_STEP%"=="0" exit /b 0
if not defined STEP_START_%CURRENT_STEP% exit /b 0
for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "STEP_END=%%T"
set /a STEP_SECS_%CURRENT_STEP%=!STEP_END!-!STEP_START_%CURRENT_STEP%!
set "STEP_STATUS_%CURRENT_STEP%=ERROR"
exit /b 0

:PRINT_TIMES
for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeSeconds()"') do set "PROCESS_END=%%T"
for /f "delims=" %%D in ('powershell -NoProfile -Command "$d=[TimeSpan]::FromSeconds([int64]!PROCESS_END!-[int64]!PROCESS_START!);'{0:00}:{1:00}:{2:00}' -f [math]::Floor($d.TotalHours),$d.Minutes,$d.Seconds"') do set "TOTAL_FMT=%%D"
echo.
echo ============================================================
echo   RESUMEN DE TIEMPOS
echo ============================================================
for /L %%N in (1,1,%MAX_STEPS%) do (
    if defined STEP_SECS_%%N (
        for /f "delims=" %%D in ('powershell -NoProfile -Command "$d=[TimeSpan]::FromSeconds([int64]!STEP_SECS_%%N!);'{0:00}:{1:00}:{2:00}' -f [math]::Floor($d.TotalHours),$d.Minutes,$d.Seconds"') do set "F=%%D"
        echo Paso %%N - !STEP_STATUS_%%N! - !F!
    )
)
echo ------------------------------------------------------------
echo TIEMPO TOTAL: !TOTAL_FMT!
echo ============================================================
exit /b 0
:VALIDATE_ORACLE_IDENTITY
set "VC=%~1"
docker exec "%VC%" bash -lc "N=$(printf \"set heading off\\nset feedback off\\nset pagesize 0\\nselect name from v\$database;\" | sqlplus -s '/ as sysdba' | tr -d '[:space:]'); test \"$N\" = 'ORACLE'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] DB_NAME no es ORACLE.
    exit /b 1
)
docker exec "%VC%" bash -lc "N=$(printf \"set heading off\\nset feedback off\\nset pagesize 0\\nselect instance_name from v\$instance;\" | sqlplus -s '/ as sysdba' | tr -d '[:space:]'); test \"$N\" = 'ORACLE'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] INSTANCE_NAME no es ORACLE.
    exit /b 1
)
docker exec "%VC%" bash -lc "N=$(printf \"set heading off\\nset feedback off\\nset pagesize 0\\nselect value from v\$parameter where name='service_names';\" | sqlplus -s '/ as sysdba' | tr -d '[:space:]'); echo \"$N\" | grep -qi 'ORACLE'" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] SERVICE_NAMES no contiene ORACLE.
    exit /b 1
)
exit /b 0
:P7_WRITE_B64
set "OUT=%~1"
set "DATA=%~2"
powershell -NoProfile -Command "[IO.File]::WriteAllBytes($env:OUT,[Convert]::FromBase64String($env:DATA))"
exit /b %ERRORLEVEL%

:P7_VALIDATE_IDENTITY
set "VC=%~1"
docker exec "%VC%" bash -lc "test "$ORACLE_SID" = 'ORACLE'" >nul 2>&1 || exit /b 1
docker exec "%VC%" bash -lc "printf 'show parameter db_name\nexit\n' | sqlplus -s '/ as sysdba' | grep -Eiq 'db_name[[:space:]]+string[[:space:]]+ORACLE'" >nul 2>&1 || exit /b 1
docker exec "%VC%" bash -lc "printf 'show parameter service_names\nexit\n' | sqlplus -s '/ as sysdba' | grep -Eiq 'service_names[[:space:]]+string[[:space:]]+ORACLE'" >nul 2>&1 || exit /b 1
echo [OK] SID=ORACLE, DB_NAME=ORACLE, SERVICE_NAMES=ORACLE.
exit /b 0

:P7_VALIDATE_DATABASE
set "VC=%~1"
docker exec "%VC%" bash -lc "sqlplus -s '/ as sysdba' @/mupol-import/%VALIDATE_SQL%"
exit /b %ERRORLEVEL%

:P7_WAIT_SQL
set "WC=%~1"
set /a MAX=%~2
set /a N=0
echo Esperando conexion SQL en %WC%...
:P7_WAIT_LOOP
for /f "delims=" %%S in ('docker inspect --format "{{.State.Running}}" "%WC%" 2^>nul') do set "RUNNING=%%S"
if /I not "!RUNNING!"=="true" (docker logs --tail 150 "%WC%" & exit /b 1)
docker exec "%WC%" bash -lc "printf 'select 1 from dual;\nexit\n' | sqlplus -s '/ as sysdba' >/dev/null 2>&1" >nul 2>&1 && (echo [OK] Oracle acepta conexiones SQL. & exit /b 0)
if !N! GEQ !MAX! (echo [ERROR] Timeout esperando Oracle. & docker logs --tail 150 "%WC%" & exit /b 1)
if !N! EQU 0 echo [INFO] Esperando Oracle...
set /a MOD=N%%30
if !MOD! EQU 0 if not !N! EQU 0 echo [INFO] !N! segundos...
timeout /t 10 /nobreak >nul
set /a N+=10
goto :P7_WAIT_LOOP
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
call :FAIL_CURRENT_STEP
call :PRINT_TIMES
echo.
echo ============================================================
echo   PROCESO INTERRUMPIDO POR ERROR
echo ============================================================
echo No se realiza limpieza destructiva tras el error.
echo Se conservan los recursos existentes para diagnostico.
echo.
echo Contenedor trabajo: %WORK_CONTAINER%
echo Volumen trabajo:    %WORK_VOLUME%
echo Contenedor final:   %FINAL_CONTAINER%
echo Volumen final:      %FINAL_VOLUME%
echo.
pause
exit /b 1
