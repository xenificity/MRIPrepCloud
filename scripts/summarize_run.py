#!/usr/bin/env python3
"""Summarize a DeepPrep run from its Nextflow report: makespan, task counts, core allocation/utilization, GPU waits.
Usage: scripts/summarize_run.py <output_dir> [total_cores=48]   -> prints a summary, writes <output_dir>/mriprepcloud/utilization.png
"""
import json, re, sys, os, collections

out = sys.argv[1]; cores = int(sys.argv[2]) if len(sys.argv) > 2 else 48
html = open(f"{out}/QC/report.html").read()
tr = json.loads(re.search(r"window\.data\s*=\s*(\{.*?\});\s*\n", html, re.S).group(1))["trace"]
I = lambda x: int(x) if str(x).lstrip("-").isdigit() else 0
F = lambda x: float(x) if x not in ("-", "") else 0.0
ok = [t for t in tr if t["status"] == "COMPLETED"]
t0 = min(I(t["submit"]) for t in tr); t1 = max(I(t["complete"]) for t in tr); span = (t1 - t0) / 60000

ev = sorted([(I(t["start"]), I(t["cpus"]), 1 if t["queue"] == "gpu-node" else 0) for t in ok]
            + [(I(t["complete"]), -I(t["cpus"]), -1 if t["queue"] == "gpu-node" else 0) for t in ok])
alloc = gpu = area = 0; last = ev[0][0]; curve = []
for ts, dc, dg in ev:
    area += alloc * (ts - last); alloc += dc; gpu += dg; last = ts; curve.append(((ts - t0) / 60000, alloc, gpu))
used = sum(F(t["%cpu"]) / 100 * I(t["realtime"]) for t in ok) / 60000  # core-minutes actually consumed
gw = [(I(t["start"]) - I(t["submit"])) / 1000 for t in ok if t["queue"] == "gpu-node"]
subj = collections.defaultdict(float)
for t in ok:
    m = re.search(r"sub-[A-Za-z0-9]+", t["tag"] or "")
    if m: subj[m.group(0)] = max(subj[m.group(0)], (I(t["complete"]) - t0) / 60000)

print(f"makespan            {span:7.1f} min   ({span / max(len(subj), 1):.2f} min/subject, {len(subj)} subjects)")
print(f"tasks               {len(ok)}/{len(tr)} completed, {len(tr) - len(ok)} retried/failed")
print(f"cores allocated     {area / (t1 - t0):7.1f} of {cores} on average")
print(f"CPU utilization     {100 * used / (cores * span):7.1f} %   ({used:.0f} core-min of work)")
if gw: print(f"GPU task wait       {sum(gw) / len(gw):7.0f} s mean, {max(gw):.0f} s max ({len(gw)} GPU tasks)")

try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    x, a, g = zip(*curve); fig, ax = plt.subplots(figsize=(8, 3)); ax2 = ax.twinx()
    ax.step(x, a, where="post", color="#2a78d6", lw=1.2, label="cores allocated"); ax.axhline(cores, color="#8a8984", ls=":", lw=0.8)
    ax2.step(x, g, where="post", color="#eb6834", lw=1.0, label="GPU tasks running")
    ax.set(xlabel="minutes", ylabel="cores", ylim=(0, cores * 1.05), xlim=(0, span)); ax2.set(ylabel="GPU tasks", ylim=(0, 8))
    ax.set_title(f"{os.path.basename(out.rstrip('/'))}: {span:.1f} min, {100 * used / (cores * span):.0f}% CPU utilization", fontsize=10)
    fig.legend(loc="upper right", fontsize=8, frameon=False, ncol=2); fig.tight_layout()
    os.makedirs(f"{out}/mriprepcloud", exist_ok=True); fig.savefig(f"{out}/mriprepcloud/utilization.png", dpi=150)
    print(f"figure              {out}/mriprepcloud/utilization.png")
except ImportError:
    pass
