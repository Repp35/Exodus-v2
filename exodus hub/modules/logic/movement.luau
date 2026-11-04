-- [[ movement ]]

local Movement = {}
local Utils, GameInfo
local connection
local generation = 0

local function disconnect()
    if not connection then return end
    if Utils then Utils.untrackGlobal(connection) end
    connection:Disconnect()
    connection = nil
end

function Movement.syncJump()
    generation += 1
    disconnect()

    if not Utils or not Utils.isActive() or Utils.getConfigValue("AutoJump") ~= true then
        return true
    end

    local player = Utils.getLocalPlayer()
    local service = Utils.getRunService()
    if not player or not service or not service.Heartbeat then
        return false, "Jogador ou Heartbeat indisponível"
    end

    local current = generation
    local character, humanoid

    connection = service.Heartbeat:Connect(function()
        if current ~= generation or not Utils.isActive() or Utils.getConfigValue("AutoJump") ~= true then
            return
        end

        if character ~= player.Character then
            character = player.Character
            humanoid = nil
        end

        if not character or not character.Parent then return end
        if humanoid and humanoid.Parent ~= character then humanoid = nil end
        humanoid = humanoid or character:FindFirstChildOfClass("Humanoid")

        if humanoid and humanoid.Health > 0 and humanoid.FloorMaterial ~= Enum.Material.Air
            and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)

    Utils.trackGlobal(connection)
    return true
end

function Movement.upDash()
    if not Utils or not GameInfo or not Utils.isActive() then return false, "Hub inativo" end

    local dash = GameInfo.getDashAbility()
    if not dash then return false, "Dash não está equipada ou ainda não carregou" end
    if dash.Dashing then return false, "Dash já está em andamento" end

    local ok, err = pcall(dash.Dash, dash)
    if not ok then return false, tostring(err) end
    if not dash.Dashing then return false, "Dash indisponível ou em cooldown" end

    dash.MoveDir = Vector3.new(0, 1, 0)
    return true
end

function Movement.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then
        return false, "dependências ausentes: Utils ou GameInfo"
    end

    Utils, GameInfo = deps.Utils, deps.GameInfo
    return Movement.syncJump()
end

function Movement.teardown()
    generation += 1
    disconnect()
    Utils, GameInfo = nil, nil
end

Movement.__contract = {
    requires = {Utils = "utils", GameInfo = "gameinfo"},
    requiresMethods = {
        Utils = {"getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive"},
        GameInfo = {"getDashAbility"},
    },
    provides = {"setup", "syncJump", "upDash", "teardown"},
}

return Movement
