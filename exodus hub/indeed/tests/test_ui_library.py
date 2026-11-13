"""UI independence and end-to-end adapter regressions."""
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'modules/front/ui.luau'
CONFIG = ROOT / 'modules/front/config.luau'

class UILibraryTests(unittest.TestCase):
    def test_library_has_no_hub_dependencies(self):
        source = UI.read_text()
        for forbidden in ('Exodus', 'AutoSpam', 'AutoParry', 'GameInfo', 'Dumper', 'Utils', '_G.'):
            self.assertNotIn(forbidden, source)
        self.assertRegex(source, r'requires\s*=\s*\{\s*\}')

    def test_configuration_does_not_implement_widgets(self):
        source = CONFIG.read_text()
        for forbidden in ('Instance.new', 'UILib.create', 'createToggleCard', 'TextButton', 'TextLabel', 'CanvasGroup', 'TweenService'):
            self.assertNotIn(forbidden, source)
        self.assertIn('ui.new({', source)
        self.assertIn('onChange', source)

    def test_single_hub_configuration_and_manifest(self):
        front = ROOT / 'modules/front'
        self.assertEqual(sorted(p.name for p in front.glob('*.luau')), ['config.luau', 'ui.luau'])
        loader = (ROOT / 'loader.luau').read_text()
        self.assertNotIn('uiconfig', loader)
        self.assertNotIn('exodusui', loader)
        self.assertIn('local interface = loaded.config', loader)
        self.assertIn('resolve("config", loaded)', loader)

    def test_components_and_hub_runtime(self):
        runtime = shutil.which('texlua')
        if runtime is None:
            self.skipTest('texlua is unavailable; structural checks still run')
        harness = Path(__file__).with_name('ui_runtime.lua')
        result = subprocess.run([runtime, str(harness)], cwd=ROOT.parent, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('UI runtime:', result.stdout)

if __name__ == '__main__':
    unittest.main()
