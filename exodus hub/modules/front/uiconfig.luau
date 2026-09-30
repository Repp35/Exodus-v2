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
		label = "Dynamic Parry",
		key = "DynamicParry",
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
		AutoParry = "boolean", AutoClash = "boolean", DynamicParry = "boolean", ClashBallVisible = "boolean",
		DynamicParryReleaseDelay = "delay", CPS = "rate", CPF = "rate", SpamRateMode = "rateMode",
		Keybind = "keyCode", SpamKeybind = "keyCode", SpamMode = "spamMode",
		BtnX = "position", BtnY = "position", ClashBallX = "position", ClashBallY = "position",
		MiniX = "position", MiniY = "position", DynamicParryX = "position", DynamicParryY = "position",
		PanelX = "position", PanelY = "position",
	},

	defaults = {
		AutoParry = true, AutoClash = true, DynamicParry = false, ClashBallVisible = false,
		DynamicParryReleaseDelay = 0.2, CPS = 23.5, CPF = 0.3917, SpamRateMode = "CPS",
		Keybind = Enum.KeyCode.F9, SpamKeybind = Enum.KeyCode.F, SpamMode = "Toggle",
	},

}
UIConfig.__contract = {
	requires = {},
}

return UIConfig
