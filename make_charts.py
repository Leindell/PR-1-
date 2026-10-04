import csv, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PQ, ORC = "#2a78d6", "#eb6834"          # validated categorical slots 1 and 2
INK, MUTED, GRID = "#1a1a19", "#5c5c58", "#e4e4e0"
SURFACE = "#fcfcfb"

rows = list(csv.DictReader(open("results.csv")))
codecs = ["NONE", "SNAPPY", "GZIP", "ZSTD"]
get = lambda f, c, k: next(float(r[k]) for r in rows if r["format"] == f and r["codec"] == c)

plt.rcParams.update({
    "font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": MUTED,
    "xtick.color": MUTED, "ytick.color": MUTED, "text.color": INK,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
})


def grouped(ax, key, title, ylabel, fmt="{:.3f}"):
    x = range(len(codecs))
    w = 0.38
    gap = 0.012                                   # 2px-ish surface gap between adjacent bars
    p = [get("PARQUET", c, key) for c in codecs]
    o = [get("ORC", c, key) for c in codecs]
    b1 = ax.bar([i - w / 2 - gap for i in x], p, w, label="Parquet", color=PQ)
    b2 = ax.bar([i + w / 2 + gap for i in x], o, w, label="ORC", color=ORC)
    for bars in (b1, b2):
        ax.bar_label(bars, fmt=fmt, padding=2, fontsize=8, color=MUTED)
    ax.set_xticks(list(x)); ax.set_xticklabels(codecs)
    ax.set_title(title, loc="left", fontsize=12, color=INK, pad=10)
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", color=GRID, lw=0.8); ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.margins(y=0.18)


# --- 1. размер ------------------------------------------------------------
fig, ax = plt.subplots(figsize=(7.5, 4.2))
grouped(ax, "gb", "Размер данных на диске (lineitem, 6 млн строк)", "ГБ")
ax.legend(frameon=False, loc="upper right")
fig.tight_layout(); fig.savefig("docs/01_size.png", dpi=160); plt.close(fig)

# --- 2. время записи ------------------------------------------------------
fig, ax = plt.subplots(figsize=(7.5, 4.2))
grouped(ax, "write_sec", "Время записи CREATE TABLE AS SELECT", "секунды", "{:.1f}")
ax.legend(frameon=False, loc="upper right")
fig.tight_layout(); fig.savefig("docs/02_write.png", dpi=160); plt.close(fig)

# --- 3. агрегация cold vs warm -------------------------------------------
fig, axes = plt.subplots(1, 2, figsize=(11, 4.2), sharey=True)
grouped(axes[0], "cold_sec", "Агрегация: холодный кэш", "секунды", "{:.1f}")
grouped(axes[1], "warm_sec", "Агрегация: тёплый кэш", "", "{:.1f}")
axes[0].legend(frameon=False, loc="upper right")
fig.tight_layout(); fig.savefig("docs/03_query.png", dpi=160); plt.close(fig)

# --- 4. компромисс: размер против времени чтения --------------------------
fig, ax = plt.subplots(figsize=(7.5, 4.6))
for fmtname, color in (("PARQUET", PQ), ("ORC", ORC)):
    xs = [get(fmtname, c, "gb") for c in codecs]
    ys = [get(fmtname, c, "cold_sec") for c in codecs]
    ax.plot(xs, ys, "o-", color=color, lw=2, ms=9, label=fmtname.title(),
            markeredgecolor=SURFACE, markeredgewidth=2)
    off = {"NONE": (8, 6), "SNAPPY": (8, 6),
           "GZIP": (-6, -16) if fmtname == "PARQUET" else (-8, -16),
           "ZSTD": (10, -4)}
    for c, xv, yv in zip(codecs, xs, ys):
        ax.annotate(c, (xv, yv), textcoords="offset points", xytext=off[c],
                    fontsize=8, color=MUTED)
ax.set_xlabel("Размер на диске, ГБ"); ax.set_ylabel("Агрегация, холодный кэш, с")
ax.set_title("Компромисс: меньше байт — быстрее чтение", loc="left", fontsize=12, color=INK, pad=10)
ax.grid(color=GRID, lw=0.8); ax.set_axisbelow(True)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.legend(frameon=False)
fig.tight_layout(); fig.savefig("docs/04_tradeoff.png", dpi=160); plt.close(fig)
print("ok")
