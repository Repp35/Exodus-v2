"""Regression tests for compact, readable Luau formatting."""
import sys
import tempfile
import unittest
import re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import formatter


class FormatterStyleTests(unittest.TestCase):
    def test_module_sections_are_top_level(self):
        for path in sorted((formatter.HUB_ROOT.parent / "modules").rglob("*.luau")):
            with self.subTest(path=path):
                for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                    self.assertFalse(
                        line[:1].isspace() and re.fullmatch(r"\s+--\s+[A-Za-z][A-Za-z0-9_/-]*\s*", line),
                        f"seção aninhada em {path}:{line_number}",
                    )

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
