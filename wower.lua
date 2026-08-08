--[[
    Combined Boulder + Crystal Bot
    Professional refactor — identical behavior, cleaner structure & UI

    Master toggle: X key or GUI button
    Sequence when master is ON:
      1. Destroy allowed boulders
      2. Delete low-tier crystals + unprotected runes
      3. Collect high-tier (mutated) crystals
      4. Collect protected runes
      5. Auto Sort (if enabled)
      6. Sell All Crystals (if enabled)
      7. Auto Buy Bombs (if enabled)

    Config persistence:
      Uses executor filesystem (writefile / readfile) so settings
      survive script reloads, early exits, and rejoinGame().
      File: BoulderCrystalBot/config.json  (own folder, not next to script)
]]

-- ====================== INFINITE YIELD ======================
loadstring(game:HttpGetAsync("https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source"))()

-- ====================== CONFIG ======================
local CONFIG = {
    masterEnabledDefault   = true,
    autoSortEnabledDefault = true,
    sellAllEnabledDefault  = true,
    bombBuyEnabledDefault  = true,

    TOOL_NAME              = "The Terminus",
    DIG_RANGE              = 10000,
    TWEEN_SPEED            = 300,
    FLY_HEIGHT             = 10,
    SPAM_DELAY             = 0.01,
    BURST_SIZE             = 50,
    DIG_INTERVAL           = 0.05,
    TIMEOUT_PER_BOULDER    = 90,
    NOCLIP_ENABLED         = true,
    SCAN_TELEPORT_POS      = Vector3.new(-38.815575, 300, 300),
    REJOIN_COOLDOWN        = 60,
    VERBOSE                = true,

    requireMutationDefault = true,

    sizeFiltersDefault = {
        S         = false,
        M         = false,
        L         = false,
        XL        = true,
        Giant     = true,
        Colossal  = true,
        Titan     = true,
        Leviathan = true,
        Behemoth  = true,
    },

    tierFiltersDefault = {
        [1] = false,
        [2] = false,
        [3] = false,
        [4] = false,
        [5] = false,
        [6] = false,
        [7] = true,
        [8] = true,
        [9] = true,
    },

    runeFiltersDefault = {
        ["Luck Rune"]         = false,
        ["Haste Rune"]        = false,
        ["Storm Rune"]        = false,
        ["Weight Rune"]       = false,
        ["Fortune Rune"]      = false,
        ["Detonation Rune"]   = false,
        ["Preservation Rune"] = true,
        ["Warmth Rune"]       = false,
        ["Excavator Rune"]    = false,
        ["Colossus Rune"]     = true,
    },

    boulderFiltersDefault = {
        Mossite    = false,
        Voltite    = false,
        Gildrite   = true,
        Rimeveil   = true,
        Nocturnite = true,
    },
    
    bombQuantitiesDefault = {
        ["Classic Bomb"]  = 0,
        ["Wind Bomb"]     = 0,
        ["Ice Bomb"]      = 0,
        ["Fire Bomb"]     = 0,
        ["Thunder Bomb"]  = 0,
        ["Poison Bomb"]   = 4,
        ["Time Bomb"]     = 0,
        ["Agony Bomb"]    = 2,
    },
}

local PRIORITY = {
    Nocturnite = 3,
    Rimeveil   = 2,
    Gildrite   = 1,
    Mossite    = 0,
    Voltite    = 0,
}

-- Internal server names for BombBuyRequest
local BOMB_SERVER_NAMES = {
    ["Classic Bomb"]  = "ClassicBomb",
    ["Wind Bomb"]     = "WindBomb",
    ["Ice Bomb"]      = "IceBomb",
    ["Fire Bomb"]     = "FireBomb",
    ["Thunder Bomb"]  = "ThunderBomb",
    ["Poison Bomb"]   = "PoisonBomb",
    ["Time Bomb"]     = "TimeBomb",
    ["Agony Bomb"]    = "AgonyBomb",
}

-- ====================== SERVICES ======================
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local Workspace          = game:GetService("Workspace")
local VirtualInputManager= game:GetService("VirtualInputManager")
local CoreGui            = game:GetService("CoreGui")
local HttpService        = game:GetService("HttpService")

local player = Players.LocalPlayer
while not player do
    player = Players.LocalPlayer
    task.wait()
end

if _G.CombinedBoulderCrystalRunning then
    warn("[Bot] Already running. Close the existing GUI first.")
    return
end
_G.CombinedBoulderCrystalRunning = true



-- ====================== VOID RESCUE BLOCK ======================
local mt = getrawmetatable(game)
local oldNamecall = mt.__namecall
local voidBlockActive = false

local function enableVoidRescueBlock()
    if voidBlockActive then return end
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if method == "FireServer" and self.Name == "VoidRescue" then
            return
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
    voidBlockActive = true
    -- print("VoidRescue blocked")
end

local function disableVoidRescueBlock()
    if not voidBlockActive then return end
    setreadonly(mt, false)
    mt.__namecall = oldNamecall
    setreadonly(mt, true)
    voidBlockActive = false
    -- print("VoidRescue unblocked")
end

-- ====================== STATE ======================
local state = {
    masterEnabled      = CONFIG.masterEnabledDefault,
    autoSortEnabled    = CONFIG.autoSortEnabledDefault,
    sellAllEnabled     = CONFIG.sellAllEnabledDefault,
    bombBuyEnabled     = CONFIG.bombBuyEnabledDefault,
    stopScript         = false,
    toolReady          = false,
    isProcessingBoulder= false,
    isTweening         = false,
    flying             = false,
    noclipActive       = false,
    digCount           = 0,
    lastDigTime        = 0,
    lastRejoinTime     = 0,
    currentTarget      = nil,
    currentTween       = nil,
    firstBoulderScan   = true,

    sizeFilters        = table.clone(CONFIG.sizeFiltersDefault),
    tierFilters        = table.clone(CONFIG.tierFiltersDefault),
    requireMutation    = CONFIG.requireMutationDefault,
    runeFilters        = table.clone(CONFIG.runeFiltersDefault),
    boulderFilters     = table.clone(CONFIG.boulderFiltersDefault),
    bombQuantities     = table.clone(CONFIG.bombQuantitiesDefault),
}

-- ====================== FILE PERSISTENCE (executor filesystem) ======================
-- Saves filters / toggles / bomb quantities across script reloads & rejoins.
-- Uses writefile / readfile (supported by virtually all modern executors).
-- Config lives inside its own folder (not next to the main script).
-- Falls back gracefully if the executor does not expose the file API.
local CONFIG_FOLDER = "mamScript"
local CONFIG_FILE   = CONFIG_FOLDER .. "/config.json"
local lastSaveTime  = 0
local SAVE_COOLDOWN = 0.8 -- light throttle so rapid GUI clicks don't spam disk

local function hasFileAPI()
    return typeof(writefile) == "function"
        and typeof(readfile) == "function"
        and typeof(isfile) == "function"
end

local function ensureConfigFolder()
    if typeof(isfolder) == "function" and typeof(makefolder) == "function" then
        if not isfolder(CONFIG_FOLDER) then
            pcall(makefolder, CONFIG_FOLDER)
        end
    end
end

local function buildSaveTable()
    return {
        autoSortEnabled  = state.autoSortEnabled,
        sellAllEnabled   = state.sellAllEnabled,
        bombBuyEnabled   = state.bombBuyEnabled,
        requireMutation  = state.requireMutation,
        sizeFilters      = state.sizeFilters,
        tierFilters      = state.tierFilters,
        runeFilters      = state.runeFilters,
        boulderFilters   = state.boulderFilters,
        bombQuantities   = state.bombQuantities,
    }
end

local function applyLoadedConfig(data)
    if type(data) ~= "table" then return false end

    if type(data.autoSortEnabled) == "boolean" then
        state.autoSortEnabled = data.autoSortEnabled
    end
    if type(data.sellAllEnabled) == "boolean" then
        state.sellAllEnabled = data.sellAllEnabled
    end
    if type(data.bombBuyEnabled) == "boolean" then
        state.bombBuyEnabled = data.bombBuyEnabled
    end
    if type(data.requireMutation) == "boolean" then
        state.requireMutation = data.requireMutation
    end

    if type(data.sizeFilters) == "table" then
        for k, v in pairs(data.sizeFilters) do
            if state.sizeFilters[k] ~= nil and type(v) == "boolean" then
                state.sizeFilters[k] = v
            end
        end
    end
    if type(data.tierFilters) == "table" then
        for k, v in pairs(data.tierFilters) do
            local numKey = tonumber(k) or k
            if state.tierFilters[numKey] ~= nil and type(v) == "boolean" then
                state.tierFilters[numKey] = v
            end
        end
    end
    if type(data.runeFilters) == "table" then
        for k, v in pairs(data.runeFilters) do
            if state.runeFilters[k] ~= nil and type(v) == "boolean" then
                state.runeFilters[k] = v
            end
        end
    end
    if type(data.boulderFilters) == "table" then
        for k, v in pairs(data.boulderFilters) do
            if state.boulderFilters[k] ~= nil and type(v) == "boolean" then
                state.boulderFilters[k] = v
            end
        end
    end
    if type(data.bombQuantities) == "table" then
        for k, v in pairs(data.bombQuantities) do
            if state.bombQuantities[k] ~= nil then
                local n = tonumber(v)
                if n and n >= 0 then
                    state.bombQuantities[k] = math.floor(n)
                end
            end
        end
    end
    return true
end

local function loadConfig()
    if not hasFileAPI() then
        warn("[Bot] Executor file API not available – using defaults.")
        return false
    end
    ensureConfigFolder()
    local ok, raw = pcall(function()
        if isfile(CONFIG_FILE) then
            return readfile(CONFIG_FILE)
        end
        return nil
    end)
    if not ok or not raw or raw == "" then
        return false
    end
    local decodeOk, data = pcall(function()
        return HttpService:JSONDecode(raw)
    end)
    if decodeOk and applyLoadedConfig(data) then
        print("[Bot] Config loaded from file:", CONFIG_FILE)
        return true
    end
    warn("[Bot] Failed to parse config file – using defaults.")
    return false
end

local function saveConfig(force)
    if not hasFileAPI() then return end
    if state.stopScript and not force then return end
    if not force and (tick() - lastSaveTime) < SAVE_COOLDOWN then
        return
    end
    ensureConfigFolder()
    local payload = buildSaveTable()
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if not ok or not encoded then
        warn("[Bot] Failed to encode config for save.")
        return
    end
    local writeOk, err = pcall(function()
        writefile(CONFIG_FILE, encoded)
    end)
    if writeOk then
        lastSaveTime = tick()
        if CONFIG.VERBOSE then
            -- print("[Bot] Config saved to file:", CONFIG_FILE)
        end
    else
        warn("[Bot] Failed to write config file:", err)
    end
end

local character, hrp, humanoid
local originalCollideStates = {}
local boulderQueue = {}
local digEvent

local ZERO_VECTOR = Vector3.zero
local Y_AXIS      = Vector3.yAxis

-- Cached config values
local TOOL_NAME           = CONFIG.TOOL_NAME
local FLY_HEIGHT          = CONFIG.FLY_HEIGHT
local BURST_SIZE          = CONFIG.BURST_SIZE
local SPAM_DELAY          = CONFIG.SPAM_DELAY
local DIG_INTERVAL        = CONFIG.DIG_INTERVAL
local TIMEOUT_PER_BOULDER = CONFIG.TIMEOUT_PER_BOULDER
local SCAN_POS            = CONFIG.SCAN_TELEPORT_POS
local REJOIN_COOLDOWN     = CONFIG.REJOIN_COOLDOWN
local TWEEN_SPEED         = CONFIG.TWEEN_SPEED

-- ====================== RUNE HELPERS ======================
local function normalizeRuneName(name)
    if not name then return "" end
    name = tostring(name):lower()
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("%s*%(.*%)%s*$", "")
        :gsub("%s*enchant%s*", " ")
        :gsub("%s+", " ")
    return name
end

local RUNE_LOOKUP = {}

local function rebuildRuneLookup()
    table.clear(RUNE_LOOKUP)
    for fullName, enabled in pairs(state.runeFilters) do
        if enabled then
            local norm = normalizeRuneName(fullName)
            RUNE_LOOKUP[norm] = true
            local short = norm:gsub("%s*rune%s*", ""):gsub("%s+", "")
            if #short > 0 then
                RUNE_LOOKUP[short] = true
            end
        end
    end
end

local function isProtectedRune(obj)
    if not obj then return false end

    local candidates = { obj.Name }
    local attrs = {
        obj:GetAttribute("RuneName"),
        obj:GetAttribute("Name"),
        obj:GetAttribute("Rune"),
        obj:GetAttribute("Type"),
        obj:GetAttribute("ItemName"),
    }
    for _, a in ipairs(attrs) do
        if a then
            candidates[#candidates + 1] = tostring(a)
        end
    end

    for _, n in ipairs(candidates) do
        local norm = normalizeRuneName(n)
        if RUNE_LOOKUP[norm] then return true end
        for key in pairs(RUNE_LOOKUP) do
            if norm:find(key, 1, true) then
                return true
            end
        end
    end
    return false
end

-- Load persisted settings (must happen after state + rune helpers exist)
loadConfig()
rebuildRuneLookup() -- rebuild so loaded runeFilters take effect

-- ====================== UTILITIES ======================
local function log(...)
    if CONFIG.VERBOSE then
        print("[Bot]", ...)
    end
end

local function rejoinGame()
    -- Always persist config before we leave the server
    pcall(function()
        saveConfig(true)
    end)

    local function findIYTextBox()
        local containers = { CoreGui }
        if typeof(gethui) == "function" then
            containers[2] = gethui()
        end
        for _, container in ipairs(containers) do
            for _, gui in ipairs(container:GetDescendants()) do
                if gui:IsA("TextBox") then
                    local ph = gui.PlaceholderText or ""
                    if ph == "Command Bar (;)" or ph:find("Command", 1, true) then
                        return gui
                    end
                end
            end
        end
        return nil
    end

    while true do
        local iyBox = findIYTextBox()

        if iyBox then
            log("IY command bar found – sending rejoin...")
            iyBox:CaptureFocus()
            iyBox.Text = "rj"
            task.wait(0.12)
            -- pcall(firesignal, iyBox.FocusLost, true)  -- true = Enter was pressed
            -- pcall(firesignal, iyBox.FocusLost, true, Enum.UserInputType.Keyboard)

            -- Press Enter
            local vim = game:GetService("VirtualInputManager")
            vim:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
            task.wait()
            vim:SendKeyEvent(false, Enum.KeyCode.Return, false, game)

            log("Rejoin command sent.")
        else
            log("IY command bar not found – cannot auto-rejoin.")
        end
        task.wait(2)
    end
    
end

local function waitForCharacter()
    if not player.Character then
        player.CharacterAdded:Wait()
    end
    character = player.Character
    hrp      = character:WaitForChild("HumanoidRootPart", 30)
    humanoid  = character:WaitForChild("Humanoid", 30)
    return character, hrp, humanoid
end

-- ====================== TOOL EQUIP ======================
local function isToolEquipped()
    return character and character:FindFirstChild(TOOL_NAME) ~= nil
end

local function findTool()
    if character then
        local t = character:FindFirstChild(TOOL_NAME)
        if t and t:IsA("Tool") then return t end
    end
    local bp = player:FindFirstChild("Backpack")
    if bp then
        local t = bp:FindFirstChild(TOOL_NAME)
        if t and t:IsA("Tool") then return t end
    end
    return nil
end

local function equipTool()
    if not character or not humanoid or humanoid.Health <= 0 then
        return false
    end
    if isToolEquipped() then return true end

    pcall(function()
        local Event = ReplicatedStorage.Remotes.ShopEquip
        Event:FireServer("TheTerminus")
    end)

    task.wait(0.1)

    local tool = findTool()
    if not tool then return false end

    local current = character:FindFirstChildOfClass("Tool")
    if current and current ~= tool then
        humanoid:UnequipTools()
        task.wait(0.1)
    end

    tool.Parent = character

    pcall(function()
        humanoid:EquipTool(tool)
    end)

    task.wait(0.1)

    return isToolEquipped()
end

local lastToolLog = 0

local function checkIfToolEquipped()
    if isToolEquipped() then
        state.toolReady = true
        return true
    end

    local attempts = 0
    local maxAttempts = 30
    while not state.stopScript and attempts < maxAttempts do
        attempts += 1
        if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
            waitForCharacter()
            task.wait(0.25)
        end
        if equipTool() then
            state.toolReady = true
            log(TOOL_NAME, "equipped.")
            return true
        end
        if tick() - lastToolLog > 3 then
            log("Waiting for", TOOL_NAME, "...")
            lastToolLog = tick()
        end
        task.wait(0.35)
    end

    state.toolReady = false

    warn("Failed to equip", TOOL_NAME)
    rejoinGame()
end

-- ====================== FLY / NOCLIP ======================
local linearVelocity: LinearVelocity? = nil
local alignOrientation: AlignOrientation? = nil
local flyAttachment: Attachment? = nil

local function enableNoclip()
    if state.noclipActive or not character then return end
    table.clear(originalCollideStates)
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            originalCollideStates[part] = part.CanCollide
            part.CanCollide = false
        end
    end
    state.noclipActive = true
end

local function disableNoclip()
    if not state.noclipActive then return end
    for part, canCollide in pairs(originalCollideStates) do
        if part and part.Parent then
            part.CanCollide = canCollide
        end
    end
    table.clear(originalCollideStates)
    state.noclipActive = false
end

local function enableFly()
    if state.flying or not hrp or not humanoid then return end

    humanoid.PlatformStand = true
    humanoid.AutoRotate = false

    flyAttachment = Instance.new("Attachment")
    flyAttachment.Name = "FlyAttachment"
    flyAttachment.Parent = hrp

    linearVelocity = Instance.new("LinearVelocity")
    linearVelocity.MaxForce = math.huge
    linearVelocity.VectorVelocity = ZERO_VECTOR
    linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    linearVelocity.Attachment0 = flyAttachment
    linearVelocity.Parent = hrp

    alignOrientation = Instance.new("AlignOrientation")
    alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    alignOrientation.MaxTorque = math.huge
    alignOrientation.Responsiveness = 40
    alignOrientation.Attachment0 = flyAttachment
    alignOrientation.Parent = hrp

    state.flying = true
end

local function disableFly()
    if not state.flying then return end

    if linearVelocity then linearVelocity:Destroy(); linearVelocity = nil end
    if alignOrientation then alignOrientation:Destroy(); alignOrientation = nil end
    if flyAttachment then flyAttachment:Destroy(); flyAttachment = nil end

    if humanoid then
        humanoid.PlatformStand = false
        humanoid.AutoRotate = true
        humanoid:ChangeState(Enum.HumanoidStateType.Running)
    end
    state.flying = false
end

local function updateFlyMovement()
    if not state.flying or not linearVelocity or not alignOrientation or not hrp then
        return
    end

    local cam = Workspace.CurrentCamera.CFrame
    local vel = ZERO_VECTOR
    local speed = 50

    if UserInputService:IsKeyDown(Enum.KeyCode.W) then vel += cam.LookVector * speed end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then vel -= cam.LookVector * speed end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then vel -= cam.RightVector * speed end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then vel += cam.RightVector * speed end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then vel += Y_AXIS * speed end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then vel -= Y_AXIS * speed end

    linearVelocity.VectorVelocity = vel
    alignOrientation.CFrame = cam
end

RunService.Heartbeat:Connect(updateFlyMovement)

-- ====================== TWEEN HELPERS ======================
local function cancelCurrentTween()
    if state.currentTween then
        state.currentTween:Cancel()
        state.currentTween = nil
    end
    state.isTweening = false
end

local function tweenTo(cframeOrPos, heightOffset)
    if not hrp or not hrp.Parent or state.isTweening then return false end

    cancelCurrentTween()
    state.isTweening = true

    local targetCF
    if typeof(cframeOrPos) == "CFrame" then
        targetCF = cframeOrPos
    else
        targetCF = CFrame.new(cframeOrPos + Vector3.new(0, heightOffset or 0, 0))
    end

    local distance = (hrp.Position - targetCF.Position).Magnitude
    local duration = math.max(distance / TWEEN_SPEED, 0.05)
    local info = TweenInfo.new(duration, Enum.EasingStyle.Linear)

    state.currentTween = TweenService:Create(hrp, info, { CFrame = targetCF })
    state.currentTween:Play()

    local start = tick()
    local deadline = duration + 1.5
    while state.currentTween and state.currentTween.PlaybackState == Enum.PlaybackState.Playing do
        if tick() - start > deadline then
            cancelCurrentTween()
            break
        end
        RunService.Heartbeat:Wait()
    end

    state.currentTween = nil
    state.isTweening = false
    return true
end

-- ====================== BOULDER LOGIC ======================
local function getBoulderPosition(model)
    if not model then return nil end
    local attach = model:FindFirstChild("Attachment") or model:FindFirstChild("Center")
    if attach then
        return attach:IsA("Attachment") and attach.WorldPosition or attach.Position
    end
    local part = model:FindFirstChildWhichIsA("BasePart")
    return part and part.Position or model:GetPivot().Position
end

local function isValidBoulder(model)
    return model and model.Parent and model:IsA("Model")
end

local function isBoulderFree(model)
    local pos = getBoulderPosition(model)
    if not pos then return false end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character then
            local otherHrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if otherHrp and (otherHrp.Position - pos).Magnitude < 35 then
                return false
            end
        end
    end
    return true
end

local function isAllowedBoulder(model)
    return model and state.boulderFilters[model.Name] == true and isBoulderFree(model)
end

local function continuousDig(boulder)
    if not isValidBoulder(boulder) or not digEvent then return false end
    local center = getBoulderPosition(boulder)
    if not center then return false end

    for i = 1, BURST_SIZE do
        if not isValidBoulder(boulder) then return true end
        local ok = pcall(digEvent.FireServer, digEvent, TOOL_NAME, center)
        if ok then
            state.digCount += 1
            state.lastDigTime = tick()
        end
        if i < BURST_SIZE then task.wait(SPAM_DELAY) end
    end
    return false
end

local function updateBoulderData()
    local data = {}
    local root = Workspace:FindFirstChild("MountainDecorations")
    if not root then return data end
    local folder = root:FindFirstChild("Boulders")
    if not folder then return data end

    for _, model in ipairs(folder:GetChildren()) do
        if model:IsA("Model") and isAllowedBoulder(model) then
            local pos = getBoulderPosition(model)
            if pos then
                data[#data + 1] = { model = model, position = pos, name = model.Name }
            end
        end
    end
    return data
end

local function scanAndBuildQueue()
    log("Scanning for boulders...")
    tweenTo(SCAN_POS)
    task.wait(2.25)

    local data = updateBoulderData()

    -- First scan only: wait up to 30s for boulders to appear, resume immediately when they do
    if #data == 0 and state.firstBoulderScan then
        log("First scan – waiting up to 30s for boulders to appear...")
        local waitStart = tick()
        while #data == 0 and (tick() - waitStart) < 30 and not state.stopScript and state.masterEnabled do
            task.wait(0.5)
            data = updateBoulderData()
            if #data > 0 then
                log("Boulders appeared after", string.format("%.1f", tick() - waitStart), "s – resuming.")
                break
            end
        end
        state.firstBoulderScan = false
    end

    if #data == 0 then
        log("No allowed boulders found.")
        return false
    end

    -- Mark first scan complete once we successfully find boulders
    state.firstBoulderScan = false

    local hrpPos = hrp and hrp.Position or ZERO_VECTOR
    table.sort(data, function(a, b)
        local pa = PRIORITY[a.name] or 0
        local pb = PRIORITY[b.name] or 0
        if pa ~= pb then return pa > pb end
        return (hrpPos - a.position).Magnitude < (hrpPos - b.position).Magnitude
    end)

    table.clear(boulderQueue)
    for i = 1, #data do
        boulderQueue[i] = data[i].model
    end

    log("Queued", #boulderQueue, "boulders.")
    return true
end

-- ====================== AUTO SORT + SELL + BUY BOMBS ======================
local function autoSort()
    if not state.autoSortEnabled or state.stopScript then return end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end

    local event = remotes:FindFirstChild("SortGarden")
    if event then
        local ok = pcall(function()
            event:FireServer("Luck", true)
        end)
        if ok then
            log("Auto Sort (Luck) fired")
            task.wait(0.5)
        end
    end
end

local function sellAllCrystals()
    if not state.sellAllEnabled or state.stopScript then return end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end

    local goHome = remotes:FindFirstChild("GoHome")
    if goHome then
        pcall(function() goHome:FireServer("sell") end)
    end
    task.wait(0.6)

    local sellReq = remotes:FindFirstChild("SellRequest")
    if sellReq then
        pcall(function() sellReq:FireServer("all") end)
        log("Sold all crystals")
    end
    task.wait(0.5)
end

local function buyBombs()
    if not state.bombBuyEnabled or state.stopScript then return end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end

    local event = remotes:FindFirstChild("BombBuyRequest")
    if not event then
        log("BombBuyRequest remote not found")
        return
    end

    local totalBought = 0
    for displayName, qty in pairs(state.bombQuantities) do
        local amount = tonumber(qty) or 0
        if amount > 0 then
            local serverName = BOMB_SERVER_NAMES[displayName]
            if serverName then
                for i = 1, amount do
                    if state.stopScript then break end
                    pcall(function()
                        event:InvokeServer(serverName)
                    end)
                    totalBought += 1
                    task.wait(0.08)
                end
                log("Bought", amount, "x", displayName)
            end
        end
    end

    if totalBought > 0 then
        log("Bomb buy finished. Total purchases:", totalBought)
        task.wait(0.3)
    else
        log("No bombs configured to buy (all quantities 0).")
    end
end

local function processBoulder(boulder)
    if not isValidBoulder(boulder) then return false end
    if not isAllowedBoulder(boulder) then
        log("Skipping boulder (not free / not allowed):", boulder.Name)
        return false
    end

    state.currentTarget = boulder
    local pos = getBoulderPosition(boulder)
    if not pos then
        state.currentTarget = nil
        return false
    end

    local name = boulder.Name
    log("Digging:", name)
    tweenTo(pos, FLY_HEIGHT)

    local destroyed = false
    local start = tick()
    local lastReposition = 0
    local deadline = TIMEOUT_PER_BOULDER

    while not destroyed and (tick() - start) < deadline do
        if state.stopScript or not state.masterEnabled then break end
        if not isValidBoulder(boulder) then
            destroyed = true
            break
        end
        if not isBoulderFree(boulder) then
            log("Aborting dig – another player is now near:", name)
            break
        end

        -- Ensure tool stays equipped during dig (prevents idle standing on boulder)
        if not isToolEquipped() then
            equipTool()
        end

        continuousDig(boulder)

        if not isValidBoulder(boulder) then
            destroyed = true
            break
        end

        local currentPos = getBoulderPosition(boulder)
        if currentPos and hrp and (currentPos - hrp.Position).Magnitude > 20
            and (tick() - lastReposition) > 3 then
            tweenTo(currentPos, FLY_HEIGHT)
            lastReposition = tick()
        end
        task.wait(DIG_INTERVAL)
    end

    state.currentTarget = nil
    log(destroyed and ("Destroyed: " .. name) or ("Timeout: " .. name))
    return destroyed
end

-- ====================== CRYSTAL LOGIC ======================
local MUTATION_KEYWORDS = {
    mutation = true, mutant = true, evolved = true, corrupt = true,
    blessed = true, cursed = true, radiant = true, shiny = true,
    glowing = true, altered = true, enhanced = true, warped = true,
    infused = true, charged = true,
}

local function getMutationType(crystal)
    local attr = crystal:GetAttribute("Mutation") or crystal:GetAttribute("MutationType")
    if attr then return tostring(attr) end
    if crystal:GetAttribute("HasMutation") == true or crystal:GetAttribute("Mutated") == true then
        return "Mutated"
    end
    for _, obj in ipairs(crystal:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextBox") then
            local text = (obj.Text or ""):lower()
            for kw in pairs(MUTATION_KEYWORDS) do
                if text:find(kw, 1, true) then return kw end
            end
        end
    end
    return nil
end

local function hasMutation(crystal)
    return getMutationType(crystal) ~= nil
end

local function getSizeClass(crystal)
    local attr = crystal:GetAttribute("SizeClass")
        or crystal:GetAttribute("Size")
        or crystal:GetAttribute("Class")
        or crystal:GetAttribute("ClassWeight")

    if attr then
        local s = tostring(attr):gsub("[%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 0 then
            local lower = s:lower()
            if lower == "xl" or lower == "x-large" then return "XL" end
            if lower == "giant"     then return "Giant" end
            if lower == "colossal"  then return "Colossal" end
            if lower == "titan"     then return "Titan" end
            if lower == "leviathan" then return "Leviathan" end
            if lower == "behemoth"  then return "Behemoth" end
            if lower == "s" or lower == "small"  then return "S" end
            if lower == "m" or lower == "medium" then return "M" end
            if lower == "l" or lower == "large"  then return "L" end
            return s:sub(1,1):upper() .. s:sub(2):lower()
        end
    end

    -- Fallback: WeightKg ranges
    local weight = tonumber(crystal:GetAttribute("WeightKg") or crystal:GetAttribute("Weight") or 0) or 0
    if weight < 8     then return "S"
    elseif weight < 30    then return "M"
    elseif weight < 90    then return "L"
    elseif weight < 200   then return "XL"
    elseif weight < 1000  then return "Giant"
    elseif weight < 3000  then return "Colossal"
    elseif weight < 8000  then return "Titan"
    elseif weight < 25000 then return "Leviathan"
    else return "Behemoth"
    end
end

local function isAllowedSizeClass(crystal)
    local sizeClass = getSizeClass(crystal)
    return sizeClass and state.sizeFilters[sizeClass] == true
end

local function isAllowedTier(crystal)
    local tier = crystal:GetAttribute("Tier")
    if tier ~= nil then
        local num = tonumber(tier)
        return num and state.tierFilters[num] == true
    end

    local name = (crystal.Name or ""):lower()
    for t = 1, 9 do
        if name:find("crystal_t" .. t, 1, true) and state.tierFilters[t] then
            return true
        end
    end
    return false
end

local function qualifiesForCollect(crystal)
    return isAllowedTier(crystal)
        and (not state.requireMutation or hasMutation(crystal))
        and isAllowedSizeClass(crystal)
end

local function shouldDelete(crystal)
    return not qualifiesForCollect(crystal)
end

local function hasQualifyingCollectibles()
    local crystalsFolder = Workspace:FindFirstChild("Things")
    crystalsFolder = crystalsFolder and crystalsFolder:FindFirstChild("Crystals")
    if crystalsFolder then
        for _, c in ipairs(crystalsFolder:GetChildren()) do
            if qualifiesForCollect(c) then return true end
        end
    end

    for _, obj in ipairs(Workspace:GetChildren()) do
        if isProtectedRune(obj) and obj.Parent then
            if obj:IsA("MeshPart") or obj:IsA("Model") or obj:IsA("BasePart") then
                return true
            end
        end
    end
    return false
end

local function destroyBoulders()
    if not state.masterEnabled or state.stopScript then return end
    if state.isProcessingBoulder then return end

    log("Starting boulder cycle.")
    if #boulderQueue == 0 then
        local found = scanAndBuildQueue()
        if not found then
            if not hasQualifyingCollectibles() then
                if (tick() - state.lastRejoinTime) > REJOIN_COOLDOWN then
                    log("No boulders and no qualified crystals/runes → rejoining")
                    state.lastRejoinTime = tick()
                    rejoinGame()
                else
                    log("Rejoin on cooldown.")
                end
            end
            return
        end
    end

    while #boulderQueue > 0 and state.masterEnabled and not state.stopScript do
        local nextBoulder = table.remove(boulderQueue, 1)
        if isValidBoulder(nextBoulder) then
            state.isProcessingBoulder = true
            processBoulder(nextBoulder)
            state.isProcessingBoulder = false
            task.wait(0.4)
        end
    end
    log("Boulder cycle finished.")
end

local function deleteLowTierCrystals()
    if not state.masterEnabled or state.stopScript then return end

    local crystalsFolder = Workspace:FindFirstChild("Things")
    crystalsFolder = crystalsFolder and crystalsFolder:FindFirstChild("Crystals")
    if not crystalsFolder then
        log("Things.Crystals folder not found")
        return
    end

    local count = 0
    local children = crystalsFolder:GetChildren()
    for _, c in ipairs(children) do
        if c.Parent and shouldDelete(c) then
            pcall(function() c:Destroy() end)
            count += 1
            if count % 20 == 0 then task.wait() end
        end
    end

    if count > 0 then
        log("Deleted", count, "unwanted crystals.")
    else
        log("No unwanted crystals to delete.")
    end
end

local function deleteRunes()
    if not state.masterEnabled or state.stopScript then return end

    local count = 0
    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj:IsA("Model") or obj:IsA("MeshPart") or obj:IsA("BasePart") then
            local lower = (obj.Name or ""):lower()
            if (lower:find("rune", 1, true) or lower:find("enchant", 1, true))
                and not isProtectedRune(obj) then
                if obj.Parent then
                    obj:Destroy()
                    count += 1
                    if count % 20 == 0 then task.wait() end
                end
            end
        end
    end

    if count > 0 then
        log("Deleted", count, "unprotected runes/enchants.")
    end
end

local function shrinkToSmallest(obj)
    if not obj or not obj.Parent then return end
    local tiny = Vector3.new(3, 3, 3)
    if obj:IsA("BasePart") then
        obj.Size = tiny
    elseif obj:IsA("Model") then
        for _, desc in ipairs(obj:GetDescendants()) do
            if desc:IsA("BasePart") then
                desc.Size = tiny
            end
        end
    end
end

local function collectQualifyingCrystals()
    if not state.masterEnabled or state.stopScript then return end

    local crystalsFolder = Workspace:FindFirstChild("Things")
    crystalsFolder = crystalsFolder and crystalsFolder:FindFirstChild("Crystals")
    if not crystalsFolder then return end

    local qualifying = {}
    for _, c in ipairs(crystalsFolder:GetChildren()) do
        if qualifiesForCollect(c) then
            qualifying[#qualifying + 1] = c
        end
    end

    if #qualifying == 0 then
        log("No qualifying crystals.")
        return
    end

    for _, crystal in ipairs(qualifying) do
        if crystal.Parent then
            shrinkToSmallest(crystal)
        end
    end

    table.sort(qualifying, function(a, b)
        return (a:GetAttribute("Value") or 0) > (b:GetAttribute("Value") or 0)
    end)

    log("Collecting", #qualifying, "crystals...")

    for _, crystal in ipairs(qualifying) do
        if state.stopScript or not state.masterEnabled then break end
        if not crystal.Parent then continue end

        local name = crystal:GetAttribute("CrystalName") or crystal.Name
        local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt then
            log("No ProximityPrompt on", name)
            continue
        end

        local attempts = 0
        while crystal.Parent and state.masterEnabled and not state.stopScript do
            attempts += 1
            local pos = crystal:IsA("Model") and crystal:GetPivot().Position or crystal.Position
            if not pos then break end

            local offset = Vector3.new(
                (math.random() - 0.5) * 1,
                0,
                1
            )

            if hrp then
                tweenTo(pos + offset)
                task.wait(0.1)
            end

            pcall(fireproximityprompt, prompt)
            task.wait(0.1)

            if not crystal.Parent then
                log("Collected:", name)
                break
            end

            if attempts % 15 == 0 and digEvent then
                pcall(digEvent.FireServer, digEvent, TOOL_NAME, pos)
            end
            if attempts > 80 then
                log("!! Max attempts reached for", name)
                break
            end
        end
    end
    log("Collection cycle done.")
end

local function collectProtectedRunes()
    if not state.masterEnabled or state.stopScript then return end

    local qualifying = {}
    for _, obj in ipairs(Workspace:GetChildren()) do
        if isProtectedRune(obj) and obj.Parent then
            if obj:IsA("MeshPart") or obj:IsA("Model") or obj:IsA("BasePart") then
                table.insert(qualifying, obj)
            end
        end
    end

    if #qualifying == 0 then
        log("No protected runes found")
        return
    end

    log("Found", #qualifying, "protected runes → collecting...")

    for _, rune in ipairs(qualifying) do
        if state.stopScript or not state.masterEnabled then break end
        if not rune.Parent then continue end

        local name = rune.Name
        local prompt = rune:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt then
            prompt = rune:FindFirstChild("ProximityPrompt", true)
            if not prompt then
                log("No ProximityPrompt on", name)
                continue
            end
        end

        log("Going for", name)
        local attempts = 0

        while rune.Parent and state.masterEnabled and not state.stopScript do
            attempts += 1

            local pos
            if rune:IsA("Model") then
                local ok, result = pcall(function() return rune:GetPivot().Position end)
                pos = ok and result or nil
            else
                pos = rune.Position
            end
            if not pos then
                log("Could not get position of", name)
                break
            end

            local offset = Vector3.new(
                (math.random() - 0.5) * 2,
                1,
                1
            )

            if hrp and (hrp.Position - pos).Magnitude > 15 then
                hrp.CFrame = CFrame.lookAt(pos + offset, pos)
            end

            pcall(fireproximityprompt, prompt)

            if not rune.Parent then break end

            if attempts % 15 == 0 and digEvent then
                pcall(digEvent.FireServer, digEvent, TOOL_NAME, pos)
            end
            if attempts >= 50 then
                log("!! Gave up on", name, "after", attempts, "attempts")
                break
            end
            task.wait(0.05)
        end
        task.wait(0.05)
    end
    log("Protected runes cycle finished.")
end

-- ====================== GUI ======================
local function createGUI()
    -- Cleanup any previous instances
    for _, gui in ipairs(player.PlayerGui:GetChildren()) do
        if gui.Name:find("CombinedBoulderCrystal", 1, true) then
            gui:Destroy()
        end
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "CombinedBoulderCrystal"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = player.PlayerGui

    -- Main frame (compact with tabs)
    local main = Instance.new("Frame")
    main.Name = "Main"
    main.Size = UDim2.fromOffset(320, 420)
    main.Position = UDim2.fromScale(0.01, 0.02)
    main.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
    main.BackgroundTransparency = 0.12
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = screenGui

    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 10)
    mainCorner.Parent = main

    local mainStroke = Instance.new("UIStroke")
    mainStroke.Color = Color3.fromRGB(60, 60, 90)
    mainStroke.Thickness = 1.5
    mainStroke.Transparency = 0.35
    mainStroke.Parent = main

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 34)
    titleBar.BackgroundColor3 = Color3.fromRGB(28, 28, 42)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = main

    local titleBarCorner = Instance.new("UICorner")
    titleBarCorner.CornerRadius = UDim.new(0, 10)
    titleBarCorner.Parent = titleBar

    local titleCover = Instance.new("Frame")
    titleCover.Size = UDim2.new(1, 0, 0, 12)
    titleCover.Position = UDim2.new(0, 0, 1, -12)
    titleCover.BackgroundColor3 = Color3.fromRGB(28, 28, 42)
    titleCover.BorderSizePixel = 0
    titleCover.Parent = titleBar

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Text = "⚡ Boulder & Crystal Bot"
    title.TextColor3 = Color3.fromRGB(255, 210, 120)
    title.TextSize = 14
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = titleBar

    -- Minimize button
    local minimizeBtn = Instance.new("TextButton")
    minimizeBtn.Size = UDim2.fromOffset(26, 26)
    minimizeBtn.Position = UDim2.new(1, -61, 0, 4)
    minimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
    minimizeBtn.Text = "─"
    minimizeBtn.TextColor3 = Color3.new(1, 1, 1)
    minimizeBtn.TextSize = 14
    minimizeBtn.Font = Enum.Font.GothamBold
    minimizeBtn.AutoButtonColor = true
    minimizeBtn.Parent = titleBar

    local minimizeCorner = Instance.new("UICorner")
    minimizeCorner.CornerRadius = UDim.new(0, 6)
    minimizeCorner.Parent = minimizeBtn

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(26, 26)
    closeBtn.Position = UDim2.new(1, -31, 0, 4)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 13
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.AutoButtonColor = true
    closeBtn.Parent = titleBar

    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 6)
    closeCorner.Parent = closeBtn

    -- Minimized restore button
    local restoreBtn = Instance.new("TextButton")
    restoreBtn.Name = "RestoreBtn"
    restoreBtn.Size = UDim2.fromOffset(48, 48)
    restoreBtn.Position = UDim2.fromScale(0.01, 0.02)
    restoreBtn.BackgroundColor3 = Color3.fromRGB(28, 28, 42)
    restoreBtn.Text = "⚡"
    restoreBtn.TextColor3 = Color3.fromRGB(255, 210, 120)
    restoreBtn.TextSize = 22
    restoreBtn.Font = Enum.Font.GothamBold
    restoreBtn.AutoButtonColor = true
    restoreBtn.Visible = false
    restoreBtn.Active = true
    restoreBtn.Draggable = true
    restoreBtn.Parent = screenGui

    local restoreCorner = Instance.new("UICorner")
    restoreCorner.CornerRadius = UDim.new(0, 10)
    restoreCorner.Parent = restoreBtn

    local restoreStroke = Instance.new("UIStroke")
    restoreStroke.Color = Color3.fromRGB(60, 60, 90)
    restoreStroke.Thickness = 1.5
    restoreStroke.Transparency = 0.4
    restoreStroke.Parent = restoreBtn

    -- Tab bar (browser-style)
    local tabBar = Instance.new("Frame")
    tabBar.Name = "TabBar"
    tabBar.Size = UDim2.new(1, -16, 0, 30)
    tabBar.Position = UDim2.fromOffset(8, 40)
    tabBar.BackgroundColor3 = Color3.fromRGB(24, 24, 36)
    tabBar.BorderSizePixel = 0
    tabBar.Parent = main

    local tabBarCorner = Instance.new("UICorner")
    tabBarCorner.CornerRadius = UDim.new(0, 7)
    tabBarCorner.Parent = tabBar

    local tabBarStroke = Instance.new("UIStroke")
    tabBarStroke.Color = Color3.fromRGB(50, 50, 75)
    tabBarStroke.Thickness = 1
    tabBarStroke.Transparency = 0.5
    tabBarStroke.Parent = tabBar

    local tabNames = {"Master", "Boulders", "Crystals", "Runes", "Bombs"}
    local tabButtons = {}
    local tabPages = {}
    local activeTab = "Master"

    local TAB_ACTIVE_BG   = Color3.fromRGB(45, 55, 95)
    local TAB_INACTIVE_BG = Color3.fromRGB(30, 30, 45)
    local TAB_ACTIVE_TXT  = Color3.fromRGB(255, 220, 140)
    local TAB_INACTIVE_TXT= Color3.fromRGB(170, 175, 200)

    -- Content area
    local content = Instance.new("Frame")
    content.Name = "Content"
    content.Size = UDim2.new(1, -16, 1, -82)
    content.Position = UDim2.fromOffset(8, 76)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.ClipsDescendants = true
    content.Parent = main

    local function createPage(name)
        local page = Instance.new("Frame")
        page.Name = name .. "Page"
        page.Size = UDim2.fromScale(1, 1)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.Parent = content
        tabPages[name] = page
        return page
    end

    local masterPage   = createPage("Master")
    local bouldersPage = createPage("Boulders")
    local crystalsPage = createPage("Crystals")
    local runesPage    = createPage("Runes")
    local bombsPage    = createPage("Bombs")

    -- Build tab buttons
    local tabWidth = 1 / #tabNames
    for i, name in ipairs(tabNames) do
        local btn = Instance.new("TextButton")
        btn.Name = name .. "Tab"
        btn.Size = UDim2.new(tabWidth, -2, 1, -4)
        btn.Position = UDim2.new((i - 1) * tabWidth, 1, 0, 2)
        btn.BackgroundColor3 = TAB_INACTIVE_BG
        btn.Text = name
        btn.TextColor3 = TAB_INACTIVE_TXT
        btn.TextSize = 11
        btn.Font = Enum.Font.GothamBold
        btn.AutoButtonColor = false
        btn.Parent = tabBar

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = btn

        tabButtons[name] = btn
    end

    local function switchTab(name)
        if state.stopScript then return end
        activeTab = name
        for n, page in pairs(tabPages) do
            page.Visible = (n == name)
        end
        for n, btn in pairs(tabButtons) do
            if n == name then
                btn.BackgroundColor3 = TAB_ACTIVE_BG
                btn.TextColor3 = TAB_ACTIVE_TXT
            else
                btn.BackgroundColor3 = TAB_INACTIVE_BG
                btn.TextColor3 = TAB_INACTIVE_TXT
            end
        end
    end

    for name, btn in pairs(tabButtons) do
        btn.MouseButton1Click:Connect(function()
            switchTab(name)
        end)
    end

    -- ========== MASTER PAGE ==========
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -8, 0, 18)
    statusLabel.Position = UDim2.fromOffset(4, 4)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Status: ❌ OFF"
    statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    statusLabel.TextSize = 12
    statusLabel.Font = Enum.Font.GothamMedium
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = masterPage

    local masterBtn = Instance.new("TextButton")
    masterBtn.Size = UDim2.new(1, -8, 0, 32)
    masterBtn.Position = UDim2.fromOffset(4, 28)
    masterBtn.TextSize = 13
    masterBtn.Font = Enum.Font.GothamBold
    masterBtn.TextColor3 = Color3.new(1, 1, 1)
    masterBtn.AutoButtonColor = true
    masterBtn.Parent = masterPage

    local masterCorner = Instance.new("UICorner")
    masterCorner.CornerRadius = UDim.new(0, 7)
    masterCorner.Parent = masterBtn

    local sortBtn = Instance.new("TextButton")
    sortBtn.Size = UDim2.new(1, -8, 0, 28)
    sortBtn.Position = UDim2.fromOffset(4, 70)
    sortBtn.TextSize = 12
    sortBtn.Font = Enum.Font.GothamBold
    sortBtn.TextColor3 = Color3.new(1, 1, 1)
    sortBtn.AutoButtonColor = true
    sortBtn.Parent = masterPage

    local sortCorner = Instance.new("UICorner")
    sortCorner.CornerRadius = UDim.new(0, 6)
    sortCorner.Parent = sortBtn

    local sellBtn = Instance.new("TextButton")
    sellBtn.Size = UDim2.new(1, -8, 0, 28)
    sellBtn.Position = UDim2.fromOffset(4, 106)
    sellBtn.TextSize = 12
    sellBtn.Font = Enum.Font.GothamBold
    sellBtn.TextColor3 = Color3.new(1, 1, 1)
    sellBtn.AutoButtonColor = true
    sellBtn.Parent = masterPage

    local sellCorner = Instance.new("UICorner")
    sellCorner.CornerRadius = UDim.new(0, 6)
    sellCorner.Parent = sellBtn

    local bombBuyBtn = Instance.new("TextButton")
    bombBuyBtn.Size = UDim2.new(1, -8, 0, 28)
    bombBuyBtn.Position = UDim2.fromOffset(4, 142)
    bombBuyBtn.TextSize = 12
    bombBuyBtn.Font = Enum.Font.GothamBold
    bombBuyBtn.TextColor3 = Color3.new(1, 1, 1)
    bombBuyBtn.AutoButtonColor = true
    bombBuyBtn.Parent = masterPage

    local bombBuyCorner = Instance.new("UICorner")
    bombBuyCorner.CornerRadius = UDim.new(0, 6)
    bombBuyCorner.Parent = bombBuyBtn

    local masterHint = Instance.new("TextLabel")
    masterHint.Size = UDim2.new(1, -8, 0, 40)
    masterHint.Position = UDim2.fromOffset(4, 182)
    masterHint.BackgroundTransparency = 1
    masterHint.Text = "Press X to toggle master on/off.\nUse tabs above to configure filters."
    masterHint.TextColor3 = Color3.fromRGB(140, 145, 170)
    masterHint.TextSize = 11
    masterHint.Font = Enum.Font.Gotham
    masterHint.TextXAlignment = Enum.TextXAlignment.Left
    masterHint.TextYAlignment = Enum.TextYAlignment.Top
    masterHint.TextWrapped = true
    masterHint.Parent = masterPage

    -- ========== BOULDERS PAGE ==========
    local bouldersHeader = Instance.new("TextLabel")
    bouldersHeader.Size = UDim2.new(1, -8, 0, 18)
    bouldersHeader.Position = UDim2.fromOffset(4, 4)
    bouldersHeader.BackgroundTransparency = 1
    bouldersHeader.Text = "Boulders to Destroy"
    bouldersHeader.TextColor3 = Color3.fromRGB(160, 170, 255)
    bouldersHeader.TextSize = 12
    bouldersHeader.Font = Enum.Font.GothamBold
    bouldersHeader.TextXAlignment = Enum.TextXAlignment.Left
    bouldersHeader.Parent = bouldersPage

    local boulderOrder = {"Mossite", "Voltite", "Gildrite", "Rimeveil", "Nocturnite"}
    local boulderShort = {
        Mossite = "Moss", Voltite = "Volt", Gildrite = "Gild",
        Rimeveil = "Rime", Nocturnite = "Noct",
    }
    local boulderBtns = {}

    for i, b in ipairs(boulderOrder) do
        local row = math.floor((i - 1) / 3)
        local col = (i - 1) % 3
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(92, 30)
        btn.Position = UDim2.fromOffset(4 + col * 100, 30 + row * 38)
        btn.Text = boulderShort[b] or b
        btn.TextSize = 12
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.AutoButtonColor = true
        btn.Parent = bouldersPage

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = btn

        boulderBtns[b] = btn
    end

    -- ========== CRYSTALS PAGE ==========
    local crystalsHeader = Instance.new("TextLabel")
    crystalsHeader.Size = UDim2.new(1, -8, 0, 18)
    crystalsHeader.Position = UDim2.fromOffset(4, 2)
    crystalsHeader.BackgroundTransparency = 1
    crystalsHeader.Text = "Crystal Filters"
    crystalsHeader.TextColor3 = Color3.fromRGB(160, 170, 255)
    crystalsHeader.TextSize = 12
    crystalsHeader.Font = Enum.Font.GothamBold
    crystalsHeader.TextXAlignment = Enum.TextXAlignment.Left
    crystalsHeader.Parent = crystalsPage

    local mutBtn = Instance.new("TextButton")
    mutBtn.Size = UDim2.new(1, -8, 0, 26)
    mutBtn.Position = UDim2.fromOffset(4, 24)
    mutBtn.TextSize = 11
    mutBtn.Font = Enum.Font.GothamBold
    mutBtn.TextColor3 = Color3.new(1, 1, 1)
    mutBtn.AutoButtonColor = true
    mutBtn.Parent = crystalsPage

    local mutCorner = Instance.new("UICorner")
    mutCorner.CornerRadius = UDim.new(0, 5)
    mutCorner.Parent = mutBtn

    local tierLabel = Instance.new("TextLabel")
    tierLabel.Size = UDim2.new(1, -8, 0, 16)
    tierLabel.Position = UDim2.fromOffset(4, 56)
    tierLabel.BackgroundTransparency = 1
    tierLabel.Text = "Tiers:"
    tierLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
    tierLabel.TextSize = 11
    tierLabel.Font = Enum.Font.Gotham
    tierLabel.TextXAlignment = Enum.TextXAlignment.Left
    tierLabel.Parent = crystalsPage

    local tierBtns = {}
    for i = 1, 9 do
        local row = math.floor((i - 1) / 5)
        local col = (i - 1) % 5
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(52, 26)
        btn.Position = UDim2.fromOffset(4 + col * 58, 74 + row * 30)
        btn.Text = "T" .. i
        btn.TextSize = 11
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.AutoButtonColor = true
        btn.Parent = crystalsPage

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = btn

        tierBtns[i] = btn
    end

    local sizeLabel = Instance.new("TextLabel")
    sizeLabel.Size = UDim2.new(1, -8, 0, 16)
    sizeLabel.Position = UDim2.fromOffset(4, 140)
    sizeLabel.BackgroundTransparency = 1
    sizeLabel.Text = "Sizes:"
    sizeLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
    sizeLabel.TextSize = 11
    sizeLabel.Font = Enum.Font.Gotham
    sizeLabel.TextXAlignment = Enum.TextXAlignment.Left
    sizeLabel.Parent = crystalsPage

    local sizeOrder = {"S", "M", "L", "XL", "Giant", "Colossal", "Titan", "Leviathan", "Behemoth"}
    local sizeShort = {
        S = "S", M = "M", L = "L", XL = "XL",
        Giant = "Gnt", Colossal = "Col", Titan = "Tit",
        Leviathan = "Lev", Behemoth = "Beh",
    }
    local sizeBtns = {}

    for i, s in ipairs(sizeOrder) do
        local row = math.floor((i - 1) / 5)
        local col = (i - 1) % 5
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(56, 26)
        btn.Position = UDim2.fromOffset(4 + col * 60, 158 + row * 32)
        btn.Text = sizeShort[s] or s
        btn.TextSize = 11
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.AutoButtonColor = true
        btn.Parent = crystalsPage

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = btn

        sizeBtns[s] = btn
    end

    -- ========== RUNES PAGE ==========
    local runesHeader = Instance.new("TextLabel")
    runesHeader.Size = UDim2.new(1, -8, 0, 18)
    runesHeader.Position = UDim2.fromOffset(4, 4)
    runesHeader.BackgroundTransparency = 1
    runesHeader.Text = "Runes to Collect"
    runesHeader.TextColor3 = Color3.fromRGB(160, 170, 255)
    runesHeader.TextSize = 12
    runesHeader.Font = Enum.Font.GothamBold
    runesHeader.TextXAlignment = Enum.TextXAlignment.Left
    runesHeader.Parent = runesPage

    local runeOrder = {
        "Luck Rune", "Haste Rune", "Storm Rune", "Weight Rune", "Fortune Rune",
        "Detonation Rune", "Preservation Rune", "Warmth Rune", "Excavator Rune", "Colossus Rune",
    }
    local runeShort = {
        ["Luck Rune"] = "Luck", ["Haste Rune"] = "Haste", ["Storm Rune"] = "Storm",
        ["Weight Rune"] = "Weight", ["Fortune Rune"] = "Fortune",
        ["Detonation Rune"] = "Deton", ["Preservation Rune"] = "Preserv",
        ["Warmth Rune"] = "Warmth", ["Excavator Rune"] = "Excav",
        ["Colossus Rune"] = "Colossus",
    }
    local runeBtns = {}

    for i, r in ipairs(runeOrder) do
        local row = math.floor((i - 1) / 5)
        local col = (i - 1) % 5
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(56, 28)
        btn.Position = UDim2.fromOffset(4 + col * 60, 28 + row * 36)
        btn.Text = runeShort[r] or r
        btn.TextSize = 10
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.AutoButtonColor = true
        btn.Parent = runesPage

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = btn

        runeBtns[r] = btn
    end

    -- ========== BOMBS PAGE ==========
    local bombsHeader = Instance.new("TextLabel")
    bombsHeader.Size = UDim2.new(1, -8, 0, 18)
    bombsHeader.Position = UDim2.fromOffset(4, 4)
    bombsHeader.BackgroundTransparency = 1
    bombsHeader.Text = "Bombs to Buy (qty)"
    bombsHeader.TextColor3 = Color3.fromRGB(160, 170, 255)
    bombsHeader.TextSize = 12
    bombsHeader.Font = Enum.Font.GothamBold
    bombsHeader.TextXAlignment = Enum.TextXAlignment.Left
    bombsHeader.Parent = bombsPage

    local bombOrder = {
        "Classic Bomb", "Wind Bomb", "Ice Bomb", "Fire Bomb",
        "Thunder Bomb", "Poison Bomb", "Time Bomb", "Agony Bomb",
    }
    local bombShort = {
        ["Classic Bomb"] = "Classic",
        ["Wind Bomb"]    = "Wind",
        ["Ice Bomb"]     = "Ice",
        ["Fire Bomb"]    = "Fire",
        ["Thunder Bomb"] = "Thunder",
        ["Poison Bomb"]  = "Poison",
        ["Time Bomb"]    = "Time",
        ["Agony Bomb"]   = "Agony",
    }
    local bombQtyBoxes = {}

    for i, bombName in ipairs(bombOrder) do
        local row = math.floor((i - 1) / 2)
        local col = (i - 1) % 2

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromOffset(72, 24)
        label.Position = UDim2.fromOffset(4 + col * 152, 28 + row * 32)
        label.BackgroundTransparency = 1
        label.Text = bombShort[bombName] or bombName
        label.TextColor3 = Color3.fromRGB(200, 200, 210)
        label.TextSize = 11
        label.Font = Enum.Font.Gotham
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = bombsPage

        local box = Instance.new("TextBox")
        box.Size = UDim2.fromOffset(52, 24)
        box.Position = UDim2.fromOffset(80 + col * 152, 28 + row * 32)
        box.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
        box.TextColor3 = Color3.new(1, 1, 1)
        box.Text = tostring(state.bombQuantities[bombName] or 0)
        box.TextSize = 12
        box.Font = Enum.Font.GothamBold
        box.PlaceholderText = "0"
        box.ClearTextOnFocus = false
        box.Parent = bombsPage

        local boxCorner = Instance.new("UICorner")
        boxCorner.CornerRadius = UDim.new(0, 4)
        boxCorner.Parent = box

        bombQtyBoxes[bombName] = box

        box.FocusLost:Connect(function()
            local num = tonumber(box.Text)
            if num and num >= 0 then
                state.bombQuantities[bombName] = math.floor(num)
                box.Text = tostring(state.bombQuantities[bombName])
                log("Bomb qty", bombName, "=", state.bombQuantities[bombName])
                saveConfig()
            else
                box.Text = tostring(state.bombQuantities[bombName] or 0)
            end
        end)
    end

    -- Visual helpers
    local function applyMasterVisuals()
        if state.masterEnabled then
            statusLabel.Text = "Status: ✅ ON"
            statusLabel.TextColor3 = Color3.fromRGB(100, 255, 130)
            masterBtn.Text = "DISABLE"
            masterBtn.BackgroundColor3 = Color3.fromRGB(190, 50, 50)
            enableFly()
            if CONFIG.NOCLIP_ENABLED then enableNoclip() end
            enableVoidRescueBlock()
        else
            statusLabel.Text = "Status: ❌ OFF"
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            masterBtn.Text = "ENABLE"
            masterBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 70)
            disableFly()
            disableNoclip()
            disableVoidRescueBlock()
            state.isProcessingBoulder = false
            state.currentTarget = nil
        end
    end

    local function applySortVisuals()
        if state.autoSortEnabled then
            sortBtn.Text = "Auto Sort: ✅ ON"
            sortBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            sortBtn.Text = "Auto Sort: ❌ OFF"
            sortBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
        end
    end

    local function applySellVisuals()
        if state.sellAllEnabled then
            sellBtn.Text = "Sell All: ✅ ON"
            sellBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            sellBtn.Text = "Sell All: ❌ OFF"
            sellBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
        end
    end

    local function applyBombBuyVisuals()
        if state.bombBuyEnabled then
            bombBuyBtn.Text = "Buy Bombs: ✅ ON"
            bombBuyBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            bombBuyBtn.Text = "Buy Bombs: ❌ OFF"
            bombBuyBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
        end
    end

    local function applyMutVisuals()
        if state.requireMutation then
            mutBtn.Text = "Mutation: WITH only"
            mutBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            mutBtn.Text = "Mutation: WITH + WITHOUT"
            mutBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 80)
        end
    end

    local function applyTierVisuals()
        for t, btn in pairs(tierBtns) do
            btn.BackgroundColor3 = state.tierFilters[t]
                and Color3.fromRGB(40, 140, 80)
                or Color3.fromRGB(70, 70, 80)
        end
    end

    local function applySizeVisuals()
        for s, btn in pairs(sizeBtns) do
            btn.BackgroundColor3 = state.sizeFilters[s]
                and Color3.fromRGB(40, 140, 80)
                or Color3.fromRGB(70, 70, 80)
        end
    end

    local function applyRuneVisuals()
        for r, btn in pairs(runeBtns) do
            btn.BackgroundColor3 = state.runeFilters[r]
                and Color3.fromRGB(40, 140, 80)
                or Color3.fromRGB(70, 70, 80)
        end
    end

    local function applyBoulderVisuals()
        for b, btn in pairs(boulderBtns) do
            btn.BackgroundColor3 = state.boulderFilters[b]
                and Color3.fromRGB(40, 140, 80)
                or Color3.fromRGB(70, 70, 80)
        end
    end

    -- Button connections
    local function toggleMaster()
        if state.stopScript then return end
        state.masterEnabled = not state.masterEnabled
        applyMasterVisuals()
        log(state.masterEnabled and "ENABLED" or "DISABLED")
    end

    masterBtn.MouseButton1Click:Connect(toggleMaster)

    sortBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.autoSortEnabled = not state.autoSortEnabled
        applySortVisuals()
        log("Auto Sort:", state.autoSortEnabled and "ON" or "OFF")
        saveConfig()
    end)

    sellBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.sellAllEnabled = not state.sellAllEnabled
        applySellVisuals()
        log("Sell All:", state.sellAllEnabled and "ON" or "OFF")
        saveConfig()
    end)

    bombBuyBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.bombBuyEnabled = not state.bombBuyEnabled
        applyBombBuyVisuals()
        log("Buy Bombs:", state.bombBuyEnabled and "ON" or "OFF")
        saveConfig()
    end)

    mutBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.requireMutation = not state.requireMutation
        applyMutVisuals()
        log("Mutation filter:", state.requireMutation and "WITH only" or "WITH + WITHOUT")
        saveConfig()
    end)

    for t, btn in pairs(tierBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.tierFilters[t] = not state.tierFilters[t]
            applyTierVisuals()
            log("Tier", t, state.tierFilters[t] and "ON" or "OFF")
            saveConfig()
        end)
    end

    for s, btn in pairs(sizeBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.sizeFilters[s] = not state.sizeFilters[s]
            applySizeVisuals()
            log("Size", s, state.sizeFilters[s] and "ON" or "OFF")
            saveConfig()
        end)
    end

    for r, btn in pairs(runeBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.runeFilters[r] = not state.runeFilters[r]
            rebuildRuneLookup()
            applyRuneVisuals()
            log("Rune", r, state.runeFilters[r] and "ON" or "OFF")
            saveConfig()
        end)
    end

    for b, btn in pairs(boulderBtns) do
        local boulderName = b
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.boulderFilters[boulderName] = not state.boulderFilters[boulderName]
            applyBoulderVisuals()
            log("Boulder", boulderName, state.boulderFilters[boulderName] and "ON" or "OFF")
            saveConfig()
        end)
    end

    minimizeBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        restoreBtn.Position = main.Position
        main.Visible = false
        restoreBtn.Visible = true
    end)

    restoreBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        main.Position = restoreBtn.Position
        restoreBtn.Visible = false
        main.Visible = true
    end)

    closeBtn.MouseButton1Click:Connect(function()
        saveConfig(true)
        state.masterEnabled = false
        state.stopScript = true
        disableFly()
        disableNoclip()
        disableVoidRescueBlock()
        if screenGui and screenGui.Parent then
            screenGui:Destroy()
        end
        _G.CombinedBoulderCrystalRunning = nil
        log("Script fully stopped.")
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
        if processed or state.stopScript then return end
        if input.KeyCode == Enum.KeyCode.X then
            toggleMaster()
        end
    end)

    -- Initial visuals + open Master tab
    applyMasterVisuals()
    applySortVisuals()
    applySellVisuals()
    applyBombBuyVisuals()
    applyMutVisuals()
    applyTierVisuals()
    applySizeVisuals()
    applyRuneVisuals()
    applyBoulderVisuals()
    switchTab("Master")

    log("Initial state → master:", state.masterEnabled,
        "autoSort:", state.autoSortEnabled,
        "sellAll:", state.sellAllEnabled,
        "bombBuy:", state.bombBuyEnabled)

    return screenGui
end

-- ====================== REVIVE ======================
local function clickButton(button)
    if not button then return end

    -- Method 1: getconnections
    local success, connections = pcall(getconnections, button.MouseButton1Click)
    if success and connections then
        for _, conn in pairs(connections) do
            pcall(function()
                conn:Fire()
            end)
        end
    end

    -- Method 2: VirtualInputManager (backup)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        local pos = button.AbsolutePosition + (button.AbsoluteSize / 2)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
        task.wait()
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
    end)
end

local function tryClickBase()
    local playerGui = player:WaitForChild("PlayerGui")

    local reviveGui = playerGui:FindFirstChild("Revive")
    if not reviveGui or not reviveGui.Enabled then return end

    local frame = reviveGui:FindFirstChild("Frame")
    if not frame then return end

    local baseBtn = frame:FindFirstChild("Base")
    if baseBtn then
        clickButton(baseBtn)
        -- print("Clicked Base")
    end
end

-- ====================== LIFECYCLE ======================
waitForCharacter()

local screenGui = createGUI()

log("Waiting for Workspace.LavaHazards to exist...")
local lavaHazards = Workspace:WaitForChild("LavaHazards", 30)
if lavaHazards then
    log("LavaHazards ready.")
    local toDelete = {"Map", "LavaHazards", "WeatherFX", "RimefireAmbience"}
    for _, name in ipairs(toDelete) do
        local obj = Workspace:FindFirstChild(name)
        if obj then
            pcall(function() obj:Destroy() end)
            log("Deleted Workspace." .. name)
        end
    end
else
    warn("[Bot] LavaHazards never appeared – rejoining game...")
    rejoinGame()
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
if Remotes then
    digEvent = Remotes:FindFirstChild("DigRequest")
end
if not digEvent then
    warn("[Bot] DigRequest remote not found – rejoining game...")
    rejoinGame()
end

task.wait(2)

player.CharacterAdded:Connect(function(newChar)
    character = newChar
    hrp = character:WaitForChild("HumanoidRootPart", 30)
    humanoid = character:WaitForChild("Humanoid", 30)
    state.toolReady = false
    checkIfToolEquipped()
    if state.masterEnabled and not state.stopScript then
        enableFly()
        if CONFIG.NOCLIP_ENABLED then enableNoclip() end
    end
end)

task.spawn(function()
    autoSort()
    sellAllCrystals()
    buyBombs()

    while not state.stopScript do
        if state.masterEnabled then

            if not isToolEquipped() then
                checkIfToolEquipped()
            end

            destroyBoulders()
            deleteLowTierCrystals()
            deleteRunes()
            collectQualifyingCrystals()
            collectProtectedRunes()
            task.wait(0.5)
        else
            task.wait(0.5)
        end
    end
    log("Master loop exited.")
end)

task.spawn(function()
    while not state.stopScript do
        if state.masterEnabled then
            tryClickBase()
        end
        task.wait(10)
    end
    log("Master loop exited.")
end)

print("===========================================================")
print("M/A/M script")
print("===========================================================")