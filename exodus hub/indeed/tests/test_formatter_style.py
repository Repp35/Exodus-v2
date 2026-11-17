"""Regression tests for compact, readable Luau formatting."""
import sys
import tempfile
import unittest
import re
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formatter


class FormatterStyleTests(unittest.TestCase):
    def test_module_sections_are_top_level(self):
        paths = sorted((formatter.HUB_ROOT / "modules").rglob("*.luau"))
        self.assertTrue(paths, "nenhum módulo Luau encontrado")
        for path in paths:
            with self.subTest(path=path):
                for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    self.assertFalse(
                        line[:1].isspace() and re.fullmatch(r"\s+--\s+[A-Za-z][A-Za-z0-9_/-]*\s*", line),
                        f"seção aninhada em {path}:{line_number}",
                    )

    def test_default_paths_include_loader_and_modules(self):
        paths = formatter.collect_files([], [])
        self.assertIn(formatter.HUB_ROOT / "loader.luau", paths)
        self.assertTrue(any(path.is_relative_to(formatter.HUB_ROOT / "modules") for path in paths))

    def test_check_does_not_require_distinct_output_paths(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(StringIO()):
            root = Path(directory)
            first = root / "sample.luau"
            second = root / "sample_formatted.luau"
            for path in (first, second):
                path.write_text("return 1\n", encoding="utf-8")
            args = formatter.build_parser().parse_args(["--check", str(first), str(second)])
            self.assertEqual(formatter.format_files(args), 1)
            self.assertEqual(first.read_bytes(), b"return 1\n")
            self.assertEqual(second.read_bytes(), b"return 1\n")

    def test_check_agrees_with_in_place_on_bom_and_crlf(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(StringIO()):
            path = Path(directory) / "sample.luau"
            parser = formatter.build_parser()
            format_args = parser.parse_args(["--in-place", str(path)])
            check_args = parser.parse_args(["--check", str(path)])
            path.write_text("return 1\n", encoding="utf-8")
            self.assertEqual(formatter.format_files(format_args), 0)
            expected = path.read_bytes()

            for original in (b"\xef\xbb\xbf" + expected, expected.replace(b"\n", b"\r\n")):
                with self.subTest(original=original):
                    path.write_bytes(original)
                    self.assertEqual(formatter.format_files(check_args), 1)
                    self.assertEqual(path.read_bytes(), original)
                    self.assertEqual(formatter.format_files(format_args), 0)
                    self.assertEqual(path.read_bytes(), expected)
                    self.assertEqual(formatter.format_files(check_args), 0)

            with patch.object(formatter, "write_atomically") as write:
                self.assertEqual(formatter.format_files(format_args), 0)
                write.assert_not_called()

    def test_nested_named_table_expands_without_splitting_values(self):
        source = ('    connectionCounts = { global = #state.globalConnections, '
                  'character = #state.characterConnections },\n')
        expected = ('    connectionCounts = {\n'
                    '        global = #state.globalConnections,\n'
                    '        character = #state.characterConnections,\n'
                    '    },\n')
        result = formatter.expand_dense_named_tables(source, 'Spaces', 4)
        self.assertEqual(result, expected)
        self.assertEqual(formatter.expand_dense_named_tables(result, 'Spaces', 4), result)

    def test_short_table_stays_compact(self):
        source = '    point = { x = 1, y = 2 },\n'
        self.assertEqual(formatter.expand_dense_named_tables(source, 'Spaces', 4), source)

    def test_long_if_keeps_each_branch_together(self):
        source = 'if ready then\n    first = 1\nelse\n    second = 2\nend\n'
        self.assertEqual(formatter.compact_simple_if_blocks(source, 25, 2, 4, 'Spaces'),
                         'if ready then first = 1\nelse second = 2 end\n')
        self.assertEqual(formatter.compact_simple_if_blocks(source, 120, 2, 4, 'Spaces'),
                         'if ready then first = 1 else second = 2 end\n')

    def test_compacts_simple_functions_and_conditions(self):
        source = """-- [[ sample ]]
-- state
function Utils.getPlayers()
    return players
end
function Utils.getWorkspace()
    return workspace
end
function Utils.load()
    if not ready then
        warn("not ready")
        return true
    end
    if valid then
        first()
        second()
    end
    return true
end
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.luau"
            path.write_text(source, encoding="utf-8")
            args = formatter.build_parser().parse_args(["--in-place", str(path)])
            self.assertEqual(formatter.format_files(args), 0)
            result = path.read_text(encoding="utf-8")
            self.assertIn("function Utils.getPlayers() return players end\n", result)
            self.assertIn("function Utils.getWorkspace() return workspace end\n", result)
            self.assertIn('if not ready then warn("not ready"); return true end', result)
            self.assertIn("if valid then first(); second() end", result)
            self.assertEqual(formatter.format_files(args), 0)
            self.assertEqual(path.read_text(encoding="utf-8"), result)

    def test_end_to_end_is_stable(self):
        source = '''-- [[ sample ]]
-- state
local function stateSnapshot()
    return {
        connectionCounts = { global = #state.globalConnections, character = #state.characterConnections },
    }
end
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.luau'
            path.write_text(source, encoding='utf-8')
            args = formatter.build_parser().parse_args(['--in-place', str(path)])
            self.assertEqual(formatter.format_files(args), 0)
            result = path.read_text(encoding='utf-8')
            self.assertIn('    connectionCounts = {\n      global =', result)
            self.assertEqual(formatter.format_files(args), 0)
            self.assertEqual(path.read_text(encoding='utf-8'), result)


if __name__ == '__main__':
    unittest.main()
