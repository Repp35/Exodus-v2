-- [[ uiconfig ]]

local UIConfig = {}
UIConfig.panelToggles = {
	{
		kind = "toggle",
		label = "Auto Parry",
		key = "AutoParry",
	},
	{
		kind = "toggle",
		label = "Auto Clash",
		key = "AutoClash",
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
		AutoClash = "boolean",
		AutoDark = "boolean",
		AutoJump = "boolean",
		AutoFierceDeflect = "boolean",
		AutoClashActivationMs = "delayMs",
		AutoClashDeactivationMs = "delayMs",
		ClashBallVisible = "boolean",
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
		AutoClash = true,
		AutoDark = false,
		AutoJump = false,
		AutoFierceDeflect = false,
		AutoClashActivationMs = 180,
		AutoClashDeactivationMs = 130,
		ClashBallVisible = false,
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
UIConfig.__contract = {
	provides = {},
	requires = {},
}

return UIConfig
