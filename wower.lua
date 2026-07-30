--[[
    Combined Boulder + Crystal Bot (Refactored + Efficient)
    Master toggle: X key or GUI button
    Sequence when master is ON:
      1. Destroy allowed boulders
      2. Delete low-tier crystals + runes
      3. Collect high-tier (mutated) crystals
      4. Auto Sort (if enabled)
      5. Sell All Crystals (if enabled)
]]
-- ====================== CONFIG ======================
local CONFIG = {
    masterEnabledDefault = true,
    autoSortEnabledDefault = true,
    sellAllEnabledDefault = false,
    TOOL_NAME = "The Terminus",
    DIG_RANGE = 10000,
    TWEEN_SPEED = 1.2,
    FLY_HEIGHT = 10,
    SPAM_DELAY = 0.001,
    BURST_SIZE = 50,
    DIG_INTERVAL = 0.05,
    TIMEOUT_PER_BOULDER = 90,
    NOCLIP_ENABLED = true,
    SCAN_TELEPORT_POS = Vector3.new(-6.950318, 200.289139, 280.262573),
    REJOIN_COOLDOWN = 60,
    VERBOSE = true,
    -- UI selection defaults (all filter defaults live here)
    requireMutationDefault = true,
    sizeFiltersDefault = {
        S = false,
        M = false,
        L = false,
        XL = false,
        Giant = false,
        Colossal = true,
        Titan = true,
        Leviathan = true,
        Behemoth = true,
    },
    tierFiltersDefault = {
        [1] = false,
        [2] = false,
        [3] = false,
        [4] = false,
        [5] = true,
        [6] = true,
    },
    -- Rune collect toggles (only Colossus, Warmth, Haste, Weight on by default)
    runeFiltersDefault = {
        ["Luck Rune"] = false,
        ["Haste Rune"] = false,
        ["Storm Rune"] = false,
        ["Weight Rune"] = false,
        ["Fortune Rune"] = false,
        ["Detonation Rune"] = false,
        ["Preservation Rune"] = false,
        ["Warmth Rune"] = false,
        ["Excavator Rune"] = false,
        ["Colossus Rune"] = false,
    },
    -- Boulder destroy toggles (only Gildrite, Rimeveil, Nocturnite on by default)
    boulderFiltersDefault = {
        Mossite = false,
        Voltite = false,
        Gildrite = true,
        Rimeveil = true,
        Nocturnite = true,
    },
}
local PRIORITY = { Nocturnite = 3, Rimeveil = 2, Gildrite = 1, Mossite = 0, Voltite = 0 }
-- ====================== SERVICES ======================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local VirtualInputManager = game:GetService("VirtualInputManager")
local CoreGui = game:GetService("CoreGui")
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
-- ====================== STATE ======================
local state = {
    masterEnabled = CONFIG.masterEnabledDefault,
    autoSortEnabled = CONFIG.autoSortEnabledDefault,
    sellAllEnabled = CONFIG.sellAllEnabledDefault,
    stopScript = false,
    toolReady = false,
    isProcessingBoulder = false,
    isTweening = false,
    flying = false,
    noclipActive = false,
    digCount = 0,
    lastDigTime = 0,
    lastRejoinTime = 0,
    currentTarget = nil,
    currentTween = nil,
    -- Crystal / rune filters (initialized from CONFIG)
    sizeFilters = table.clone(CONFIG.sizeFiltersDefault),
    tierFilters = table.clone(CONFIG.tierFiltersDefault),
    requireMutation = CONFIG.requireMutationDefault,
    runeFilters = table.clone(CONFIG.runeFiltersDefault),
    boulderFilters = table.clone(CONFIG.boulderFiltersDefault),
}
local character, hrp, humanoid
local originalCollideStates = {}
local boulderQueue = {}
local digEvent
local ZERO_VECTOR = Vector3.zero
local Y_AXIS = Vector3.yAxis
local TOOL_NAME = CONFIG.TOOL_NAME
local FLY_HEIGHT = CONFIG.FLY_HEIGHT
local BURST_SIZE = CONFIG.BURST_SIZE
local SPAM_DELAY = CONFIG.SPAM_DELAY
local DIG_INTERVAL = CONFIG.DIG_INTERVAL
local TIMEOUT_PER_BOULDER = CONFIG.TIMEOUT_PER_BOULDER
local SCAN_POS = CONFIG.SCAN_TELEPORT_POS
local REJOIN_COOLDOWN = CONFIG.REJOIN_COOLDOWN
local TWEEN_SPEED = CONFIG.TWEEN_SPEED

-- ====================== RUNE NAME HELPERS (FIXED) ======================
local function normalizeRuneName(name)
    if not name then return "" end
    name = tostring(name):lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%s*%(.*%)%s*$", ""):gsub("%s*enchant%s*", " "):gsub("%s+", " ")
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

local function isProtectedRune(objName)
    if not objName then return false end
    local norm = normalizeRuneName(objName)
    if RUNE_LOOKUP[norm] then return true end
    for key in pairs(RUNE_LOOKUP) do
        if norm:find(key, 1, true) then
            return true
        end
    end
    return false
end

-- Build lookup once at start
rebuildRuneLookup()

-- ====================== UTILITIES ======================
local function log(...)
    if CONFIG.VERBOSE then
        print("[Bot]", ...)
    end
end
local function waitForCharacter()
    if not player.Character then
        player.CharacterAdded:Wait()
    end
    character = player.Character
    hrp = character:WaitForChild("HumanoidRootPart", 30)
    humanoid = character:WaitForChild("Humanoid", 30)
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
    if isToolEquipped() then
        return true
    end
    local tool = findTool()
    if not tool then
        return false
    end
    local current = character:FindFirstChildOfClass("Tool")
    if current and current ~= tool then
        humanoid:UnequipTools()
        task.wait(0.1)
    end
    tool.Parent = character
    pcall(function()
        humanoid:EquipTool(tool)
    end)
    return isToolEquipped()
end
local lastToolLog = 0
local function waitForToolEquipped()
    if isToolEquipped() then
        state.toolReady = true
        return true
    end
    pcall(function()
        local Event = ReplicatedStorage.Remotes.ShopEquip
        Event:FireServer("TheTerminus")
    end)
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
    log("Failed to equip", TOOL_NAME)
    return false
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
    if linearVelocity then
        linearVelocity:Destroy()
        linearVelocity = nil
    end
    if alignOrientation then
        alignOrientation:Destroy()
        alignOrientation = nil
    end
    if flyAttachment then
        flyAttachment:Destroy()
        flyAttachment = nil
    end
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
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then
        vel += cam.LookVector * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then
        vel -= cam.LookVector * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then
        vel -= cam.RightVector * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then
        vel += cam.RightVector * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
        vel += Y_AXIS * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        vel -= Y_AXIS * speed
    end
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
    local info = TweenInfo.new(TWEEN_SPEED, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    state.currentTween = TweenService:Create(hrp, info, { CFrame = targetCF })
    state.currentTween:Play()
    local start = tick()
    local deadline = TWEEN_SPEED + 1.5
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


local function smartTweenTo(targetPos, heightOffset)
    if not hrp or not hrp.Parent then return false end

    local startPos = hrp.Position
    local distance = (targetPos - startPos).Magnitude
    local height = heightOffset or FLY_HEIGHT

    if distance >= 500 then
        -- Only for 500+ → half way
        local mid = startPos:Lerp(targetPos, 0.5)
        log("Very far (" .. math.floor(distance) .. ") → going halfway")
        tweenTo(mid, height)
        task.wait(0.25 + math.random() * 0.15)
        tweenTo(targetPos, height)
    else
        -- Less than 500 → go direct
        tweenTo(targetPos, height)
    end

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
local function isAllowedBoulder(model)
    return model and state.boulderFilters[model.Name] == true
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
    task.wait(0.7) -- slightly faster
    local data = updateBoulderData()
    if #data == 0 then
        log("No allowed boulders found.")
        return false
    end
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
-- ====================== AUTO SORT + SELL ======================
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
            task.wait(0.4)
        end
    end
end
local function sellAllCrystals()
    if not state.sellAllEnabled or state.stopScript then return end
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return end
    local goHome = remotes:FindFirstChild("GoHome")
    if goHome then
        pcall(function()
            goHome:FireServer("sell")
        end)
    end
    task.wait(0.5)
    local sellReq = remotes:FindFirstChild("SellRequest")
    if sellReq then
        pcall(function()
            sellReq:FireServer("all")
        end)
        log("Sell All Crystals fired")
    end
    task.wait(0.4)
end
local function rejoinGame()
    local function findIYTextBox()
        local containers = { CoreGui }
        if typeof(gethui) == "function" then
            containers[2] = gethui()
        end
        for _, container in ipairs(containers) do
            for _, gui in ipairs(container:GetDescendants()) do
                if gui:IsA("TextBox") then
                    local ph = gui.PlaceholderText or ""
                    if ph == "Command Bar (])" or ph:find("Command", 1, true) then
                        return gui
                    end
                end
            end
        end
        return nil
    end
    local iyBox = findIYTextBox()
    if iyBox then
        log("IY command bar found – sending rejoin...")
        iyBox:CaptureFocus()
        iyBox.Text = "rj"
        task.wait(0.1)
        pcall(firesignal, iyBox.FocusLost, true, Enum.UserInputType.Keyboard)
        log("Rejoin command sent.")
    else
        log("IY command bar not found – cannot auto-rejoin.")
    end
end
local function processBoulder(boulder)
    if not isValidBoulder(boulder) then return false end
    state.currentTarget = boulder
    local pos = getBoulderPosition(boulder)
    if not pos then
        state.currentTarget = nil
        return false
    end
    local name = boulder.Name
    log("Digging:", name)
    smartTweenTo(pos, FLY_HEIGHT) -- ← uses halfway pathing
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
        continuousDig(boulder)
        if not isValidBoulder(boulder) then
            destroyed = true
            break
        end
        local currentPos = getBoulderPosition(boulder)
        if currentPos and hrp and (currentPos - hrp.Position).Magnitude > 20
            and (tick() - lastReposition) > 3 then
            smartTweenTo(currentPos, FLY_HEIGHT)
            lastReposition = tick()
        end
        task.wait(DIG_INTERVAL)
    end
    state.currentTarget = nil
    log(destroyed and ("Destroyed: " .. name) or ("Timeout: " .. name))
    return destroyed
end
-- ====================== CRYSTAL LOGIC (FIXED) ======================
local MUTATION_KEYWORDS = {
    mutation = true, mutant = true, evolved = true, corrupt = true,
    blessed = true, cursed = true, radiant = true, shiny = true,
    glowing = true, altered = true, enhanced = true, warped = true,
    infused = true, charged = true
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

-- Returns size class string (e.g. "XL", "Giant") or nil
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
            if lower == "giant" then return "Giant" end
            if lower == "colossal" then return "Colossal" end
            if lower == "titan" then return "Titan" end
            if lower == "leviathan" then return "Leviathan" end
            if lower == "behemoth" then return "Behemoth" end
            if lower == "s" or lower == "small" then return "S" end
            if lower == "m" or lower == "medium" then return "M" end
            if lower == "l" or lower == "large" then return "L" end
            return s:sub(1,1):upper() .. s:sub(2):lower()
        end
    end
    -- Fallback: derive from WeightKg (official ranges)
    local weight = tonumber(crystal:GetAttribute("WeightKg") or crystal:GetAttribute("Weight") or 0) or 0
    if weight < 8 then return "S"
    elseif weight < 30 then return "M"
    elseif weight < 90 then return "L"
    elseif weight < 200 then return "XL"
    elseif weight < 1000 then return "Giant"
    elseif weight < 3000 then return "Colossal"
    elseif weight < 8000 then return "Titan"
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
        if num and state.tierFilters[num] == true then
            return true
        end
        return false
    end
    -- Fallback for name-based tier detection
    local name = (crystal.Name or ""):lower()
    for t = 1, 6 do
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
            if qualifiesForCollect(c) then
                return true
            end
        end
    end
    for _, obj in ipairs(Workspace:GetChildren()) do
        if isProtectedRune(obj.Name) and obj.Parent then
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
    if not isToolEquipped() then
        waitForToolEquipped()
        if not state.toolReady then return end
    end
    log("Starting boulder cycle.")
    if #boulderQueue == 0 then
        local found = scanAndBuildQueue()
        if not found then
            return false   -- signal that no boulders were found
        end
    end
    while #boulderQueue > 0 and state.masterEnabled and not state.stopScript do
        local nextBoulder = table.remove(boulderQueue, 1)
        if isValidBoulder(nextBoulder) then
            state.isProcessingBoulder = true
            processBoulder(nextBoulder)
            state.isProcessingBoulder = false
            task.wait(0.3)
        end
    end
    log("Boulder cycle finished.")
    return true
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
            pcall(function()
                c:Destroy()
            end)
            count += 1
            if count % 25 == 0 then
                task.wait()
            end
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
                and not isProtectedRune(obj.Name) then
                if obj.Parent then
                    obj:Destroy()
                    count += 1
                    if count % 25 == 0 then
                        task.wait()
                    end
                end
            end
        end
    end
    if count > 0 then
        log("Deleted", count, "unprotected runes/enchants.")
    end
end

-- Shrink collectible crystals/runes to smallest size possible
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

-- Always collect the closest qualifying crystal
local function collectQualifyingCrystals()
    if not state.masterEnabled or state.stopScript then return end
    local crystalsFolder = Workspace:FindFirstChild("Things")
    crystalsFolder = crystalsFolder and crystalsFolder:FindFirstChild("Crystals")
    if not crystalsFolder then return end

    local function getClosestQualifying()
        local best, bestDist = nil, math.huge
        local hrpPos = hrp and hrp.Position or ZERO_VECTOR
        for _, c in ipairs(crystalsFolder:GetChildren()) do
            if c.Parent and qualifiesForCollect(c) then
                local pos = c:IsA("Model") and c:GetPivot().Position or c.Position
                if pos then
                    local dist = (hrpPos - pos).Magnitude
                    if dist < bestDist then
                        bestDist = dist
                        best = c
                    end
                end
            end
        end
        return best
    end

    local collected = 0
    while true do
        if state.stopScript or not state.masterEnabled then break end
        local crystal = getClosestQualifying()
        if not crystal then break end

        shrinkToSmallest(crystal)

        local name = crystal:GetAttribute("CrystalName") or crystal.Name
        local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt then
            log("No ProximityPrompt on", name)
            pcall(function() crystal:Destroy() end)
            continue
        end

        local attempts = 0
        while crystal.Parent and state.masterEnabled and not state.stopScript do
            attempts += 1
            local pos = crystal:IsA("Model") and crystal:GetPivot().Position or crystal.Position
            if not pos then break end

            -- Use smart pathing when far
            if hrp and (pos - hrp.Position).Magnitude > 8 then
                smartTweenTo(pos, 3.5)
            else
                local offset = Vector3.new(
                    (math.random() - 0.5) * 1.5,
                    1.2 + math.random() * 1.5,
                    (math.random() - 0.5) * 1.5
                )
                hrp.CFrame = CFrame.new(pos + offset)
            end

            pcall(fireproximityprompt, prompt)

            if not crystal.Parent then
                log("Collected:", name)
                collected += 1
                break
            end

            if attempts % 10 == 0 and digEvent then
                pcall(digEvent.FireServer, digEvent, TOOL_NAME, pos)
            end
            if attempts > 70 then
                log("!! Max attempts reached for", name)
                break
            end
            task.wait(0.06) -- slightly faster
        end
        task.wait(0.03)
    end

    if collected > 0 then
        log("Collection cycle done. Collected:", collected)
    else
        log("No qualifying crystals.")
    end
end

-- Always collect the closest protected rune
local function collectProtectedRunes()
    if not state.masterEnabled or state.stopScript then return end

    local function getClosestProtected()
        local best, bestDist = nil, math.huge
        local hrpPos = hrp and hrp.Position or ZERO_VECTOR
        for _, obj in ipairs(Workspace:GetChildren()) do
            if isProtectedRune(obj.Name) and obj.Parent then
                if obj:IsA("MeshPart") or obj:IsA("Model") or obj:IsA("BasePart") then
                    local pos
                    if obj:IsA("Model") then
                        local ok, result = pcall(function() return obj:GetPivot().Position end)
                        pos = ok and result or nil
                    else
                        pos = obj.Position
                    end
                    if pos then
                        local dist = (hrpPos - pos).Magnitude
                        if dist < bestDist then
                            bestDist = dist
                            best = obj
                        end
                    end
                end
            end
        end
        return best
    end

    local collected = 0
    while true do
        if state.stopScript or not state.masterEnabled then break end
        local rune = getClosestProtected()
        if not rune then break end

        shrinkToSmallest(rune)
        local name = rune.Name
        local prompt = rune:FindFirstChildWhichIsA("ProximityPrompt", true)
            or rune:FindFirstChild("ProximityPrompt", true)

        if not prompt then
            log("No ProximityPrompt on", name)
            pcall(function() rune:Destroy() end)
            continue
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
            if not pos then break end

            if hrp and (pos - hrp.Position).Magnitude > 8 then
                smartTweenTo(pos, 3.5)
            else
                local offset = Vector3.new(
                    (math.random() - 0.5) * 2.5,
                    1.5 + math.random() * 1.8,
                    (math.random() - 0.5) * 2.5
                )
                hrp.CFrame = CFrame.new(pos + offset)
            end

            pcall(fireproximityprompt, prompt)

            if not rune.Parent then
                log("Successfully collected:", name)
                collected += 1
                break
            end

            if attempts % 10 == 0 and digEvent then
                pcall(digEvent.FireServer, digEvent, TOOL_NAME, pos)
            end
            if attempts >= 45 then
                log("!! Gave up on", name, "after", attempts, "attempts")
                break
            end
            task.wait(0.07) -- slightly faster
        end
        task.wait(0.03)
    end

    if collected > 0 then
        log("Protected runes cycle finished. Collected:", collected)
    else
        log("No protected runes found in Workspace")
    end
end

-- ====================== GUI ======================
local function createGUI()
    for _, gui in ipairs(player.PlayerGui:GetChildren()) do
        if gui.Name:find("CombinedBoulderCrystal", 1, true) then gui:Destroy() end
    end
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "CombinedBoulderCrystal"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = player.PlayerGui
    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(300, 640)
    main.Position = UDim2.fromScale(0.01, 0.05)
    main.BackgroundColor3 = Color3.fromRGB(20, 20, 40)
    main.BackgroundTransparency = 0.2
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = true
    main.Parent = screenGui
    Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 30)
    title.Position = UDim2.fromOffset(0, 5)
    title.BackgroundTransparency = 1
    title.Text = "⚡ Boulder & Crystal Bot"
    title.TextColor3 = Color3.fromRGB(255, 200, 100)
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.Parent = main
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, 0, 0, 20)
    statusLabel.Position = UDim2.fromOffset(0, 32)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Status: ❌ OFF"
    statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
    statusLabel.TextSize = 12
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.Parent = main
    local masterBtn = Instance.new("TextButton")
    masterBtn.Size = UDim2.new(0.7, 0, 0, 28)
    masterBtn.Position = UDim2.fromOffset(14, 55)
    masterBtn.TextSize = 13
    masterBtn.Font = Enum.Font.GothamBold
    masterBtn.TextColor3 = Color3.new(1, 1, 1)
    masterBtn.Parent = main
    Instance.new("UICorner", masterBtn).CornerRadius = UDim.new(0, 6)
    local sortBtn = Instance.new("TextButton")
    sortBtn.Size = UDim2.new(0.9, 0, 0, 24)
    sortBtn.Position = UDim2.fromOffset(14, 90)
    sortBtn.TextSize = 12
    sortBtn.Font = Enum.Font.GothamBold
    sortBtn.TextColor3 = Color3.new(1, 1, 1)
    sortBtn.Parent = main
    Instance.new("UICorner", sortBtn).CornerRadius = UDim.new(0, 6)
    local sellBtn = Instance.new("TextButton")
    sellBtn.Size = UDim2.new(0.9, 0, 0, 24)
    sellBtn.Position = UDim2.fromOffset(14, 118)
    sellBtn.TextSize = 12
    sellBtn.Font = Enum.Font.GothamBold
    sellBtn.TextColor3 = Color3.new(1, 1, 1)
    sellBtn.Parent = main
    Instance.new("UICorner", sellBtn).CornerRadius = UDim.new(0, 6)
    -- ===== Boulder Filters Section =====
    local boulderHeader = Instance.new("TextLabel")
    boulderHeader.Size = UDim2.new(1, -20, 0, 18)
    boulderHeader.Position = UDim2.fromOffset(10, 148)
    boulderHeader.BackgroundTransparency = 1
    boulderHeader.Text = "Boulders to Destroy"
    boulderHeader.TextColor3 = Color3.fromRGB(180, 180, 255)
    boulderHeader.TextSize = 12
    boulderHeader.Font = Enum.Font.GothamBold
    boulderHeader.TextXAlignment = Enum.TextXAlignment.Left
    boulderHeader.Parent = main
    local boulderOrder = {"Mossite", "Voltite", "Gildrite", "Rimeveil", "Nocturnite"}
    local boulderShort = {
        Mossite = "Moss",
        Voltite = "Volt",
        Gildrite = "Gild",
        Rimeveil = "Rime",
        Nocturnite = "Noct",
    }
    local boulderBtns = {}
    for i, b in ipairs(boulderOrder) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(50, 22)
        btn.Position = UDim2.fromOffset(14 + (i - 1) * 54, 168)
        btn.Text = boulderShort[b] or b
        btn.TextSize = 10
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
        boulderBtns[b] = btn
    end
    -- ===== Crystal Filters Section =====
    local filterHeader = Instance.new("TextLabel")
    filterHeader.Size = UDim2.new(1, -20, 0, 18)
    filterHeader.Position = UDim2.fromOffset(10, 200)
    filterHeader.BackgroundTransparency = 1
    filterHeader.Text = "Crystal Filters"
    filterHeader.TextColor3 = Color3.fromRGB(180, 180, 255)
    filterHeader.TextSize = 12
    filterHeader.Font = Enum.Font.GothamBold
    filterHeader.TextXAlignment = Enum.TextXAlignment.Left
    filterHeader.Parent = main
    -- Mutation toggle
    local mutBtn = Instance.new("TextButton")
    mutBtn.Size = UDim2.new(0.9, 0, 0, 22)
    mutBtn.Position = UDim2.fromOffset(14, 220)
    mutBtn.TextSize = 11
    mutBtn.Font = Enum.Font.GothamBold
    mutBtn.TextColor3 = Color3.new(1, 1, 1)
    mutBtn.Parent = main
    Instance.new("UICorner", mutBtn).CornerRadius = UDim.new(0, 5)
    -- Tier filters label
    local tierLabel = Instance.new("TextLabel")
    tierLabel.Size = UDim2.new(1, -20, 0, 16)
    tierLabel.Position = UDim2.fromOffset(10, 248)
    tierLabel.BackgroundTransparency = 1
    tierLabel.Text = "Tiers:"
    tierLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    tierLabel.TextSize = 11
    tierLabel.Font = Enum.Font.Gotham
    tierLabel.TextXAlignment = Enum.TextXAlignment.Left
    tierLabel.Parent = main
    local tierBtns = {}
    local tierNames = {1, 2, 3, 4, 5, 6}
    for i, t in ipairs(tierNames) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(40, 22)
        btn.Position = UDim2.fromOffset(14 + (i - 1) * 44, 266)
        btn.Text = "T" .. t
        btn.TextSize = 11
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
        tierBtns[t] = btn
    end
    -- Size filters label
    local sizeLabel = Instance.new("TextLabel")
    sizeLabel.Size = UDim2.new(1, -20, 0, 16)
    sizeLabel.Position = UDim2.fromOffset(10, 296)
    sizeLabel.BackgroundTransparency = 1
    sizeLabel.Text = "Sizes:"
    sizeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    sizeLabel.TextSize = 11
    sizeLabel.Font = Enum.Font.Gotham
    sizeLabel.TextXAlignment = Enum.TextXAlignment.Left
    sizeLabel.Parent = main
    local sizeOrder = {"S", "M", "L", "XL", "Giant", "Colossal", "Titan", "Leviathan", "Behemoth"}
    local sizeBtns = {}
    local sizeShort = {
        S = "S", M = "M", L = "L", XL = "XL",
        Giant = "Gnt", Colossal = "Col", Titan = "Tit",
        Leviathan = "Lev", Behemoth = "Beh"
    }
    for i, s in ipairs(sizeOrder) do
        local row = math.floor((i - 1) / 5)
        local col = (i - 1) % 5
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(50, 22)
        btn.Position = UDim2.fromOffset(14 + col * 54, 314 + row * 26)
        btn.Text = sizeShort[s] or s
        btn.TextSize = 10
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
        sizeBtns[s] = btn
    end
    -- ===== Rune Filters Section =====
    local runeHeader = Instance.new("TextLabel")
    runeHeader.Size = UDim2.new(1, -20, 0, 18)
    runeHeader.Position = UDim2.fromOffset(10, 372)
    runeHeader.BackgroundTransparency = 1
    runeHeader.Text = "Runes to Collect"
    runeHeader.TextColor3 = Color3.fromRGB(180, 180, 255)
    runeHeader.TextSize = 12
    runeHeader.Font = Enum.Font.GothamBold
    runeHeader.TextXAlignment = Enum.TextXAlignment.Left
    runeHeader.Parent = main
    local runeOrder = {
        "Luck Rune", "Haste Rune", "Storm Rune", "Weight Rune", "Fortune Rune",
        "Detonation Rune", "Preservation Rune", "Warmth Rune", "Excavator Rune", "Colossus Rune"
    }
    local runeShort = {
        ["Luck Rune"] = "Luck",
        ["Haste Rune"] = "Haste",
        ["Storm Rune"] = "Storm",
        ["Weight Rune"] = "Weight",
        ["Fortune Rune"] = "Fortune",
        ["Detonation Rune"] = "Deton",
        ["Preservation Rune"] = "Preserv",
        ["Warmth Rune"] = "Warmth",
        ["Excavator Rune"] = "Excav",
        ["Colossus Rune"] = "Colossus",
    }
    local runeBtns = {}
    for i, r in ipairs(runeOrder) do
        local row = math.floor((i - 1) / 5)
        local col = (i - 1) % 5
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(50, 22)
        btn.Position = UDim2.fromOffset(14 + col * 54, 392 + row * 26)
        btn.Text = runeShort[r] or r
        btn.TextSize = 10
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = main
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)
        runeBtns[r] = btn
    end
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.fromOffset(25, 25)
    closeBtn.Position = UDim2.new(1, -30, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.TextSize = 14
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = main
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 4)

    local function applyMasterVisuals()
        if state.masterEnabled then
            statusLabel.Text = "Status: ✅ ON"
            statusLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
            masterBtn.Text = "DISABLE"
            masterBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
            enableFly()
            if CONFIG.NOCLIP_ENABLED then enableNoclip() end
        else
            statusLabel.Text = "Status: ❌ OFF"
            statusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
            masterBtn.Text = "ENABLE"
            masterBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 0)
            disableFly()
            disableNoclip()
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
            sortBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        end
    end
    local function applySellVisuals()
        if state.sellAllEnabled then
            sellBtn.Text = "Sell All: ✅ ON"
            sellBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            sellBtn.Text = "Sell All: ❌ OFF"
            sellBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        end
    end
    local function applyMutVisuals()
        if state.requireMutation then
            mutBtn.Text = "Mutation: WITH only"
            mutBtn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
        else
            mutBtn.Text = "Mutation: WITH + WITHOUT"
            mutBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        end
    end
    local function applyTierVisuals()
        for t, btn in pairs(tierBtns) do
            if state.tierFilters[t] then
                btn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
            else
                btn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
            end
        end
    end
    local function applySizeVisuals()
        for s, btn in pairs(sizeBtns) do
            if state.sizeFilters[s] then
                btn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
            else
                btn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
            end
        end
    end
    local function applyRuneVisuals()
        for r, btn in pairs(runeBtns) do
            if state.runeFilters[r] then
                btn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
            else
                btn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
            end
        end
    end
    local function applyBoulderVisuals()
        for b, btn in pairs(boulderBtns) do
            if state.boulderFilters[b] then
                btn.BackgroundColor3 = Color3.fromRGB(40, 140, 80)
            else
                btn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
            end
        end
    end

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
    end)
    sellBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.sellAllEnabled = not state.sellAllEnabled
        applySellVisuals()
        log("Sell All:", state.sellAllEnabled and "ON" or "OFF")
    end)
    mutBtn.MouseButton1Click:Connect(function()
        if state.stopScript then return end
        state.requireMutation = not state.requireMutation
        applyMutVisuals()
        log("Mutation filter:", state.requireMutation and "WITH only" or "WITH + WITHOUT")
    end)
    for t, btn in pairs(tierBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.tierFilters[t] = not state.tierFilters[t]
            applyTierVisuals()
            log("Tier", t, state.tierFilters[t] and "ON" or "OFF")
        end)
    end
    for s, btn in pairs(sizeBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.sizeFilters[s] = not state.sizeFilters[s]
            applySizeVisuals()
            log("Size", s, state.sizeFilters[s] and "ON" or "OFF")
        end)
    end
    for r, btn in pairs(runeBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.runeFilters[r] = not state.runeFilters[r]
            rebuildRuneLookup()
            applyRuneVisuals()
            log("Rune", r, state.runeFilters[r] and "ON" or "OFF")
        end)
    end
    for b, btn in pairs(boulderBtns) do
        btn.MouseButton1Click:Connect(function()
            if state.stopScript then return end
            state.boulderFilters[b] = not state.boulderFilters[b]
            applyBoulderVisuals()
            log("Boulder", b, state.boulderFilters[b] and "ON" or "OFF")
        end)
    end
    closeBtn.MouseButton1Click:Connect(function()
        state.masterEnabled = false
        state.stopScript = true
        disableFly()
        disableNoclip()
        if screenGui and screenGui.Parent then screenGui:Destroy() end
        _G.CombinedBoulderCrystalRunning = nil
        log("Script fully stopped.")
    end)
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed or state.stopScript then return end
        if input.KeyCode == Enum.KeyCode.X then
            toggleMaster()
        end
    end)
    applyMasterVisuals()
    applySortVisuals()
    applySellVisuals()
    applyMutVisuals()
    applyTierVisuals()
    applySizeVisuals()
    applyRuneVisuals()
    applyBoulderVisuals()
    return screenGui
end

-- ====================== LIFECYCLE ======================
waitForCharacter()
log("Waiting for Workspace.LavaHazards to exist...")
local lavaHazards = Workspace:WaitForChild("LavaHazards", 25)
if lavaHazards then
    log("LavaHazards ready.")
else
    warn("[Bot] LavaHazards never appeared – continuing anyway...")
end
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if Remotes then
    digEvent = Remotes:FindFirstChild("DigRequest")
end
if not digEvent then
    warn("[Bot] DigRequest remote not found – boulder digging will fail.")
end
local screenGui = createGUI()
task.wait(2.5)
waitForToolEquipped()
player.CharacterAdded:Connect(function(newChar)
    character = newChar
    hrp = character:WaitForChild("HumanoidRootPart", 30)
    humanoid = character:WaitForChild("Humanoid", 30)
    state.toolReady = false
    waitForToolEquipped()
    if state.masterEnabled and not state.stopScript then
        enableFly()
        if CONFIG.NOCLIP_ENABLED then enableNoclip() end
    end
end)
task.spawn(function()
    while not state.stopScript do
        if state.masterEnabled then
            if not isToolEquipped() then
                waitForToolEquipped()
                if not state.toolReady then
                    task.wait(1.0)
                    continue
                end
            end

            local foundBoulders = destroyBoulders()

            -- Always do crystal/rune cleanup
            deleteLowTierCrystals()
            deleteRunes()
            collectQualifyingCrystals()
            collectProtectedRunes()

            -- Only rejoin if no boulders AND still no collectibles after the final pass
            if not foundBoulders then
                if not hasQualifyingCollectibles() then
                    if (tick() - state.lastRejoinTime) > REJOIN_COOLDOWN then
                        log("No boulders + no crystals/runes after final scan → rejoining")
                        state.lastRejoinTime = tick()
                        autoSort()
                        sellAllCrystals()
                        rejoinGame()
                        state.stopScript = true
                    else
                        log("Rejoin on cooldown.")
                    end
                else
                    log("Found collectibles on final scan → skipping rejoin")
                end
            end

            task.wait(0.4)
        else
            task.wait(0.4)
        end
    end
    log("Master loop exited.")
end)
print("===========================================================")
print("Mine a mountain script (with smart pathing + closest target)")
print("===========================================================")