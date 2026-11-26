getgenv().KnifeHub = getgenv().KnifeHub or {}
if getgenv().KnifeHub.loading then return end
getgenv().KnifeHub.loading = true

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local CoreGui          = game:GetService("CoreGui")

local LP     = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local repo         = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library      = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager  = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local Options = Library.Options
local Toggles = Library.Toggles

local function tryRequire(getter)
    local ok, inst = pcall(getter)
    if not ok or not inst then return nil end
    local ok2, mod = pcall(require, inst)
    return ok2 and mod or nil
end

local Scripts     = LP:WaitForChild("PlayerScripts")
local Controllers = Scripts:WaitForChild("Controllers", 15)
local Shared      = ReplicatedStorage:WaitForChild("Shared", 15)

local KnifeController  = tryRequire(function() return Controllers.Combat.KnifeController end)
local MatchController  = tryRequire(function() return Controllers.Match.MatchController end)
local InventoryClient  = tryRequire(function() return Controllers.Utils.InventoryClient end)
local EquippedRep      = tryRequire(function() return Controllers.Utils.EquippedKnifeReplicationController end)
local ViewmodelCtrl    = tryRequire(function() return Controllers.Combat.ViewmodelController end)
local KnifeConfig      = tryRequire(function() return Shared.KnifeConfig end) or {}
local Constants        = tryRequire(function() return Shared.KnifeConstantsConfig end)
local Trajectory       = tryRequire(function() return Shared.KnifeThrowTrajectory end)

local Connections, Cleanups = {}, {}
local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

-- ── Mobile detection ──────────────────────────────────────────────────────────
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function isTouchDevice()
    local last = UserInputService:GetLastInputType()
    return last == Enum.UserInputType.Touch
        or (UserInputService.TouchEnabled and not UserInputService.MouseEnabled)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function isEnemy(plr, useTeamCheck)
    if plr == LP then return false end
    if not useTeamCheck then return true end

    if MatchController and MatchController.IsPlayerEnemy then
        local ok, res = pcall(MatchController.IsPlayerEnemy, MatchController, plr)
        if ok then return res == true end
    end
    if LP.Team and plr.Team == LP.Team then return false end
    return true
end

local function getHumanoid(char)
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function isAlive(plr)
    local hum = getHumanoid(plr.Character)
    return hum ~= nil and hum.Health > 0
end

local function pickPart(char)
    local name = Options.TargetPart and Options.TargetPart.Value or "Head"
    return char:FindFirstChild(name)
        or char:FindFirstChild("UpperTorso")
        or char:FindFirstChild("HumanoidRootPart")
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function isVisible(part, char)
    local origin = Camera.CFrame.Position
    rayParams.FilterDescendantsInstances = { LP.Character, char, Camera }
    return Workspace:Raycast(origin, part.Position - origin, rayParams) == nil
end

-- screenCenter: returns the screen-space point used as the FOV anchor.
-- On mobile "Mouse" mode makes no sense, so always use screen center on touch.
local function screenCenter()
    if not isTouchDevice() and Options.FOVOrigin and Options.FOVOrigin.Value == "Mouse" then
        local loc = UserInputService:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        if loc.X > 0 or loc.Y > 0 then
            return loc - inset
        end
    end
    return Camera.ViewportSize / 2
end

-- ── Targeting ─────────────────────────────────────────────────────────────────
local function getTarget()
    local center  = screenCenter()
    local radius  = Options.FOVRadius.Value
    local best, bestDist

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isAlive(plr) and isEnemy(plr, Toggles.TeamCheck.Value) then
            local char = plr.Character
            local part = pickPart(char)
            if part then
                local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen and sp.Z > 0 then
                    local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if (not Toggles.FOVOnly.Value or d <= radius) and (not bestDist or d < bestDist) then
                        if not Toggles.WallCheck.Value or isVisible(part, char) then
                            best, bestDist = { Player = plr, Character = char, Part = part }, d
                        end
                    end
                end
            end
        end
    end
    return best
end

-- ── Trajectory solver ─────────────────────────────────────────────────────────
local function solveDirection(originCF, part)
    local origin    = originCF.Position
    local targetPos = part.Position
    local straight  = (targetPos - origin).Unit

    local wantDrop    = Toggles.DropComp.Value
    local wantPredict = Toggles.Predict.Value
    if not (wantDrop or wantPredict) or not Trajectory or not Constants then
        return straight
    end

    local vel = wantPredict and (part.AssemblyLinearVelocity * Options.PredictScale.Value) or Vector3.zero
    local aim = targetPos
    local t   = 0

    for _ = 1, 8 do
        local dir  = (aim - origin).Unit
        local want = ((targetPos + vel * t) - origin).Magnitude

        local lo, hi = 0, 3
        for _ = 1, 18 do
            local mid = (lo + hi) / 2
            local r   = Trajectory.Evaluate(originCF, dir, mid)
            if r.displacement:Dot(dir) < want then lo = mid else hi = mid end
        end
        t = (lo + hi) / 2

        local predicted = targetPos + vel * t
        if not wantDrop then
            aim = predicted
        else
            local r = Trajectory.Evaluate(originCF, dir, t)
            aim = aim + (predicted - r.position)
        end
    end
    return (aim - origin).Unit
end

-- ── UI ────────────────────────────────────────────────────────────────────────
local Window = Library:CreateWindow({
    Title           = "KnifeHub",
    Footer          = "obsidian",
    NotifySide      = "Right",
    ShowCustomCursor = false,
})

local Tabs = {
    Combat   = Window:AddTab("Combat",   "crosshair"),
    Visuals  = Window:AddTab("Visuals",  "eye"),
    Cosmetic = Window:AddTab("Cosmetic", "palette"),
    Settings = Window:AddTab("Settings", "settings"),
}

-- ── Aimbot groupbox (LEFT) ────────────────────────────────────────────────────
local AimBox = Tabs.Combat:AddLeftGroupbox("Aimbot", "target")

AimBox:AddToggle("Aimbot", { Text = "Enable Aimbot", Default = false })

AimBox:AddSlider("AimSmooth", {
    Text    = "Smoothness",
    Default = 10,
    Min     = 0,
    Max     = 95,
    Rounding = 0,
    Suffix  = "%",
    Tooltip = "0 = instant snap, higher = slower / smoother",
})

-- ── Targeting groupbox (LEFT, under Aimbot) ───────────────────────────────────
local TargetBox = Tabs.Combat:AddLeftGroupbox("Targeting", "users")

TargetBox:AddDropdown("TargetPart", {
    Text   = "Target part",
    Values = { "Head", "UpperTorso", "HumanoidRootPart" },
    Default = 1,
})
TargetBox:AddToggle("TeamCheck",  { Text = "Team check",           Default = true })
TargetBox:AddToggle("WallCheck",  { Text = "Wall check",           Default = true })
TargetBox:AddToggle("Predict",    { Text = "Movement prediction",   Default = true })
TargetBox:AddSlider("PredictScale", {
    Text = "Prediction scale", Default = 1, Min = 0, Max = 2, Rounding = 2,
})
TargetBox:AddToggle("DropComp", { Text = "Knife drop compensation", Default = true })

-- ── FOV groupbox (RIGHT) ──────────────────────────────────────────────────────
local FovBox = Tabs.Combat:AddRightGroupbox("FOV", "circle-dashed")

FovBox:AddToggle("ShowFOV", { Text = "Show FOV circle", Default = true })
    :AddColorPicker("FOVColor", { Default = Color3.fromRGB(255, 255, 255), Title = "FOV color" })
FovBox:AddToggle("FOVFilled",  { Text = "Filled FOV", Default = false })
FovBox:AddSlider("FOVFillOpacity", {
    Text = "Fill opacity", Default = 0.15, Min = 0.05, Max = 1, Rounding = 2,
})
FovBox:AddSlider("FOVRadius", {
    Text = "Radius", Default = 150, Min = 10, Max = 600, Rounding = 0, Suffix = "px",
})
FovBox:AddSlider("FOVThickness", {
    Text = "Outline thickness", Default = 1, Min = 1, Max = 5, Rounding = 0,
})
-- Only show mouse-origin option on PC; on mobile it has no effect
if not isMobile then
    FovBox:AddDropdown("FOVOrigin", {
        Text   = "FOV origin",
        Values = { "Screen Center", "Mouse" },
        Default = 1,
    })
else
    -- Create a stub so Options.FOVOrigin.Value is always "Screen Center"
    FovBox:AddLabel("FOV origin: Screen Center (mobile)")
    -- Provide a compatible stub so screenCenter() doesn't error
    Options["FOVOrigin"] = { Value = "Screen Center" }
end
FovBox:AddToggle("FOVOnly", { Text = "Only target inside FOV", Default = true })

-- ── ESP ───────────────────────────────────────────────────────────────────────
local EspBox = Tabs.Visuals:AddLeftGroupbox("ESP", "scan-eye")

EspBox:AddToggle("ESPEnabled",  { Text = "Enable ESP",    Default = false })
EspBox:AddToggle("ESPTeamCheck",{ Text = "Enemies only",  Default = true })
EspBox:AddSlider("ESPMaxDist",  { Text = "Max distance",  Default = 1500, Min = 50, Max = 5000, Rounding = 0, Suffix = " studs" })
EspBox:AddSlider("ESPTextSize", { Text = "Text size",     Default = 13,   Min = 10, Max = 24,   Rounding = 0 })

local EspElements = Tabs.Visuals:AddRightGroupbox("Elements", "layers")

EspElements:AddToggle("ESPBox", { Text = "Box", Default = true })
    :AddColorPicker("ESPBoxColor",  { Default = Color3.fromRGB(255, 70, 70), Title = "Box color" })
EspElements:AddToggle("ESPFill", { Text = "Filled box", Default = false })
    :AddColorPicker("ESPFillColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Fill color" })
EspElements:AddSlider("ESPFillOpacity", { Text = "Fill opacity", Default = 0.2, Min = 0.05, Max = 1, Rounding = 2 })
EspElements:AddToggle("ESPName", { Text = "Name", Default = true })
    :AddColorPicker("ESPNameColor",  { Default = Color3.fromRGB(255, 255, 255), Title = "Name color" })
EspElements:AddToggle("ESPHealth",   { Text = "Health bar",  Default = true })
EspElements:AddToggle("ESPDistance", { Text = "Distance",    Default = true })
    :AddColorPicker("ESPDistColor",  { Default = Color3.fromRGB(200, 200, 200), Title = "Distance color" })
EspElements:AddToggle("ESPTracer", { Text = "Tracers", Default = false })
    :AddColorPicker("ESPTracerColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Tracer color" })
EspElements:AddDropdown("ESPTracerOrigin", {
    Text = "Tracer origin", Values = { "Bottom", "Center", "Top" }, Default = 1,
})
EspElements:AddToggle("ESPChams", { Text = "Chams (highlight)", Default = false })
    :AddColorPicker("ESPChamsColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Chams color" })
EspElements:AddSlider("ESPChamsFill", { Text = "Chams fill opacity", Default = 0.5, Min = 0, Max = 1, Rounding = 2 })

-- ── Cosmetic ──────────────────────────────────────────────────────────────────
local knifeLabels, knifeLabelToId = {}, {}
for id, data in pairs(KnifeConfig) do
    if type(data) == "table" then
        local label = string.format("%s - %s (%s)", tostring(data.Name or id), tostring(data.Type or "?"), id)
        table.insert(knifeLabels, label)
        knifeLabelToId[label] = id
    end
end
table.sort(knifeLabels)
if #knifeLabels == 0 then knifeLabels = { "Default" }; knifeLabelToId["Default"] = "Default" end

local KnifeBox = Tabs.Cosmetic:AddLeftGroupbox("Knives", "swords")

KnifeBox:AddToggle("UnlockAll", {
    Text    = "Unlock all knives (inventory UI)",
    Default = false,
    Tooltip = "Adds every knife to your inventory view. Local only.",
})
KnifeBox:AddDropdown("KnifePick", { Text = "Knife", Values = knifeLabels, Default = 1, Searchable = true })
KnifeBox:AddToggle("ForceKnife", {
    Text    = "Use selected knife (viewmodel + throw skin)",
    Default = false,
    Tooltip = "Only you see it.",
})
KnifeBox:AddButton({ Text = "Apply / refresh", Func = function()
    if _G.__KnifeHubApply then _G.__KnifeHubApply() end
end })

-- ── Settings ──────────────────────────────────────────────────────────────────
local MenuGroup = Tabs.Settings:AddLeftGroupbox("Menu", "wrench")
MenuGroup:AddToggle("KeybindMenuOpen", {
    Default  = Library.KeybindFrame and Library.KeybindFrame.Visible or false,
    Text     = "Open keybind menu",
    Callback = function(v) if Library.KeybindFrame then Library.KeybindFrame.Visible = v end end,
})
MenuGroup:AddButton("Unload", function() Library:Unload() end)
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", {
    Default = "RightShift", NoUI = true, Text = "Menu keybind",
})
Library.ToggleKeybind = Options.MenuKeybind

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
ThemeManager:SetFolder("KnifeHub")
SaveManager:SetFolder("KnifeHub/knife")
SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()

-- ── Drawing utils ─────────────────────────────────────────────────────────────
local hasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
if not hasDrawing then
    Library:Notify({ Title = "KnifeHub", Description = "Drawing API missing — FOV circle and ESP are disabled.", Time = 6 })
end

local function newDrawing(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props) do d[k] = v end
    return d
end
local function killDrawing(d) pcall(function() d:Remove() end) end

local FovCircle = hasDrawing and newDrawing("Circle", { NumSides = 64, Visible = false, ZIndex = 5 }) or nil

-- ── Aimbot RenderStep ─────────────────────────────────────────────────────────
-- Fix: smoothness formula was inverted. The slider is labelled 0=instant, 95=slowest.
-- Correct alpha: map [0..95] → lerp factor [1..~0.03] using exp decay.
-- alpha = exp(-k * dt) where k scales with inverse of smoothness.
-- We use: alpha = 1 - (smooth/100)^(dt*60)  BUT clamp minimum alpha so it never stalls.
-- Actual fix: invert — higher slider value → lower alpha (slower).
--   raw_smooth = AimSmooth.Value / 100          (0 = no smooth, 0.95 = max smooth)
--   At dt≈0.016, we want:
--     smooth=0  → alpha=1 (instant)
--     smooth=50 → alpha≈0.5
--     smooth=95 → alpha≈0.05
--   Formula: alpha = 1 - raw_smooth  doesn't depend on dt, bad.
--   Better: alpha = (1 - raw_smooth)^(dt * 60)
--   At raw=0 → 1^anything = 1 ✓
--   At raw=0.5, dt=0.016 → 0.5^(0.96) ≈ 0.51 ✓
--   At raw=0.95, dt=0.016 → 0.05^(0.96) ≈ 0.054 ✓
--   This is the correct inversion of the original broken formula.

local AIM_BIND = "KnifeHubAimbot"
RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 10, function(dt)
    Camera = Workspace.CurrentCamera

    -- FOV circle
    if FovCircle then
        FovCircle.Visible = Toggles.ShowFOV.Value
        if FovCircle.Visible then
            FovCircle.Position     = screenCenter()
            FovCircle.Radius       = Options.FOVRadius.Value
            FovCircle.Color        = Options.FOVColor.Value
            FovCircle.Thickness    = Options.FOVThickness.Value
            FovCircle.Filled       = Toggles.FOVFilled.Value
            FovCircle.Transparency = Toggles.FOVFilled.Value and Options.FOVFillOpacity.Value or 1
        end
    end

    if not Toggles.Aimbot.Value then return end
    local target = getTarget()
    if not target then return end

    local cf  = Camera.CFrame
    local dir = solveDirection(cf, target.Part)

    -- Fixed-alpha lerp: same pattern as working reference scripts.
    -- Slider 0 = instant (alpha 1.0), slider 95 = slowest (alpha 0.05).
    -- No dt scaling — constant per-frame alpha matches what actually works.
    local raw   = Options.AimSmooth.Value / 100          -- 0.0 .. 0.95
    local alpha = math.clamp(1 - raw, 0.05, 1.0)

    Camera.CFrame = Camera.CFrame:Lerp(CFrame.lookAt(cf.Position, cf.Position + dir), alpha)
end)
table.insert(Cleanups, function() pcall(RunService.UnbindFromRenderStep, RunService, AIM_BIND) end)

-- ── ESP ───────────────────────────────────────────────────────────────────────
-- Box drawn as 4 Lines (universal) instead of Square (not supported everywhere).
-- BillboardGui fallback covers executors/mobile with no Drawing API at all.
-- Transparency: Drawing uses 0=opaque,1=transparent on all major executors.

local ESPObjects, Chams = {}, {}
local guiParent = (typeof(gethui) == "function" and pcall(gethui) and gethui()) or CoreGui

-- Make a 4-line box from individual Line objects (works on every executor)
local function newBox(zIndex)
    local lines = {}
    for i = 1, 4 do
        lines[i] = newDrawing("Line", { Thickness = 1, Visible = false, ZIndex = zIndex })
    end
    return lines
end

local function setBox(lines, x, y, w, h, color, visible)
    -- top, bottom, left, right
    local corners = {
        { Vector2.new(x,   y),   Vector2.new(x+w, y)   },
        { Vector2.new(x,   y+h), Vector2.new(x+w, y+h) },
        { Vector2.new(x,   y),   Vector2.new(x,   y+h) },
        { Vector2.new(x+w, y),   Vector2.new(x+w, y+h) },
    }
    for i, l in ipairs(lines) do
        l.Visible = visible
        if visible then
            l.From  = corners[i][1]
            l.To    = corners[i][2]
            l.Color = color
        end
    end
end

local function hideBox(lines)
    for _, l in ipairs(lines) do l.Visible = false end
end

local function killBox(lines)
    for _, l in ipairs(lines) do killDrawing(l) end
end

-- BillboardGui fallback: used when Drawing is unavailable (mobile executors)
local function createBillboard(char)
    local bb = Instance.new("BillboardGui")
    bb.Name            = "KnifeHubESP"
    bb.AlwaysOnTop     = true
    bb.Size            = UDim2.new(0, 0, 0, 0)
    bb.StudsOffset     = Vector3.new(0, 3.5, 0)
    bb.Adornee         = char:FindFirstChild("HumanoidRootPart")
    bb.Parent          = guiParent

    local nameLabel = Instance.new("TextLabel", bb)
    nameLabel.Name              = "Name"
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextColor3        = Color3.fromRGB(255,255,255)
    nameLabel.TextStrokeTransparency = 0
    nameLabel.TextStrokeColor3  = Color3.new(0,0,0)
    nameLabel.Font              = Enum.Font.GothamBold
    nameLabel.TextSize          = 13
    nameLabel.Size              = UDim2.new(1, 0, 0, 20)
    nameLabel.Position          = UDim2.new(0, 0, 0, 0)
    nameLabel.TextXAlignment    = Enum.TextXAlignment.Center

    local distLabel = Instance.new("TextLabel", bb)
    distLabel.Name              = "Dist"
    distLabel.BackgroundTransparency = 1
    distLabel.TextColor3        = Color3.fromRGB(200,200,200)
    distLabel.TextStrokeTransparency = 0
    distLabel.TextStrokeColor3  = Color3.new(0,0,0)
    distLabel.Font              = Enum.Font.Gotham
    distLabel.TextSize          = 11
    distLabel.Size              = UDim2.new(1, 0, 0, 16)
    distLabel.Position          = UDim2.new(0, 0, 0, 20)
    distLabel.TextXAlignment    = Enum.TextXAlignment.Center

    return bb
end

local function createESP(plr)
    if plr == LP or ESPObjects[plr] then return end
    if hasDrawing then
        ESPObjects[plr] = {
            mode       = "drawing",
            BoxLines   = newBox(2),
            FillLines  = newBox(1),   -- 4 lines won't fill; fill done via Quad if available
            Name       = newDrawing("Text", { Center = true, Outline = true, Visible = false, ZIndex = 4 }),
            Dist       = newDrawing("Text", { Center = true, Outline = true, Visible = false, ZIndex = 4 }),
            HealthBack = newDrawing("Line", { Thickness = 4, Visible = false, ZIndex = 2, Color = Color3.new(0,0,0) }),
            Health     = newDrawing("Line", { Thickness = 2, Visible = false, ZIndex = 3 }),
            Tracer     = newDrawing("Line", { Thickness = 1, Visible = false, ZIndex = 1 }),
        }
        -- Try Quad for fill (more executors support it than Square)
        local ok, quad = pcall(Drawing.new, "Quad")
        if ok and quad then
            quad.Filled  = true
            quad.Visible = false
            quad.ZIndex  = 1
            ESPObjects[plr].FillQuad = quad
            -- kill the 4-line fill placeholders, we have a real quad
            killBox(ESPObjects[plr].FillLines)
            ESPObjects[plr].FillLines = nil
        end
    else
        -- No Drawing — BillboardGui fallback (works on mobile)
        local char = plr.Character
        if not char then
            -- will get created on CharacterAdded
            ESPObjects[plr] = { mode = "billboard", bb = nil, char = nil }
            return
        end
        ESPObjects[plr] = { mode = "billboard", bb = createBillboard(char), char = char }
    end
end

local function ensureBillboard(plr)
    local o = ESPObjects[plr]
    if not o or o.mode ~= "billboard" then return end
    local char = plr.Character
    if char and char ~= o.char then
        if o.bb then pcall(function() o.bb:Destroy() end) end
        o.bb   = createBillboard(char)
        o.char = char
    end
end

local function hideESP(o)
    if o.mode == "drawing" then
        hideBox(o.BoxLines)
        if o.FillLines  then hideBox(o.FillLines) end
        if o.FillQuad   then o.FillQuad.Visible   = false end
        if o.Name       then o.Name.Visible        = false end
        if o.Dist       then o.Dist.Visible        = false end
        if o.HealthBack then o.HealthBack.Visible  = false end
        if o.Health     then o.Health.Visible      = false end
        if o.Tracer     then o.Tracer.Visible      = false end
    elseif o.mode == "billboard" and o.bb then
        o.bb.Enabled = false
    end
end

local function removeESP(plr)
    local o = ESPObjects[plr]
    if o then
        if o.mode == "drawing" then
            killBox(o.BoxLines)
            if o.FillLines then killBox(o.FillLines) end
            if o.FillQuad  then killDrawing(o.FillQuad) end
            for _, k in ipairs({"Name","Dist","HealthBack","Health","Tracer"}) do
                if o[k] then killDrawing(o[k]) end
            end
        elseif o.mode == "billboard" and o.bb then
            pcall(function() o.bb:Destroy() end)
        end
        ESPObjects[plr] = nil
    end
    if Chams[plr] then pcall(function() Chams[plr]:Destroy() end); Chams[plr] = nil end
end

local function setChams(plr, char, on)
    local h = Chams[plr]
    if not on then if h then h.Enabled = false end; return end
    if not h or not h.Parent then
        h = Instance.new("Highlight")
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent    = guiParent
        Chams[plr]  = h
    end
    h.Adornee             = char
    h.Enabled             = true
    h.FillColor           = Options.ESPChamsColor.Value
    h.OutlineColor        = Options.ESPChamsColor.Value
    h.FillTransparency    = 1 - Options.ESPChamsFill.Value
    h.OutlineTransparency = 0
end

for _, plr in ipairs(Players:GetPlayers()) do createESP(plr) end
connect(Players.PlayerAdded,   createESP)
connect(Players.PlayerRemoving, removeESP)

-- Re-attach billboard when character respawns
connect(Players.PlayerAdded, function(plr)
    connect(plr.CharacterAdded, function()
        task.wait(1)
        ensureBillboard(plr)
    end)
end)
for _, plr in ipairs(Players:GetPlayers()) do
    connect(plr.CharacterAdded, function()
        task.wait(1)
        ensureBillboard(plr)
    end)
end

local ESP_BIND = "KnifeHubESP"
RunService:BindToRenderStep(ESP_BIND, Enum.RenderPriority.Camera.Value + 11, function()
    local enabled  = Toggles.ESPEnabled.Value
    local camCF    = Camera.CFrame
    local vp       = Camera.ViewportSize
    local textSize = Options.ESPTextSize.Value

    for plr, o in pairs(ESPObjects) do
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = getHumanoid(char)
        local shouldShow = enabled and root and hum and hum.Health > 0
                       and isEnemy(plr, Toggles.ESPTeamCheck.Value)

        -- ── Billboard fallback path ──────────────────────────────────────────
        if o.mode == "billboard" then
            ensureBillboard(plr)
            if o.bb then
                o.bb.Enabled = shouldShow
                if shouldShow then
                    local dist = (camCF.Position - root.Position).Magnitude
                    o.bb.Enabled = dist <= Options.ESPMaxDist.Value
                    if o.bb.Enabled then
                        local nameL = o.bb:FindFirstChild("Name")
                        local distL = o.bb:FindFirstChild("Dist")
                        if nameL then
                            nameL.Visible    = Toggles.ESPName.Value
                            nameL.Text       = plr.DisplayName
                            nameL.TextSize   = textSize
                            nameL.TextColor3 = Options.ESPNameColor.Value
                        end
                        if distL then
                            distL.Visible    = Toggles.ESPDistance.Value
                            distL.Text       = string.format("%d studs", math.floor(dist))
                            distL.TextSize   = math.max(textSize - 2, 10)
                            distL.TextColor3 = Options.ESPDistColor.Value
                        end
                    end
                end
                setChams(plr, char, shouldShow and Toggles.ESPChams.Value)
            end
            continue
        end

        -- ── Drawing path ─────────────────────────────────────────────────────
        local visible = false

        if shouldShow then
            local dist = (camCF.Position - root.Position).Magnitude
            if dist <= Options.ESPMaxDist.Value then
                local head = char:FindFirstChild("Head")
                local topW = (head and head.Position or root.Position + Vector3.new(0,2,0)) + Vector3.new(0,0.7,0)
                local botW = root.Position - Vector3.new(0,3,0)
                local tv   = Camera:WorldToViewportPoint(topW)
                local bv   = Camera:WorldToViewportPoint(botW)

                if tv.Z > 0 and bv.Z > 0 then
                    visible = true
                    local bh = math.abs(bv.Y - tv.Y)
                    local bw = bh * 0.6
                    local cx = (tv.X + bv.X) / 2
                    local bx = cx - bw / 2
                    local by = math.min(tv.Y, bv.Y)

                    -- Box (4 lines)
                    setBox(o.BoxLines, bx, by, bw, bh,
                        Options.ESPBoxColor.Value, Toggles.ESPBox.Value)

                    -- Fill (Quad if available, else skip — lines can't fill)
                    if o.FillQuad then
                        o.FillQuad.Visible = Toggles.ESPFill.Value
                        if o.FillQuad.Visible then
                            o.FillQuad.PointA      = Vector2.new(bx,    by)
                            o.FillQuad.PointB      = Vector2.new(bx+bw, by)
                            o.FillQuad.PointC      = Vector2.new(bx+bw, by+bh)
                            o.FillQuad.PointD      = Vector2.new(bx,    by+bh)
                            o.FillQuad.Color        = Options.ESPFillColor.Value
                            o.FillQuad.Transparency = 1 - Options.ESPFillOpacity.Value
                        end
                    end

                    -- Name
                    o.Name.Visible = Toggles.ESPName.Value
                    if o.Name.Visible then
                        o.Name.Text     = plr.DisplayName
                        o.Name.Size     = textSize
                        o.Name.Color    = Options.ESPNameColor.Value
                        o.Name.Position = Vector2.new(cx, by - textSize - 2)
                    end

                    -- Distance
                    o.Dist.Visible = Toggles.ESPDistance.Value
                    if o.Dist.Visible then
                        o.Dist.Text     = string.format("%d studs", math.floor(dist))
                        o.Dist.Size     = textSize
                        o.Dist.Color    = Options.ESPDistColor.Value
                        o.Dist.Position = Vector2.new(cx, by + bh + 2)
                    end

                    -- Health bar (two Lines: black bg, colored fg)
                    o.HealthBack.Visible = Toggles.ESPHealth.Value
                    o.Health.Visible     = Toggles.ESPHealth.Value
                    if o.Health.Visible then
                        local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                        local barX = bx - 5
                        o.HealthBack.From      = Vector2.new(barX, by)
                        o.HealthBack.To        = Vector2.new(barX, by + bh)
                        o.HealthBack.Thickness = 3
                        o.Health.From          = Vector2.new(barX, by + bh * (1 - frac))
                        o.Health.To            = Vector2.new(barX, by + bh)
                        o.Health.Thickness     = 3
                        o.Health.Color         = Color3.fromRGB(255,50,50):Lerp(Color3.fromRGB(60,255,90), frac)
                    end

                    -- Tracer
                    o.Tracer.Visible = Toggles.ESPTracer.Value
                    if o.Tracer.Visible then
                        local originMode = Options.ESPTracerOrigin.Value
                        local from = originMode == "Top"    and Vector2.new(vp.X/2, 0)
                                  or originMode == "Center" and Vector2.new(vp.X/2, vp.Y/2)
                                  or Vector2.new(vp.X/2, vp.Y)
                        o.Tracer.From  = from
                        o.Tracer.To    = Vector2.new(cx, by + bh)
                        o.Tracer.Color = Options.ESPTracerColor.Value
                    end
                end
            end
        end

        if not visible then hideESP(o) end
        setChams(plr, char, visible and Toggles.ESPChams.Value)
    end
end)
table.insert(Cleanups, function() pcall(RunService.UnbindFromRenderStep, RunService, ESP_BIND) end)

-- ── Cosmetic logic ────────────────────────────────────────────────────────────
local hasDebug = typeof(debug) == "table"
    and typeof(debug.getupvalues) == "function"
    and typeof(debug.setupvalue)  == "function"

local function selectedKnifeId()
    return knifeLabelToId[Options.KnifePick.Value] or "Default"
end

local inventorySignal
if InventoryClient and hasDebug then
    for _, v in pairs(debug.getupvalues(InventoryClient.Observe)) do
        if type(v) == "table" and type(v.Fire) == "function" and type(v.Connect) == "function" then
            inventorySignal = v
            break
        end
    end
end

local lastFake
local function injectInventory()
    if not (inventorySignal and InventoryClient) then return end
    local real   = InventoryClient:Get() or {}
    local merged = {}
    for k, v in pairs(real) do merged[k] = v end
    for id in pairs(KnifeConfig) do merged["knifehub_" .. id] = { ID = id } end
    lastFake = merged
    inventorySignal:Fire(merged)
end

if InventoryClient and inventorySignal then
    local conn = InventoryClient:Observe(function(map)
        if map == lastFake then return end
        if Toggles.UnlockAll and Toggles.UnlockAll.Value then
            task.defer(injectInventory)
        end
    end)
    table.insert(Cleanups, function() pcall(function() conn:Disconnect() end) end)
end

local origGet
if EquippedRep and typeof(EquippedRep.Get) == "function" then
    origGet = EquippedRep.Get
    local function isLocal(target)
        if typeof(target) == "Instance" then return target == LP end
        return tonumber(target) == LP.UserId
    end
    pcall(function()
        EquippedRep.Get = function(self, target)
            local res = origGet(self, target)
            if Toggles.ForceKnife and Toggles.ForceKnife.Value and isLocal(target) and type(res) == "table" then
                local copy = table.clone(res)
                copy.KnifeId = selectedKnifeId()
                return copy
            end
            return res
        end
    end)
    table.insert(Cleanups, function() pcall(function() EquippedRep.Get = origGet end) end)
end

local function viewmodelKnifeUpvalue()
    if not (ViewmodelCtrl and hasDebug) then return nil end
    local fn = ViewmodelCtrl.SetupViewmodel
    for i, v in pairs(debug.getupvalues(fn)) do
        if type(v) == "string" and KnifeConfig[v] ~= nil then
            return fn, i, v
        end
    end
end

local function applyViewmodel(id)
    local fn, idx, cur = viewmodelKnifeUpvalue()
    if not fn then return false end
    if cur ~= id then
        debug.setupvalue(fn, idx, id)
        pcall(function() ViewmodelCtrl:SetupViewmodel() end)
    end
    return true
end

_G.__KnifeHubApply = function()
    if Toggles.UnlockAll.Value  then pcall(injectInventory) end
    if Toggles.ForceKnife.Value then pcall(applyViewmodel, selectedKnifeId()) end
end
table.insert(Cleanups, function() _G.__KnifeHubApply = nil end)

Toggles.UnlockAll:OnChanged(function()
    if Toggles.UnlockAll.Value then
        pcall(injectInventory)
    elseif inventorySignal and InventoryClient then
        pcall(function() inventorySignal:Fire(InventoryClient:Get()) end)
    end
end)
Toggles.ForceKnife:OnChanged(function() _G.__KnifeHubApply() end)
Options.KnifePick:OnChanged(function() if Toggles.ForceKnife.Value then _G.__KnifeHubApply() end end)

task.spawn(function()
    while not Library.Unloaded do
        task.wait(0.5)
        if Toggles.ForceKnife.Value then pcall(applyViewmodel, selectedKnifeId()) end
    end
end)

-- ── Cleanup ───────────────────────────────────────────────────────────────────
Library:OnUnload(function()
    for _, fn in ipairs(Cleanups) do pcall(fn) end
    for _, c  in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    for plr   in pairs(ESPObjects)   do removeESP(plr) end
    for _, h  in pairs(Chams)        do pcall(function() h:Destroy() end) end
    if FovCircle then killDrawing(FovCircle) end
end)

Library:Notify({ Title = "KnifeHub", Description = "Loaded. Menu key: RightShift", Time = 5 })
getgenv().KnifeHub.loading = false
