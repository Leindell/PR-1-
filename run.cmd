@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ==============================================
echo  Практическая 1: Lakehouse + ELT + бенчмарк
echo ==============================================

echo.
echo [1/5] Стенд (MinIO + Lakekeeper + Trino)
powershell -NoProfile -ExecutionPolicy Bypass -File ".\00_setup.ps1"
if errorlevel 1 goto fail

echo.
echo [2/5] Bronze: сырьё
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01_run_sql.ps1" "sql\01_bronze.sql"
if errorlevel 1 goto fail

echo.
echo [3/5] Бенчмарк 2 формата x 4 кодека (долго, ~25 мин)
python 02_benchmark.py --sf 1
if errorlevel 1 goto fail

echo.
echo [4/5] Silver
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01_run_sql.ps1" "sql\03_silver.sql"
if errorlevel 1 goto fail

echo.
echo [5/5] Gold
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01_run_sql.ps1" "sql\04_gold.sql"
if errorlevel 1 goto fail

echo.
echo === ВСЁ ГОТОВО ===
echo Результат: results.csv  (его отправь Клоду)
goto end

:fail
echo.
echo !!! Шаг завершился с ошибкой. Скопируй вывод выше.
echo Диагностика:  docker ps -a    и    docker logs trino

:end
pause
