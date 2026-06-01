#!/usr/bin/env python3
"""Tests for the static coverage analyzer (tests/coverage-report.py).

Guards the call-graph model against regressions: command-position matching,
string/comment stripping, main-not-traversed, and the covered/untested split.
Run: python3 tests/test_coverage_report.py
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "coverage-report.py")

spec = importlib.util.spec_from_file_location("coverage_report", MODULE)
cov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cov)


class TestCallGraph(unittest.TestCase):
    def test_command_position_call_is_an_edge(self):
        funcs = {
            "a": (1, 3, ["a() {\n", "    b\n", "}\n"]),
            "b": (4, 5, ["b() {\n", "}\n"]),
        }
        graph = cov.build_call_graph(funcs)
        self.assertIn("b", graph["a"])

    def test_name_inside_string_is_not_an_edge(self):
        funcs = {
            "a": (1, 3, ["a() {\n", '    echo "run b to clean up"\n', "}\n"]),
            "b": (4, 5, ["b() {\n", "}\n"]),
        }
        graph = cov.build_call_graph(funcs)
        self.assertNotIn("b", graph["a"], "name in an echo string must not count as a call")

    def test_name_in_comment_is_not_an_edge(self):
        funcs = {
            "a": (1, 3, ["a() {\n", "    # calls b later\n", "}\n"]),
            "b": (4, 5, ["b() {\n", "}\n"]),
        }
        graph = cov.build_call_graph(funcs)
        self.assertNotIn("b", graph["a"])

    def test_edge_after_separator_and_on_later_line(self):
        funcs = {
            "a": (1, 4, ["a() {\n", "    foo\n", "    if x; then b; fi\n", "}\n"]),
            "b": (5, 6, ["b() {\n", "}\n"]),
            "foo": (7, 8, ["foo() {\n", "}\n"]),
        }
        graph = cov.build_call_graph(funcs)
        self.assertIn("b", graph["a"])      # after `then`
        self.assertIn("foo", graph["a"])    # multiline: leading command on its own line

    def test_edge_when_called_as_if_condition(self):
        # `if some_func; then` is a real call — the matcher must see it.
        funcs = {
            "a": (1, 4, ["a() {\n", "    if check; then echo ok; fi\n", "}\n"]),
            "check": (5, 6, ["check() {\n", "}\n"]),
        }
        graph = cov.build_call_graph(funcs)
        self.assertIn("check", graph["a"])


class TestRealScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.funcs = cov.parse_functions(cov.SCRIPT)
        cls.graph = cov.build_call_graph(cls.funcs)
        cls.direct = cov.directly_referenced(cls.funcs)
        seeds = (set(cov.ALWAYS_RUN) | set(cov.INSTALL_FLOW) | cls.direct) - {"main"}
        cls.covered = (cov.closure(seeds, cls.graph) & set(cls.funcs)) | {"main"}

    def test_parses_some_functions(self):
        self.assertGreater(len(self.funcs), 30)

    def test_all_seeds_are_real_functions(self):
        for seed in cov.ALWAYS_RUN + cov.INSTALL_FLOW:
            self.assertIn(seed, self.funcs, f"seed '{seed}' is stale")

    def test_covered_and_untested_partition_total(self):
        untested = set(self.funcs) - self.covered
        self.assertEqual(len(self.covered) + len(untested), len(self.funcs))

    def test_install_flow_is_covered(self):
        self.assertIn("setup_last9_monitoring", self.covered)
        self.assertIn("install_collector", self.covered)

    def test_uninstall_paths_are_covered(self):
        # uninstall.bats drives every uninstall path through the entry point.
        for fn in ("uninstall_all", "uninstall_opentelemetry",
                   "uninstall_last9_monitoring", "uninstall_events_agent"):
            self.assertIn(fn, self.covered, f"{fn} should be covered by uninstall.bats")

    def test_main_is_counted_covered(self):
        self.assertIn("main", self.covered)


if __name__ == "__main__":
    unittest.main()
