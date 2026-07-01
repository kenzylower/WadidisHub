-- ============================================================
--  Valstrax Auto Raid Loop
--  Flow: Check boss → if not found, teleport to portal → set limit 3
--        → click Start → wait for boss → stick + fight → repeat
-- ============================================================

local Players          = game:GetService("Players")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local vim              = game:GetService("VirtualInputManager")

-- Wait until LocalPlayer is available
local localPlayer
repeat
    localPlayer = Players.LocalPlayer
    if not localPlayer then task.wait(0.1) end
until localPlayer

-- Wait until PlayerGui is available
local playerGui
repeat
    playerGui = localPlayer:FindFirstChild("PlayerGui")
    if not playerGui then task.wait(0.1) end
until playerGui

-- Wait for character
if not localPlayer.Character then
    localPlayer.CharacterAdded:Wait()
end

-- ══════════════════════════════════════════════════════════════
--  CONFIG
-- ══════════════════════════════════════════════════════════════

local PORTAL_CF = CFrame.new(
    532.777771, 202.403214, -3241.55322, -0.707134247, 0, -0.707079291, 0, 1, 0, 0.707079291, 0, -0.707134247
)

local VALSTRAX_CF = CFrame.new(
    85.1660004, 645.124512, 20.5139999,
    0.990533471, 0, 0.137271285,
    0, 1, 0,
    -0.137271285, 0, 0.990533471
)

local NPCSPACE_CF = CFrame.new(
    498.458008, 200.500824, -3155.82227, 0.707134247, -0, -0.707079291, 0, 1, -0, 0.707079291, 0, 0.707134247
)

local BOSS_NAME  = "Valstrax"
local STICK_Y    = -13

-- ══════════════════════════════════════════════════════════════
--  STATE
-- ══════════════════════════════════════════════════════════════

local running     = false
local thread      = nil
local stickConn   = nil
local skillActive = false
local bossDefeated = false  -- ADD THIS LINE

-- ══════════════════════════════════════════════════════════════
--  HELPERS
-- ══════════════════════════════════════════════════════════════

local function make(class, props)
    local obj = Instance.new(class)
    for k,v in pairs(props) do if k~="Parent" then obj[k]=v end end
    if props.Parent then obj.Parent=props.Parent end
    return obj
end

local function getRoot()
    local char = localPlayer.Character or localPlayer.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart")
end

    local function pressKey(key)
        vim:SendKeyEvent(true,  key, false, game)
        task.wait(0.05)
        vim:SendKeyEvent(false, key, false, game)
    end

local function startSkills()
    if skillActive then return end
    skillActive = true
    task.spawn(function() while skillActive do pcall(pressKey, Enum.KeyCode.Z); task.wait(0.1) end end)
    task.spawn(function() while skillActive do pcall(pressKey, Enum.KeyCode.V); task.wait(0.15) end end)
end

local function stopSkills()
    skillActive = false
end

local function stopSticking()
    if stickConn then stickConn:Disconnect(); stickConn = nil end
end

local function stickToBoss(model)
    stopSticking()
    local part = model:FindFirstChild("HumanoidRootPart", true)
        or model:FindFirstChild("Torso", true)
        or model:FindFirstChild("UpperTorso", true)
    if not part then
        for _, v in ipairs(model:GetDescendants()) do
            if v:IsA("BasePart") then part = v; break end
        end
    end
    if not part then return end
    stickConn = RunService.Heartbeat:Connect(function()
        if not part or not part.Parent then stopSticking(); return end
        local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root then root.CFrame = part.CFrame * CFrame.new(0, STICK_Y, 0) end
    end)
end

local function getBoss()
    local es = workspace:FindFirstChild("EnemyService")
    if not es then return nil end
    for _, child in ipairs(es:GetChildren()) do
        if child.Name:find(BOSS_NAME) then return child end
    end
    return nil
end

local function isBossAlive(model)
    if not model or not model.Parent then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    return not hum or hum.Health > 0
end

local function isInBossWorld()
    local es = workspace:FindFirstChild("EnemyService")
    if es then
        for _, child in ipairs(es:GetChildren()) do
            if child.Name:find(BOSS_NAME) then return true end
        end
    end
    return false
end

local function getStartFrame()
    local ok, f = pcall(function()
        return playerGui.Main.Func.Raid.Content.Panel.Outline.Stats.Outline.Start
    end)
    return ok and f or nil
end

local function clickStart()
    local frame = getStartFrame()
    if not frame or not frame.Visible then return false end
    local pos = frame.AbsolutePosition + frame.AbsoluteSize / 2
    local inset = game:GetService("GuiService"):GetGuiInset()
    pos = pos + inset
    vim:SendMouseMoveEvent(pos.X, pos.Y, game)
    task.wait(0.05)
    vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true,  game, 0)
    task.wait(1)
    vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    return true
end

local function setPlayerLimit(n)
    pcall(function()
        local tb = playerGui.Main.Func.Raid.Content.Panel.Outline.Stats.Outline.Resources.Outline.People.Number.TextBox
        tb.Text = tostring(n)
    end)
end

local function clickDifficulty(diff)
    pcall(function()
        local frame = playerGui.Main.Func.Raid.Content.Panel.Outline.Chrono.ContentButten.Button[diff]
        local pos = frame.AbsolutePosition + frame.AbsoluteSize / 2
        local inset = game:GetService("GuiService"):GetGuiInset()
        pos = pos + inset
        vim:SendMouseMoveEvent(pos.X, pos.Y, game)
        task.wait(0.1)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true,  game, 0)
        task.wait(0.1)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true,  game, 0)
        task.wait(0.3)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
        task.wait(0.3)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
    end)
end

-- ══════════════════════════════════════════════════════════════
--  MAIN LOOP
-- ══════════════════════════════════════════════════════════════

local function mainLoop(statLbl, countLbl)
    local kills = 0

    while running do
        stopSkills()
        stopSticking()

        local boss = getBoss()

        if not isInBossWorld() and not boss then
            -- Main world — teleport to portal and click Start
            statLbl.Text = "● Teleporting to portal…"
            statLbl.TextColor3 = Color3.fromRGB(255,180,40)

            for i = 1, 3 do
        local root = getRoot()
        root.CFrame = NPCSPACE_CF
        task.wait(0.5)
    end
    task.wait(1)
    
            for i = 1, 3 do
                local root = getRoot()
                root.CFrame = PORTAL_CF
                task.wait(0.5)
            end
            task.wait(1)

            -- Click Hard difficulty
            clickDifficulty("Nightmare")
            task.wait(0.3)

            -- Set player limit to 3
            setPlayerLimit(3)
            task.wait(0.2)

            statLbl.Text = "● Clicking Start…"
            statLbl.TextColor3 = Color3.fromRGB(255,220,50)
            local clicked = false
            local attempts = 0
            while running and not clicked do
                attempts += 1
                if clickStart() then
                    clicked = true
                    print("[Valstrax] Start clicked (attempt " .. attempts .. ")")
                else
                    statLbl.Text = ("● Start not found, retrying… (#%d)"):format(attempts)
                    root = getRoot()
                    root.CFrame = PORTAL_CF
                    task.wait(1.5)
                end
            end
            if not running then break end

            -- Wait up to 20s for boss to appear
            statLbl.Text = "● Waiting for boss to spawn…"
            statLbl.TextColor3 = Color3.fromRGB(200,200,100)
            local waited = 0
            while running and not boss and waited < 20 do
                boss = getBoss()
                statLbl.Text = ("● Waiting for boss… (%ds)"):format(math.floor(waited))
                task.wait(0.5)
                waited += 0.5
            end
        else
            statLbl.Text = "● Boss world detected!"
            statLbl.TextColor3 = Color3.fromRGB(100,255,150)
            local waited = 0
            while running and not boss and waited < 10 do
                boss = getBoss()
                task.wait(0.5)
                waited += 0.5
            end
        end

        if not boss then
            statLbl.Text = "● Boss not found, retrying…"
            statLbl.TextColor3 = Color3.fromRGB(255,100,100)
            task.wait(2)
            continue
        end

        -- Teleport to boss 3 times to make sure
        statLbl.Text = "● Boss found! Teleporting…"
        statLbl.TextColor3 = Color3.fromRGB(255,120,40)
        for i = 1, 3 do
            local root = getRoot()
            root.CFrame = VALSTRAX_CF
            task.wait(0.3)
        end

        -- Stick + fight
        statLbl.Text = "● Fighting Valstrax!"
        statLbl.TextColor3 = Color3.fromRGB(100,255,150)
        stickToBoss(boss)
        startSkills()

        local fightModel = boss
        while running do
            if not isBossAlive(fightModel) then break end
            task.wait(0.1)
        end

        -- Boss dead
                -- Boss dead
        stopSkills()
        stopSticking()
        kills += 1
        countLbl.Text = ("Kills: %d"):format(kills)
        statLbl.Text = "● Boss defeated! Waiting for rewards…"
        statLbl.TextColor3 = Color3.fromRGB(100,255,120)
        
        -- Wait for kill to register and auto-teleport out
        task.wait(8)
        
        -- Check if we got the kill - stop the script
                -- Check if we got the kill - stop the script
        if kills >= 1 then
            statLbl.Text = "● Kill complete! Stopping…"
            statLbl.TextColor3 = Color3.fromRGB(100,255,100)
            running = false
            
            -- Use pcall to safely update GUI
            pcall(function()
                TweenService:Create(knob, tweenInfo, {
                    Position = UDim2.new(0, 3, 0.5, -9),
                    BackgroundColor3 = Color3.fromRGB(200, 120, 50)
                }):Play()
                TweenService:Create(track, tweenInfo, {
                    BackgroundColor3 = Color3.fromRGB(60, 30, 10)
                }):Play()
            end)
            
            if portalThread then task.cancel(portalThread); portalThread = nil end
            break  -- Exit the while loop completely
        end
        
        statLbl.Text = "● Returning to lobby…"
        statLbl.TextColor3 = Color3.fromRGB(255,180,40)
        task.wait()
    end

    stopSkills()
    stopSticking()
    statLbl.Text = "● IDLE"
    statLbl.TextColor3 = Color3.fromRGB(120,100,60)
end

-- ══════════════════════════════════════════════════════════════
--  GUI
-- ══════════════════════════════════════════════════════════════

local screen = make("ScreenGui",{Name="ValstraxLoop",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,Parent=playerGui})
local window = make("Frame",{Size=UDim2.new(0,250,0,160),Position=UDim2.new(0.5,-125,0.5,-80),
    BackgroundColor3=Color3.fromRGB(30,30,40),BorderSizePixel=0,Active=true,Parent=screen})
make("UICorner",{CornerRadius=UDim.new(0,10),Parent=window})
make("UIStroke",{Color=Color3.fromRGB(255,100,0),Thickness=1.5,Parent=window})

local titleBar = make("Frame",{Size=UDim2.new(1,0,0,36),BackgroundColor3=Color3.fromRGB(200,70,0),BorderSizePixel=0,ZIndex=3,Parent=window})
make("UICorner",{CornerRadius=UDim.new(0,10),Parent=titleBar})
make("Frame",{Size=UDim2.new(1,0,0,10),Position=UDim2.new(0,0,1,-10),BackgroundColor3=Color3.fromRGB(200,70,0),BorderSizePixel=0,ZIndex=3,Parent=titleBar})
make("TextLabel",{Size=UDim2.new(1,-12,1,0),Position=UDim2.new(0,12,0,0),BackgroundTransparency=1,
    Text="⚔️  VALSTRAX AUTO LOOP",TextColor3=Color3.fromRGB(255,255,255),Font=Enum.Font.GothamBold,TextSize=12,
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=4,Parent=titleBar})

local toggleRow = make("Frame",{Size=UDim2.new(1,-24,0,40),Position=UDim2.new(0,12,0,46),
    BackgroundColor3=Color3.fromRGB(25,18,10),BorderSizePixel=0,ZIndex=2,Parent=window})
make("UICorner",{CornerRadius=UDim.new(0,8),Parent=toggleRow})
make("UIStroke",{Color=Color3.fromRGB(255,100,0),Thickness=0.8,Transparency=0.4,Parent=toggleRow})
make("TextLabel",{Size=UDim2.new(1,-70,1,0),Position=UDim2.new(0,12,0,0),BackgroundTransparency=1,
    Text="⚔️ Auto Farm",TextColor3=Color3.fromRGB(255,200,100),Font=Enum.Font.GothamBold,TextSize=12,
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=3,Parent=toggleRow})
local track = make("Frame",{Size=UDim2.new(0,46,0,24),Position=UDim2.new(1,-58,0.5,-12),
    BackgroundColor3=Color3.fromRGB(60,30,10),BorderSizePixel=0,ZIndex=4,Parent=toggleRow})
make("UICorner",{CornerRadius=UDim.new(1,0),Parent=track})
local knob = make("Frame",{Size=UDim2.new(0,18,0,18),Position=UDim2.new(0,3,0.5,-9),
    BackgroundColor3=Color3.fromRGB(200,120,50),BorderSizePixel=0,ZIndex=5,Parent=track})
make("UICorner",{CornerRadius=UDim.new(1,0),Parent=knob})

local statLbl = make("TextLabel",{Size=UDim2.new(1,-24,0,16),Position=UDim2.new(0,12,0,96),
    BackgroundTransparency=1,Text="● IDLE",TextColor3=Color3.fromRGB(120,100,60),
    Font=Enum.Font.GothamBold,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=3,Parent=window})
local countLbl = make("TextLabel",{Size=UDim2.new(1,-24,0,16),Position=UDim2.new(0,12,0,114),
    BackgroundTransparency=1,Text="Kills: 0",TextColor3=Color3.fromRGB(255,180,80),
    Font=Enum.Font.Gotham,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=3,Parent=window})

local tweenInfo = TweenInfo.new(0.2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)

track.InputBegan:Connect(function(input)
    if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
    running = not running
    TweenService:Create(knob,tweenInfo,{Position=running and UDim2.new(0,25,0.5,-9) or UDim2.new(0,3,0.5,-9),BackgroundColor3=running and Color3.fromRGB(255,255,255) or Color3.fromRGB(200,120,50)}):Play()
    TweenService:Create(track,tweenInfo,{BackgroundColor3=running and Color3.fromRGB(255,100,0) or Color3.fromRGB(60,30,10)}):Play()
    if running then
        thread = task.spawn(function() mainLoop(statLbl, countLbl) end)
    else
        if thread then task.cancel(thread); thread=nil end
        stopSkills(); stopSticking()
        statLbl.Text="● IDLE"; statLbl.TextColor3=Color3.fromRGB(120,100,60)
    end
end)

local dragging,dragStart,startPos
titleBar.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true; dragStart=i.Position; startPos=window.Position end
end)
UserInputService.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
        local d=i.Position-dragStart; window.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end
end)
UserInputService.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end
end)

window.Size=UDim2.new(0,0,0,0); window.Position=UDim2.new(0.5,0,0.5,0)
TweenService:Create(window,TweenInfo.new(0.3,Enum.EasingStyle.Back,Enum.EasingDirection.Out),{
    Size=UDim2.new(0,250,0,160), Position=UDim2.new(0.5,-125,0.5,-80)}):Play()

print("[ValstraxLoop] Loaded")

-- Auto enable on load
task.spawn(function()
    task.wait(2)
    running = true
    TweenService:Create(knob,tweenInfo,{Position=UDim2.new(0,25,0.5,-9),BackgroundColor3=Color3.fromRGB(255,255,255)}):Play()
    TweenService:Create(track,tweenInfo,{BackgroundColor3=Color3.fromRGB(255,100,0)}):Play()
    thread = task.spawn(function() mainLoop(statLbl, countLbl) end)
    print("[ValstraxLoop] Auto-started")
end)

-- ══════════════════════════════════════════════════════════════
--  PORTAL STAY LOOP - Added at the very bottom
-- ══════════════════════════════════════════════════════════════

local portalThread = nil

local function stayAtPortal()
    while running do
        pcall(function()
            local root = getRoot()
            if root then
                root.CFrame = PORTAL_CF
            end
        end)
        task.wait(3)
    end
end

-- Override the mainLoop to include portal stay
local originalMainLoop = mainLoop
mainLoop = function(statLbl, countLbl)
    -- Start portal stay thread
    portalThread = task.spawn(stayAtPortal)
    
    -- Run original loop
    originalMainLoop(statLbl, countLbl)
    
    -- Clean up portal thread when done
    if portalThread then
        task.cancel(portalThread)
        portalThread = nil
    end
end

-- Also override the stop function to clean up portal thread
local originalStop = track.InputBegan
track.InputBegan:Connect(function(input)
    if input.UserInputType~=Enum.UserInputType.MouseButton1 and input.UserInputType~=Enum.UserInputType.Touch then return end
    running = not running
    TweenService:Create(knob,tweenInfo,{Position=running and UDim2.new(0,25,0.5,-9) or UDim2.new(0,3,0.5,-9),BackgroundColor3=running and Color3.fromRGB(255,255,255) or Color3.fromRGB(200,120,50)}):Play()
    TweenService:Create(track,tweenInfo,{BackgroundColor3=running and Color3.fromRGB(255,100,0) or Color3.fromRGB(60,30,10)}):Play()
    if running then
        thread = task.spawn(function() mainLoop(statLbl, countLbl) end)
    else
        if thread then task.cancel(thread); thread=nil end
        if portalThread then task.cancel(portalThread); portalThread = nil end
        stopSkills(); stopSticking()
        statLbl.Text="● IDLE"; statLbl.TextColor3=Color3.fromRGB(120,100,60)
    end
end)