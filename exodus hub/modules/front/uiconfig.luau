-- [[ uiconfig ]]

local UIConfig = {}

-- config
UIConfig.panelToggles = {
	{
		kind = "toggle",
		label = "Auto Parry",
		key = "AutoParry",
	},
	{
		kind = "toggle",
		label = "Mini Parry UI",
		key = "ParryBallVisible",
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
UIConfig.__config = {
	schema = {
		AutoParry = "boolean",
		AutoParryWindowFactor = "rate",
		CameraSensitivity = "rate",
		ParryBallVisible = "boolean",
		ParryBallX = "position",
		ParryBallY = "position",
		AutoSpam = "boolean",
		AutoDark = "boolean",
		AutoFierce = "boolean",
		AutoJump = "boolean",
		AutoClashUpDash = "boolean",
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
		CameraSensitivity = 1,
		ParryBallVisible = false,
		AutoSpam = true,
		AutoDark = false,
		AutoFierce = false,
		AutoJump = false,
		AutoClashUpDash = false,
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
