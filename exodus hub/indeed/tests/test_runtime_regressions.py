"""Static checks for regressions found during the runtime audit."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


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


if __name__ == "__main__":
    unittest.main()
