#!/usr/bin/env python3
"""Static test-coverage estimate for last9-otel-setup.sh.

kcov-style runtime line coverage does not work for this script (kcov's bash
instrumentation is Linux-only and does not propagate to the grandchild
`bash "$SCRIPT"` processes the tests spawn). Instead we estimate coverage
statically: build the script's function call graph, seed it with the functions
the test suites actually drive, take the transitive closure, and report what
fraction of the script's functions (and their lines) that reaches.

Model (intentionally transparent — the function lists are printed so a human can
audit the estimate):

  covered = transitive closure, over the static call graph, of
      SEED = directly-referenced functions in the test files
           ∪ ALWAYS_RUN   (main + the prelude main runs for every invocation)
           ∪ INSTALL_FLOW (the mode handlers main dispatches to, all exercised
                           by the layer-2 e2e modes + layer-1 orchestration)

Not covered, by construction, are the uninstall family, the help/examples
screens, and any function only those reach — no test drives them today.

Exit status is always 0 (report-only). Pass --min N to fail under N% (unused by
default; available if a gate is ever wanted).
"""

import os
import re
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(REPO_ROOT, "last9-otel-setup.sh")
TEST_FILES = [
    os.path.join(REPO_ROOT, "tests", "unit.bats"),
    os.path.join(REPO_ROOT, "tests", "integration", "orchestration.bats"),
    os.path.join(REPO_ROOT, "tests", "integration", "uninstall.bats"),
    os.path.join(REPO_ROOT, "tests", "test_adopt_otel_crds.py"),
    os.path.join(REPO_ROOT, "tests", "test_adopt_prometheus_crds.py"),
    os.path.join(REPO_ROOT, "tests", "test_install_operator.py"),
]

# main() runs these for every (non-empty) invocation — see main()/parse_arguments.
# main itself is NOT a traversal seed: it dispatches to ALL branches (including
# the untested uninstall + help/examples cases), so seeding it would wrongly
# credit those. main is counted as covered separately (every test runs it).
ALWAYS_RUN = [
    "parse_arguments",
    "setup_context_wrappers",
    "check_prerequisites",
]

# The install / monitoring / events handlers main dispatches to. Every one of
# these is exercised end-to-end by a layer-2 e2e mode (operator-only, logs-only,
# monitoring-only, events-only, crd-conflict, context) and/or layer-1
# orchestration. Derived from main()'s install branches (see the tail of main).
INSTALL_FLOW = [
    "setup_repository",
    "setup_helm_repos",
    "install_operator",
    "install_collector",
    "create_collector_service",
    "create_instrumentation",
    "verify_installation",
    "setup_last9_monitoring",
    "install_events_agent",
    "create_logs_only_config",
    "cleanup",
]

FUNC_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?\s*$")


def parse_functions(path):
    """Return {name: (start_line, end_line, body_lines)} for top-level funcs.

    Functions are defined as `name() {` ... and closed by a `}` at column 0.
    """
    with open(path) as fh:
        lines = fh.readlines()
    funcs = {}
    i = 0
    while i < len(lines):
        m = FUNC_DEF.match(lines[i].rstrip("\n"))
        if m:
            name = m.group(1)
            start = i
            j = i + 1
            while j < len(lines) and not lines[j].startswith("}"):
                j += 1
            body = lines[start : j + 1]
            funcs[name] = (start + 1, j + 1, body)
            i = j + 1
        else:
            i += 1
    return funcs


_DQ = re.compile(r'"(?:[^"\\]|\\.)*"')
_SQ = re.compile(r"'[^']*'")


def _clean_line(line):
    """Drop comments and string literals so names inside echo/log strings and
    hint text ('To uninstall later, run ...') are not mistaken for calls."""
    line = line.rstrip("\n")
    # Strip a leading-or-inline comment (approximate: '#' preceded by space/start).
    line = re.sub(r"(^|\s)#.*$", r"\1", line)
    line = _DQ.sub('""', line)
    line = _SQ.sub("''", line)
    return line


def build_call_graph(funcs):
    """Edge A->B when B is invoked in command position inside A's body.

    Command position = first token of a simple command: line start, or after
    ; & | ( ) { } or the keywords then/do/else. This excludes name mentions
    inside strings/comments, which a bare word-match would count as calls."""
    names = set(funcs)
    # (?:start | separator | keyword) <spaces> NAME <word-boundary>
    patterns = {
        n: re.compile(
            r"(?:^|[;&|(){}]|\b(?:if|elif|while|until|then|do|else)\b)[ \t]*"
            + re.escape(n)
            + r"(?![A-Za-z0-9_])",
            re.MULTILINE,
        )
        for n in names
    }
    graph = {n: set() for n in names}
    for caller, (_s, _e, body) in funcs.items():
        text = "\n".join(_clean_line(l) for l in body[1:])  # skip def line
        for callee in names:
            if callee == caller:
                continue
            if patterns[callee].search(text):
                graph[caller].add(callee)
    return graph


def closure(seeds, graph):
    seen, stack = set(), [s for s in seeds if s in graph]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(graph.get(n, ()))
    return seen


def directly_referenced(funcs):
    """Script functions whose name is used as a word in any test file."""
    names = set(funcs)
    hit = set()
    for tf in TEST_FILES:
        if not os.path.exists(tf):
            continue
        with open(tf) as fh:
            text = fh.read()
        for n in names:
            if re.search(r"(?<![A-Za-z0-9_])" + re.escape(n) + r"(?![A-Za-z0-9_])", text):
                hit.add(n)
    return hit


def loc(funcs, name):
    s, e, _ = funcs[name]
    return e - s + 1


def main():
    funcs = parse_functions(SCRIPT)
    total = len(funcs)
    graph = build_call_graph(funcs)

    # Warn on any stale seed (guards against script edits renaming functions).
    for seed in ALWAYS_RUN + INSTALL_FLOW:
        if seed not in funcs:
            print(f"WARNING: seed '{seed}' is not a defined function — update coverage-report.py", file=sys.stderr)

    direct = directly_referenced(funcs)
    seeds = (set(ALWAYS_RUN) | set(INSTALL_FLOW) | direct) - {"main"}
    # main is the dispatch entry: it is executed by every test but routes to ALL
    # branches (incl. the untested uninstall + help/examples cases). Seeding it
    # would wrongly credit those, so we never traverse it — just count it covered.
    covered = closure(seeds, graph) & set(funcs)
    covered.add("main")
    uncovered = sorted(set(funcs) - covered)

    reachable_from_main = closure(["main"], graph) & set(funcs)
    dead = sorted(set(funcs) - reachable_from_main)

    total_loc = sum(loc(funcs, n) for n in funcs)
    covered_loc = sum(loc(funcs, n) for n in covered)

    func_pct = round(100 * len(covered) / total) if total else 0
    line_pct = round(100 * covered_loc / total_loc) if total_loc else 0

    print("=" * 64)
    print("  last9-otel-setup.sh — static test-coverage estimate")
    print("=" * 64)
    print(f"  Functions:        {total}")
    print(f"  Covered:          {len(covered)}  ({func_pct}% of functions)")
    print(f"  Line-weighted:    {covered_loc}/{total_loc} lines  ({line_pct}%)")
    print(f"  Directly tested:  {len(direct)} functions named in test files")
    print("-" * 64)
    print(f"  Untested ({len(uncovered)}):")
    for n in uncovered:
        s, e, _ = funcs[n]
        print(f"    - {n}  (L{s}-{e}, {e - s + 1} lines)")
    if dead:
        print("-" * 64)
        print(f"  Unreachable from main() — dead/unused ({len(dead)}):")
        for n in dead:
            print(f"    - {n}")
    print("=" * 64)
    print("  Model: static call-graph closure from test-driven seeds")
    print("  (install/monitoring/events flow + directly-tested helpers).")
    print("  unit.bats's eval'd helpers ARE counted (named in the test file).")
    print("=" * 64)

    if len(sys.argv) >= 3 and sys.argv[1] == "--min":
        threshold = int(sys.argv[2])
        if func_pct < threshold:
            print(f"FAIL: {func_pct}% < required {threshold}%", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
