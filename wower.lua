--[[
    Combined Boulder + Crystal Bot (Refactored)
    Master toggle: X key or GUI button
    Sequence when master is ON:
      1. Destroy allowed boulders
      2. Delete low-tier crystals + runes
      3. Collect high-tier (mutated) crystals
]]

-- ====================== CONFIG ======================
local CONFIG = {
    masterEnabledDefault   = true,
    boulderEnabledDefault  = true,
    crystalDeleteDefault   = true,
    crystalCollectDefault  = true,

    TOOL_NAME              = "The Terminus",
    DIG_RANGE              = 10000,          -- currently unused, kept for reference
    TWEEN_SPEED            = 1.5,
    FLY_HEIGHT             = 10,
    SPAM_DELAY             = 0.001,
    BURST_SIZE             = 50,
    DIG_INTERVAL           = 0.05,
    TIMEOUT_PER_BOULDER    = 90,
    NOCLIP_ENABLED         = true,
    SCAN_TELEPORT_POS      = Vector3.new(-38.815575, 240.036621, 477.202576),
    MAX_ZERO_SCANS         = 2,
    REJOIN_COOLDOWN        = 60,
    VERBOSE                = true,           -- set false to reduce console spam
}

local ALLOWED_BOULDERS = { "Nocturnite", "Rimeveil" }
local PRIORITY = { Nocturnite = 3, Rimeveil = 2, Gildrite = 1 }

-- ====================== SERVICES ======================
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local Workspace          = game:GetService("Workspace")
local VirtualInputManager= game:GetService("VirtualInputManager")

local player = Players.LocalPlayer
while not player do
    player = Players.LocalPlayer
    task.wait()
end

-- Prevent double-run
if _G.CombinedBoulderCrystalRunning then
    warn("[Bot] Already running. Close the existing GUI first.")
    return
end
_G.CombinedBoulderCrystalRunning = true

-- ====================== STATE ======================
local state = {
    masterEnabled          = CONFIG.masterEnabledDefault,
    boulderEnabled         = CONFIG.boulderEnabledDefault,
    crystalDeleteEnabled   = CONFIG.crystalDeleteDefault,
    crystalCollectEnabled  = CONFIG.crystalCollectDefault,
    stopScript             = false,
    toolReady              = false,
    isProcessingBoulder    = false,
    isTweening             = false,
    flying                 = false,
    noclipActive           = false,
    digCount               = 0,
    lastDigTime            = 0,
    zeroScanCount          = 0,
    lastRejoinTime         = 0,
    currentTarget          = nil,
    currentTween           = nil,
}

local character, hrp, humanoid
local bodyVelocity, bodyGyro
local originalCollideStates = {}
local boulderQueue = {}
local digEvent

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

local function isToolEquipped()
    if not character then return false end
    local tool = character:FindFirstChildOfClass("Tool")
    return tool and tool.Name == CONFIG.TOOL_NAME
end

local function equipTool()
    if not character or not humanoid then return false end
    local tool = player.Backpack:FindFirstChild(CONFIG.TOOL_NAME)
    if tool then
        humanoid:EquipTool(tool)
        return true
    end
    return false
end

local function waitForToolEquipped()
    log("Waiting for", CONFIG.TOOL_NAME, "to be equipped...")
    while not state.stopScript do
        if isToolEquipped() then
            state.toolReady = true
            log(CONFIG.TOOL_NAME, "is equipped.")
            return true
        end
        if equipTool() then
            task.wait(0.4)
            if isToolEquipped() then
                state.toolReady = true
                log(CONFIG.TOOL_NAME, "equipped from backpack.")
                return true
            end
        end
        task.wait(0.5)
    end
    return false
end

-- ====================== FLY / NOCLIP ======================
local linearVelocity: LinearVelocity? = nil
local alignOrientation: AlignOrientation? = nil
local flyAttachment: Attachment? = nil

local function enableNoclip()
    if state.noclipActive or not character then return end
    originalCollideStates = {}
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
    originalCollideStates = {}
    state.noclipActive = false
end

local function enableFly()
    if state.flying or not hrp or not humanoid then return end

    humanoid.PlatformStand = true
    humanoid.AutoRotate = false

    -- Create attachment (required by the new constraints)
    flyAttachment = Instance.new("Attachment")
    flyAttachment.Name = "FlyAttachment"
    flyAttachment.Parent = hrp

    -- Modern replacement for BodyVelocity
    linearVelocity = Instance.new("LinearVelocity")
    linearVelocity.MaxForce = math.huge
    linearVelocity.VectorVelocity = Vector3.zero
    linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
    linearVelocity.Attachment0 = flyAttachment
    linearVelocity.Parent = hrp

    -- Modern replacement for BodyGyro
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
    local vel = Vector3.zero
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
        vel += Vector3.yAxis * speed
    end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        vel -= Vector3.yAxis * speed
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

    local info = TweenInfo.new(CONFIG.TWEEN_SPEED, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    state.currentTween = TweenService:Create(hrp, info, { CFrame = targetCF })
    state.currentTween:Play()

    local start = tick()
    while state.currentTween and state.currentTween.PlaybackState == Enum.PlaybackState.Playing do
        if tick() - start > CONFIG.TWEEN_SPEED + 1.5 then
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

local function isAllowedBoulder(model)
    if not model then return false end
    for _, name in ipairs(ALLOWED_BOULDERS) do
        if model.Name == name then return true end
    end
    return false
end

local function continuousDig(boulder)
    if not isValidBoulder(boulder) or not digEvent then return false end
    local center = getBoulderPosition(boulder)
    if not center then return false end

    for i = 1, CONFIG.BURST_SIZE do
        if not isValidBoulder(boulder) then return true end
        local ok = pcall(function()
            digEvent:FireServer(CONFIG.TOOL_NAME, center)
        end)
        if ok then
            state.digCount += 1
            state.lastDigTime = tick()
        end
        if i < CONFIG.BURST_SIZE then task.wait(CONFIG.SPAM_DELAY) end
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
                table.insert(data, { model = model, position = pos, name = model.Name })
            end
        end
    end
    return data
end

-- ====================== BOULDER LOGIC ======================
local function scanAndBuildQueue()
    log("Scanning for boulders...")

    -- Always go to the scan position before checking
    tweenTo(CONFIG.SCAN_TELEPORT_POS)
    task.wait(0.9)          -- give the client a moment to stream the area

    local data = updateBoulderData()
    if #data == 0 then
        log("No allowed boulders found.")
        return false
    end

    table.sort(data, function(a, b)
        local pa = PRIORITY[a.name] or 0
        local pb = PRIORITY[b.name] or 0
        if pa ~= pb then return pa > pb end
        return (hrp.Position - a.position).Magnitude < (hrp.Position - b.position).Magnitude
    end)

    boulderQueue = {}
    for _, entry in ipairs(data) do
        table.insert(boulderQueue, entry.model)
    end
    log("Queued", #boulderQueue, "boulders.")
    return true
end

local function rejoinGame()
    local function findIYTextBox()
        local containers = { game:GetService("CoreGui") }
        if typeof(gethui) == "function" then
            table.insert(containers, gethui())
        end

        for _, container in ipairs(containers) do
            for _, gui in ipairs(container:GetDescendants()) do
                if gui:IsA("TextBox") then
                    local ph = gui.PlaceholderText or ""
                    if ph == "Command Bar (])" or ph:find("Command") then
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
        task.wait(0.12)
        pcall(function()
            firesignal(iyBox.FocusLost, true, Enum.UserInputType.Keyboard)
        end)
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
    tweenTo(pos, CONFIG.FLY_HEIGHT)

    local destroyed = false
    local start = tick()
    local lastReposition = 0

    while not destroyed and (tick() - start) < CONFIG.TIMEOUT_PER_BOULDER do
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
            tweenTo(currentPos, CONFIG.FLY_HEIGHT)
            lastReposition = tick()
        end

        task.wait(CONFIG.DIG_INTERVAL)
    end

    state.currentTarget = nil
    log(destroyed and ("Destroyed: " .. name) or ("Timeout: " .. name))
    return destroyed
end

local function destroyBoulders()
    if not state.boulderEnabled or not state.masterEnabled or state.stopScript then return end
    if state.isProcessingBoulder then return end

    if not isToolEquipped() then
        log("Tool missing – waiting...")
        waitForToolEquipped()
        if not state.toolReady then return end
    end

    log("Starting boulder cycle.")

    if #boulderQueue == 0 then
        local found = scanAndBuildQueue()
        if not found then
            state.zeroScanCount += 1
            log("Empty scan count:", state.zeroScanCount, "/", CONFIG.MAX_ZERO_SCANS)

            if state.zeroScanCount >= CONFIG.MAX_ZERO_SCANS then
                if (tick() - state.lastRejoinTime) > CONFIG.REJOIN_COOLDOWN then
                    log("No boulders after", CONFIG.MAX_ZERO_SCANS, "scans → rejoining")
                    state.lastRejoinTime = tick()
                    state.zeroScanCount = 0          -- reset so it doesn't spam
                    rejoinGame()
                else
                    log("Rejoin on cooldown.")
                end
            end
            return
        else
            state.zeroScanCount = 0
        end
    end

    while #boulderQueue > 0 and state.masterEnabled and state.boulderEnabled and not state.stopScript do
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

-- ====================== CRYSTAL LOGIC ======================
local MUTATION_KEYWORDS = {
    "mutation","mutant","evolved","corrupt","blessed","cursed",
    "radiant","shiny","glowing","altered","enhanced","warped",
    "infused","charged"
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
            for _, kw in ipairs(MUTATION_KEYWORDS) do
                if text:find(kw, 1, true) then return kw end
            end
        end
    end
    return nil
end

local function hasMutation(crystal)
    return getMutationType(crystal) ~= nil
end

local function shouldDelete(crystal)
    local tier = crystal:GetAttribute("Tier") or 0
    -- if tier <= 4 then return true end
    -- if tier == 5 or tier == 6 then return not hasMutation(crystal) end
    if tier <= 5 then return true end
    if tier == 6 then return not hasMutation(crystal) end
    return false
end

local function qualifiesForCollect(crystal)
    local tier = crystal:GetAttribute("Tier") or 0
    return (tier == 5 or tier == 6) and hasMutation(crystal)
end

local function deleteLowTierCrystals()
    if not state.crystalDeleteEnabled or not state.masterEnabled or state.stopScript then return end
    local ok, crystals = pcall(function()
        return Workspace.Things.Crystals:GetChildren()
    end)
    if not ok then return end

    local count = 0
    for _, c in ipairs(crystals) do
        if shouldDelete(c) and c.Parent then
            c:Destroy()
            count += 1
        end
    end
    if count > 0 then log("Deleted", count, "low-tier crystals.") end
end

local function deleteRunes()
    if not state.crystalDeleteEnabled or not state.masterEnabled or state.stopScript then return end
    local count = 0
    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj:IsA("Model") then
            local lower = obj.Name:lower()
            if lower:find("rune") or lower:find("enchant") then
                if obj.Parent then
                    obj:Destroy()
                    count += 1
                end
            end
        end
    end
    if count > 0 then log("Deleted", count, "runes/enchants.") end
end

local function collectQualifyingCrystals()
    if not state.crystalCollectEnabled or not state.masterEnabled or state.stopScript then return end
    local ok, crystals = pcall(function()
        return Workspace.Things.Crystals:GetChildren()
    end)
    if not ok then return end

    local qualifying = {}
    for _, c in ipairs(crystals) do
        if qualifiesForCollect(c) then
            table.insert(qualifying, c)
        end
    end

    if #qualifying == 0 then
        log("No qualifying crystals.")
        return
    end

    table.sort(qualifying, function(a, b)
        return (a:GetAttribute("Value") or 0) > (b:GetAttribute("Value") or 0)
    end)

    log("Collecting", #qualifying, "crystals...")

    for _, crystal in ipairs(qualifying) do
        if state.stopScript or not state.masterEnabled or not state.crystalCollectEnabled then break end
        if not crystal.Parent then continue end

        local name = crystal:GetAttribute("CrystalName") or crystal.Name
        local prompt = crystal:FindFirstChildWhichIsA("ProximityPrompt", true)
        if not prompt then
            log("No ProximityPrompt on", name)
            continue
        end

        local attempts = 0
        while crystal.Parent and state.masterEnabled and state.crystalCollectEnabled and not state.stopScript do
            attempts += 1

            local pos = crystal:IsA("Model") and crystal:GetPivot().Position or crystal.Position
            if not pos then break end

            -- Move to crystal if too far
            if hrp and (pos - hrp.Position).Magnitude > 5 then
                hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
                task.wait(0.08)
            end

            

            -- Also try the normal proximity prompt + E key
            pcall(function()
                if fireproximityprompt then fireproximityprompt(prompt) end
            end)
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
            task.wait(0.15)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            task.wait(0.05)

            -- Send DigRequest to the crystal position only every 5 attempts
            if attempts % 5 == 0 and digEvent then
                pcall(function()
                    digEvent:FireServer(CONFIG.TOOL_NAME, pos)
                end)
            end

            if not crystal.Parent then
                log("Collected:", name)
                break
            end
            if attempts > 250 then
                log("Max attempts reached for", name)
                break
            end
        end
        task.wait(0.05)
    end
    log("Collection cycle done.")
end

-- ====================== GUI ======================
local function createGUI()
    for _, gui in ipairs(player.PlayerGui:GetChildren()) do
        if gui.Name:find("CombinedBoulderCrystal") then gui:Destroy() end
    end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "CombinedBoulderCrystal"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = player.PlayerGui

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(280, 210)
    main.Position = UDim2.fromScale(0.01, 0.1)
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

    local function makeToggle(y, label, get, set)
        local bg = Instance.new("Frame")
        bg.Size = UDim2.new(1, -10, 0, 22)
        bg.Position = UDim2.fromOffset(5, y)
        bg.BackgroundColor3 = Color3.fromRGB(28, 28, 50)
        bg.BorderSizePixel = 0
        bg.Parent = main
        Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 4)

        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(0.68, 0, 1, 0)
        lbl.Position = UDim2.fromOffset(6, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = label
        lbl.TextColor3 = Color3.fromRGB(200, 200, 230)
        lbl.TextSize = 11
        lbl.Font = Enum.Font.Gotham
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = bg

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.28, 0, 1, -4)
        btn.Position = UDim2.new(0.7, 0, 0.5, -9)
        btn.BorderSizePixel = 0
        btn.TextSize = 10
        btn.Font = Enum.Font.GothamBold
        btn.TextColor3 = Color3.new(1, 1, 1)
        btn.Parent = bg
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 3)

        local function refresh()
            local on = get()
            btn.Text = on and "ON" or "OFF"
            btn.BackgroundColor3 = on and Color3.fromRGB(0, 170, 0) or Color3.fromRGB(180, 40, 40)
        end
        refresh()

        btn.MouseButton1Click:Connect(function()
            set(not get())
            refresh()
        end)
        return btn
    end

    makeToggle(54,  "🔨 Destroy Boulders",
        function() return state.boulderEnabled end,
        function(v) state.boulderEnabled = v end)
    makeToggle(78,  "🗑 Delete Low-Tier Crystals",
        function() return state.crystalDeleteEnabled end,
        function(v) state.crystalDeleteEnabled = v end)
    makeToggle(102, "💎 Collect High-Tier Crystals",
        function() return state.crystalCollectEnabled end,
        function(v) state.crystalCollectEnabled = v end)

    local masterBtn = Instance.new("TextButton")
    masterBtn.Size = UDim2.new(0.7, 0, 0, 30)
    masterBtn.Position = UDim2.fromOffset(14, 135)
    masterBtn.TextSize = 14
    masterBtn.Font = Enum.Font.GothamBold
    masterBtn.TextColor3 = Color3.new(1, 1, 1)
    masterBtn.Parent = main
    Instance.new("UICorner", masterBtn).CornerRadius = UDim.new(0, 6)

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

    local function toggleMaster()
        if state.stopScript then return end
        state.masterEnabled = not state.masterEnabled
        applyMasterVisuals()
        log(state.masterEnabled and "ENABLED" or "DISABLED")
    end

    masterBtn.MouseButton1Click:Connect(toggleMaster)
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
    return screenGui, applyMasterVisuals
end

-- ====================== LIFECYCLE ======================
waitForCharacter()

-- Wait for Workspace.MountainDecorations to exist and have children
log("Waiting for Workspace.MountainDecorations to have children...")
local mountainDecor = Workspace:WaitForChild("MountainDecorations", 20)
if mountainDecor then
    while #mountainDecor:GetChildren() == 0 and not state.stopScript do
        task.wait(0.5)
    end
    if not state.stopScript then
        log("MountainDecorations is ready (" .. #mountainDecor:GetChildren() .. " children).")
    end
else
    warn("[Bot] MountainDecorations never appeared (timeout). Continuing anyway...")
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if Remotes then
    digEvent = Remotes:FindFirstChild("DigRequest")
end
if not digEvent then
    warn("[Bot] DigRequest remote not found – boulder digging will fail.")
end

local screenGui = createGUI()

-- Block until tool is ready (or user closes)
waitForToolEquipped()

-- Character respawn handling
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

-- Main loop
task.spawn(function()
    while not state.stopScript do
        if state.masterEnabled then
            if not isToolEquipped() then
                log("Tool not equipped – waiting...")
                waitForToolEquipped()
                if not state.toolReady then
                    task.wait(1)
                    continue
                end
            end

            -- Original priority order
            destroyBoulders()              -- can teleport to base only when queue is empty
            deleteLowTierCrystals()
            deleteRunes()
            collectQualifyingCrystals()    -- goes crystal → crystal → crystal (no base teleport inside here)

            task.wait(1.5)
        else
            task.wait(0.8)
        end
    end
    log("Master loop exited.")
end)

print("========================================")
print("⚡ Refactored Boulder + Crystal Bot loaded")
print("   X / GUI button = master toggle")
print("   Sub-toggles control individual features")
print("   Close with ✕ button")
print("   CONFIG.VERBOSE = false to silence logs")
print("========================================")