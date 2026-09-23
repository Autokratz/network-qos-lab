#!/usr/bin/env python3
"""Network performance lab: build the six portfolio screenshots from the captured lab data.

Terminal panels are rendered from the *real* command output captured by
net1.sh / net2.sh; the charts are plotted from the *real* interface byte
counters and ping RTTs recorded during the lab runs.
"""
import csv
import os
import re
import textwrap

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(BASE, "data")
OUT = os.path.join(BASE, "out")
os.makedirs(OUT, exist_ok=True)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
]
MONO = next(p for p in FONT_CANDIDATES if os.path.exists(p))
MONO_B = FONT_CANDIDATES[1] if os.path.exists(FONT_CANDIDATES[1]) else MONO

BG = (12, 15, 18)
FG = (216, 222, 233)
PROMPT = (126, 224, 138)
CMDCOL = (240, 240, 240)
HDR = (110, 200, 255)
WARN = (255, 106, 106)
GOOD = (126, 224, 138)
DIM = (140, 150, 160)
TITLEBAR = (28, 33, 40)

FS = 15
COLS = 104


def line_colour(line):
    s = line.strip()
    if s.startswith("====="):
        return HDR
    if re.match(r"^[A-Za-z0-9\-]+# ", line):
        return PROMPT
    low = s.lower()
    if any(k in low for k in ("saturated", "link saturated", "-->", "overlimits",
                              "dropped", "drop ", "packet loss", "errors")):
        if re.search(r"0% packet loss", s):
            return GOOD
        if re.search(r"\b(dropped|drop|overlimits|errors)\b", low) and re.search(r"\b0\b\s*$", s):
            return FG
        return WARN
    if s.startswith("#") or s.startswith("--"):
        return DIM
    return FG


def condense(text, keep_head=6, keep_tail=2):
    """Collapse long runs of identical-shape ping replies so a transcript stays
    readable. The omission is stated explicitly in the output."""
    out, run = [], []

    def flush():
        if len(run) > keep_head + keep_tail + 1:
            out.extend(run[:keep_head])
            out.append("            ... %d further replies omitted for brevity ..."
                       % (len(run) - keep_head - keep_tail))
            out.extend(run[-keep_tail:])
        else:
            out.extend(run)
        run.clear()

    for ln in text.split("\n"):
        if re.match(r"^\d+ bytes from ", ln.strip()):
            run.append(ln)
        else:
            flush()
            out.append(ln)
    flush()
    return "\n".join(out)


def render_terminal(text, title, width_px=None):
    text = condense(text)
    font = ImageFont.truetype(MONO, FS)
    bold = ImageFont.truetype(MONO_B, FS)
    ch_w = font.getbbox("M")[2] - font.getbbox("M")[0]
    ch_h = FS + 6

    lines = []
    for raw in text.rstrip("\n").split("\n"):
        raw = raw.replace("\t", "    ")
        if len(raw) <= COLS:
            lines.append(raw)
        else:
            wrapped = textwrap.wrap(raw, COLS, subsequent_indent="    ",
                                    drop_whitespace=False) or [""]
            lines.extend(wrapped)

    pad = 16
    bar = 34
    w = width_px or (COLS * ch_w + pad * 2)
    h = bar + pad * 2 + ch_h * len(lines)
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, w, bar], fill=TITLEBAR)
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        d.ellipse([14 + i * 20, 12, 26 + i * 20, 24], fill=c)
    d.text((92, 9), title, font=bold, fill=(200, 208, 218))

    y = bar + pad
    for ln in lines:
        col = line_colour(ln)
        m = re.match(r"^([A-Za-z0-9\-]+#) (.*)$", ln)
        if m and col is PROMPT:
            d.text((pad, y), m.group(1), font=bold, fill=PROMPT)
            d.text((pad + (len(m.group(1)) + 1) * ch_w, y), m.group(2),
                   font=font, fill=CMDCOL)
        else:
            d.text((pad, y), ln, font=font, fill=col)
        y += ch_h
    return img


def dark_axes(ax, fig):
    fig.patch.set_facecolor("#0c0f12")
    ax.set_facecolor("#11161c")
    for s in ax.spines.values():
        s.set_color("#3a444f")
    ax.tick_params(colors="#c3ccd6", labelsize=9)
    ax.xaxis.label.set_color("#c3ccd6")
    ax.yaxis.label.set_color("#c3ccd6")
    ax.title.set_color("#e6edf3")
    ax.grid(True, color="#232c35", linewidth=0.8)
    ax.set_axisbelow(True)


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def chart_util(csv_path, title, ylabel, png, colour="#ff5f56", thresh=90,
               width_in=10.4, height_in=3.4, cap_label=None):
    rows = read_csv(csv_path)
    x = [int(r["second"]) for r in rows]
    y = [float(r["util_pct"]) for r in rows]
    fig, ax = plt.subplots(figsize=(width_in, height_in), dpi=100)
    dark_axes(ax, fig)
    ax.plot(x, y, color=colour, linewidth=1.8)
    ax.fill_between(x, y, color=colour, alpha=0.28)
    if thresh:
        ax.axhline(thresh, color="#ffbd2e", linestyle="--", linewidth=1.2)
        ax.text(x[-1], thresh + 2, f"  {thresh}% alarm threshold",
                color="#ffbd2e", fontsize=8, ha="right")
    peak = max(y)
    ax.annotate(f"peak {peak:.1f}%",
                xy=(x[y.index(peak)], peak), xytext=(0.42, 0.72),
                textcoords="axes fraction", color="#ffffff", fontsize=10,
                arrowprops=dict(arrowstyle="->", color="#ffffff", lw=1.1))
    if cap_label:
        ax.text(0.02, 0.88, cap_label, transform=ax.transAxes,
                color="#7ee08a", fontsize=9)
    ax.set_ylim(0, max(105, max(y) * 1.06))
    ax.text(0.0, -0.30, "byte counters include L2 framing overhead; nominal shaped rate shown in title",
            transform=ax.transAxes, ha="left", fontsize=7, color="#7d8894")
    ax.set_xlabel("elapsed time (seconds)")
    ax.set_ylabel(ylabel)
    ax.set_title(title, fontsize=11, loc="left", pad=12, color="#e6edf3")
    fig.tight_layout()
    fig.subplots_adjust(top=0.83)
    fig.savefig(png, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)
    return peak


def parse_ping(path):
    rtts = []
    with open(path) as f:
        for ln in f:
            m = re.search(r"time=([\d.]+) ms", ln)
            if m:
                rtts.append(float(m.group(1)))
    return rtts


def chart_latency(before, after, png):
    b = parse_ping(before)
    a = parse_ping(after)
    fig, ax = plt.subplots(figsize=(10.4, 3.6), dpi=100)
    dark_axes(ax, fig)
    xb = [i * 0.5 for i in range(len(b))]
    xa = [i * 0.5 for i in range(len(a))]
    ax.plot(xb, b, color="#ff5f56", linewidth=1.8,
            label=f"before QoS - avg {sum(b)/len(b):.1f} ms")
    ax.plot(xa, a, color="#7ee08a", linewidth=1.8,
            label=f"after QoS (DSCP EF) - avg {sum(a)/len(a):.1f} ms")
    ax.axhline(150, color="#ffbd2e", linestyle="--", linewidth=1.1)
    ax.text(0.99, 0.93, "150 ms ITU-T G.114 one-way voice budget",
            transform=ax.transAxes, ha="right", color="#ffbd2e", fontsize=8)
    ax.set_ylim(0, max(max(b), 170) * 1.15)
    ax.set_xlabel("elapsed time (seconds)")
    ax.set_ylabel("VoIP RTT (ms)")
    ax.set_title("Network 1 - voice path latency, identical bulk load offered",
                 fontsize=11, loc="left", pad=12, color="#e6edf3")
    leg = ax.legend(facecolor="#11161c", edgecolor="#3a444f", fontsize=9)
    for t in leg.get_texts():
        t.set_color("#d8dee9")
    fig.tight_layout()
    fig.subplots_adjust(top=0.83)
    fig.savefig(png, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)
    return b, a


def chart_24h(csv_path, png):
    rows = read_csv(csv_path)
    hours = [int(r["hour"]) for r in rows]
    util = [float(r["util_pct"]) for r in rows]
    order = sorted(range(len(hours)), key=lambda i: hours[i])
    hours = [hours[i] for i in order]
    util = [util[i] for i in order]
    colours = ["#4c8dff" if 8 <= h <= 19 else "#ff9f43" for h in hours]
    fig, ax = plt.subplots(figsize=(10.4, 3.6), dpi=100)
    dark_axes(ax, fig)
    ax.bar(hours, util, color=colours, width=0.75)
    ax.axvspan(7.6, 19.4, color="#4c8dff", alpha=0.08)
    ax.text(13.5, 92, "business hours 08:00-19:00", color="#8fb6ff",
            fontsize=9, ha="center")
    ax.text(2, 92, "scheduled backup window", color="#ffb877", fontsize=9,
            ha="center")
    ax.set_xticks(range(0, 24))
    ax.set_xlim(-0.7, 23.7)
    ax.set_ylim(0, max(105, max(util) * 1.08))
    ax.set_xlabel("hour of day (accelerated lab run: 1 simulated hour = 2 s of real traffic)")
    ax.set_ylabel("WAN egress utilisation (%)")
    ax.set_title("Network 2 - 24-hour WAN profile after relocating cloud backup to off-peak",
                 fontsize=11, loc="left", pad=12, color="#e6edf3")
    fig.tight_layout()
    fig.subplots_adjust(top=0.83)
    fig.savefig(png, facecolor=fig.get_facecolor(), bbox_inches="tight", pad_inches=0.25)
    plt.close(fig)
    return dict(zip(hours, util))


def stack(paths, out_png, gap=10):
    imgs = [Image.open(p).convert("RGB") for p in paths]
    w = max(i.width for i in imgs)
    h = sum(i.height for i in imgs) + gap * (len(imgs) - 1) + 2 * gap
    canvas = Image.new("RGB", (w + 2 * gap, h), BG)
    y = gap
    for im in imgs:
        canvas.paste(im, (gap + (w - im.width) // 2, y))
        y += im.height + gap
    canvas.save(out_png)
    return out_png


def caption(text, width, sub=None):
    font = ImageFont.truetype(MONO_B, 17)
    small = ImageFont.truetype(MONO, 13)
    h = 62 if sub else 40
    img = Image.new("RGB", (width, h), (18, 22, 27))
    d = ImageDraw.Draw(img)
    d.text((16, 10), text, font=font, fill=(235, 241, 247))
    if sub:
        d.text((16, 36), sub, font=small, fill=(150, 162, 175))
    return img


def build(shot, title, subtitle, term_file, term_title, charts):
    term = render_terminal(open(term_file).read(), term_title)
    parts = []
    tmp = os.path.join(OUT, f".tmp_term_{shot}.png")
    term.save(tmp)
    parts.append(tmp)
    parts.extend(charts)
    imgs = [Image.open(p).convert("RGB") for p in parts]
    w = max(i.width for i in imgs)
    cap = caption(title, w + 20, subtitle)
    capp = os.path.join(OUT, f".tmp_cap_{shot}.png")
    cap.save(capp)
    final = os.path.join(OUT, f"Screenshot_{shot}.png")
    stack([capp] + parts, final)
    for p in parts + [capp]:
        if os.path.basename(p).startswith(".tmp"):
            os.remove(p)
    print(f"  wrote {final}")
    return final
