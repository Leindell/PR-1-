# 00_setup.ps1 -- deploy local Lakehouse: MinIO -> Lakekeeper -> Trino
# ASCII-only on purpose: PowerShell 5.1 reads .ps1 as ANSI, non-ASCII breaks the parser.
$ErrorActionPreference = "Continue"

function Say($m) { Write-Host "`n>>> $m" -ForegroundColor Cyan }

function Wait-Http($url, $name, $tries = 60) {
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing | Out-Null
            Write-Host "    $name ready" -ForegroundColor Green
            return $true
        } catch { Start-Sleep 3 }
    }
    Write-Host "    $name FAILED to start in $($tries*3)s -- check docker logs" -ForegroundColor Red
    return $false
}

Say "0/7 Checking Docker"
docker version --format '{{.Server.Version}}'
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker is not running. Start Docker Desktop and wait for the whale icon." -ForegroundColor Red
    exit 1
}

Say "1/7 MinIO (S3 object storage, ports 9000/9001)"
docker rm -f lakehouse-minio 2>$null | Out-Null
docker run -d --name lakehouse-minio `
  -p 9000:9000 -p 9001:9001 `
  -e MINIO_ROOT_USER=minioadmin `
  -e MINIO_ROOT_PASSWORD=minioadmin `
  -v minio-data:/data `
  pgsty/silo:latest server /data --console-address ":9001"
if (-not (Wait-Http "http://localhost:9000/minio/health/live" "MinIO")) { exit 1 }

Say "2/7 Buckets bronze / silver / gold"
docker run --rm --entrypoint /bin/sh --add-host host.docker.internal:host-gateway pgsty/mc:latest -c `
  "mc alias set m http://host.docker.internal:9000 minioadmin minioadmin && mc mb -p m/bronze m/silver m/gold && mc ls m"

Say "3/7 Postgres (Lakekeeper metadata)"
docker rm -f lakehouse-pg 2>$null | Out-Null
docker run -d --name lakehouse-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 -v pg-data:/var/lib/postgresql/data postgres:17
for ($i = 0; $i -lt 30; $i++) {
    docker exec lakehouse-pg pg_isready 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 2
}
Write-Host "    Postgres ready" -ForegroundColor Green

Say "4/7 Lakekeeper migrate + serve (port 8181)"
$PGURL = "postgresql://postgres:postgres@host.docker.internal:5432/postgres"
docker run --rm `
  -e "LAKEKEEPER__PG_ENCRYPTION_KEY=This-is-NOT-Secure!" `
  -e "LAKEKEEPER__PG_DATABASE_URL_READ=$PGURL" `
  -e "LAKEKEEPER__PG_DATABASE_URL_WRITE=$PGURL" `
  quay.io/lakekeeper/catalog:latest-main migrate
docker rm -f lakekeeper 2>$null | Out-Null
docker run -d --name lakekeeper `
  -e "LAKEKEEPER__PG_ENCRYPTION_KEY=This-is-NOT-Secure!" `
  -e "LAKEKEEPER__PG_DATABASE_URL_READ=$PGURL" `
  -e "LAKEKEEPER__PG_DATABASE_URL_WRITE=$PGURL" `
  -p 8181:8181 `
  quay.io/lakekeeper/catalog:latest-main serve
if (-not (Wait-Http "http://localhost:8181/health" "Lakekeeper")) { exit 1 }

Say "5/7 Bootstrap + 3 warehouses (bronze/silver/gold)"
curl.exe -s -o NUL -w "bootstrap: %{http_code}`n" -X POST http://localhost:8181/management/v1/bootstrap -H "Content-Type: application/json" -d '{\"accept-terms-of-use\": true}'
foreach ($w in @("bronze", "silver", "gold")) {
    $code = curl.exe -s -o NUL -w "%{http_code}" -X POST http://localhost:8181/management/v1/warehouse -H "Content-Type: application/json" -d "@warehouses/$w.json"
    Write-Host "    warehouse ${w}: HTTP $code -- 201 = created, 409/400 = already exists, both fine"
}

Say "6/7 Trino (port 8080), catalogs mounted from .\catalog"
docker rm -f trino 2>$null | Out-Null
docker run -d --name trino -p 8080:8080 -v "${PWD}\catalog:/etc/trino/catalog" trinodb/trino:476
Write-Host "    Trino needs 30-60s to start..."
for ($i = 0; $i -lt 60; $i++) {
    try {
        $info = Invoke-RestMethod "http://localhost:8080/v1/info" -TimeoutSec 3
        if (-not $info.starting) {
            Write-Host "    Trino ready (v$($info.nodeVersion.version))" -ForegroundColor Green
            break
        }
    } catch {}
    Start-Sleep 3
}

Say "7/7 Catalog check"
docker exec trino trino --execute "SHOW CATALOGS"

Write-Host "`n=== STACK IS UP ===" -ForegroundColor Green
Write-Host "MinIO UI  : http://localhost:9001  (minioadmin / minioadmin)"
Write-Host "Lakekeeper: http://localhost:8181/ui/"
Write-Host "Trino     : http://localhost:8080"
Write-Host "`nNext: 01_run_sql.ps1 sql\01_bronze.sql, then python 02_benchmark.py --sf 1"
