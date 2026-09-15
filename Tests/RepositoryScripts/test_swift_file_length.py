from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "Scripts" / "Quality" / "check_swift_file_length.py"
SPEC = importlib.util.spec_from_file_location("check_swift_file_length", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SwiftFileLengthTests(unittest.TestCase):
    def test_counts_code_and_ignores_blank_and_comment_only_lines(self) -> None:
        source = """
// heading
let first = 1 // trailing comment
/* outer
  /* nested */
*/ let second = 2

"""
        self.assertEqual(MODULE.code_line_count(source), 2)

    def test_comment_markers_inside_strings_are_code(self) -> None:
        source = 'let slash = "//"\nlet block = "/* not a comment */"'
        self.assertEqual(MODULE.code_line_count(source), 2)

    def test_counts_nonblank_multiline_string_content(self) -> None:
        source = '''
let value = """
payload

/* literal content */
"""
'''
        self.assertEqual(MODULE.code_line_count(source), 4)

    def test_supports_raw_multiline_strings(self) -> None:
        source = '''
let value = #"""
""" is content until the hashed delimiter
"""#
'''
        self.assertEqual(MODULE.code_line_count(source), 3)

    def test_reports_only_tracked_swift_files_over_the_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Sources").mkdir()
            (root / "Tests").mkdir()
            (root / "Sources/Long.swift").write_text("let a = 1\nlet b = 2\n")
            (root / "Tests/Short.swift").write_text("let value = 1\n")
            import subprocess

            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            subprocess.run(
                ["git", "add", "Sources/Long.swift", "Tests/Short.swift"],
                cwd=root,
                check=True,
            )

            self.assertEqual(
                MODULE.oversized_files(root, limit=1), [(Path("Sources/Long.swift"), 2)]
            )


if __name__ == "__main__":
    unittest.main()
