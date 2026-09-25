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
function UIConfig.setup() return true end
UIConfig.__contract = {
	requires = {},
}

return UIConfig
