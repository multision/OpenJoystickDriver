from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


class DispatcherTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[2]
    command = root / "Scripts/ojd"

    def run_ojd(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.command), *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_help_route_succeeds(self) -> None:
        self.assertEqual(self.run_ojd("--help").returncode, 0)

    def test_build_help_route_succeeds(self) -> None:
        self.assertEqual(self.run_ojd("build", "help").returncode, 0)

    def test_unknown_route_fails_with_usage_status(self) -> None:
        self.assertEqual(self.run_ojd("unknown").returncode, 2)

    def test_removed_routes_fail_with_usage_status(self) -> None:
        for arguments in (
            ("build", "nuke"),
            ("check", "scripts"),
            ("check", "swift-structure"),
            ("check", "capabilities"),
            ("check", "fast"),
            ("check", "all"),
            ("lint",),
            ("format",),
            ("test", "swift"),
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_ojd(*arguments).returncode, 2)
