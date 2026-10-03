-- ============================================================
-- GOLD: витрины для бизнес-аналитики (готовый ответ, без джойнов)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS gold.mart;

-- ------------------------------------------------------------
-- Витрина 1: выручка по регион x сегмент x месяц
-- Бизнес-вопрос: "как растёт выручка по рынкам и сегментам клиентов"
-- Клиент берётся в АКТУАЛЬНОЙ версии (is_current) — смысл SCD Type 2
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gold.mart.revenue_by_region_segment_month;
CREATE TABLE gold.mart.revenue_by_region_segment_month
WITH (format = 'PARQUET') AS
SELECT
    d.region,
    d.nation,
    d.market_segment,
    f.order_month,
    count(DISTINCT f.orderkey)        AS orders_cnt,
    count(*)                          AS lines_cnt,
    sum(f.quantity)                   AS qty,
    sum(f.gross_amount)               AS gross_revenue,
    sum(f.discount_amount)            AS discount_total,
    sum(f.net_amount)                 AS net_revenue,
    round(sum(f.discount_amount) * 100.0 / sum(f.gross_amount), 2) AS discount_pct,
    round(sum(f.net_amount) / count(DISTINCT f.orderkey), 2)       AS avg_order_value
FROM silver.core.fct_lineitem f
JOIN silver.core.dim_customer d
  ON f.custkey = d.custkey AND d.is_current
GROUP BY d.region, d.nation, d.market_segment, f.order_month;

-- ------------------------------------------------------------
-- Витрина 2: качество логистики по способу доставки
-- Бизнес-вопрос: "какой перевозчик срывает сроки и чего это стоит"
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gold.mart.shipping_performance;
CREATE TABLE gold.mart.shipping_performance
WITH (format = 'PARQUET') AS
SELECT
    ship_mode,
    order_year,
    count(*)                                                AS lines_cnt,
    round(avg(delivery_days), 2)                            AS avg_delivery_days,
    round(avg(delay_vs_commit), 2)                          AS avg_delay_vs_commit,
    count_if(is_late)                                       AS late_lines,
    round(count_if(is_late) * 100.0 / count(*), 2)          AS late_pct,
    sum(net_amount)                                         AS net_revenue,
    sum(CASE WHEN is_late THEN net_amount ELSE 0 END)       AS revenue_at_risk
FROM silver.core.fct_lineitem
GROUP BY ship_mode, order_year;

-- ------------------------------------------------------------
-- Витрина 3: возвраты по бренду (топ проблемных товаров)
-- ------------------------------------------------------------
DROP TABLE IF EXISTS gold.mart.returns_by_brand;
CREATE TABLE gold.mart.returns_by_brand
WITH (format = 'PARQUET') AS
SELECT
    brand,
    count(*)                                                       AS lines_cnt,
    count_if(return_status = 'returned')                           AS returned_lines,
    round(count_if(return_status = 'returned') * 100.0 / count(*), 2) AS return_pct,
    sum(CASE WHEN return_status = 'returned' THEN net_amount ELSE 0 END) AS returned_amount
FROM silver.core.fct_lineitem
WHERE brand IS NOT NULL
GROUP BY brand;

-- ------------------------------------------------------------
-- Контроль + демо time travel (Iceberg)
-- ------------------------------------------------------------
SELECT region, market_segment, sum(net_revenue) AS net
FROM gold.mart.revenue_by_region_segment_month
GROUP BY region, market_segment ORDER BY net DESC LIMIT 10;

SELECT * FROM gold.mart.shipping_performance ORDER BY late_pct DESC LIMIT 10;

-- история версий таблицы (time travel): Iceberg хранит снапшоты
SELECT snapshot_id, committed_at, operation
FROM bronze.raw."customer_hist$snapshots" ORDER BY committed_at;
