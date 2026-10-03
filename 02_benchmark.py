#!/usr/bin/env python3
"""
Бенчмарк форматов и кодеков в Iceberg/Trino: 2 формата x 4 кодека.

Что делает:
  1) создаёт bronze.bench.lineitem_<format>_<codec> из tpch.sf<N>.lineitem,
     замеряя время записи (wall clock);
  2) снимает размер данных и метаданных из системных таблиц Iceberg
     ($files, $manifests);
  3) для каждой таблицы перезапускает Trino+MinIO (сброс кэшей) и гоняет
     агрегацию TPC-H Q1 дважды: cold + warm;
  4) пишет results.csv и results.json.

Запуск:  python 02_benchmark.py                 # всё целиком, sf1
         python 02_benchmark.py --sf 10         # другой объём
         python 02_benchmark.py --only-queries  # пропустить создание таблиц
         python 02_benchmark.py --no-restart     # без сброса кэша (быстро, менее честно)
"""
import argparse
import csv
import json
import subprocess
import sys
import time
import urllib.request
import urllib.error

try:
    import trino
except ImportError:
    sys.exit("Нет пакета trino. Установи:  pip install trino")

HOST, PORT, USER = "localhost", 8080, "bench"
CATALOG, SCHEMA = "bronze", "bench"
FORMATS = ["PARQUET", "ORC"]
CODECS = ["NONE", "SNAPPY", "GZIP", "ZSTD"]
CONTAINERS = ["trino", "lakehouse-minio"]

# TPC-H Q1 без ORDER BY: полный проход таблицы + свёртка по двум колонкам.
AGG_SQL = """
SELECT returnflag, linestatus,
       count(*)                            AS cnt,
       sum(quantity)                       AS sum_qty,
       sum(extendedprice)                  AS sum_price,
       sum(discount)                       AS sum_disc,
       sum(extendedprice * (1 - discount)) AS sum_charge
FROM {table}
GROUP BY returnflag, linestatus
"""


def connect(session_properties=None):
    return trino.dbapi.connect(
        host=HOST, port=PORT, user=USER,
        catalog=CATALOG, schema=SCHEMA,
        session_properties=session_properties or {},
    )


def run(sql, session_properties=None, fetch=True):
    """Выполнить SQL, вернуть (rows, elapsed_sec)."""
    conn = connect(session_properties)
    cur = conn.cursor()
    t0 = time.perf_counter()
    cur.execute(sql)
    rows = cur.fetchall() if fetch else (cur.fetchall() or [])
    elapsed = time.perf_counter() - t0
    cur.close()
    conn.close()
    return rows, elapsed


def wait_trino(timeout=180):
    """Ждать, пока Trino не ответит starting=false."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://{HOST}:{PORT}/v1/info", timeout=3) as r:
                if not json.load(r).get("starting", True):
                    time.sleep(2)  # дать коннекторам инициализироваться
                    return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(3)
    sys.exit("Trino не поднялся — проверь: docker logs trino")


def restart_stack():
    """Сброс кэшей: внутренние кэши Trino + перезапуск MinIO."""
    print("    [restart] docker restart", " ".join(CONTAINERS), flush=True)
    subprocess.run(["docker", "restart", *CONTAINERS],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    wait_trino()


def table_name(fmt, codec):
    return f"lineitem_{fmt.lower()}_{codec.lower()}"


def fqn(fmt, codec):
    return f"{CATALOG}.{SCHEMA}.{table_name(fmt, codec)}"


def create_table(fmt, codec, sf):
    """CREATE TABLE AS SELECT с заданным форматом/кодеком. Возвращает время записи."""
    t = fqn(fmt, codec)
    props = {f"{CATALOG}.compression_codec": codec}

    run(f"DROP TABLE IF EXISTS {t}", fetch=False)

    # Проверяем, что кодек реально применился к сессии, а не молча проигнорирован
    chk, _ = run(f"SHOW SESSION LIKE '{CATALOG}.compression_codec'", props)
    actual = chk[0][1] if chk else "?"
    if str(actual).upper() != codec:
        print(f"    ВНИМАНИЕ: сессия сообщает codec={actual}, ожидался {codec}")

    sql = (f"CREATE TABLE {t} WITH (format = '{fmt}') AS "
           f"SELECT * FROM tpch.sf{sf}.lineitem")
    _, elapsed = run(sql, props, fetch=False)
    return elapsed, actual


def measure_storage(fmt, codec):
    """Размер данных и метаданных из системных таблиц Iceberg."""
    tn = table_name(fmt, codec)
    sysname = lambda suffix: f'{CATALOG}.{SCHEMA}."{tn}${suffix}"'

    files, data_bytes = run(
        f"SELECT count(*), coalesce(sum(file_size_in_bytes), 0) FROM {sysname('files')}")[0][0]
    manifests, meta_bytes = run(
        f"SELECT count(*), coalesce(sum(length), 0) FROM {sysname('manifests')}")[0][0]
    rows = run(f"SELECT count(*) FROM {fqn(fmt, codec)}")[0][0][0]

    return dict(files=int(files), data_bytes=int(data_bytes),
                manifests=int(manifests), meta_bytes=int(meta_bytes), rows=int(rows))


def measure_queries(fmt, codec, do_restart):
    """cold (после сброса кэша) + warm (сразу повторно)."""
    sql = AGG_SQL.format(table=fqn(fmt, codec))
    if do_restart:
        restart_stack()
    _, cold = run(sql)
    _, warm = run(sql)
    return cold, warm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sf", default="1", help="scale factor TPC-H (по умолчанию 1)")
    ap.add_argument("--only-queries", action="store_true", help="не создавать таблицы заново")
    ap.add_argument("--no-restart", action="store_true", help="не сбрасывать кэш перед cold")
    ap.add_argument("--out", default="results", help="префикс файлов результата")
    args = ap.parse_args()

    variants = [(f, c) for f in FORMATS for c in CODECS]
    do_restart = not args.no_restart

    print(f"Trino: http://{HOST}:{PORT} | данные: tpch.sf{args.sf}.lineitem | "
          f"вариантов: {len(variants)} | сброс кэша: {'да' if do_restart else 'нет'}")
    wait_trino()
    run(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.{SCHEMA}", fetch=False)

    results = []
    for i, (fmt, codec) in enumerate(variants, 1):
        name = table_name(fmt, codec)
        print(f"\n[{i}/{len(variants)}] {name}", flush=True)
        row = dict(variant=name, format=fmt, codec=codec)

        if args.only_queries:
            row["write_sec"] = None
            row["codec_applied"] = codec
        else:
            print("    запись...", end="", flush=True)
            w, actual = create_table(fmt, codec, args.sf)
            row["write_sec"] = round(w, 3)
            row["codec_applied"] = actual
            print(f" {w:.1f}с", flush=True)

        row.update(measure_storage(fmt, codec))
        print(f"    размер: {row['data_bytes']/1024**3:.3f} ГБ в {row['files']} файл(ах), "
              f"метаданные: {row['meta_bytes']/1024:.1f} КБ", flush=True)

        print("    агрегация cold/warm...", end="", flush=True)
        cold, warm = measure_queries(fmt, codec, do_restart)
        row["cold_sec"], row["warm_sec"] = round(cold, 3), round(warm, 3)
        print(f" {cold:.2f}с / {warm:.2f}с", flush=True)

        results.append(row)

    # ---------- производные метрики ----------
    baseline = next((r["data_bytes"] for r in results
                     if r["format"] == "PARQUET" and r["codec"] == "NONE"), None)
    for r in results:
        r["gb"] = round(r["data_bytes"] / 1024 ** 3, 4)
        r["meta_share_pct"] = round(r["meta_bytes"] * 100.0 / r["data_bytes"], 5) if r["data_bytes"] else None
        r["ratio_vs_parquet_none"] = round(baseline / r["data_bytes"], 3) if baseline and r["data_bytes"] else None
        r["cache_speedup"] = round(r["cold_sec"] / r["warm_sec"], 2) if r.get("warm_sec") else None
        r["write_mb_per_sec"] = round(r["data_bytes"] / 1024 ** 2 / r["write_sec"], 1) if r.get("write_sec") else None

    cols = ["variant", "format", "codec", "codec_applied", "rows", "gb", "data_bytes",
            "files", "manifests", "meta_bytes", "meta_share_pct", "ratio_vs_parquet_none",
            "write_sec", "write_mb_per_sec", "cold_sec", "warm_sec", "cache_speedup"]
    with open(f"{args.out}.csv", "w", newline="", encoding="utf-8") as f:
        wr = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        wr.writeheader()
        wr.writerows(results)
    with open(f"{args.out}.json", "w", encoding="utf-8") as f:
        json.dump(dict(sf=args.sf, restart=do_restart, results=results), f,
                  ensure_ascii=False, indent=2)

    print(f"\n{'вариант':<24}{'ГБ':>8}{'файлов':>8}{'запись,с':>10}{'cold,с':>9}{'warm,с':>9}")
    for r in results:
        print(f"{r['variant']:<24}{r['gb']:>8.3f}{r['files']:>8}"
              f"{(r['write_sec'] or 0):>10.1f}{r['cold_sec']:>9.2f}{r['warm_sec']:>9.2f}")
    print(f"\nГотово: {args.out}.csv и {args.out}.json")


if __name__ == "__main__":
    main()
