@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem MUPOL - Build Oracle 19c EE NON-CDB TZ43 base image
rem Root layout: C:\MUPOL
rem ============================================================================

set "MUPOL_HOME=C:\MUPOL"
set "DOCKER_IMAGES=%MUPOL_HOME%\docker-images"
set "BASE_HOME=%MUPOL_HOME%\mupol-base-image"
set "ARTIFACTS=%MUPOL_HOME%\artifacts"
set "WORK=%BASE_HOME%\work"
set "RESOURCES=%BASE_HOME%\resources"
set "VALIDATION=%BASE_HOME%\validation"
set "BUILDER=%BASE_HOME%\builder"
set "SEEDED=%BASE_HOME%\seeded-image"
set "SCRIPTS=%BASE_HOME%\scripts"

set "ORACLE_VERSION=19.3.0"
set "ORACLE_OFFICIAL_IMAGE=oracle/database:19.3.0-ee"
set "BUILDER_IMAGE=mupol-oracle:19.3.0-noncdb-tz43-builder"
set "FINAL_IMAGE=mupol-oracle:19.3.0-noncdb-tz43-base"
set "ORACLE_DIR=%DOCKER_IMAGES%\OracleDatabase\SingleInstance\dockerfiles\19.3.0"
set "ORACLE_ZIP=%ORACLE_DIR%\LINUX.X64_193000_db_home.zip"
set "DOCKERFILES_ROOT=%DOCKER_IMAGES%\OracleDatabase\SingleInstance\dockerfiles"

set "BUILD_VOLUME=mupol_base_build_oradata"
set "TEST_VOLUME=mupol_base_test_oradata"
set "BUILD_CONTAINER=mupol_base_builder"
set "TEST_CONTAINER=mupol_base_test"
set "BASE_TAR=%ARTIFACTS%\mupol-oracle-base.tar"

set "ORACLE_SID=ORACLE"
set "ORACLE_PWD=calculosa"
set "ORACLE_CHARACTERSET=AL32UTF8"

set "WAIT_MAX=5400"
set "WAIT_STEP=10"

call :banner "MUPOL ORACLE BASE - PRECHECK"

rem ---- Absolute safety: this script only removes the four temporary resources above.
rem ---- It never references mupol_rds, aioi or any non-MUPOL image/container.

call :require_cmd docker || goto :fail

docker info >nul 2>&1
if errorlevel 1 (
  echo ERROR: Docker Desktop is not running or the Docker daemon is unavailable.
  goto :fail
)

if not exist "%MUPOL_HOME%" (
  echo ERROR: Missing root directory: %MUPOL_HOME%
  goto :fail
)
if not exist "%DOCKER_IMAGES%" (
  echo ERROR: Missing Oracle docker-images repository: %DOCKER_IMAGES%
  goto :fail
)
if not exist "%ORACLE_DIR%" (
  echo ERROR: Missing Oracle 19.3.0 dockerfiles directory: %ORACLE_DIR%
  goto :fail
)
if not exist "%ORACLE_ZIP%" (
  echo ERROR: Missing Oracle installation ZIP:
  echo        %ORACLE_ZIP%
  goto :fail
)

for %%F in (
  "%RESOURCES%\createDB.sh"
  "%RESOURCES%\upgradeTimezone.sh"
  "%RESOURCES%\crea_objetos_previo_imp.sql"
  "%RESOURCES%\timezone_43.dat"
  "%RESOURCES%\timezlrg_43.dat"
  "%VALIDATION%\validate-base.sql"
  "%BUILDER%\Dockerfile"
  "%SEEDED%\Dockerfile"
  "%SEEDED%\seed-oradata.sh"
  "%SCRIPTS%\shutdown.sql"
) do (
  if not exist "%%~F" (
    echo ERROR: Required MUPOL file not found: %%~F
    goto :fail
  )
)

call :find_bash
if not defined BASH_EXE (
  echo ERROR: Git Bash could not be located.
  echo        Install Git for Windows or make bash.exe available in PATH.
  goto :fail
)

echo Docker:       OK
echo Git Bash:     %BASH_EXE%
echo docker-images:%DOCKER_IMAGES%
echo Oracle ZIP:   %ORACLE_ZIP%
echo TZ43 files:   OK

echo.
if not exist "%ARTIFACTS%" mkdir "%ARTIFACTS%" || goto :fail
if exist "%WORK%" rmdir /s /q "%WORK%" || goto :fail
mkdir "%WORK%" || goto :fail

call :banner "1/8 - PREPARE NON-CDB BUILD FILES"

copy /y "%RESOURCES%\createDB.sh" "%WORK%\createDB.sh" >nul || goto :fail
copy /y "%RESOURCES%\upgradeTimezone.sh" "%WORK%\upgradeTimezone.sh" >nul || goto :fail
copy /y "%RESOURCES%\crea_objetos_previo_imp.sql" "%WORK%\crea_objetos_previo_imp.sql" >nul || goto :fail
copy /y "%ORACLE_DIR%\dbca.rsp.tmpl" "%WORK%\dbca.rsp.tmpl" >nul || goto :fail
copy /y "%ORACLE_DIR%\checkDBStatus.sh" "%WORK%\checkDBStatus.sh" >nul || goto :fail
copy /y "%ORACLE_DIR%\startDB.sh" "%WORK%\startDB.sh" >nul || goto :fail

rem Patch dbca.rsp.tmpl to NON-CDB.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%WORK%\dbca.rsp.tmpl'; $s=[IO.File]::ReadAllText($p);" ^
  "$s=[regex]::Replace($s,'(?m)^createAsContainerDatabase=.*$','createAsContainerDatabase=false');" ^
  "$s=[regex]::Replace($s,'(?m)^numberOfPDBs=.*$','numberOfPDBs=0');" ^
  "$s=[regex]::Replace($s,'(?m)^pdbName=.*$','# pdbName disabled by MUPOL NON-CDB build');" ^
  "[IO.File]::WriteAllText($p,$s,(New-Object Text.UTF8Encoding($false)))"
if errorlevel 1 goto :fail

rem Patch health check: do not require a PDB in a NON-CDB database.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%WORK%\checkDBStatus.sh'; $lines=[IO.File]::ReadAllLines($p);" ^
  "$out=foreach($line in $lines){ if($line -match '^\s*checkPDBOpen\s*;?\s*$'){ '#checkPDBOpen' } else { $line } };" ^
  "[IO.File]::WriteAllLines($p,[string[]]$out,(New-Object Text.UTF8Encoding($false)))"
if errorlevel 1 goto :fail

rem Patch startup: no ALTER PLUGGABLE DATABASE in NON-CDB.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%WORK%\startDB.sh'; $lines=[IO.File]::ReadAllLines($p);" ^
  "$out=foreach($line in $lines){ if($line -match 'ALTER\s+PLUGGABLE\s+DATABASE'){ '# MUPOL NON-CDB: ' + $line } else { $line } };" ^
  "[IO.File]::WriteAllLines($p,[string[]]$out,(New-Object Text.UTF8Encoding($false)))"
if errorlevel 1 goto :fail

rem Normalize all shell scripts to LF. Force string replacement to avoid the Char overload of String.Replace.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$utf8=New-Object Text.UTF8Encoding($false); $files=Get-ChildItem '%WORK%' -Filter *.sh; foreach($f in $files){ $s=[IO.File]::ReadAllText($f.FullName); $s=$s.Replace([string]([char]13)+[string]([char]10),[string]([char]10)); $s=$s.Replace([string]([char]13),[string]([char]10)); [IO.File]::WriteAllText($f.FullName,$s,$utf8) };" ^
  "$p='%SEEDED%\seed-oradata.sh'; $s=[IO.File]::ReadAllText($p); $s=$s.Replace([string]([char]13)+[string]([char]10),[string]([char]10)); $s=$s.Replace([string]([char]13),[string]([char]10)); [IO.File]::WriteAllText($p,$s,$utf8)"
if errorlevel 1 goto :fail

echo NON-CDB files prepared successfully.

call :banner "2/8 - BUILD/VERIFY OFFICIAL ORACLE 19.3 EE IMAGE"

docker image inspect "%ORACLE_OFFICIAL_IMAGE%" >nul 2>&1
if not errorlevel 1 (
  echo Existing image found: %ORACLE_OFFICIAL_IMAGE%
  echo Reusing it.
) else (
  set "BUILD_SCRIPT="
  if exist "%DOCKERFILES_ROOT%\buildContainerImage.sh" set "BUILD_SCRIPT=./buildContainerImage.sh"
  if not defined BUILD_SCRIPT if exist "%DOCKERFILES_ROOT%\buildDockerImage.sh" set "BUILD_SCRIPT=./buildDockerImage.sh"
  if not defined BUILD_SCRIPT (
    echo ERROR: Neither buildContainerImage.sh nor buildDockerImage.sh exists in:
    echo        %DOCKERFILES_ROOT%
    goto :fail
  )

  pushd "%DOCKERFILES_ROOT%" || goto :fail
  echo Running Oracle official build: !BUILD_SCRIPT! -v %ORACLE_VERSION% -e
  "%BASH_EXE%" -lc "cd '%DOCKERFILES_ROOT:\=/%' && !BUILD_SCRIPT! -v %ORACLE_VERSION% -e"
  set "RC=!ERRORLEVEL!"
  popd
  if not "!RC!"=="0" goto :fail
)

docker image inspect "%ORACLE_OFFICIAL_IMAGE%" >nul 2>&1 || (
  echo ERROR: Expected Oracle image was not produced: %ORACLE_OFFICIAL_IMAGE%
  goto :fail
)

call :banner "3/8 - BUILD MUPOL TZ43 NON-CDB BUILDER IMAGE"

docker build --pull=false ^
  --build-arg "ORACLE_BASE_IMAGE=%ORACLE_OFFICIAL_IMAGE%" ^
  -f "%BUILDER%\Dockerfile" ^
  -t "%BUILDER_IMAGE%" ^
  "%BASE_HOME%"
if errorlevel 1 goto :fail

call :banner "4/8 - CREATE AND VALIDATE CLEAN MUPOL DATABASE"

call :cleanup_temp

docker volume create "%BUILD_VOLUME%" >nul || goto :fail

docker run -d ^
  --name "%BUILD_CONTAINER%" ^
  --health-interval=10s --health-timeout=5s --health-retries=60 ^
  -e "ORACLE_SID=%ORACLE_SID%" ^
  -e "ORACLE_PWD=%ORACLE_PWD%" ^
  -e "ORACLE_CHARACTERSET=%ORACLE_CHARACTERSET%" ^
  -v "%BUILD_VOLUME%:/opt/oracle/oradata" ^
  "%BUILDER_IMAGE%" >nul
if errorlevel 1 goto :fail

call :wait_healthy "%BUILD_CONTAINER%" || goto :show_build_logs

call :run_validation "%BUILD_CONTAINER%" || goto :show_build_logs

echo Shutting down Oracle cleanly...
docker cp "%SCRIPTS%\shutdown.sql" "%BUILD_CONTAINER%:/tmp/mupol-shutdown.sql" >nul || goto :fail
docker exec "%BUILD_CONTAINER%" bash -lc "sqlplus -s / as sysdba @/tmp/mupol-shutdown.sql" || goto :fail

docker stop -t 30 "%BUILD_CONTAINER%" >nul 2>&1

call :banner "5/8 - CREATE ORADATA BASE SEED"

if exist "%WORK%\oradata-base.tar.gz" del /q "%WORK%\oradata-base.tar.gz"

docker run --rm ^
  --user root ^
  --entrypoint /bin/bash ^
  -v "%BUILD_VOLUME%:/source:ro" ^
  -v "%WORK%:/backup" ^
  "%BUILDER_IMAGE%" ^
  -lc "cd /source && tar -czf /backup/oradata-base.tar.gz ."
if errorlevel 1 goto :fail

if not exist "%WORK%\oradata-base.tar.gz" (
  echo ERROR: ORADATA seed was not generated.
  goto :fail
)

for %%A in ("%WORK%\oradata-base.tar.gz") do echo Seed created: %%~zA bytes

call :banner "6/8 - BUILD FINAL SEEDED BASE IMAGE"

docker build --pull=false ^
  --build-arg "BUILDER_IMAGE=%BUILDER_IMAGE%" ^
  -f "%SEEDED%\Dockerfile" ^
  -t "%FINAL_IMAGE%" ^
  "%BASE_HOME%"
if errorlevel 1 goto :fail

call :banner "7/8 - TEST FINAL IMAGE AND PERSISTENCE"

docker rm -f "%TEST_CONTAINER%" >nul 2>&1
docker volume rm "%TEST_VOLUME%" >nul 2>&1
docker volume create "%TEST_VOLUME%" >nul || goto :fail

docker run -d ^
  --name "%TEST_CONTAINER%" ^
  --health-interval=10s --health-timeout=5s --health-retries=60 ^
  -e "ORACLE_SID=%ORACLE_SID%" ^
  -e "ORACLE_PWD=%ORACLE_PWD%" ^
  -e "ORACLE_CHARACTERSET=%ORACLE_CHARACTERSET%" ^
  -v "%TEST_VOLUME%:/opt/oracle/oradata" ^
  "%FINAL_IMAGE%" >nul
if errorlevel 1 goto :fail

call :wait_healthy "%TEST_CONTAINER%" || goto :show_test_logs
call :run_validation "%TEST_CONTAINER%" || goto :show_test_logs

echo Restarting final image to verify existing ORADATA is reused...
docker restart "%TEST_CONTAINER%" >nul || goto :fail
call :wait_healthy "%TEST_CONTAINER%" || goto :show_test_logs
call :run_validation "%TEST_CONTAINER%" || goto :show_test_logs

docker logs "%TEST_CONTAINER%" 2>&1 | findstr /C:"MUPOL - Existing ORADATA detected." >nul
if errorlevel 1 (
  echo ERROR: Persistence marker was not found in the final container logs.
  goto :show_test_logs
)

echo Persistence validation: OK

call :banner "8/8 - EXPORT BASE IMAGE"

if exist "%BASE_TAR%" del /q "%BASE_TAR%"
docker save -o "%BASE_TAR%" "%FINAL_IMAGE%"
if errorlevel 1 goto :fail
if not exist "%BASE_TAR%" goto :fail

for %%A in ("%BASE_TAR%") do set "BASE_TAR_SIZE=%%~zA"

rem Cleanup only temporary resources created by this script.
docker rm -f "%BUILD_CONTAINER%" >nul 2>&1
docker rm -f "%TEST_CONTAINER%" >nul 2>&1
docker volume rm "%BUILD_VOLUME%" >nul 2>&1
docker volume rm "%TEST_VOLUME%" >nul 2>&1

call :banner "MUPOL ORACLE BASE CREATED SUCCESSFULLY"
echo Image:        %FINAL_IMAGE%
echo Oracle:       19.3.0 EE
echo SID:          %ORACLE_SID%
echo CDB:          NO
echo Charset:      %ORACLE_CHARACTERSET%
echo Timezone:     43
echo DST state:    NONE
echo Pre-import:   OK
echo Persistence:  OK
echo Docker TAR:   %BASE_TAR%
echo TAR bytes:    %BASE_TAR_SIZE%
echo.
echo Existing Docker resources mupol_rds and aioi were not referenced or modified.
echo.
exit /b 0

:show_build_logs
echo.
echo ===== Last logs from %BUILD_CONTAINER% =====
docker logs --tail 200 "%BUILD_CONTAINER%"
goto :fail

:show_test_logs
echo.
echo ===== Last logs from %TEST_CONTAINER% =====
docker logs --tail 200 "%TEST_CONTAINER%"
goto :fail

:cleanup_temp
docker rm -f "%BUILD_CONTAINER%" >nul 2>&1
docker rm -f "%TEST_CONTAINER%" >nul 2>&1
docker volume rm "%BUILD_VOLUME%" >nul 2>&1
docker volume rm "%TEST_VOLUME%" >nul 2>&1
exit /b 0

:run_validation
set "VC=%~1"
docker cp "%VALIDATION%\validate-base.sql" "%VC%:/tmp/validate-base.sql" >nul || exit /b 1
docker exec "%VC%" bash -lc "sqlplus -s / as sysdba @/tmp/validate-base.sql"
exit /b %ERRORLEVEL%

:wait_healthy
set "WC=%~1"
set /a ELAPSED=0
:wait_loop
set "STATUS="
for /f "usebackq delims=" %%H in (`docker inspect --format="{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" "%WC%" 2^>nul`) do set "STATUS=%%H"
if /i "!STATUS!"=="healthy" (
  echo %WC% is HEALTHY.
  exit /b 0
)
if not defined STATUS (
  echo ERROR: Unable to inspect status for %WC%.
  exit /b 1
)
if /i "!STATUS!"=="unhealthy" (
  if !ELAPSED! EQU 0 echo %WC% is temporarily UNHEALTHY while Oracle is initializing. Continuing to wait...
)
if /i "!STATUS!"=="exited" (
  echo ERROR: %WC% exited unexpectedly.
  exit /b 1
)
if !ELAPSED! GEQ %WAIT_MAX% (
  echo ERROR: Timeout waiting for %WC% to become healthy.
  exit /b 1
)
if !ELAPSED! EQU 0 echo Waiting for %WC% to become healthy...
timeout /t %WAIT_STEP% /nobreak >nul
set /a ELAPSED+=%WAIT_STEP%
goto :wait_loop

:find_bash
set "BASH_EXE="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\usr\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH_EXE for /f "delims=" %%B in ('where bash.exe 2^>nul') do if not defined BASH_EXE set "BASH_EXE=%%B"
exit /b 0

:require_cmd
where %~1 >nul 2>&1
if errorlevel 1 (
  echo ERROR: Required command not found: %~1
  exit /b 1
)
exit /b 0

:banner
echo.
echo ============================================================
echo  %~1
echo ============================================================
exit /b 0

:fail
echo.
echo ============================================================
echo  MUPOL ORACLE BASE BUILD FAILED
 echo ============================================================
echo Review the error above. No non-MUPOL Docker resource is removed by this script.
echo.
exit /b 1
