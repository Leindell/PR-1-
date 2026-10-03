# 01_run_sql.ps1 -- run a .sql file through the Trino CLI inside the container
# Usage: .\01_run_sql.ps1 sql\01_bronze.sql
# ASCII-only on purpose (PowerShell 5.1 ANSI parsing).
param([Parameter(Mandatory = $true)][string]$File)

if (-not (Test-Path $File)) {
    Write-Host "File not found: $File" -ForegroundColor Red
    exit 1
}

$name = Split-Path $File -Leaf
Write-Host ">>> $name" -ForegroundColor Cyan

docker cp $File "trino:/tmp/$name"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Container 'trino' is not running? Run 00_setup.ps1 first." -ForegroundColor Red
    exit 1
}

$t0 = Get-Date
docker exec trino trino --file "/tmp/$name" --output-format=ALIGNED --progress
$code = $LASTEXITCODE
$sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

if ($code -eq 0) {
    Write-Host "`nOK in ${sec}s" -ForegroundColor Green
} else {
    Write-Host "`nFAILED (exit $code) in ${sec}s" -ForegroundColor Red
}
exit $code
