-- [[ uiconfig ]]

local UIConfig = {}
-- panel toggles
UIConfig.panelToggles = {
	{
		kind = "toggle",
		label = "Auto Parry",
		key = "AutoParry",
	},
	{
		kind = "toggle",
		label = "Auto Spam",
		key = "AutoSpam",
	},
	{
		kind = "toggle",
		label = "Mini Clash UI",
		key = "ClashBallVisible",
	},
}
-- panel components
UIConfig.panelComponents = {
	{
		kind = "rate_selector",
	},
	{
		kind = "keybind_selector",
	},
	{
		kind = "manual_spam",
	},
}
-- config schema and defaults
UIConfig.__config = {
	schema = {
		AutoParry = "boolean",
		AutoParryWindowFactor = "rate",
		AutoSpam = "boolean",
		AutoDark = "boolean",
		AutoJump = "boolean",
		ClashBallVisible = "boolean",
		MiniSpamVisible = "boolean",
		DarkBallVisible = "boolean",
		JumpBallVisible = "boolean",
		UpDashBallVisible = "boolean",
		CPS = "rate",
		CPF = "rate",
		SpamRateMode = "rateMode",
		Keybind = "keyCode",
		SpamKeybind = "keyCode",
		BtnX = "position",
		BtnY = "position",
		ClashBallX = "position",
		ClashBallY = "position",
		DarkBallX = "position",
		DarkBallY = "position",
		JumpBallX = "position",
		JumpBallY = "position",
		UpDashBallX = "position",
		UpDashBallY = "position",
		MiniX = "position",
		MiniY = "position",
		PanelX = "position",
		PanelY = "position",
	},

	defaults = {
		AutoParry = true,
		AutoParryWindowFactor = 0.5,
		AutoSpam = true,
		AutoDark = false,
		AutoJump = false,
		ClashBallVisible = false,
		MiniSpamVisible = false,
		DarkBallVisible = false,
		JumpBallVisible = false,
		UpDashBallVisible = false,
		CPS = 24,
		CPF = 0.36,
		SpamRateMode = "CPF",
		Keybind = Enum.KeyCode.F9,
		SpamKeybind = Enum.KeyCode.F,
	},

}
-- contract
UIConfig.__contract = {
	provides = {},
	requires = {},
}

return UIConfig
