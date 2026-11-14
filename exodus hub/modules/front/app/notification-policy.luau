-- [[ uinotifications ]]

-- module
local Notifications = {}

-- configuration
local CONFIG = { SILENT_TOPICS = { manualSpam = true, upDash = true } }

-- setup
function Notifications.setup() return true end

-- policy
function Notifications.shouldShow(config, desktop, event)
  event = event or {}
  if event.category == "critical" or event.category == "lifecycle" then return true end
  if event.topic and CONFIG.SILENT_TOPICS[event.topic] then return false end
  local enabled = config[desktop and "DesktopNotifications" or "MobileNotifications"] == true
  if not enabled then return false end
  if event.category == "system" then return true end
  return desktop and event.category == "shortcut" and config.DesktopShortcutNotifications == true
end

-- contract
Notifications.__contract = { provides = { "setup", "shouldShow" }, requires = {} }

return Notifications
