-- [[ Scheduler ]]
-- CPF e CPS usando o mesmo acumulador temporal.

local Scheduler = {}

local EPSILON = 1e-7
local TARGET_FPS = 60

local accumulator = 0
local generation = 0

local function reset()
    generation += 1
    accumulator = 0
end

local function addRate(rate, dt)
    if type(rate) ~= "number"
        or type(dt) ~= "number"
        or rate <= 0
        or dt <= 0
        or rate ~= rate
        or dt ~= dt
        or rate == math.huge
        or dt == math.huge
    then
        return 0
    end

    accumulator += rate * dt

    local count = math.floor(accumulator + EPSILON)
    accumulator -= count

    return count
end

-- CPF:
-- 1 CPF = 1 ação por frame a 60 FPS.
-- Portanto:
-- 60 CPF = 60 ações/s
-- 30 CPF = 30 ações/s
-- etc.
local function stepCPF(cpf, dt)
    return addRate(cpf, dt)
end

-- CPS:
-- X CPS = X ações por segundo.
local function stepCPS(cps, dt)
    return addRate(cps, dt)
end

-- Distribui N ações uniformemente no intervalo.
--
-- callback(index, total, normalizedPosition)
--
-- normalizedPosition fica entre 0 e 1 e representa
-- onde a ação deveria ficar dentro daquele intervalo.
local function distribute(total, callback)
    if total <= 0 or type(callback) ~= "function" then
        return 0
    end

    local currentGeneration = generation

    for index = 1, total do
        if currentGeneration ~= generation then
            break
        end

        local position = (index - 0.5) / total

        callback(index, total, position)
    end

    return total
end

function Scheduler.step(mode, rate, dt, callback)
    local count

    if mode == "CPS" then
        count = stepCPS(rate, dt)
    else
        count = stepCPF(rate, dt)
    end

    return distribute(count, callback)
end

function Scheduler.reset()
    reset()
end

function Scheduler.invalidate()
    generation += 1
    accumulator = 0
end

function Scheduler.getAccumulator()
    return accumulator
end

return Scheduler