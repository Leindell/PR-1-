-- ============================================================
-- BRONZE: сырьё как пришло, append-only, без преобразований
-- Источник: встроенный коннектор tpch (отрасль — оптовая торговля)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS bronze.raw;
CREATE SCHEMA IF NOT EXISTS bronze.bench;

-- ---------- 1. Справочники и заказы (ETL-сырьё) ----------
DROP TABLE IF EXISTS bronze.raw.orders;
CREATE TABLE bronze.raw.orders
WITH (format = 'PARQUET') AS
SELECT *, CURRENT_TIMESTAMP AS loaded_at FROM tpch.sf1.orders;

DROP TABLE IF EXISTS bronze.raw.nation;
CREATE TABLE bronze.raw.nation
WITH (format = 'PARQUET') AS
SELECT *, CURRENT_TIMESTAMP AS loaded_at FROM tpch.sf1.nation;

DROP TABLE IF EXISTS bronze.raw.region;
CREATE TABLE bronze.raw.region
WITH (format = 'PARQUET') AS
SELECT *, CURRENT_TIMESTAMP AS loaded_at FROM tpch.sf1.region;

DROP TABLE IF EXISTS bronze.raw.part;
CREATE TABLE bronze.raw.part
WITH (format = 'PARQUET') AS
SELECT *, CURRENT_TIMESTAMP AS loaded_at FROM tpch.sf1.part;

-- ---------- 2. Клиенты: две загрузки -> появляется история ----------
-- Партия 1 (как есть)
DROP TABLE IF EXISTS bronze.raw.customer_hist;
CREATE TABLE bronze.raw.customer_hist
WITH (format = 'PARQUET') AS
SELECT custkey, name, nationkey, mktsegment, acctbal,
       TIMESTAMP '2026-09-01 09:00:00' AS loaded_at
FROM tpch.sf1.customer;

-- Партия 2 (append, НЕ перезапись): часть клиентов сменила сегмент и баланс.
-- Это имитация второй суточной выгрузки из источника -> материал для SCD Type 2.
INSERT INTO bronze.raw.customer_hist
SELECT custkey, name, nationkey,
       'HOUSEHOLD' AS mktsegment,
       acctbal * 1.1 AS acctbal,
       TIMESTAMP '2026-09-15 09:00:00' AS loaded_at
FROM tpch.sf1.customer
WHERE custkey % 10 = 0 AND mktsegment <> 'HOUSEHOLD';

-- ---------- 3. Контроль ----------
SELECT 'orders' t, count(*) c FROM bronze.raw.orders
UNION ALL SELECT 'customer_hist', count(*) FROM bronze.raw.customer_hist
UNION ALL SELECT 'part', count(*) FROM bronze.raw.part
UNION ALL SELECT 'nation', count(*) FROM bronze.raw.nation
UNION ALL SELECT 'region', count(*) FROM bronze.raw.region;
