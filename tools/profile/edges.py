"""Reads the .count files of runs over libraries of different sizes (run.sh
-p count) and reports, for each function Lua calls, how often, from how many
modules, with how many bytes of string arguments, and how the calls grow with
the number of books (the exponent b in calls ~ books^b, between the smallest
and the largest library).

    python3 -I tools/profile/edges.py STEP BOOKS=OUT [BOOKS=OUT ...]

STEP is a step's name (propose, verify ...); each OUT is a run.sh output
folder. C functions are named with nm from the object they live in.
"""
import bisect
import collections
import math
import os
import re
import subprocess
import sys

step, runs = sys.argv[1], [a.split("=", 1) for a in sys.argv[2:]]
runs = sorted((int(n), out) for n, out in runs)

symbols = {}


def name_c(obj, off):
    if obj not in symbols:
        table = []
        for flag in ([], ["-D"]):
            try:
                text = subprocess.run(["nm", "--defined-only", *flag, obj], capture_output=True, text=True).stdout
            except OSError:
                text = ""
            for line in text.splitlines():
                parts = line.split()
                if len(parts) == 3 and parts[1] in "tTwW":
                    table.append((int(parts[0], 16), parts[2]))
        table.sort()
        symbols[obj] = table
    table = symbols[obj]
    i = bisect.bisect_right(table, (off, "￿")) - 1
    lib = os.path.basename(obj)
    if i >= 0 and table[i][0] == off:
        return f"{table[i][1]} ({lib})"
    return f"{lib}+{off:#x}"


def module(source):
    m = re.search(r"/(lua/lulibre/|scripts/|tools/profile/)(.*)\.lua$", source)
    if m:
        return m.group(2) if m.group(1) == "lua/lulibre/" else m.group(1).rstrip("/") + "/" + m.group(2)
    return source.lstrip("@=")


def lua_fn(source_line):
    src, _, line = source_line.rpartition(":")
    return f"{module(src)}:{line}"


per = {}  # books -> callee -> [calls, bytes, tables, set of caller modules]
for books, out in runs:
    path = os.path.join(out, f"{step}.count")
    table = collections.defaultdict(lambda: [0, 0, 0, set()])
    with open(path) as f:
        for line in f:
            src, _, kind, callee, calls, nbytes, tables = line.rstrip("\n").split("\t")
            if kind == "C":
                obj, _, off = callee.rpartition("+")
                key = ("C", name_c(obj, int(off, 16)) if obj else callee)
            else:
                key = ("Lua", lua_fn(callee))
            e = table[key]
            e[0] += int(calls)
            e[1] += int(nbytes)
            e[2] += int(tables)
            e[3].add(module(src))
    per[books] = table

small, large = runs[0][0], runs[-1][0]


def growth(key):
    a, b = per[small].get(key), per[large].get(key)
    if not a or not b or not a[0] or large == small:
        return float("nan")
    return math.log(b[0] / a[0]) / math.log(large / small)


def report(kind, limit):
    rows = sorted(((v[0], k) for k, v in per[large].items() if k[0] == kind), reverse=True)[:limit]
    head = "".join(f"{n:>11}" for n, _ in runs)
    print(f"\n{kind} functions called most, step {step} (calls at {', '.join(str(n) for n, _ in runs)} books)")
    print(f"{'function':48}{head}  growth  modules  bytes/call  callers")
    for _, k in rows:
        v = per[large][k]
        counts = "".join(f"{per[n].get(k, [0])[0]:>11}" for n, _ in runs)
        callers = ", ".join(sorted(v[3])[:6]) + (" ..." if len(v[3]) > 6 else "")
        print(f"{k[1][:47]:48}{counts}  {growth(k):6.2f}  {len(v[3]):7}  {v[1] / v[0]:10.0f}  {callers}")


total = {n: sum(v[0] for v in t.values()) for n, t in per.items()}
print(f"step {step}: calls from Lua, by library size: " + ", ".join(f"{n} books {total[n]}" for n in sorted(total)))
by_kind = {n: collections.Counter() for n in per}
for n, t in per.items():
    for k, v in t.items():
        by_kind[n][k[0]] += v[0]
print("into C / into Lua: " + ", ".join(f"{n}: {by_kind[n]['C']} / {by_kind[n]['Lua']}" for n in sorted(by_kind)))
report("C", 40)
report("Lua", 40)
