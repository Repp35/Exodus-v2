"""Static checks for regressions found during the runtime audit."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPO = ROOT.parent


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class RuntimeRegressionTests(unittest.TestCase):
    def test_loader_has_no_unresolved_branch_fallback(self):
        loader = read("loader.luau")
        self.assertNotRegex(loader, r"\bBRANCH\b")
        self.assertIn('document.schema == 1', loader)
        self.assertIn('document.product == "Exodus-v2"', loader)

    def test_packet_ordering_is_owned_by_gameinfo(self):
        loader = read("loader.luau")
        gameinfo = read("modules/logic/gameinfo.luau")
        self.assertIn('type(gameInfo.applyPacket) ~= "function"', loader)
        self.assertIn("pcall(gameInfo.applyPacket, packet)", loader)
        self.assertRegex(gameinfo, r"function GameInfo\.applyPacket\(value\)")

    def test_ui_declares_all_animation_styles_it_uses(self):
        ui = read("modules/front/ui.luau")
        self.assertRegex(ui, r"local EASE_OUT, EASE_SINE, EASE_BACK\s*=")
        self.assertIn("EASE_BACK", ui)

    def test_autodark_is_limited_to_its_useful_tick(self):
        autodark = read("modules/logic/extras/autodark.luau")
        self.assertIn("nextFireAt", autodark)
        self.assertIn("now + 1 / 60", autodark)

    def test_window_factor_uses_a_dedicated_bounded_validator(self):
        config = read("modules/front/config.luau")
        ui_config = read("modules/front/uiconfig.luau")
        self.assertIn("windowFactor = function", config)
        self.assertIn('AutoParryWindowFactor = "windowFactor"', ui_config)

    def test_ui_waits_for_close_tweens_before_stopping(self):
        ui = read("modules/front/ui.luau")
        close = ui[ui.index("local function animateClose"):ui.index("-- setup")]
        self.assertIn("createTweenGroup()", close)
        self.assertIn("waitForCompletion()", close)
        self.assertNotIn("task.delay(0.32", close)
        self.assertIn("tween.Completed:Connect", ui)

    def test_ui_uses_shared_motion_and_atomic_page_transitions(self):
        ui = read("modules/front/ui.luau")
        self.assertIn("reducedMotion = false", ui)
        self.assertIn("local PAGE_HEAD_H = CONFIG.PAGE_HEAD_H", ui)
        self.assertIn("local playTween, _, onComplete = createTweenGroup()", ui)
        self.assertNotIn("task.delay(0.5, finish)", ui)
        self.assertNotIn("task.delay(0.3, function()", ui)

    def test_readme_is_the_immutable_original_and_release_doc_is_gone(self):
        self.assertEqual((REPO / "README.md").read_text(encoding="utf-8"), "# Lá vem o kiddie")
        self.assertFalse((REPO / "docs" / "PROTECTED_RELEASE.md").exists())
        self.assertIn("README.md", (REPO / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertIn("README.md", (REPO / "docs" / "UI.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
