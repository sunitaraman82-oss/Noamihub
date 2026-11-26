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
    return char:FindFirstChild(name) or char:FindFirstChild("UpperTorso") or char:FindFirstChild("HumanoidRootPart")
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function isVisible(part, char)
    local origin = Camera.CFrame.Position
    rayParams.FilterDescendantsInstances = { LP.Character, char, Camera }
    return Workspace:Raycast(origin, part.Position - origin, rayParams) == nil
end

local function screenCenter()
    if Options.FOVOrigin and Options.FOVOrigin.Value == "Mouse" then
        return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
    end
    return Camera.ViewportSize / 2
end

local function getTarget()
    local center = screenCenter()
    local radius = Options.FOVRadius.Value
    local best, bestDist

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isAlive(plr) and isEnemy(plr, Toggles.TeamCheck.Value) then
            local char = plr.Character
            local part = pickPart(char)
            if part then
                local sp, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen then
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

local function solveDirection(originCF, part)
    local origin    = originCF.Position
    local targetPos = part.Position
    local straight  = (targetPos - origin).Unit

    local wantDrop    = Toggles.DropComp.Value
    local wantPredict = Toggles.Predict.Value
    if not (wantDrop or wantPredict) or not Trajectory or not Constants then
        return straight
    end

    local vel   = wantPredict and (part.AssemblyLinearVelocity * Options.PredictScale.Value) or Vector3.zero
    local aim   = targetPos
    local t     = 0

    for _ = 1, 8 do
        local dir = (aim - origin).Unit
        local want = ((targetPos + vel * t) - origin).Magnitude

        local lo, hi = 0, 3
        for _ = 1, 18 do
            local mid = (lo + hi) / 2
            local r = Trajectory.Evaluate(originCF, dir, mid)
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

local Window = Library:CreateWindow({
    Title = "KnifeHub",
    Footer = "obsidian",
    NotifySide = "Right",
    ShowCustomCursor = false,
})

local Tabs = {
    Combat   = Window:AddTab("Combat", "crosshair"),
    Visuals  = Window:AddTab("Visuals", "eye"),
    Cosmetic = Window:AddTab("Cosmetic", "palette"),
    Settings = Window:AddTab("Settings", "settings"),
}

local AimBox = Tabs.Combat:AddLeftGroupbox("Aimbot", "target")

AimBox:AddToggle("Aimbot", { Text = "Enable Aimbot", Default = false })
    :AddKeyPicker("AimbotKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot key", SyncToggleState = false })

AimBox:AddSlider("AimSmooth", {
    Text = "Smoothness", Default = 35, Min = 0, Max = 95, Rounding = 0, Suffix = "%",
    Tooltip = "0 = instant snap, higher = slower / smoother",
})

local SilentBox = Tabs.Combat:AddLeftGroupbox("Silent Aim", "ghost")

SilentBox:AddToggle("SilentAim", { Text = "Enable Silent Aim", Default = false })
SilentBox:AddSlider("SilentSmooth", {
    Text = "Smoothness", Default = 0, Min = 0, Max = 95, Rounding = 0, Suffix = "%",
    Tooltip = "0 = thrown knife goes straight at the target, higher = blends toward your crosshair",
})
SilentBox:AddSlider("SilentHitChance", {
    Text = "Hit chance", Default = 100, Min = 1, Max = 100, Rounding = 0, Suffix = "%",
})

local FovBox = Tabs.Combat:AddRightGroupbox("FOV (shared by Aimbot + Silent Aim)", "circle-dashed")

FovBox:AddToggle("ShowFOV", { Text = "Show FOV circle", Default = true })
    :AddColorPicker("FOVColor", { Default = Color3.fromRGB(255, 255, 255), Title = "FOV color" })
FovBox:AddToggle("FOVFilled", { Text = "Filled FOV", Default = false })
FovBox:AddSlider("FOVFillOpacity", {
    Text = "Fill opacity", Default = 0.15, Min = 0.05, Max = 1, Rounding = 2,
})
FovBox:AddSlider("FOVRadius", { Text = "Radius", Default = 150, Min = 10, Max = 600, Rounding = 0, Suffix = "px" })
FovBox:AddSlider("FOVThickness", { Text = "Outline thickness", Default = 1, Min = 1, Max = 5, Rounding = 0 })
FovBox:AddDropdown("FOVOrigin", { Text = "FOV origin", Values = { "Screen Center", "Mouse" }, Default = 1 })
FovBox:AddToggle("FOVOnly", { Text = "Only target inside FOV", Default = true })

local TargetBox = Tabs.Combat:AddRightGroupbox("Targeting", "users")

TargetBox:AddDropdown("TargetPart", {
    Text = "Target part", Values = { "Head", "UpperTorso", "HumanoidRootPart" }, Default = 1,
})
TargetBox:AddToggle("TeamCheck", { Text = "Team check", Default = true })
TargetBox:AddToggle("WallCheck", { Text = "Wall check", Default = true })
TargetBox:AddToggle("Predict", { Text = "Movement prediction", Default = true })
TargetBox:AddSlider("PredictScale", { Text = "Prediction scale", Default = 1, Min = 0, Max = 2, Rounding = 2 })
TargetBox:AddToggle("DropComp", { Text = "Knife drop compensation", Default = true })

local EspBox = Tabs.Visuals:AddLeftGroupbox("ESP", "scan-eye")

EspBox:AddToggle("ESPEnabled", { Text = "Enable ESP", Default = false })
EspBox:AddToggle("ESPTeamCheck", { Text = "Enemies only", Default = true })
EspBox:AddSlider("ESPMaxDist", { Text = "Max distance", Default = 1500, Min = 50, Max = 5000, Rounding = 0, Suffix = " studs" })
EspBox:AddSlider("ESPTextSize", { Text = "Text size", Default = 13, Min = 10, Max = 24, Rounding = 0 })

local EspElements = Tabs.Visuals:AddRightGroupbox("Elements", "layers")

EspElements:AddToggle("ESPBox", { Text = "Box", Default = true })
    :AddColorPicker("ESPBoxColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Box color" })
EspElements:AddToggle("ESPFill", { Text = "Filled box", Default = false })
    :AddColorPicker("ESPFillColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Fill color" })
EspElements:AddSlider("ESPFillOpacity", { Text = "Fill opacity", Default = 0.2, Min = 0.05, Max = 1, Rounding = 2 })
EspElements:AddToggle("ESPName", { Text = "Name", Default = true })
    :AddColorPicker("ESPNameColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Name color" })
EspElements:AddToggle("ESPHealth", { Text = "Health bar", Default = true })
EspElements:AddToggle("ESPDistance", { Text = "Distance", Default = true })
    :AddColorPicker("ESPDistColor", { Default = Color3.fromRGB(200, 200, 200), Title = "Distance color" })
EspElements:AddToggle("ESPTracer", { Text = "Tracers", Default = false })
    :AddColorPicker("ESPTracerColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Tracer color" })
EspElements:AddDropdown("ESPTracerOrigin", { Text = "Tracer origin", Values = { "Bottom", "Center", "Top" }, Default = 1 })
EspElements:AddToggle("ESPChams", { Text = "Chams (highlight)", Default = false })
    :AddColorPicker("ESPChamsColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Chams color" })
EspElements:AddSlider("ESPChamsFill", { Text = "Chams fill opacity", Default = 0.5, Min = 0, Max = 1, Rounding = 2 })

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
    Text = "Unlock all knives (inventory UI)",
    Default = false,
    Tooltip = "Adds every knife to your inventory view. Local only — the server still owns your real inventory.",
})
KnifeBox:AddDropdown("KnifePick", { Text = "Knife", Values = knifeLabels, Default = 1, Searchable = true })
KnifeBox:AddToggle("ForceKnife", {
    Text = "Use selected knife (viewmodel + throw skin)",
    Default = false,
    Tooltip = "Only you see it. Other players still see your server-equipped knife.",
})
KnifeBox:AddButton({ Text = "Apply / refresh", Func = function() if _G.__KnifeHubApply then _G.__KnifeHubApply() end end })

local MenuGroup = Tabs.Settings:AddLeftGroupbox("Menu", "wrench")
MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame and Library.KeybindFrame.Visible or false,
    Text = "Open keybind menu",
    Callback = function(v) if Library.KeybindFrame then Library.KeybindFrame.Visible = v end end,
})
MenuGroup:AddButton("Unload", function() Library:Unload() end)
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
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

local hasDrawing = typeof(Drawing) == "table" or typeof(Drawing) == "userdata"
if not hasDrawing then
    Library:Notify({ Title = "KnifeHub", Description = "Drawing API missing — FOV circle and ESP boxes are disabled.", Time = 6 })
end

local function newDrawing(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props) do d[k] = v end
    return d
end
local function killDrawing(d)
    pcall(function() d:Remove() end)
end

local FovCircle = hasDrawing and newDrawing("Circle", { NumSides = 64, Visible = false, ZIndex = 5 }) or nil

local AIM_BIND = "KnifeHubAimbot"
RunService:BindToRenderStep(AIM_BIND, Enum.RenderPriority.Camera.Value + 10, function(dt)
    Camera = Workspace.CurrentCamera

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

    if not (Toggles.Aimbot.Value and Options.AimbotKey:GetState()) then return end
    local target = getTarget()
    if not target then return end

    local cf  = Camera.CFrame
    local dir = solveDirection(cf, target.Part)
    local smooth = Options.AimSmooth.Value / 100
    local alpha = 1 - smooth ^ (dt * 60)
    Camera.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, cf.Position + dir), math.clamp(alpha, 0.01, 1))
end)
table.insert(Cleanups, function() pcall(RunService.UnbindFromRenderStep, RunService, AIM_BIND) end)

local function silentDirection(camCF, originalDir)
    if math.random(1, 100) > Options.SilentHitChance.Value then return nil end
    local target = getTarget()
    if not target then return nil end

    local aimed = solveDirection(camCF, target.Part)
    local blend = 1 - (Options.SilentSmooth.Value / 100)
    blend = math.clamp(blend, 0.02, 1)
    local mixed = originalDir:Lerp(aimed, blend)
    if mixed.Magnitude < 0.001 then return aimed end
    return mixed.Unit
end

if KnifeController and typeof(KnifeController._GetThrowDirection) == "function" then
    local original = KnifeController._GetThrowDirection
    local function wrapped(self, camCF)
        local dir = original(self, camCF)
        if Toggles.SilentAim.Value then
            local ok, res = pcall(silentDirection, camCF, dir)
            if ok and res then return res end
        end
        return dir
    end

    local assigned = pcall(function() KnifeController._GetThrowDirection = wrapped end)
    if assigned then
        table.insert(Cleanups, function() pcall(function() KnifeController._GetThrowDirection = original end) end)
    elseif typeof(hookfunction) == "function" then
        local old
        old = hookfunction(original, function(self, camCF)
            local dir = old(self, camCF)
            if Toggles.SilentAim.Value then
                local ok, res = pcall(silentDirection, camCF, dir)
                if ok and res then return res end
            end
            return dir
        end)
        table.insert(Cleanups, function() pcall(hookfunction, original, old) end)
    else
        Library:Notify({ Title = "KnifeHub", Description = "Couldn't hook KnifeController — silent aim unavailable.", Time = 6 })
        Toggles.SilentAim:SetDisabled(true)
    end
else
    Library:Notify({ Title = "KnifeHub", Description = "KnifeController not found — silent aim unavailable.", Time = 6 })
    Toggles.SilentAim:SetDisabled(true)
end

local ESPObjects, Chams = {}, {}

local function createESP(plr)
    if plr == LP or ESPObjects[plr] or not hasDrawing then return end
    ESPObjects[plr] = {
        Fill       = newDrawing("Square", { Filled = true, Visible = false, ZIndex = 1 }),
        Box        = newDrawing("Square", { Filled = false, Thickness = 1, Visible = false, ZIndex = 2 }),
        Name       = newDrawing("Text",   { Center = true, Outline = true, Visible = false, ZIndex = 4 }),
        Dist       = newDrawing("Text",   { Center = true, Outline = true, Visible = false, ZIndex = 4 }),
        HealthBack = newDrawing("Square", { Filled = true, Color = Color3.new(0, 0, 0), Visible = false, ZIndex = 2 }),
        Health     = newDrawing("Square", { Filled = true, Visible = false, ZIndex = 3 }),
        Tracer     = newDrawing("Line",   { Thickness = 1, Visible = false, ZIndex = 1 }),
    }
end

local function hideESP(o)
    for _, d in pairs(o) do d.Visible = false end
end

local function removeESP(plr)
    local o = ESPObjects[plr]
    if o then
        for _, d in pairs(o) do killDrawing(d) end
        ESPObjects[plr] = nil
    end
    if Chams[plr] then Chams[plr]:Destroy(); Chams[plr] = nil end
end

local function setChams(plr, char, on)
    local h = Chams[plr]
    if not on then
        if h then h.Enabled = false end
        return
    end
    if not h or not h.Parent then
        h = Instance.new("Highlight")
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.Parent = (typeof(gethui) == "function" and gethui()) or CoreGui
        Chams[plr] = h
    end
    h.Adornee = char
    h.Enabled = true
    h.FillColor = Options.ESPChamsColor.Value
    h.OutlineColor = Options.ESPChamsColor.Value
    h.FillTransparency = 1 - Options.ESPChamsFill.Value
    h.OutlineTransparency = 0
end

for _, plr in ipairs(Players:GetPlayers()) do createESP(plr) end
connect(Players.PlayerAdded, createESP)
connect(Players.PlayerRemoving, removeESP)

local ESP_BIND = "KnifeHubESP"
RunService:BindToRenderStep(ESP_BIND, Enum.RenderPriority.Camera.Value + 11, function()
    local enabled = Toggles.ESPEnabled.Value
    local camCF   = Camera.CFrame
    local vp      = Camera.ViewportSize
    local textSize = Options.ESPTextSize.Value

    for plr, o in pairs(ESPObjects) do
        local char = plr.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = getHumanoid(char)
        local visible = false

        if enabled and root and hum and hum.Health > 0 and isEnemy(plr, Toggles.ESPTeamCheck.Value) then
            local dist = (camCF.Position - root.Position).Magnitude
            if dist <= Options.ESPMaxDist.Value then
                local head = char:FindFirstChild("Head")
                local topW = (head and head.Position or root.Position + Vector3.new(0, 2, 0)) + Vector3.new(0, 0.7, 0)
                local botW = root.Position - Vector3.new(0, 3, 0)
                local t = Camera:WorldToViewportPoint(topW)
                local b = Camera:WorldToViewportPoint(botW)

                if t.Z > 0 and b.Z > 0 then
                    visible = true
                    local h  = math.abs(b.Y - t.Y)
                    local w  = h * 0.6
                    local cx = (t.X + b.X) / 2
                    local x, y = cx - w / 2, math.min(t.Y, b.Y)

                    o.Box.Visible = Toggles.ESPBox.Value
                    if o.Box.Visible then
                        o.Box.Position = Vector2.new(x, y)
                        o.Box.Size     = Vector2.new(w, h)
                        o.Box.Color    = Options.ESPBoxColor.Value
                    end

                    o.Fill.Visible = Toggles.ESPFill.Value
                    if o.Fill.Visible then
                        o.Fill.Position     = Vector2.new(x, y)
                        o.Fill.Size         = Vector2.new(w, h)
                        o.Fill.Color        = Options.ESPFillColor.Value
                        o.Fill.Transparency = Options.ESPFillOpacity.Value
                    end

                    o.Name.Visible = Toggles.ESPName.Value
                    if o.Name.Visible then
                        o.Name.Text     = plr.DisplayName
                        o.Name.Size     = textSize
                        o.Name.Color    = Options.ESPNameColor.Value
                        o.Name.Position = Vector2.new(cx, y - textSize - 2)
                    end

                    o.Dist.Visible = Toggles.ESPDistance.Value
                    if o.Dist.Visible then
                        o.Dist.Text     = string.format("%d studs", dist)
                        o.Dist.Size     = textSize
                        o.Dist.Color    = Options.ESPDistColor.Value
                        o.Dist.Position = Vector2.new(cx, y + h + 2)
                    end

                    o.HealthBack.Visible = Toggles.ESPHealth.Value
                    o.Health.Visible     = Toggles.ESPHealth.Value
                    if o.Health.Visible then
                        local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                        o.HealthBack.Position = Vector2.new(x - 6, y - 1)
                        o.HealthBack.Size     = Vector2.new(4, h + 2)
                        o.Health.Position     = Vector2.new(x - 5, y + h * (1 - frac))
                        o.Health.Size         = Vector2.new(2, h * frac)
                        o.Health.Color        = Color3.fromRGB(255, 50, 50):Lerp(Color3.fromRGB(60, 255, 90), frac)
                    end

                    o.Tracer.Visible = Toggles.ESPTracer.Value
                    if o.Tracer.Visible then
                        local originMode = Options.ESPTracerOrigin.Value
                        local from = originMode == "Top" and Vector2.new(vp.X / 2, 0)
                            or originMode == "Center" and Vector2.new(vp.X / 2, vp.Y / 2)
                            or Vector2.new(vp.X / 2, vp.Y)
                        o.Tracer.From  = from
                        o.Tracer.To    = Vector2.new(cx, y + h)
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

local hasDebug = typeof(debug) == "table" and typeof(debug.getupvalues) == "function" and typeof(debug.setupvalue) == "function"

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
    local real = InventoryClient:Get() or {}
    local merged = {}
    for k, v in pairs(real) do merged[k] = v end
    for id in pairs(KnifeConfig) do
        merged["knifehub_" .. id] = { ID = id }
    end
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
    if Toggles.UnlockAll.Value then pcall(injectInventory) end
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

Library:OnUnload(function()
    for _, fn in ipairs(Cleanups) do pcall(fn) end
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    for plr in pairs(ESPObjects) do removeESP(plr) end
    for plr, h in pairs(Chams) do pcall(function() h:Destroy() end) end
    if FovCircle then killDrawing(FovCircle) end
end)

Library:Notify({ Title = "KnifeHub", Description = "Loaded. Menu key: RightShift", Time = 5 })
