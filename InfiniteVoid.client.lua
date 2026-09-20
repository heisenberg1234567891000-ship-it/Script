--[[
    INFINITE VOID / CINEMATIC DOMAIN / 1.0
    LocalScript -> StarterPlayer > StarterPlayerScripts.
    Press V or the VOID button. Add InfiniteVoid.server.lua for actual multiplayer stun.
    Without the server this is explicitly a local visual preview.
    No external model, texture, animation or module required. Optional sounds below.
]]
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local CAS = game:GetService("ContextActionService")
local player = Players.LocalPlayer
assert(RunService:IsClient() and player, "Infinite Void must run in a Roblox client context")

local CONFIG = {
    Quality = "Auto", -- Auto / High / Low. Auto uses Low on touch devices.
    IntroTime = 3.2, Duration = 8, Radius = 85, Cooldown = 28,
    CinematicCamera = true, CameraMotion = 1, FlashStrength = 0.35,
    MaxAvatars = 12, VisibleDistance = 650, MaxDomains = 3,
    IntroSound = "", OpenSound = "", AmbienceSound = "", -- authorized rbxassetid://... only
    Volume = 0.55,
}
local C = {
    Ink = Color3.fromRGB(2, 3, 12), Blue = Color3.fromRGB(42, 110, 255),
    Cyan = Color3.fromRGB(122, 235, 255), Violet = Color3.fromRGB(154, 110, 255),
    White = Color3.fromRGB(239, 250, 255),
}
local LOW = CONFIG.Quality == "Low" or (CONFIG.Quality == "Auto" and UIS.TouchEnabled)
local V3, ONE, TAU = Vector3.new, Vector3.new(1, 1, 1), math.pi * 2
local function clamp(x) return math.clamp(x, 0, 1) end
local function ease(x) return 1 - (1 - clamp(x)) ^ 3 end
local function smooth(x) x = clamp(x); return x * x * (3 - 2 * x) end
local function mix(a, b, t) return a + (b - a) * t end
local function new(class, parent, properties)
    local object = Instance.new(class)
    for key, value in pairs(properties or {}) do object[key] = value end
    object.Parent = parent
    return object
end
local function part(parent, color, size, transparency, material)
    return new("Part", parent, {
        Name = "VoidFX", Size = size or ONE, Color = color,
        Transparency = transparency or 0, Material = material or Enum.Material.Neon,
        Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = false,
    })
end
local function ball(parent, color, diameter, transparency, material)
    local p = part(parent, color, ONE * diameter, transparency, material)
    p.Shape = Enum.PartType.Ball
    return p
end
local function ring(parent, color)
    local carrier = part(parent, color, ONE * 0.05, 1)
    local attachments, beams = {}, {}
    for i = 1, 4 do attachments[i] = new("Attachment", carrier) end
    for i = 1, 4 do
        beams[i] = new("Beam", carrier, {
            Attachment0 = attachments[i], Attachment1 = attachments[i % 4 + 1],
            Color = ColorSequence.new(color), FaceCamera = true, LightEmission = 1,
            LightInfluence = 0, Segments = LOW and 8 or 14,
        })
    end
    local r = {part = carrier}
    function r:pose(cf, radius, width, transparency)
        carrier.CFrame = cf
        local alpha = NumberSequence.new(clamp(transparency or 0))
        for i = 1, 4 do
            local a = (i - 1) * math.pi / 2
            attachments[i].CFrame = CFrame.fromMatrix(V3(math.cos(a), math.sin(a), 0) * radius,
                V3(-math.sin(a), math.cos(a), 0), V3(0, 0, 1))
            local b = beams[i]
            b.CurveSize0, b.CurveSize1 = radius * 0.55228475, radius * 0.55228475
            b.Width0, b.Width1, b.Transparency = width, width, alpha
        end
    end
    return r
end

local playerGui = player:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("InfiniteVoid_Cinematic")
if old then
    local stop = old:FindFirstChild("Shutdown")
    if stop and stop:IsA("BindableEvent") then stop:Fire() end
    old:Destroy()
end
local gui = new("ScreenGui", playerGui, {
    Name = "InfiniteVoid_Cinematic", IgnoreGuiInset = true, ResetOnSpawn = false,
    DisplayOrder = 85, ZIndexBehavior = Enum.ZIndexBehavior.Global,
})
local shutdownEvent = new("BindableEvent", gui, {Name = "Shutdown"})
local world = new("Folder", workspace, {Name = "InfiniteVoid_VFX_" .. player.UserId})
local alive, connections, domains = true, {}, {}
local remote, remoteConnection, pendingAt, nextCastAt = nil, nil, nil, 0
local token = "InfiniteVoid_" .. HttpService:GenerateGUID(false)
local intro, interior, interiorDomain = nil, nil, nil
local interiorAlpha, overloadAmount = 0, 0
local toastUntil, flashAt, lastUiTick = 0, -100, -1
local function connect(signal, callback)
    local conn = signal:Connect(callback)
    connections[#connections + 1] = conn
    return conn
end
local function clock() return workspace:GetServerTimeNow() end
local function characterParts()
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if char and hum and root and hum.Health > 0 then return char, hum, root end
end
local function frame(parent, props)
    props = props or {}
    if props.BackgroundTransparency == nil then props.BackgroundTransparency = 1 end
    props.BorderSizePixel = 0
    props.Active = false
    return new("Frame", parent, props)
end
local function label(parent, props)
    local p = {BackgroundTransparency = 1, BorderSizePixel = 0, TextColor3 = C.White,
        Font = Enum.Font.GothamMedium, TextSize = 16, Text = "", Active = false}
    for key, value in pairs(props) do p[key] = value end
    return new("TextLabel", parent, p)
end
local function textFit(object, minimum, maximum)
    object.TextScaled = true
    new("UITextSizeConstraint", object, {MinTextSize = minimum, MaxTextSize = maximum})
end

local insideLayer = frame(gui, {Name = "VoidSpace", Size = UDim2.fromScale(1, 1), ZIndex = 30})
local cinematic = frame(gui, {Size = UDim2.fromScale(1, 1), ZIndex = 60, Visible = false})
local dimmer = frame(cinematic, {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Ink, ZIndex = 60})
local topBar = frame(cinematic, {Size = UDim2.fromScale(1, 0), BackgroundTransparency = 0,
    BackgroundColor3 = Color3.new(), ZIndex = 80})
local bottomBar = frame(cinematic, {AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1),
    Size = UDim2.fromScale(1, 0), BackgroundTransparency = 0, BackgroundColor3 = Color3.new(), ZIndex = 80})
local title = label(cinematic, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.78),
    Size = UDim2.fromScale(0.86, 0.1), Font = Enum.Font.GothamBlack, ZIndex = 76,
    Text = "БЕСКОНЕЧНАЯ ПУСТОТА", TextTransparency = 1})
textFit(title, 16, 62)
local subTitle = label(cinematic, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.7),
    Size = UDim2.fromScale(0.8, 0.034), Font = Enum.Font.GothamMedium, ZIndex = 76,
    Text = "Р А С Ш И Р Е Н И Е   Т Е Р Р И Т О Р И И", TextTransparency = 1})
textFit(subTitle, 9, 18)
local crest = label(cinematic, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42),
    Size = UDim2.fromScale(0.22, 0.3), Font = Enum.Font.Garamond, ZIndex = 73,
    Text = "∞", TextColor3 = C.Cyan, TextTransparency = 1})
textFit(crest, 34, 210)
local hairline = frame(cinematic, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.66),
    Size = UDim2.fromScale(0, 0.002), BackgroundColor3 = C.Cyan, BackgroundTransparency = 0, ZIndex = 77})
new("UIGradient", hairline, {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1),
    NumberSequenceKeypoint.new(0.3,0), NumberSequenceKeypoint.new(0.7,0),NumberSequenceKeypoint.new(1,1)})})

local portraitFrame = frame(cinematic, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42),
    Size = UDim2.fromScale(1, 0.32), BackgroundColor3 = C.Ink, BackgroundTransparency = 0,
    ZIndex = 70, Visible = false, ClipsDescendants = true})
local portraitView = new("ViewportFrame", portraitFrame, {Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1, ZIndex = 71, Ambient = Color3.fromRGB(95, 127, 160),
    LightColor = C.Cyan, LightDirection = V3(-0.3, -0.4, -1), Active = false})
local portraitWorld = new("WorldModel", portraitView)
local portraitCamera = new("Camera", portraitView, {FieldOfView = 34})
portraitView.CurrentCamera = portraitCamera
for _, y in ipairs({0, 1}) do
    frame(portraitFrame, {AnchorPoint = Vector2.new(0, y), Position = UDim2.fromScale(0, y),
        Size = UDim2.new(1, 0, 0, 1), BackgroundTransparency = 0.2, BackgroundColor3 = C.Cyan, ZIndex = 73})
end
local eyeFlare = frame(portraitFrame, {AnchorPoint = Vector2.new(0.5, 0.5),
    Size = UDim2.new(0.26, 0, 0, 2), BackgroundColor3 = C.White, ZIndex = 74})
new("UIGradient", eyeFlare, {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1),
    NumberSequenceKeypoint.new(0.45,0.5),NumberSequenceKeypoint.new(0.5,0),
    NumberSequenceKeypoint.new(0.55,0.5),NumberSequenceKeypoint.new(1,1)})})

local overlay = frame(gui, {Size = UDim2.fromScale(1, 1), ZIndex = 45, Visible = false})
local overloadShade = frame(overlay, {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Blue, ZIndex = 45})
new("UIGradient", overloadShade, {Rotation = 90, Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(0.3,1),
    NumberSequenceKeypoint.new(0.7,1),NumberSequenceKeypoint.new(1,0.2)})})
local interiorTitle = label(overlay, {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.09),
    Size = UDim2.fromScale(0.78, 0.035), Text = "Б Е С К О Н Е Ч Н А Я   П У С Т О Т А", ZIndex = 50})
textFit(interiorTitle, 9, 19)
local timerText = label(overlay, {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.137),
    Size = UDim2.fromScale(0.5, 0.029), TextColor3 = C.Cyan, ZIndex = 50})
textFit(timerText, 10, 16)
local overloadText = label(overlay, {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.88),
    Size = UDim2.fromScale(0.82, 0.04), Text = "ПЕРЕГРУЗКА ВОСПРИЯТИЯ", TextColor3 = C.Cyan, ZIndex = 50})
textFit(overloadText, 10, 21)
local streams, speedLines = {}, {}
local screenRng = Random.new(73091)
local fragments = {"∞  /  ∞  /  ∞", "0  1  0  1  1  0  0  1", "ПАМЯТЬ / СВЕТ / ВРЕМЯ", "ПРОСТРАНСТВО / СОЗНАНИЕ", "∞   0   ∞   1   ∞"}
for i = 1, LOW and 12 or 24 do
    local text = label(overlay, {Size = UDim2.fromScale(0.32, 0.027),
        Text = fragments[(i - 1) % #fragments + 1], TextSize = screenRng:NextInteger(10, 16),
        TextColor3 = (i % 3 == 0) and C.Violet or C.Cyan, TextTransparency = 1,
        TextXAlignment = Enum.TextXAlignment.Left, Rotation = screenRng:NextNumber(-7, 7), ZIndex = 47})
    streams[i] = {label = text, x = screenRng:NextNumber(-0.12, 0.86),
        y = screenRng:NextNumber(), speed = screenRng:NextNumber(0.025, 0.1)}
end
for i = 1, LOW and 20 or 34 do
    local a = i * TAU / (LOW and 20 or 34)
    local streak = frame(overlay, {AnchorPoint = Vector2.new(0.5, 0.5),
        Rotation = math.deg(a), Size = UDim2.fromOffset(90, 1), BackgroundColor3 = C.White,
        BackgroundTransparency = 1, ZIndex = 46})
    new("UIGradient", streak, {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1),
        NumberSequenceKeypoint.new(0.7,0.2),NumberSequenceKeypoint.new(1,1)})})
    speedLines[i] = {frame = streak, angle = a, phase = screenRng:NextNumber()}
end
local flash = frame(gui, {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.White, ZIndex = 95})
local toast = label(gui, {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.72),
    Size = UDim2.fromScale(0.8, 0.045), TextTransparency = 1, TextColor3 = C.Cyan, ZIndex = 100})
textFit(toast, 10, 20)
local button = new("TextButton", gui, {Name = "VoidButton", AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(1, -107, 1, -264), Size = UDim2.fromOffset(98, 98),
    BackgroundColor3 = C.Ink, BackgroundTransparency = 0.12, BorderSizePixel = 0,
    Text = "", AutoButtonColor = false, ZIndex = 110})
new("UICorner", button, {CornerRadius = UDim.new(1, 0)})
local buttonStroke = new("UIStroke", button, {Color = C.Cyan, Thickness = 1.6, Transparency = 0.15})
local icon = label(button, {Size = UDim2.fromScale(1, 0.6), Position = UDim2.fromScale(0, 0.02),
    Text = "∞", TextSize = 52, Font = Enum.Font.Garamond, TextColor3 = C.White, ZIndex = 111})
local buttonLabel = label(button, {Size = UDim2.fromScale(0.96, 0.23), Position = UDim2.fromScale(0.02, 0.62),
    Text = "ПУСТОТА", Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.Cyan, ZIndex = 111})
local modeLabel = label(gui, {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(1, -107, 1, -208),
    Size = UDim2.fromOffset(184, 28), TextSize = 9, TextWrapped = true,
    TextColor3 = C.Cyan, TextTransparency = 0.2, ZIndex = 111})
local skip = new("TextButton", gui, {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -24, 0, 38),
    Size = UDim2.fromOffset(134, 32), BackgroundTransparency = 0.5, BackgroundColor3 = C.Ink,
    BorderSizePixel = 0, Font = Enum.Font.Gotham, Text = "ПРОПУСТИТЬ  ›", TextSize = 12,
    TextColor3 = C.White, AutoButtonColor = false, ZIndex = 120, Visible = false})
new("UICorner", skip, {CornerRadius = UDim.new(0, 7)})
local cc = new("ColorCorrectionEffect", Lighting, {Name = token .. "_Color", Enabled = false})
local bloom = new("BloomEffect", Lighting, {Name = token .. "_Bloom", Intensity = 0, Size = 40, Threshold = 0.85})
local blur = new("BlurEffect", Lighting, {Name = token .. "_Blur", Size = 0})
local sounds = {}
local function sound(name, id, looped)
    if type(id) ~= "string" or id == "" then return end
    local previous = sounds[name]
    if previous then previous:Destroy() end
    local s = new("Sound", gui, {Name = name, SoundId = id, Volume = CONFIG.Volume, Looped = looped or false})
    sounds[name] = s
    s:Play()
end
local function stopSound(name)
    if sounds[name] then sounds[name]:Destroy(); sounds[name] = nil end
end
local function message(text)
    toast.Text = text; toastUntil = clock() + 2.5
end


-- Outside view: a restrained event horizon, a fast opening wave, and orbiting light.
-- The owner drives this effect with the shared server clock. No private connections.
local function createWorldDomain(payload)
    local folder = new("Folder", world, { Name = "Void_" .. tostring(payload.id) })
    local center = payload.center
    local radius = payload.radius or 85
    local basis = payload.frame or CFrame.new(center)
    local rotation = basis - basis.Position
    local startAt, openAt = payload.startAt, payload.openAt
    local random = Random.new(payload.seed or 7319)
    local dead = false

    local black = ball(folder, C.Ink, 0.1, 1, Enum.Material.SmoothPlastic)
    local skin = ball(folder, C.Blue, 0.1, 1, Enum.Material.ForceField)
    local atmosphere = ball(folder, C.Violet, 0.1, 1, Enum.Material.ForceField)
    local singularity = ball(folder, C.White, 0.1, 1, Enum.Material.Neon)
    local singularityGlow = ball(folder, C.Cyan, 0.1, 1, Enum.Material.Neon)
    local light = new("PointLight", singularity, {
        Color = C.Cyan, Brightness = 0, Range = 45, Shadows = false,
    })

    local crown = {}
    for i = 1, 3 do
        crown[i] = ring(folder, i == 2 and C.Violet or C.Cyan)
    end
    local meridians = {}
    for i = 1, (LOW and 3 or 5) do
        meridians[i] = ring(folder, i % 2 == 0 and C.Violet or C.Cyan)
    end
    local waves = {}
    for i = 1, 3 do
        waves[i] = ring(folder, i == 2 and C.White or C.Cyan)
    end

    -- One shared invisible carrier; attachments stay local to the domain center.
    local carrier = part(folder, C.Ink, V3(0.1, 0.1, 0.1), 1, Enum.Material.SmoothPlastic)
    carrier.CFrame = CFrame.new(center) * rotation
    local strands = {}
    local steps = LOW and 7 or 11
    local strandCount = LOW and 1 or 2
    for s = 1, strandCount do
        local strand = { anchors = {}, beams = {}, phase = (s - 1) * math.pi }
        for i = 0, steps do
            strand.anchors[i + 1] = new("Attachment", carrier, {})
        end
        for i = 1, steps do
            strand.beams[i] = new("Beam", carrier, {
                Attachment0 = strand.anchors[i], Attachment1 = strand.anchors[i + 1],
                FaceCamera = true, LightEmission = 1, LightInfluence = 0,
                Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, s == 1 and C.Cyan or C.Violet),
                    ColorSequenceKeypoint.new(0.5, C.White),
                    ColorSequenceKeypoint.new(1, s == 1 and C.Blue or C.Cyan),
                }),
                Transparency = NumberSequence.new(1), Width0 = 0.1, Width1 = 0.1,
                Segments = LOW and 5 or 8,
            })
        end
        strands[s] = strand
    end

    -- Sparse stars give the enormous black silhouette a readable sense of scale.
    local stars = {}
    local starCount = LOW and 14 or 28
    for i = 1, starCount do
        stars[i] = {
            part = ball(folder, i % 4 == 0 and C.Violet or C.Cyan, 0.1, 1, Enum.Material.Neon),
            phase = random:NextNumber(0, TAU),
            latitude = random:NextNumber(-0.9, 0.9),
            orbit = random:NextNumber(1.025, 1.12),
            speed = random:NextNumber(0.018, 0.045),
            size = random:NextNumber(0.08, LOW and 0.27 or 0.4),
        }
    end

    local function setSphere(object, position, diameter, transparency)
        object.Position = position
        object.Size = ONE * math.max(0.05, diameter)
        object.Transparency = clamp(transparency)
    end

    local function spiralPoint(u, clock, phase, r)
        local latitude = -0.91 + u * 1.82
        local angle = u * TAU * 1.42 + clock * 0.065 + phase
        local ca, sa = math.cos(angle), math.sin(angle)
        local cl, sl = math.cos(latitude), math.sin(latitude)
        local p = V3(cl * ca, sl, cl * sa) * r
        local thetaRate = TAU * 1.42
        local tangent = V3(-sl * 1.82 * ca - cl * sa * thetaRate,
            cl * 1.82, -sl * 1.82 * sa + cl * ca * thetaRate) * r
        return p, tangent
    end

    local function tangentFrame(position, tangent)
        local x = tangent.Unit
        local reference = math.abs(x.Y) > 0.93 and V3(0, 0, 1) or V3(0, 1, 0)
        local y = (reference - x * x:Dot(reference)).Unit
        return CFrame.fromMatrix(position, x, y)
    end

    local effect = { folder = folder }
    function effect:update(now, dt)
        if dead then return end
        local elapsed = now - startAt
        local preparation = clamp(elapsed / math.max(0.1, openAt - startAt))
        local opened = now - openAt
        local expanding = ease(clamp(opened / 0.92))
        -- Root retains the effect for the 0.8-second closing tail after endAt.
        local closing = smooth(clamp((now - payload.endAt) / 0.8))
        local life = 1 - closing
        local inPreparation = now >= startAt and now < openAt
        local chargeAlpha = inPreparation and smooth(clamp(preparation * 4)) or 0
        local growth = math.max(0.002, expanding * life)
        local r = math.max(0.1, radius * growth)
        local shimmer = 0.5 + 0.5 * math.sin(elapsed * 1.8)
        local barrierAlpha = opened >= 0 and clamp(opened / 0.1) * life or 0
        local crownPosition = center + rotation:VectorToWorldSpace(V3(0, 2.25, -0.45))

        -- Opaque core; the enormous shell is accented by thin curves, not solid discs.
        setSphere(black, center, r * 2, 1 - barrierAlpha)
        setSphere(skin, center, r * 2.012, 1 - barrierAlpha * (0.075 + 0.015 * shimmer))
        setSphere(atmosphere, center, r * 2.04, 1 - barrierAlpha * 0.035)

        local chargeDiameter = (0.1 + preparation * 0.42) * (0.94 + 0.06 * math.sin(elapsed * 9))
        setSphere(singularity, crownPosition, chargeDiameter, 1 - chargeAlpha)
        setSphere(singularityGlow, crownPosition, chargeDiameter * 2.15, 1 - chargeAlpha * 0.35)
        light.Brightness = chargeAlpha * (0.5 + preparation * 2.8)

        for i, halo in ipairs(crown) do
            local haloRadius = (1.8 + i * 0.5) * (1.2 - preparation * 0.35)
            local cf = CFrame.new(crownPosition) * rotation
                * CFrame.Angles(0.25 * (i - 2), elapsed * (i % 2 == 0 and -0.9 or 0.7), i * math.pi / 3)
            halo:pose(cf, haloRadius, 0.035 + preparation * 0.055, 1 - chargeAlpha * (0.6 + 0.12 * i))
        end

        for i, meridian in ipairs(meridians) do
            local cf = CFrame.new(center) * rotation
                * CFrame.Angles(0.12 * math.sin(elapsed * 0.13 + i), i * math.pi / #meridians + elapsed * 0.012, 0.32)
            local opacity = barrierAlpha * (i == 1 and 0.5 or 0.23)
            meridian:pose(cf, r * 1.003 + 0.07, 0.07 + 0.08 * growth, 1 - opacity)
        end

        for i, wave in ipairs(waves) do
            local age = (opened - (i - 1) * 0.13) / 1.2
            local waveAlpha = age >= 0 and age <= 1 and math.sin(math.pi * clamp(age)) * life or 0
            local waveRadius = radius * (0.08 + ease(clamp(age)) * (1.15 + i * 0.15))
            local position = center - V3(0, 2.8 - (i - 1) * 0.45, 0)
            local cf = CFrame.new(position) * CFrame.Angles(math.pi / 2 + (i - 2) * 0.035, 0, 0)
            wave:pose(cf, math.max(0.1, waveRadius), (0.48 - i * 0.075) * (1 - clamp(age) * 0.6), 1 - waveAlpha * 0.85)
        end

        -- Cubic Beam segments make continuous, gently winding orbital filaments.
        local filamentAlpha = barrierAlpha * smooth(clamp(opened / 0.65))
        for _, strand in ipairs(strands) do
            local tangents = {}
            for i = 0, steps do
                local position, tangent = spiralPoint(i / steps, elapsed, strand.phase, r * 1.007 + 0.08)
                strand.anchors[i + 1].CFrame = tangentFrame(position, tangent)
                tangents[i + 1] = tangent.Magnitude / (steps * 3)
            end
            for i, beam in ipairs(strand.beams) do
                local endpointFade = math.sin(math.pi * (i - 0.5) / steps)
                beam.CurveSize0 = tangents[i]
                beam.CurveSize1 = tangents[i + 1]
                beam.Width0 = (0.08 + 0.12 * endpointFade) * (0.3 + growth * 0.7)
                beam.Width1 = beam.Width0
                beam.Transparency = NumberSequence.new(1 - filamentAlpha * endpointFade * 0.68)
            end
        end

        for i, star in ipairs(stars) do
            local angle = star.phase + elapsed * star.speed
            local latitude = star.latitude + math.sin(elapsed * 0.09 + star.phase) * 0.035
            local direction = V3(math.cos(latitude) * math.cos(angle), math.sin(latitude), math.cos(latitude) * math.sin(angle))
            local chargeDistance = 11 * (1 - preparation * 0.87) + (i % 3) * 0.9
            local chargePosition = crownPosition + rotation:VectorToWorldSpace(direction) * chargeDistance
            local worldPosition = center + rotation:VectorToWorldSpace(direction) * r * star.orbit
            local opacity = inPreparation and chargeAlpha * preparation * 0.6 or barrierAlpha * 0.58
            opacity = opacity * (0.7 + 0.3 * math.sin(elapsed * 1.5 + star.phase) ^ 2)
            setSphere(star.part, inPreparation and chargePosition or worldPosition,
                star.size * (inPreparation and 0.65 or 1), 1 - opacity)
        end
    end

    function effect:destroy()
        if dead then return end
        dead = true
        folder:Destroy()
    end
    return effect
end


-- A second, non-interactive world is drawn over the real map while inside the domain.
-- ViewportFrame does not render the live Workspace: the real place is never hidden,
-- reparented or changed. All stars, filaments and avatar replicas belong to this view.

local function voidIndexParts(node, prefix, result)
    local occurrence = {}
    for _, child in ipairs(node:GetChildren()) do
        local token = child.ClassName .. ":" .. child.Name
        occurrence[token] = (occurrence[token] or 0) + 1
        local key = prefix .. "/" .. token .. "#" .. occurrence[token]
        if child:IsA("BasePart") then result[key] = child end
        voidIndexParts(child, key, result)
    end
end

local function copyVoidAvatar(source, parent)
    if not source or not source.Parent then return nil end
    local previous = source.Archivable
    local ok, replica = pcall(function()
        source.Archivable = true
        return source:Clone()
    end)
    -- Restore the source even when cloning fails. No source pose or physics changes.
    pcall(function() source.Archivable = previous end)
    if not ok or not replica then return nil end
    local sourceParts, replicaParts = {}, {}
    voidIndexParts(source, "", sourceParts)
    voidIndexParts(replica, "", replicaParts)
    local pairsList = {}
    for path, part in pairs(replicaParts) do
        local original = sourceParts[path]
        if original then
            pairsList[#pairsList + 1] = {source = original, copy = part}
        end
    end
    -- Disable neck/death rules before removing any joints, regardless of the
    -- descendant enumeration order. These settings apply only to the replica.
    for _, item in ipairs(replica:GetDescendants()) do
        if item:IsA("Humanoid") then
            item.RequiresNeck = false
            item.BreakJointsOnDeath = false
        end
    end
    -- Sanitize before parenting. No scripts, joints, animators, sounds or emitters
    -- from a character are allowed to run inside the miniature world.
    for _, item in ipairs(replica:GetDescendants()) do
        if item:IsA("BasePart") then
            item.Anchored = true
            item.CanCollide = false
            item.CanTouch = false
            item.CanQuery = false
            item.CastShadow = false
            item.LocalTransparencyModifier = 0
        elseif item:IsA("Humanoid") then
            item.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            item.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
            item.AutoRotate = false
        elseif not (item:IsA("Model") or item:IsA("Folder")
            or item:IsA("Accessory") or item:IsA("Clothing")
            or item:IsA("ShirtGraphic") or item:IsA("BodyColors")
            or item:IsA("DataModelMesh") or item:IsA("Decal")
            or item:IsA("SurfaceAppearance") or item:IsA("Attachment")
            or item:IsA("WrapLayer") or item:IsA("WrapTarget")) then
            item:Destroy()
        end
    end
    replica.Name = "VoidAvatar_" .. source.Name
    replica.Parent = parent
    local avatar = {model = replica, pairs = pairsList, source = source, frozen = false}
    function avatar:update(offset)
        offset = offset or Vector3.zero
        local frozen = self.source:GetAttribute("InfiniteVoidOverloaded") == true
        local sourceRoot = self.source:FindFirstChild("HumanoidRootPart")
        local rootFrame = sourceRoot and sourceRoot:IsA("BasePart") and sourceRoot.CFrame or nil
        if frozen and self.frozen and self.lastOffset == offset
            and self.lastFrozenRootFrame == rootFrame then return end
        for _, pair in ipairs(self.pairs) do
            if pair.source.Parent and pair.copy.Parent then
                if frozen then
                    -- Capture once at onset, then preserve the pose even if the
                    -- source Animate script continues running. Keep limb transforms
                    -- relative to the root so an authoritative teleport still moves
                    -- the motionless replica to the correct place.
                    if not self.frozen then
                        pair.frozenCFrame = pair.source.CFrame
                        pair.frozenLocal = rootFrame and rootFrame:ToObjectSpace(pair.source.CFrame) or nil
                    end
                    local pose = rootFrame and pair.frozenLocal and rootFrame * pair.frozenLocal
                        or pair.frozenCFrame or pair.source.CFrame
                    pair.copy.CFrame = pose + offset
                else
                    pair.frozenCFrame = nil
                    pair.frozenLocal = nil
                    pair.copy.CFrame = pair.source.CFrame + offset
                end
            end
        end
        self.frozen = frozen
        self.lastOffset = offset
        self.lastFrozenRootFrame = rootFrame
    end
    function avatar:destroy()
        self.model:Destroy()
        self.pairs = {}
    end
    return avatar
end

local function createVoidInterior(parent, payload)
    local interior = {}
    local voidCollectionService = game:GetService("CollectionService")
    local rng = Random.new(math.floor(payload.seed or 7319))
    local center = payload.center
    local frame = payload.frame or CFrame.new(center)
    local radius = payload.radius or 85
    local viewport = new("ViewportFrame", parent, {
        Name = "InfiniteVoidInterior", Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromScale(0, 0), BorderSizePixel = 0,
        BackgroundColor3 = Color3.fromRGB(1, 2, 9),
        BackgroundTransparency = 1, ImageTransparency = 1,
        ZIndex = parent.ZIndex, Active = false,
        Ambient = Color3.fromRGB(154, 170, 208),
        LightColor = Color3.fromRGB(205, 228, 255),
        LightDirection = Vector3.new(-0.25, -0.65, -0.7),
    })
    local world = new("WorldModel", viewport, {Name = "Cosmos"})
    local viewCamera = new("Camera", viewport, {Name = "VoidCamera", FieldOfView = 70})
    viewport.CurrentCamera = viewCamera
    local scenery = new("Folder", world, {Name = "CelestialGeometry"})
    local avatarFolder = new("Folder", world, {Name = "Participants"})
    local avatars, stars, rings, stream = {}, {}, {}, {}
    local destroyed = false
    local nextRoster, nextTwinkle, twinkleCursor = 0, 0, 1
    local maxAvatars = math.min(CONFIG.MaxAvatars or 12, LOW and 6 or 12)

    local function cosmicPart(name, size, color, opacity, shape)
        return new("Part", scenery, {
            Name = name, Anchored = true, CanCollide = false,
            CanTouch = false, CanQuery = false, CastShadow = false,
            Material = Enum.Material.SmoothPlastic,
            Color = color, Transparency = opacity or 0,
            Size = size, Shape = shape or Enum.PartType.Block,
            TopSurface = Enum.SurfaceType.Smooth, BottomSurface = Enum.SurfaceType.Smooth,
        })
    end
    local function segment(part, a, b, width)
        local delta = b - a
        part.Size = Vector3.new(width, width, math.max(0.02, delta.Magnitude))
        part.CFrame = CFrame.lookAt((a + b) * 0.5, b)
    end
    local forward = frame.LookVector
    local eclipseCenter = forward * 460 + Vector3.new(0, 145, 0)
    local eclipseFrame = CFrame.lookAt(eclipseCenter, Vector3.new(0, 8, 0))
        * CFrame.Angles(0, 0, -0.19)

    -- An actual dark celestial body occludes a bright accretion band. Halo rings
    -- are polygons made from thin parts: they do not rely on Neon/Bloom support.
    local pearl = cosmicPart("BlackPearl", Vector3.new(184, 184, 184),
        Color3.fromRGB(0, 0, 2), 0, Enum.PartType.Ball)
    pearl.CFrame = eclipseFrame
    local bands = {
        {size = Vector3.new(1370, 0.75, 5), color = C.White, alpha = 0.04},
        {size = Vector3.new(1150, 2.6, 17), color = C.Cyan, alpha = 0.37},
        {size = Vector3.new(1000, 8, 34), color = C.Blue, alpha = 0.70},
        {size = Vector3.new(900, 18, 60), color = C.Violet, alpha = 0.89},
    }
    for i, definition in ipairs(bands) do
        local band = cosmicPart("AccretionBand" .. i, definition.size,
            definition.color, definition.alpha, Enum.PartType.Ball)
        band.CFrame = eclipseFrame * CFrame.new(0, -8, 13 + i * 2)
    end
    local function ring(radiusX, radiusY, count, color, width, alpha, phase, speed, gap)
        local entries = {}
        for i = 1, count do
            if not gap or i % gap ~= 0 then
                local piece = cosmicPart("PhotonArc", Vector3.new(1, 1, 1), color, alpha)
                entries[#entries + 1] = {part = piece, index = i - 1}
            end
        end
        rings[#rings + 1] = {
            entries = entries, radiusX = radiusX, radiusY = radiusY,
            count = count, width = width, phase = phase, speed = speed,
        }
    end
    ring(97, 97, LOW and 44 or 72, C.White, 1.5, 0.02, 0, 0.013)
    ring(103, 103, LOW and 36 or 56, C.Cyan, 2.4, 0.5, 0.2, -0.04)
    ring(118, 107, LOW and 32 or 52, C.Violet, 1.0, 0.44, 0.35, 0.085, 7)
    ring(160, 42, LOW and 36 or 60, C.White, 0.65, 0.18, 0.2, -0.1, 9)
    ring(199, 58, LOW and 28 or 44, C.Blue, 1.5, 0.57, 0.5, 0.07, 6)

    -- A distant spherical distribution means looking backwards or straight up
    -- still reveals depth. Static star positions do not churn instances each frame.
    for i = 1, (LOW and 105 or 210) do
        local yaw = rng:NextNumber(0, math.pi * 2)
        local elevation = rng:NextNumber(-1, 1)
        local horizontal = math.sqrt(1 - elevation * elevation)
        local direction = Vector3.new(math.cos(yaw) * horizontal,
            elevation, math.sin(yaw) * horizontal)
        local distance = rng:NextNumber(310, 970)
        -- Keep far stars above sub-pixel size on mobile ViewportFrames.
        local size = distance * rng:NextNumber(0.0012, 0.003)
        if i % 13 == 0 then size = size * 1.9 end
        local color = (i % 9 == 0 and C.Violet) or (i % 4 == 0 and C.Cyan) or C.White
        local star = cosmicPart("Star", Vector3.new(size, size, size), color,
            rng:NextNumber(0.02, 0.52), Enum.PartType.Ball)
        star.Position = direction * distance
        stars[#stars + 1] = {part = star, phase = rng:NextNumber(0, 8),
            base = rng:NextNumber(0.04, 0.44)}
        if i % 18 == 0 then
            local glint = cosmicPart("StarRay", Vector3.new(size * 4.5, size * 0.18, size * 0.18),
                color, 0.42)
            glint.CFrame = CFrame.new(star.Position)
        end
    end

    -- Long spiral filaments form a galaxy around, above and below the participants.
    -- Each strand is prebuilt; only the narrow eclipse rings and near-eye streaks move.
    local arms = LOW and 3 or 5
    local armSteps = LOW and 25 or 42
    for arm = 1, arms do
        local previous
        for i = 0, armSteps do
            local fraction = i / armSteps
            local angle = arm / arms * math.pi * 2 + fraction * math.pi * 2.3
            local r = 120 + fraction * 620
            local p = Vector3.new(math.cos(angle) * r,
                -25 + fraction * 60 + math.sin(angle * 1.7) * 26,
                math.sin(angle) * r)
            if previous then
                local color = arm % 2 == 0 and C.Cyan or C.Violet
                local line = cosmicPart("SpiralFilament", Vector3.new(1, 1, 1), color,
                    0.37 + fraction * 0.43)
                segment(line, previous, p, 0.26 + fraction * 0.6)
            end
            previous = p
        end
    end

    -- Finite, reusable streak pool creates parallax without particles or replication.
    for i = 1, (LOW and 20 or 42) do
        local piece = cosmicPart("InformationStreak", Vector3.new(0.03, 0.03, 2),
            i % 4 == 0 and C.Cyan or C.White, 0.65)
        stream[#stream + 1] = {part = piece, x = rng:NextNumber(-1, 1),
            y = rng:NextNumber(-0.65, 0.65), phase = rng:NextNumber(),
            speed = rng:NextNumber(0.08, 0.18), width = rng:NextNumber(0.022, 0.06)}
    end

    local function refreshRoster()
        local candidates, seen = {}, {}
        local function addCandidate(character, participant)
            if not character or not character:IsA("Model") or seen[character]
                or not character:IsDescendantOf(workspace) then return end
            seen[character] = true
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
                local distance = (root.Position - center).Magnitude
                if distance <= radius + 1 then
                    -- Caster and local viewer retain their replicas under the budget.
                    local score = distance
                    if participant and participant.UserId == payload.casterUserId then score = -20000 end
                    if participant == player then score = -10000 end
                    candidates[#candidates + 1] = {character = character, score = score}
                end
            end
        end
        for _, participant in ipairs(Players:GetPlayers()) do
            addCandidate(participant.Character, participant)
        end
        -- Only opt-in NPCs are mirrored; no traversal of the real map is needed.
        for _, character in ipairs(voidCollectionService:GetTagged("InfiniteVoidTarget")) do
            addCandidate(character, nil)
        end
        table.sort(candidates, function(a, b) return a.score < b.score end)
        local keep = {}
        for i = 1, math.min(maxAvatars, #candidates) do
            local candidate = candidates[i]
            keep[candidate.character] = true
            if not avatars[candidate.character] then
                avatars[candidate.character] = copyVoidAvatar(candidate.character, avatarFolder)
            end
        end
        for character, avatar in pairs(avatars) do
            if not keep[character] then
                avatar:destroy()
                avatars[character] = nil
            end
        end
    end

    function interior:update(now, dt, realCamera, opacity)
        if destroyed then return end
        opacity = math.clamp(opacity or 0, 0, 1)
        viewport.Visible = opacity > 0.001
        viewport.ImageTransparency = 1 - opacity
        viewport.BackgroundTransparency = 1 - opacity
        if opacity <= 0.001 or not realCamera then return end
        local elapsed = math.max(0, now - payload.startAt)
        viewCamera.CFrame = realCamera.CFrame - center
        viewCamera.FieldOfViewMode = realCamera.FieldOfViewMode
        viewCamera.FieldOfView = realCamera.FieldOfView
        viewCamera.Focus = realCamera.Focus - center
        if now >= nextRoster then
            nextRoster = now + 0.4
            refreshRoster()
        end
        for character, avatar in pairs(avatars) do
            if avatar.source.Parent then
                avatar:update(-center)
                -- Match first-person visibility only for the viewer's own body.
                if character == player.Character then
                    for _, pair in ipairs(avatar.pairs) do
                        if pair.copy.Parent and pair.source.Parent then
                            pair.copy.LocalTransparencyModifier = pair.source.LocalTransparencyModifier
                        end
                    end
                end
            end
        end
        for _, description in ipairs(rings) do
            local phase = description.phase + elapsed * description.speed
            local pulse = 1 + 0.009 * math.sin(elapsed * 1.1 + description.phase)
            for _, entry in ipairs(description.entries) do
                local a = entry.index / description.count * math.pi * 2 + phase
                local b = (entry.index + 1.04) / description.count * math.pi * 2 + phase
                local p = eclipseFrame:PointToWorldSpace(Vector3.new(
                    math.cos(a) * description.radiusX * pulse,
                    math.sin(a) * description.radiusY * pulse, -5))
                local q = eclipseFrame:PointToWorldSpace(Vector3.new(
                    math.cos(b) * description.radiusX * pulse,
                    math.sin(b) * description.radiusY * pulse, -5))
                segment(entry.part, p, q, description.width)
            end
        end
        for _, mote in ipairs(stream) do
            local cycle = (elapsed * mote.speed + mote.phase) % 1
            local z = 10 + (1 - cycle) * 250
            mote.part.Size = Vector3.new(mote.width, mote.width, 0.8 + cycle * 4)
            mote.part.CFrame = viewCamera.CFrame * CFrame.new(mote.x * z, mote.y * z, -z)
            mote.part.Transparency = 0.35 + 0.65 * math.abs(cycle * 2 - 1)
        end
        if now >= nextTwinkle then
            nextTwinkle = now + 0.04
            for _ = 1, LOW and 5 or 10 do
                local star = stars[twinkleCursor]
                star.part.Transparency = math.clamp(star.base
                    + 0.14 * math.sin(elapsed * 0.8 + star.phase), 0, 0.78)
                twinkleCursor = twinkleCursor % #stars + 1
            end
        end
    end
    function interior:destroy()
        if destroyed then return end
        destroyed = true
        for _, avatar in pairs(avatars) do avatar:destroy() end
        avatars = {}
        viewport:Destroy()
    end
    return interior
end


-- Camera ownership is restricted to the caster's short introduction.
-- The default Roblox camera continues normally behind the interior viewport.
local function restoreCamera()
    local s = intro and intro.camera
    if not s then return end
    intro.camera = nil
    if s.camera.Parent and s.camera:GetAttribute("InfiniteVoidCameraOwner") == token then
        -- Ownership survives another effect adding shake to our last CFrame.
        if s.camera.CameraType == Enum.CameraType.Scriptable then
            s.camera.CameraType = s.kind
            if s.subject and s.subject.Parent then s.camera.CameraSubject = s.subject end
            s.camera.CFrame = s.cf
            s.camera.Focus = s.focus
            s.camera.FieldOfView = s.fov
        end
        s.camera:SetAttribute("InfiniteVoidCameraOwner", nil)
    end
end
local function endIntro()
    if not intro then return end
    restoreCamera()
    CAS:UnbindAction(token .. "_Movement")
    if intro.avatar then intro.avatar:destroy() end
    intro = nil
    cinematic.Visible, portraitFrame.Visible, skip.Visible = false, false, false
    stopSound("Intro")
end
local function beginIntro(d)
    endIntro()
    local char, _, root = characterParts()
    if not char then return end
    -- Ask the companion ability to remove any additive camera offset before the snapshot.
    local purpleGui = playerGui:FindFirstChild("HollowPurple_AnimeV2")
    local handoff = purpleGui and purpleGui:FindFirstChild("ReleaseCamera")
    if handoff and handoff:IsA("BindableFunction") then pcall(function() handoff:Invoke() end) end
    local camera = workspace.CurrentCamera
    intro = {domain = d, character = char, root = root, avatar = copyVoidAvatar(char, portraitWorld)}
    if camera and CONFIG.CinematicCamera and CONFIG.CameraMotion > 0 and not UIS.VREnabled
        and camera.CameraType ~= Enum.CameraType.Scriptable then
        intro.camera = {camera = camera, kind = camera.CameraType, subject = camera.CameraSubject,
            cf = camera.CFrame, focus = camera.Focus, fov = camera.FieldOfView}
        camera:SetAttribute("InfiniteVoidCameraOwner", token)
        camera.CameraType = Enum.CameraType.Scriptable
    end
    -- This suppresses only normal character movement during the cinematic, not chat/UI.
    CAS:BindActionAtPriority(token .. "_Movement", function()
        return Enum.ContextActionResult.Sink
    end, false, Enum.ContextActionPriority.High.Value + 10, Enum.PlayerActions.CharacterForward,
        Enum.PlayerActions.CharacterBackward, Enum.PlayerActions.CharacterLeft,
        Enum.PlayerActions.CharacterRight, Enum.PlayerActions.CharacterJump)
    cinematic.Visible, skip.Visible = true, true
    sound("Intro", CONFIG.IntroSound, false)
end
local function updateIntro(now)
    if not intro then return 0 end
    local d = intro.domain
    local t = now - d.startAt
    if now >= d.openAt or intro.character ~= player.Character or not intro.root.Parent then
        endIntro(); return 0
    end
    t = math.max(0, t)
    local total = d.openAt - d.startAt
    local normalized = t / math.max(0.1, total)
    local time = normalized * CONFIG.IntroTime
    local fade = smooth(t / 0.2) * (1 - smooth((time - 2.9) / 0.3))
    topBar.Size, bottomBar.Size = UDim2.fromScale(1, 0.115 * fade), UDim2.fromScale(1, 0.115 * fade)
    dimmer.BackgroundTransparency = 1 - fade * (0.10 + 0.30 * smooth((time - 1.35) / 0.6))
    local titleIn = smooth((time - 1.58) / 0.25) * (1 - smooth((time - 3) / 0.2))
    title.TextTransparency = 1 - titleIn
    title.Position = UDim2.fromScale(0.5, mix(0.82, 0.77, ease((time - 1.55) / 0.6)))
    subTitle.TextTransparency = 1 - smooth((time - 0.12) / 0.5) * fade
    hairline.Size = UDim2.fromScale(0.66 * ease((time - 1.42) / 0.7), 0.002)
    hairline.BackgroundTransparency = 1 - fade
    crest.TextTransparency = 1 - titleIn * 0.6
    crest.Rotation = 3 * math.sin(time * 0.8)
    local portraitOpacity = smooth((time - 0.45) / 0.16) * (1 - smooth((time - 1.25) / 0.18))
    portraitFrame.Visible = portraitOpacity > 0.01 and intro.avatar ~= nil
    portraitView.ImageTransparency = 1 - portraitOpacity
    portraitFrame.BackgroundTransparency = 1 - portraitOpacity
    portraitFrame.Size = UDim2.fromScale(1, mix(0.1, 0.30, ease((time - 0.45) / 0.35)))
    if intro.avatar then
        intro.avatar:update(-d.center)
        local head = intro.character:FindFirstChild("Head")
        if head then
            local cf = head.CFrame - d.center
            local focus = cf.Position + cf.UpVector * 0.1
            portraitCamera.CFrame = CFrame.lookAt(focus + cf.LookVector * mix(3.6, 2.45,
                ease((time - 0.45) / 1)) + cf.RightVector * 0.15, focus)
            portraitCamera.Focus = CFrame.new(focus)
            -- A ViewportFrame camera does not share the main Camera.ViewportSize.
            local point = portraitCamera.CFrame:PointToObjectSpace(focus + cf.RightVector * 0.18)
            local size = portraitView.AbsoluteSize
            local depth = math.max(0.01, -point.Z)
            local halfHeight = depth * math.tan(math.rad(portraitCamera.FieldOfView * 0.5))
            if size.X > 1 and size.Y > 1 then
                eyeFlare.Position = UDim2.fromScale(0.5 + point.X / (2 * halfHeight * size.X / size.Y),
                    0.5 - point.Y / (2 * halfHeight))
            end
            eyeFlare.BackgroundTransparency = 1 - portraitOpacity * 0.8
        end
    end
    local s = intro.camera
    if s then
        if s.camera ~= workspace.CurrentCamera or s.camera.CameraType ~= Enum.CameraType.Scriptable then
            restoreCamera()
        else
            local root = intro.root
            local head = intro.character:FindFirstChild("Head")
            local target = head and head.Position or root.Position + V3(0, 1.6, 0)
            local front, right = d.frame.LookVector, d.frame.RightVector
            local cameraPos, focus, fov
            if time < 0.65 then
                local q = ease(time / 0.65)
                cameraPos = target + front * mix(8.5, 3.6, q) + right * mix(2.8, 0.4, q) + V3(0, mix(0.8, 0.08, q), 0)
                focus, fov = target, mix(54, 39, q)
            elseif time < 1.45 then
                local q = clamp((time - 0.65) / 0.8)
                cameraPos = target + front * mix(3.6, 2.9, q) + right * mix(0.4, -0.35, q) + V3(0, 0.08, 0)
                focus, fov = target, mix(39, 32, q)
            else
                local q = ease((time - 1.45) / 1.45)
                local angle = mix(-0.1, 0.75, q) * CONFIG.CameraMotion
                local direction = front * math.cos(angle) + right * math.sin(angle)
                cameraPos = root.Position + direction * mix(6, 24, q) + V3(0, mix(1, 9, q), 0)
                focus, fov = root.Position + V3(0, 1.3, 0), mix(43, 73, q)
            end
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = {world, intro.character}
            params.RespectCanCollide = true
            local delta = cameraPos - focus
            local hit = workspace:Raycast(focus, delta, params)
            if hit and delta.Magnitude > 0.01 then
                cameraPos = focus + delta.Unit * math.max(0.6, hit.Distance - 0.4)
            end
            local result = CFrame.lookAt(cameraPos, focus)
            local returnBlend = smooth((time - 2.87) / 0.33)
            result = result:Lerp(s.cf, returnBlend)
            s.camera.CFrame = result
            s.camera.Focus = CFrame.new(focus):Lerp(s.focus, returnBlend)
            s.camera.FieldOfView = mix(fov, s.fov, returnBlend)
            s.applied = result
        end
    end
    return fade
end
local function validPayload(d)
    return type(d) == "table" and type(d.id) == "string" and #d.id <= 100
        and typeof(d.center) == "Vector3" and typeof(d.frame) == "CFrame"
        and type(d.casterUserId) == "number" and type(d.startAt) == "number"
        and type(d.openAt) == "number" and type(d.endAt) == "number"
        and type(d.radius) == "number" and d.radius > 0 and d.radius <= 300
        and d.endAt > d.openAt and d.openAt > d.startAt
        and d.endAt - d.startAt < 120
end
local function removeDomain(id)
    local d = domains[id]
    if not d then return end
    if intro and intro.domain == d then endIntro() end
    if d.fx then d.fx:destroy(); d.fx = nil end
    domains[id] = nil
end
local function startDomain(payload)
    if not validPayload(payload) or domains[payload.id] then return end
    local now = clock()
    if payload.endAt <= now or payload.startAt > now + 5 then return end
    local count = 0
    -- Closing visual tails do not occupy an authoritative active-domain slot.
    for _, activeDomain in pairs(domains) do
        if activeDomain.endAt > now then count = count + 1 end
    end
    if count >= CONFIG.MaxDomains then return end
    local d = {}
    for k, v in pairs(payload) do d[k] = v end
    domains[d.id] = d
    local char, _, root = characterParts()
    if root and (root.Position - d.center).Magnitude <= CONFIG.VisibleDistance then d.fx = createWorldDomain(d) end
    if d.casterUserId == player.UserId then
        pendingAt = nil
        nextCastAt = math.max(nextCastAt, d.cooldownUntil or now + CONFIG.Cooldown)
        if char and now < d.openAt - 0.15 then beginIntro(d) end
    end
end
local function endDomain(payload)
    local d = type(payload) == "table" and domains[payload.id]
    if not d then return end
    if intro and intro.domain == d then endIntro() end
    local now = clock()
    d.endAt = math.min(d.endAt, now)
    d.cancelled = d.endAt < d.openAt
end
local function attachRemote(candidate)
    if candidate.Name ~= "ISAGI_InfiniteVoidRemote" or not candidate:IsA("RemoteEvent") or remote == candidate then return end
    if remoteConnection then remoteConnection:Disconnect() end
    for id, d in pairs(domains) do if d.preview then removeDomain(id) end end
    remote = candidate
    remoteConnection = candidate.OnClientEvent:Connect(function(action, payload)
        if not alive then return end
        if action == "Start" then startDomain(payload)
        elseif action == "End" then endDomain(payload)
        elseif action == "Denied" then
            pendingAt = nil
            if type(payload) == "table" then
                if type(payload.retryAt) == "number" then nextCastAt = math.max(nextCastAt, payload.retryAt) end
                local reasons = {Cooldown = "Территория восстанавливается", AlreadyCasting = "Территория уже раскрывается",
                    CharacterUnavailable = "Нужен живой персонаж", Seated = "Сначала встань с сиденья",
                    Interrupted = "Расширение прервано", TooManyDomains = "Слишком много активных территорий"}
                message(reasons[payload.reason] or "Расширение сейчас недоступно")
            end
        end
    end)
    remote:FireServer("Sync")
end
local function requestCast()
    local now = clock()
    local char, _, root = characterParts()
    if not char or pendingAt or now < nextCastAt or intro then return end
    if char:GetAttribute("InfiniteVoidOverloaded") or char:GetAttribute("InfiniteVoidCasting") then return end
    if remote and remote.Parent then
        pendingAt = now
        remote:FireServer("Cast")
    else
        local start = now + 0.1
        startDomain({id = HttpService:GenerateGUID(false), casterUserId = player.UserId,
            center = root.Position, frame = root.CFrame, startAt = start,
            openAt = start + CONFIG.IntroTime, endAt = start + CONFIG.IntroTime + CONFIG.Duration,
            radius = CONFIG.Radius, seed = Random.new():NextInteger(1, 1000000),
            cooldownUntil = start + CONFIG.Cooldown, preview = true})
    end
end
local function findInteriorDomain(now, root)
    if not root then return nil end
    local chosen, score
    for _, d in pairs(domains) do
        if not d.cancelled and now >= d.openAt and now < d.endAt then
            local distance = (root.Position - d.center).Magnitude
            if distance <= d.radius then
                local rank = distance + (d.casterUserId == player.UserId and 1000 or 0)
                if not score or rank < score then chosen, score = d, rank end
            end
        end
    end
    return chosen
end
local function setInteriorDomain(d, now)
    if interior then interior:destroy(); interior = nil end
    interiorDomain = d
    interiorAlpha = 0
    if d then
        interior = createVoidInterior(insideLayer, d)
        flashAt = now
        sound("Open", CONFIG.OpenSound, false)
        sound("Ambience", CONFIG.AmbienceSound, true)
    else
        stopSound("Ambience")
    end
end
local function resetScene()
    endIntro()
    for id in pairs(domains) do removeDomain(id) end
    setInteriorDomain(nil, clock())
    pendingAt, overloadAmount = nil, 0
    cc.Enabled, bloom.Intensity, blur.Size = false, 0, 0
    flash.BackgroundTransparency = 1
    overlay.Visible = false
end
local function readCooldown()
    local value = player:GetAttribute("InfiniteVoidCooldownUntil")
    if type(value) == "number" then nextCastAt = math.max(nextCastAt, value) end
end
readCooldown()
connect(player:GetAttributeChangedSignal("InfiniteVoidCooldownUntil"), readCooldown)
connect(button.Activated, requestCast)
connect(skip.Activated, endIntro)
connect(UIS.InputBegan, function(input, processed)
    if input.KeyCode == Enum.KeyCode.Escape then endIntro(); return end
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode == Enum.KeyCode.V then requestCast() end
end)
connect(UIS.WindowFocusReleased, endIntro)
connect(player.CharacterRemoving, resetScene)
connect(player.CharacterAdded, function()
    resetScene()
    task.defer(function() if alive and remote and remote.Parent then remote:FireServer("Sync") end end)
end)
connect(ReplicatedStorage.ChildAdded, attachRemote)
connect(ReplicatedStorage.ChildRemoved, function(child)
    if child == remote then
        if remoteConnection then remoteConnection:Disconnect(); remoteConnection = nil end
        remote = nil
        resetScene()
    end
end)
local foundRemote = ReplicatedStorage:FindFirstChild("ISAGI_InfiniteVoidRemote")
if foundRemote then attachRemote(foundRemote) end

local function render(dt)
    if not alive then return end
    local now, camera = clock(), workspace.CurrentCamera
    local char, _, root = characterParts()
    if intro and not char then endIntro() end
    local introAmount = updateIntro(now)
    for id, d in pairs(domains) do
        if now > d.endAt + 0.85 or d.cancelled then
            removeDomain(id)
        else
            local nearby = root and (root.Position - d.center).Magnitude <= CONFIG.VisibleDistance
            if nearby and not d.fx then d.fx = createWorldDomain(d) end
            if not nearby and d.fx then d.fx:destroy(); d.fx = nil end
            if d.fx then d.fx:update(now, dt) end
        end
    end
    local chosen = findInteriorDomain(now, root)
    if chosen and chosen ~= interiorDomain then setInteriorDomain(chosen, now) end
    if interior then
        local target = chosen == interiorDomain and 1 or 0
        interiorAlpha = mix(interiorAlpha, target, 1 - math.exp(-dt * (target == 1 and 12 or 6)))
        interior:update(now, dt, camera, interiorAlpha)
        if not chosen and interiorAlpha < 0.015 then setInteriorDomain(nil, now) end
    end
    local overloaded = char and char:GetAttribute("InfiniteVoidOverloaded") == true
    overloadAmount = mix(overloadAmount, overloaded and 1 or 0, 1 - math.exp(-dt * 7))
    overlay.Visible = interior ~= nil
    if interior then
        interiorTitle.TextTransparency = 1 - interiorAlpha * 0.9
        timerText.TextTransparency = 1 - interiorAlpha * 0.7
        overloadText.TextTransparency = 1 - interiorAlpha * overloadAmount * 0.9
        overloadShade.BackgroundTransparency = 1 - interiorAlpha * (0.18 + overloadAmount * 0.25)
        if interiorDomain.preview then
            overloadText.Text = "ВИЗУАЛЬНЫЙ ПРОСМОТР"
            overloadText.TextTransparency = 1 - interiorAlpha * 0.8
        else overloadText.Text = "ПЕРЕГРУЗКА ВОСПРИЯТИЯ" end
        local intensity = interiorAlpha * mix(0.22, 0.75, overloadAmount)
        for _, item in ipairs(streams) do
            local y = (item.y - (now - interiorDomain.openAt) * item.speed) % 1.12 - 0.06
            item.label.Position = UDim2.fromScale(item.x, y)
            item.label.TextTransparency = 1 - intensity * (0.45 + 0.1 * math.sin(y * 7))
        end
        local screenSize = overlay.AbsoluteSize
        for _, item in ipairs(speedLines) do
            local cycle = ((now - interiorDomain.openAt) * 0.14 + item.phase) % 1
            local r = mix(0.3, 0.8, cycle)
            local angle = item.angle
            item.frame.Position = UDim2.fromScale(0.5 + math.cos(angle) * r, 0.5 + math.sin(angle) * r)
            item.frame.Rotation = math.deg(math.atan2(math.sin(angle) * screenSize.Y, math.cos(angle) * screenSize.X))
            item.frame.Size = UDim2.fromOffset(mix(18, math.min(screenSize.X, screenSize.Y) * 0.28, cycle), 1)
            item.frame.BackgroundTransparency = 1 - intensity * 0.34 * math.sin(cycle * math.pi)
        end
    end
    local active = math.max(introAmount, interiorAlpha)
    cc.Enabled = active > 0.005
    cc.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(193, 223, 255), introAmount * 0.28)
    cc.Contrast, cc.Saturation = introAmount * 0.12, -introAmount * 0.2
    cc.Brightness = -introAmount * 0.025
    bloom.Intensity = introAmount * 0.45
    blur.Size = introAmount * 0.65
    local flashTime = now - flashAt
    flash.BackgroundTransparency = 1 - CONFIG.FlashStrength * math.exp(-math.max(0, flashTime) * 8)
    toast.TextTransparency = 1 - smooth((toastUntil - now) / 0.3)
    if pendingAt and now - pendingAt > 3 then
        pendingAt = nil; message("Сервер не подтвердил запуск. Попробуй снова.")
    end
    local uiTick = math.floor(now * 10)
    if uiTick ~= lastUiTick then
        lastUiTick = uiTick
        local remaining = math.max(0, nextCastAt - now)
        icon.Text = pendingAt and "…" or (remaining > 0 and tostring(math.ceil(remaining)) or "∞")
        icon.TextSize = remaining > 0 and 30 or 52
        buttonStroke.Transparency = remaining > 0 and 0.65 or 0.15
        buttonLabel.Text = overloaded and "ПЕРЕГРУЗКА" or (remaining > 0 and "ПЕРЕЗАРЯДКА" or "ПУСТОТА")
        modeLabel.Text = remote and "V · РАСШИРЕНИЕ ТЕРРИТОРИИ" or "V · ВИЗУАЛЬНЫЙ ПРОСМОТР"
        if interiorDomain then timerText.Text = string.format("∞   /   %.1f s", math.max(0, interiorDomain.endAt - now)) end
    end
end
local function shutdown()
    if not alive then return end
    alive = false
    RunService:UnbindFromRenderStep(token)
    resetScene()
    if remoteConnection then remoteConnection:Disconnect() end
    for _, connection in ipairs(connections) do connection:Disconnect() end
    for _, item in pairs(sounds) do item:Destroy() end
    cc:Destroy(); bloom:Destroy(); blur:Destroy()
    world:Destroy(); gui:Destroy()
end
connect(shutdownEvent.Event, shutdown)
connect(gui.Destroying, shutdown)
if typeof(script) == "Instance" then connect(script.Destroying, shutdown) end
RunService:BindToRenderStep(token, Enum.RenderPriority.Camera.Value + 5, function(dt)
    local ok, err = xpcall(function() render(dt) end, debug.traceback)
    if not ok then warn("Infinite Void stopped safely: " .. tostring(err)); shutdown() end
end)
