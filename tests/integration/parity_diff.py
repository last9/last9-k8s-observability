#!/usr/bin/env python3
"""Compare two metric pipelines (distinguished by a label) in one VictoriaMetrics.

usage: parity_diff.py <vm_url> <labelA> <labelB> [--queries FILE] [--name-regex RE] [--window SEC]
  labelA/labelB are "key=value" (e.g. pipeline=prom pipeline=otel).
Exit 1 on any name diff, label-key diff, strict-key value diff, or query diff > 5%.
"""
import argparse, json, re, sys, time, urllib.parse, urllib.request

# operator-added external labels on the old side + the gate's own marker
IGNORED = {"pipeline", "prometheus", "prometheus_replica"}
# label values that must match exactly (informational for the rest)
STRICT = {"job", "namespace", "service", "endpoint", "metrics_path", "node", "instance", "cluster"}


def num(v):
    try:
        return float(v)
    except ValueError:
        return v


def get(base, path, **params):
    url = base.rstrip("/") + path + "?" + urllib.parse.urlencode(params, doseq=True)
    with urllib.request.urlopen(url, timeout=60) as r:
        d = json.load(r)
    if d.get("status") != "success":
        sys.exit("VM error: %s" % d)
    return d["data"]


def series(base, k, v, window, name_re):
    # instant query, not /series: VM's series API matches by day index so it returns startup-transient series outside the window
    data = [r["metric"] for r in get(base, "/api/v1/query", query='last_over_time({%s="%s"}[%ds])' % (k, v, window))["result"]]
    out = {}  # name -> {key -> set(values)}
    for s in data:
        n = s["__name__"]
        if name_re and not name_re.fullmatch(n):
            continue
        d = out.setdefault(n, {})
        for lk, lv in s.items():
            if lk != "__name__" and lk not in IGNORED:
                d.setdefault(lk, set()).add(lv)
    return out


def qval(base, q, k, v):
    for r in get(base, "/api/v1/query", query=q)["result"]:
        if r["metric"].get(k) == v:
            return float(r["value"][1])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vm_url"); ap.add_argument("a"); ap.add_argument("b")
    ap.add_argument("--queries"); ap.add_argument("--name-regex"); ap.add_argument("--window", type=int, default=300)
    o = ap.parse_args()
    (ak, av), (bk, bv) = o.a.split("=", 1), o.b.split("=", 1)
    rx = re.compile(o.name_regex) if o.name_regex else None
    A, B = series(o.vm_url, ak, av, o.window, rx), series(o.vm_url, bk, bv, o.window, rx)
    bad = False

    oa, ob = sorted(set(A) - set(B)), sorted(set(B) - set(A))
    print("== names only in %s (%d)" % (o.a, len(oa))); [print("  " + n) for n in oa]
    print("== names only in %s (%d)" % (o.b, len(ob))); [print("  " + n) for n in ob]
    print("== common names: %d" % len(set(A) & set(B)))
    bad |= bool(oa or ob)

    print("== label-key diffs")
    nk = 0
    for n in sorted(set(A) & set(B)):
        ka, kb = set(A[n]), set(B[n])
        if ka != kb:
            nk += 1
            print("  %s: only-%s=%s only-%s=%s" % (n, av, sorted(ka - kb), bv, sorted(kb - ka)))
    print("  (%d)" % nk); bad |= bool(nk)

    print("== label-value diffs (strict keys fail the gate, others informational)")
    ns = 0
    for n in sorted(set(A) & set(B)):
        for lk in sorted(set(A[n]) & set(B[n])):
            x, y = A[n][lk], B[n][lk]
            if lk in ("le", "quantile"):
                x, y = {num(v) for v in x}, {num(v) for v in y}
            if x != y:
                strict = lk in STRICT
                ns += strict
                print("  %s %s.%s: only-%s=%s only-%s=%s" % ("STRICT" if strict else "info  ", n, lk, av, sorted(x - y)[:4], bv, sorted(y - x)[:4]))
    print("  strict value diffs: %d" % ns); bad |= bool(ns)

    if o.queries:
        print("== queries (%s vs %s)" % (av, bv))
        for q in [l.strip() for l in open(o.queries) if l.strip() and not l.startswith("#")]:
            x, y = qval(o.vm_url, q, ak, av), qval(o.vm_url, q, bk, bv)
            if x is None or y is None:
                rel, ok = None, False
            else:
                rel = abs(x - y) / max(abs(x), abs(y), 1e-12) if (x or y) else 0.0
                ok = rel <= 0.05
            print("  %-70s %s=%s %s=%s rel=%s %s" % (q, av, x, bv, y, "n/a" if rel is None else "%.4f" % rel, "OK" if ok else "FAIL"))
            bad |= not ok
    print("RESULT: %s" % ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)


main()
