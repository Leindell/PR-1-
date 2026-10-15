-- Silver: проверка качества, справочник клиентов, очищенный факт продаж
-- запускать после 02_benchmark.py (берём bronze.bench.lineitem_parquet_zstd)

CREATE SCHEMA IF NOT EXISTS silver.core;

-- 1. сколько плохих строк в сырых данных (до фильтрации)
DROP TABLE IF EXISTS silver.core.dq_report;
CREATE TABLE silver.core.dq_report
WITH (format = 'PARQUET') AS
SELECT
    count(*)                                                         AS rows_total,
    count_if(quantity IS NULL OR quantity <= 0)                      AS bad_quantity,
    count_if(extendedprice IS NULL OR extendedprice <= 0)            AS bad_price,
    count_if(discount < 0 OR discount > 1)                           AS bad_discount,
    count_if(shipdate < orderdate)                                   AS bad_shipdate,
    count_if(returnflag NOT IN ('A','N','R'))                        AS bad_returnflag,
    count_if(o.orderkey IS NULL)                                     AS orphan_orderkey
FROM bronze.bench.lineitem_parquet_zstd l
LEFT JOIN bronze.raw.orders o ON l.orderkey = o.orderkey;

-- 2. справочник клиентов, последняя загрузка клиента помечается is_current
DROP TABLE IF EXISTS silver.core.dim_customer;
CREATE TABLE silver.core.dim_customer
WITH (format = 'PARQUET') AS
SELECT
    c.custkey,
    c.name                                   AS customer_name,
    upper(trim(c.mktsegment))                AS market_segment,
    CAST(c.acctbal AS decimal(12,2))         AS account_balance,
    n.name                                   AS nation,
    r.name                                   AS region,
    c.loaded_at                              AS valid_from,
    LEAD(c.loaded_at) OVER (PARTITION BY c.custkey ORDER BY c.loaded_at) AS valid_to,
    LEAD(c.loaded_at) OVER (PARTITION BY c.custkey ORDER BY c.loaded_at) IS NULL AS is_current
FROM bronze.raw.customer_hist c
JOIN bronze.raw.nation n ON c.nationkey = n.nationkey
JOIN bronze.raw.region r ON n.regionkey = r.regionkey;

-- 3. факт продаж
DROP TABLE IF EXISTS silver.core.fct_lineitem;
CREATE TABLE silver.core.fct_lineitem
WITH (format = 'PARQUET') AS
SELECT
    l.orderkey,
    l.linenumber,
    o.custkey,
    l.partkey,

    -- деньги в decimal, коды в нормальные значения
    CAST(l.quantity       AS decimal(12,2))                   AS quantity,
    CAST(l.extendedprice  AS decimal(12,2))                   AS gross_amount,
    CAST(l.discount       AS decimal(5,4))                    AS discount_rate,
    CAST(l.tax            AS decimal(5,4))                    AS tax_rate,
    CASE l.returnflag WHEN 'A' THEN 'accepted'
                      WHEN 'N' THEN 'none'
                      WHEN 'R' THEN 'returned' END            AS return_status,
    CASE l.linestatus  WHEN 'O' THEN 'open'
                       WHEN 'F' THEN 'fulfilled' END          AS line_status,
    upper(trim(l.shipmode))                                   AS ship_mode,

    -- расчётные поля
    CAST(l.extendedprice * (1 - l.discount)             AS decimal(12,2)) AS net_amount,
    CAST(l.extendedprice * (1 - l.discount) * (1 + l.tax) AS decimal(12,2)) AS net_with_tax,
    CAST(l.extendedprice * l.discount                   AS decimal(12,2)) AS discount_amount,
    date_diff('day', l.shipdate, l.receiptdate)                           AS delivery_days,
    date_diff('day', l.commitdate, l.receiptdate)                         AS delay_vs_commit,
    l.receiptdate > l.commitdate                                          AS is_late,

    -- из заказов и товаров
    o.orderdate,
    date_trunc('month', CAST(o.orderdate AS timestamp))        AS order_month,
    year(o.orderdate)                                          AS order_year,
    o.orderpriority,
    p.brand,
    p.type                                                     AS part_type,
    l.shipdate,
    l.commitdate,
    l.receiptdate
FROM bronze.bench.lineitem_parquet_zstd l
JOIN bronze.raw.orders o ON l.orderkey = o.orderkey      -- строки без заказа отсекаются
LEFT JOIN bronze.raw.part p ON l.partkey = p.partkey
WHERE l.quantity      > 0
  AND l.extendedprice > 0
  AND l.discount BETWEEN 0 AND 1
  AND l.returnflag IN ('A','N','R')
  AND l.shipdate >= o.orderdate;

-- проверка
SELECT * FROM silver.core.dq_report;
SELECT count(*) AS silver_rows FROM silver.core.fct_lineitem;
SELECT count(*) AS dim_rows, count_if(is_current) AS current_rows,
       count_if(NOT is_current) AS historical_rows
FROM silver.core.dim_customer;
