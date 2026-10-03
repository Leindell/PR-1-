@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Пересоздаю контейнер Trino (данные в MinIO и каталог не трогаем)...
docker rm -f trino
docker run -d --name trino -p 8080:8080 -v "%CD%\catalog:/etc/trino/catalog" trinodb/trino:476
echo Жду старта Trino (60 сек)...
timeout /t 60 /nobreak >nul

echo.
echo [4/5] Silver
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01_run_sql.ps1" "sql\03_silver.sql"
if errorlevel 1 goto fail

echo.
echo [5/5] Gold
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01_run_sql.ps1" "sql\04_gold.sql"
if errorlevel 1 goto fail

echo.
echo === ГОТОВО ===
goto end

:fail
echo.
echo !!! Ошибка. Скопируй вывод выше.

:end
pause
