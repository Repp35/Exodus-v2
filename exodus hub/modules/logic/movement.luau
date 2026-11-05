local Movement = {}
local utils, gameInfo, jumpConnection
local epoch = 0

local function stopJump()
    epoch += 1
    if jumpConnection then
        if utils then utils.untrackGlobal(jumpConnection) end
        jumpConnection:Disconnect()
        jumpConnection = nil
    end
end

function Movement.syncJump()
    stopJump()
    if not utils or not utils.isActive() or utils.getConfigValue("AutoJump") ~= true then return true end
    local player, runService = utils.getLocalPlayer(), utils.getRunService()
    if not player or not runService or not runService.Heartbeat then return false, "Jogador ou Heartbeat indisponível" end
    local current = epoch
    local character, humanoid
    jumpConnection = runService.Heartbeat:Connect(function()
        if current ~= epoch or not utils.isActive() or utils.getConfigValue("AutoJump") ~= true then return end
        if character ~= player.Character or (humanoid and humanoid.Parent ~= character) then
            character, humanoid = player.Character, nil
        end
        if not character or not character.Parent then return end
        humanoid = humanoid or character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 and humanoid.FloorMaterial ~= Enum.Material.Air
            and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)
    utils.trackGlobal(jumpConnection)
    return true
end

function Movement.upDash()
    if not utils or not gameInfo or not utils.isActive() then return false, "Hub inativo" end
    local ability = gameInfo.getDashAbility()
    if not ability then return false, "Dash não está equipada ou ainda não carregou" end
    if ability.Dashing then return false, "Dash já está em andamento" end
    local ok, err = pcall(ability.Dash, ability)
    if not ok then return false, tostring(err) end
    if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
    ability.MoveDir = Vector3.new(0, 1, 0)
    return true
end

function Movement.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then
        return false, "dependências ausentes: Utils ou GameInfo"
    end
    stopJump()
    utils, gameInfo = deps.Utils, deps.GameInfo
    return Movement.syncJump()
end
function Movement.teardown()
    stopJump()
    utils, gameInfo = nil, nil
end
Movement.__contract = {
    requires = { Utils = "utils", GameInfo = "gameinfo" },
    requiresMethods = {
        Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive" },
        GameInfo = { "getDashAbility" },
    },
    provides = { "setup", "syncJump", "upDash", "teardown" },
}
return Movement
