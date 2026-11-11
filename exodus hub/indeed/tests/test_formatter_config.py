"""Regression tests for formatter configuration auditing."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formatter


VALID = """-- [[ example ]]

-- tuning
local CONFIG = {
    TIMEOUT = 0.5,
    SPEED_LIMIT = 70,
}

-- state
local lastUpdate = 0
"""


class ConfigAuditTests(unittest.TestCase):
    def test_valid_config(self):
        self.assertEqual(formatter.audit_module_config(VALID, Path("test.luau")), [])

    def test_missing_config_fails(self):
        with self.assertRaisesRegex(formatter.FormatterError, "local CONFIG"):
            formatter.audit_module_config("-- [[ bad ]]\n\n-- state\nlocal x = 1\n", Path("bad.luau"))

    def test_missing_tuning_section_fails(self):
        with self.assertRaisesRegex(formatter.FormatterError, "tuning"):
            formatter.audit_module_config("local CONFIG = { VALUE = 1 }\n", Path("bad.luau"))

    def test_tuning_must_precede_config(self):
        with self.assertRaisesRegex(formatter.FormatterError, "tuning"):
            formatter.audit_module_config("local CONFIG = { VALUE = 1 }\n-- tuning\n", Path("bad.luau"))

    def test_duplicate_config_fails(self):
        with self.assertRaisesRegex(formatter.FormatterError, "exatamente um"):
            formatter.audit_module_config(
                "-- tuning\nlocal CONFIG = { A = 1 }\nlocal CONFIG = { B = 2 }\n",
                Path("bad.luau"),
            )

    def test_warns_without_moving_constants(self):
        source = VALID + 'local MAX_RETRIES = 3\nlocal MODULE_NAME = "Example"\n'
        warnings = formatter.audit_module_config(source, Path("example.luau"))
        self.assertEqual(len(warnings), 2)
        self.assertIn("MAX_RETRIES", warnings[0])
        self.assertIn("MODULE_NAME", warnings[1])
        self.assertIn("local MAX_RETRIES = 3", source)

    def test_ignores_runtime_and_config_aliases(self):
        source = VALID + (
            "local currentSpeed = 70\n"
            "local REPOSITORY = CONFIG.REPOSITORY\n"
            "local INSTANCE = game:GetService(\"Players\")\n"
            "local RESULT = math.min(1, 2)\n"
        )
        self.assertEqual(formatter.audit_module_config(source, Path("example.luau")), [])

    def test_expands_inline_config_without_splitting_nested_commas(self):
        source = (
            'local CONFIG = { DETECTION_RANGE = 70, FLAGS = { true, false }, NAME = "A,B" }\n'
        )
        expanded = formatter.expand_inline_config_tables(source)
        self.assertIn("\tDETECTION_RANGE = 70,", expanded)
        self.assertIn("\tFLAGS = { true, false },", expanded)
        self.assertIn('\tNAME = "A,B",', expanded)
        self.assertEqual(expanded, formatter.expand_inline_config_tables(expanded))

    def test_all_hub_luau_files_have_local_config(self):
        paths = sorted(formatter.HUB_ROOT.parent.rglob("*.luau"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                formatter.audit_module_config(text, path)


if __name__ == "__main__":
    unittest.main()
