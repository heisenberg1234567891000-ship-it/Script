--[[
  HOLLOW PURPLE / 200% OUTPUT / ANIME REWORK 3.0
  LocalScript -> StarterPlayer > StarterPlayerScripts. Remove the old script.
  Hold G / on-screen button, release to fire. Escape cancels before release.
  Standalone = visual preview. Add HollowPurple.server.lua for multiplayer damage.
  Procedural geometry, built-in particle textures, no external model dependencies.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
assert(RunService:IsClient() and player, "HollowPurple must run in a Roblox client context")
local CONFIG = {
    Quality = "Auto", -- Auto | Low | High. Auto uses Low on touch devices.
    ChargeTime = 3.4,
    MergeTime = 1.1, -- Keep synchronized with the optional server.
    MinCharge = 0.3,
    Cooldown = 6,
    MaxHold = 12,
    Speed = 200,
    MaxRange = 360,
    ProjectileRadius = 6,
    MuzzleHeight = 7,
    MuzzleForward = 12,
    MuzzleCorridorRadius = 1.25,
    ProjectileDiameter = 12, -- Bright body; the outer aura is 18 studs across.
    VisualBlastRadius = 70, -- Main wave; the last ground ring expands to 112.
    VisibleDistance = 600,
    CameraShake = 0.8, -- 0 disables shake.
    FlashStrength = 0.5, -- 0 disables full-screen impact frames.
    FovKick = 8, -- 0 disables additive FOV animation.
    CinematicBars = true,
    MaxProjectiles = 4,
    MaxBursts = 90,
    -- Optional audio owned / authorized for your experience; empty = silent.
    ChargeSound = "",
    ReleaseSound = "",
    ImpactSound = "",
}

local C = {
    Blue = Color3.fromRGB(32, 132, 255), Cyan = Color3.fromRGB(138, 233, 255),
    Red = Color3.fromRGB(255, 28, 76), Pink = Color3.fromRGB(255, 133, 190),
    Purple = Color3.fromRGB(149, 38, 255), Lilac = Color3.fromRGB(222, 153, 255),
    White = Color3.fromRGB(249, 243, 255), Ink = Color3.fromRGB(7, 4, 15),
}
local LOW = CONFIG.Quality == "Low" or (CONFIG.Quality == "Auto" and UIS.TouchEnabled)
local RNG = Random.new()
local TAU = math.pi * 2
local V3 = Vector3.new
local ONE = V3(1, 1, 1)
local ZERO = V3(0, 0, 0)
local Y = V3(0, 1, 0)
local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local function new(class, parent, properties)
    local object = Instance.new(class)
    for key, value in pairs(properties or {}) do object[key] = value end
    object.Parent = parent
    return object
end
local function clamp(x) return math.clamp(x, 0, 1) end
local function ease(x) return 1 - (1 - clamp(x)) ^ 3 end
local function smooth(x) x = clamp(x); return x * x * (3 - 2 * x) end
local function lerp(a, b, t) return a + (b - a) * t end
local function unit(vector, fallback)
    return vector.Magnitude > 0.001 and vector.Unit or fallback
end
local function facing(position, direction)
    local up = math.abs(direction:Dot(Y)) > 0.98 and V3(1, 0, 0) or Y
    return CFrame.lookAt(position, position + direction, up)
end

-- One owned root, one render loop; every animation has an explicit lifetime.
local playerGui = player:WaitForChild("PlayerGui")
local oldGui = playerGui:FindFirstChild("HollowPurple_AnimeV2")
if oldGui then
    local stop = oldGui:FindFirstChild("Shutdown")
    if stop and stop:IsA("BindableEvent") then stop:Fire() end
    oldGui:Destroy()
end
local gui = new("ScreenGui", playerGui, {
    Name = "HollowPurple_AnimeV2", ResetOnSpawn = false, IgnoreGuiInset = true,
    DisplayOrder = 70, ZIndexBehavior = Enum.ZIndexBehavior.Global,
})
local shutdownEvent = new("BindableEvent", gui, {Name = "Shutdown"})
local world = new("Folder", workspace, {Name = "HollowPurple_VFX_" .. player.UserId})
local muzzleProbe = new("Part", world, {
    Name="MuzzleQuery", Shape=Enum.PartType.Ball, Size=ONE*CONFIG.ProjectileRadius*2,
    Anchored=true, CanCollide=false, CanTouch=false, CanQuery=false,
    Transparency=1, CastShadow=false, Position=V3(0,-10000,0),
})
local alive = true
local connections, jobs, scopes = {}, {}, {}
local transientCount = 0
local remote, remoteConnection
local state, charge, pending = "Idle", nil, nil
local nextCastAt = 0
local activeInput
local ownNetworkId
local projectiles = {}
local cameraState = {camera = nil, delta = nil, applied = nil, fov = 0, lastFov = nil}
local chargeAmount, releasePulse, impactPulse = 0, 0, 0
local shakeEnergy, shakeClock = 0, 0

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end
local function scope(name, lifetime, transient)
    if transient and transientCount >= CONFIG.MaxBursts then return nil end
    local s = {
        folder = new("Folder", world, {Name = name}), alive = true,
        expires = lifetime and os.clock() + lifetime, transient = transient,
    }
    if transient then transientCount = transientCount + 1 end
    function s:destroy()
        if not self.alive then return end
        self.alive = false
        if self.transient then transientCount = transientCount - 1 end
        self.folder:Destroy()
    end
    table.insert(scopes, s)
    return s
end
local function animate(owner, duration, callback, onComplete)
    table.insert(jobs, {owner = owner, start = os.clock(), duration = duration,
        callback = callback, onComplete = onComplete})
end
local function part(parent, color, size, transparency, material)
    return new("Part", parent, {
        Name = "VFX", Anchored = true, CanCollide = false, CanTouch = false,
        CanQuery = false, CastShadow = false, Size = size or ONE,
        Color = color, Material = material or Enum.Material.Neon,
        Transparency = transparency or 0,
    })
end
local function ball(parent, color, diameter, transparency, material)
    local p = part(parent, color, ONE * diameter, transparency, material)
    p.Shape = Enum.PartType.Ball
    return p
end
local function linePart(parent, color, a, b, width, transparency)
    local p = part(parent, color, V3(width, width, math.max((b-a).Magnitude, 0.01)), transparency)
    p.CFrame = facing((a+b)*0.5, unit(b-a, Y))
    return p
end

-- A hollow ring made from four cubic Bezier beams, not a solid cylinder.
local function ring(parent, color)
    local carrier = part(parent, color, ONE * 0.05, 1)
    local attachments, beams = {}, {}
    for i = 1, 4 do attachments[i] = new("Attachment", carrier) end
    for i = 1, 4 do
        beams[i] = new("Beam", carrier, {
            Attachment0 = attachments[i], Attachment1 = attachments[i % 4 + 1],
            Color = ColorSequence.new(color), FaceCamera = true,
            LightEmission = 1, LightInfluence = 0, Segments = LOW and 7 or 12,
            Width0 = 0.1, Width1 = 0.1,
        })
    end
    local r = {part = carrier, beams = beams}
    function r:pose(cf, radius, width, alpha)
        carrier.CFrame = cf
        for i = 1, 4 do
            local angle = (i-1)*math.pi/2
            local point = V3(math.cos(angle), math.sin(angle), 0) * radius
            local tangent = V3(-math.sin(angle), math.cos(angle), 0)
            attachments[i].CFrame = CFrame.fromMatrix(point, tangent, V3(0, 0, 1))
            local beam = beams[i]
            beam.CurveSize0 = radius * 0.55228475
            beam.CurveSize1 = radius * 0.55228475
            beam.Width0 = width
            beam.Width1 = width
            beam.Transparency = NumberSequence.new(clamp(alpha or 0))
        end
    end
    return r
end

local function particles(parent, color, rate, size, speed, life, texture)
    return new("ParticleEmitter", parent, {
        Texture = texture or SPARK, Color = ColorSequence.new(color),
        Rate = LOW and rate * 0.5 or rate, Speed = NumberRange.new(speed * 0.45, speed),
        Lifetime = NumberRange.new(life * 0.65, life), SpreadAngle = Vector2.new(180,180),
        Size = NumberSequence.new({NumberSequenceKeypoint.new(0,size), NumberSequenceKeypoint.new(1,0)}),
        Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.12), NumberSequenceKeypoint.new(1,1)}),
        LightEmission = 0.85, LightInfluence = 0, Drag = 3,
        Rotation = NumberRange.new(-180,180), RotSpeed = NumberRange.new(-90,90),
    })
end
local function trail(p, width, color, lifetime)
    -- Attachments MUST be separated, otherwise Trail has zero width.
    local a = new("Attachment", p, {Position = V3(0, width/2, 0)})
    local b = new("Attachment", p, {Position = V3(0, -width/2, 0)})
    return new("Trail", p, {
        Attachment0 = a, Attachment1 = b, Lifetime = lifetime or 0.23,
        FaceCamera = true, MinLength = 0.04, LightEmission = 1, LightInfluence = 0,
        Color = ColorSequence.new(color, C.White),
        WidthScale = NumberSequence.new({NumberSequenceKeypoint.new(0,1), NumberSequenceKeypoint.new(1,0)}),
        Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.12), NumberSequenceKeypoint.new(1,1)}),
    })
end
local function sound(parent, asset, volume, looped)
    if asset == "" then return nil end
    local s = new("Sound", parent, {SoundId = asset, Volume = volume,
        Looped = looped or false, RollOffMinDistance = 8, RollOffMaxDistance = 180})
    s:Play()
    return s
end
local function orb(parent, color, pale)
    local outer = ball(parent, color, 1, 0.35)
    local core = ball(parent, pale, 0.5, 0)
    local shell = ball(parent, color, 1.4, 0.82, Enum.Material.ForceField)
    local light = new("PointLight", outer, {Color = color, Range = 16, Brightness = 2, Shadows = false})
    local emitter = particles(outer, pale, 24, 0.3, 5, 0.4)
    local band = ring(parent, pale)
    local tail = trail(outer, 0.8, color, 0.22)
    local o = {part = outer, core = core, shell = shell, light = light, emitter = emitter, trail = tail}
    function o:pose(cf, size, t, alpha)
        alpha = alpha or 0
        outer.CFrame, core.CFrame, shell.CFrame = cf, cf, cf
        outer.Size, core.Size, shell.Size = ONE*size, ONE*(size*0.5), ONE*(size*1.5)
        outer.Transparency = lerp(0.35,1,alpha)
        core.Transparency = alpha
        shell.Transparency = lerp(0.82,1,alpha)
        light.Brightness = (1-alpha)*2.5
        light.Range = math.min(60,12+size*3)
        band:pose(cf*CFrame.Angles(t*1.7, t*0.6, -t), size*0.85, 0.065+size*0.025, lerp(0.2,1,alpha))
    end
    return o
end

-- Short-lived shards / arcs share the central scheduler.
local function bolt(a, b, color, width, duration)
    local s = scope("Lightning", duration+0.03, true)
    if not s then return end
    local axis = b-a
    local basis = facing(a, unit(axis,Y))
    local count = LOW and 4 or 6
    local points, pieces = {a}, {}
    for i = 1, count-1 do
        local envelope = math.sin(i/count*math.pi)
        points[#points+1] = a+axis*(i/count)
            + basis.RightVector*RNG:NextNumber(-1,1)*envelope*axis.Magnitude*0.13
            + basis.UpVector*RNG:NextNumber(-1,1)*envelope*axis.Magnitude*0.13
    end
    points[#points+1] = b
    for i = 1, #points-1 do
        pieces[#pieces+1] = linePart(s.folder,color,points[i],points[i+1],width,0.1)
        if not LOW then pieces[#pieces+1] = linePart(s.folder,C.White,points[i],points[i+1],width*0.28,0.05) end
    end
    animate(s,duration,function(p)
        for _, piece in ipairs(pieces) do piece.Transparency = ease(p) end
    end)
end
local function wave(position, cf, color, targetRadius, duration, width)
    local s = scope("ShockRing",duration+0.03,true)
    if not s then return end
    local r = ring(s.folder,color)
    animate(s,duration,function(p)
        r:pose(CFrame.new(position)*cf,lerp(0.8,targetRadius,ease(p)),width*(1-p)+0.025,p^0.7)
    end)
end
local function expandingBall(position,color,size,duration)
    local s = scope("FlashSphere",duration+0.03,true)
    if not s then return end
    local b = ball(s.folder,color,1,0.5,Enum.Material.ForceField)
    b.Position = position
    animate(s,duration,function(p)
        b.Size = ONE*lerp(1,size,ease(p))
        b.Transparency = lerp(0.35,1,ease(p))
    end)
end

-- Lingering luminous wake. Separate scopes let it fade after the core impacts.
local function energyWake(a,b,diameter)
    if (b-a).Magnitude<0.05 then return end
    local duration=LOW and 0.46 or 0.65
    local s=scope("PurpleWake",duration+0.04,true)
    if not s then return end
    local carrier=part(s.folder,C.Purple,ONE*0.05,1)
    carrier.Position=a
    local a0=new("Attachment",carrier)
    local a1=new("Attachment",carrier,{Position=b-a})
    local beams={}
    for i=1,2 do
        beams[i]=new("Beam",carrier,{Attachment0=a0,Attachment1=a1,FaceCamera=true,
            Color=ColorSequence.new(i==1 and C.Purple or C.Lilac,C.White),
            LightEmission=1,LightInfluence=0,Segments=1,
            Width0=diameter*(i==1 and 0.78 or 0.19),Width1=diameter*(i==1 and 0.78 or 0.19)})
    end
    animate(s,duration,function(p)
        for i,beam in ipairs(beams) do
            local width=diameter*(i==1 and 0.78 or 0.19)*(1-p*0.7)
            beam.Width0=width; beam.Width1=width
            beam.Transparency=NumberSequence.new(lerp(i==1 and 0.55 or 0.28,1,ease(p)))
        end
    end)
end

-- Sparse debris ribbon: raycasts sample the ground rather than copying a
-- horizontal crater into the air. Low quality keeps the same scale, fewer pieces.
local function wakeGround(position,direction)
    local s=scope("GroundWake",1.45,true)
    if not s then return end
    local basis=facing(position,direction)
    local query=RaycastParams.new()
    query.FilterType=Enum.RaycastFilterType.Exclude
    query.FilterDescendantsInstances=player.Character and {world,player.Character} or {world}
    query.IgnoreWater=true
    local didFind=false
    for _,side in ipairs({-1,1}) do
        local sample=position+basis.RightVector*side*RNG:NextNumber(7,10)+Y*6
        local hit=workspace:Raycast(sample,-Y*36,query)
        if hit then
            didFind=true
            local color=hit.Instance:IsA("BasePart") and hit.Instance.Color or Color3.fromRGB(83,77,94)
            local shard=part(s.folder,color,V3(1.6,0.7,2.4)*RNG:NextNumber(0.7,1.4),0,hit.Material)
            local start=hit.Position
            local velocity=basis.RightVector*side*13+Y*16
            animate(s,1.35,function(p,_,t)
                shard.CFrame=CFrame.new(start+velocity*t-Y*18*t*t)*CFrame.Angles(t*2,side*t,t)
                shard.Transparency=smooth((p-0.4)/0.6)
            end)
        end
    end
    if not didFind then s:destroy() end
end

local function impactColumn(position,radius)
    local s=scope("ImpactPillar",0.85,true)
    if not s then return end
    local pale=part(s.folder,C.Lilac,ONE,0.86,Enum.Material.ForceField)
    local core=part(s.folder,C.Purple,ONE,0.64,Enum.Material.ForceField)
    new("SpecialMesh",pale,{MeshType=Enum.MeshType.Sphere})
    new("SpecialMesh",core,{MeshType=Enum.MeshType.Sphere})
    animate(s,0.8,function(p)
        local height=lerp(10,radius*2.1,ease(p))
        local width=lerp(radius*0.6,2,ease(p))
        pale.Position=position+Y*(height*0.32)
        core.Position=pale.Position
        pale.Size=V3(width*1.6,height,width*1.6)
        core.Size=V3(width,height*0.9,width)
        pale.Transparency=lerp(0.64,1,smooth(p))
        core.Transparency=lerp(0.42,1,smooth(p))
    end)
end

local function launchFlare(position)
    local s=scope("LaunchStarburst",0.3,true)
    if not s then return end
    local anchor=part(s.folder,C.White,ONE*0.05,1)
    anchor.Position=position
    local billboard=new("BillboardGui",anchor,{Size=UDim2.fromScale(28,28),
        AlwaysOnTop=false,LightInfluence=0,MaxDistance=CONFIG.VisibleDistance})
    local star=new("ImageLabel",billboard,{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,
        Image=SPARK,ImageColor3=C.White,ImageTransparency=0.1})
    animate(s,0.27,function(p)
        local size=lerp(12,38,ease(p))
        billboard.Size=UDim2.fromScale(size,size)
        star.ImageTransparency=lerp(0.1,1,ease(p))
        star.Rotation=15*p
    end)
end

-- Screen treatment: thin cinematic bars, restrained typography and edge lines.
local overlay = new("Frame",gui,{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Active=false,ZIndex=20})
local flash = new("Frame",gui,{Size=UDim2.fromScale(1,1),BackgroundColor3=C.White,
    BackgroundTransparency=1,BorderSizePixel=0,ZIndex=80,Active=false})
local topBar = new("Frame",overlay,{Size=UDim2.fromScale(1,0),BackgroundColor3=C.Ink,BorderSizePixel=0,ZIndex=30})
local bottomBar = new("Frame",overlay,{Position=UDim2.fromScale(0,1),AnchorPoint=Vector2.new(0,1),
    Size=UDim2.fromScale(1,0),BackgroundColor3=C.Ink,BorderSizePixel=0,ZIndex=30})
local title = new("TextLabel",overlay,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.24),
    Size=UDim2.fromScale(0.78,0.12),BackgroundTransparency=1,Text="HOLLOW  PURPLE",
    TextColor3=C.White,TextTransparency=1,Font=Enum.Font.GothamBlack,TextScaled=true,ZIndex=42,
    TextStrokeColor3=C.Ink,TextStrokeTransparency=0.4})
new("UITextSizeConstraint",title,{MaxTextSize=68,MinTextSize=18})
local subtitle = new("TextLabel",overlay,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.17),
    Size=UDim2.fromScale(0.8,0.035),BackgroundTransparency=1,Text="200% OUTPUT  /  IMAGINARY TECHNIQUE",
    TextColor3=C.Lilac,TextTransparency=1,Font=Enum.Font.GothamMedium,TextScaled=true,ZIndex=42})
new("UITextSizeConstraint",subtitle,{MaxTextSize=14,MinTextSize=9})
local gradient = new("UIGradient",title,{Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,C.Cyan),ColorSequenceKeypoint.new(0.5,C.White),
    ColorSequenceKeypoint.new(1,C.Pink)})})

local edges = {}
for i = 1,4 do
    local horizontal = i <= 2
    local f = new("Frame",overlay,{BorderSizePixel=0,BackgroundColor3=C.Purple,
        BackgroundTransparency=1,Size=horizontal and UDim2.fromScale(0.14,1) or UDim2.fromScale(1,0.18),
        Position=({UDim2.fromScale(0,0),UDim2.fromScale(1,0),UDim2.fromScale(0,0),UDim2.fromScale(0,1)})[i],
        AnchorPoint=({Vector2.new(0,0),Vector2.new(1,0),Vector2.new(0,0),Vector2.new(0,1)})[i],ZIndex=21})
    new("UIGradient",f,{Rotation=({0,180,90,270})[i],Transparency=NumberSequence.new(0,1)})
    edges[#edges+1] = f
end
local speedLines = {}
for i = 1,(LOW and 20 or 34) do
    local f = new("Frame",overlay,{AnchorPoint=Vector2.new(0.5,0.5),BackgroundColor3=C.White,
        BackgroundTransparency=1,BorderSizePixel=0,ZIndex=23})
    speedLines[#speedLines+1] = {frame=f,angle=i/(LOW and 20 or 34)*TAU,
        seed=RNG:NextNumber(),width=RNG:NextNumber(1,2.5)}
end

-- Responsive control, away from the default mobile jump button.
local button = new("TextButton",gui,{Name="Cast",AnchorPoint=Vector2.new(1,1),
    Position=UDim2.new(1,-28,1,-190),Size=UDim2.fromOffset(94,94),Text="",
    BackgroundColor3=C.Ink,BackgroundTransparency=0.13,BorderSizePixel=0,
    AutoButtonColor=false,Active=true,ZIndex=100})
new("UICorner",button,{CornerRadius=UDim.new(1,0)})
local buttonStroke = new("UIStroke",button,{Color=C.Purple,Thickness=2,Transparency=0.2})
local buttonText = new("TextLabel",button,{Size=UDim2.fromScale(1,0.5),Position=UDim2.fromScale(0,0.23),
    BackgroundTransparency=1,Text="PURPLE",TextColor3=C.White,TextSize=14,Font=Enum.Font.GothamBold,ZIndex=101})
local hint = new("TextLabel",button,{Size=UDim2.fromScale(1,0.18),Position=UDim2.fromScale(0,0.69),
    BackgroundTransparency=1,Text=UIS.TouchEnabled and "HOLD" or "G / HOLD",TextColor3=C.Lilac,
    TextSize=10,Font=Enum.Font.GothamMedium,ZIndex=101})
hint.Text=UIS.TouchEnabled and "200% / HOLD" or "200% / G"
local meter = new("Frame",gui,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.86),
    Size=UDim2.new(0.33,0,0,4),BackgroundColor3=C.Ink,BorderSizePixel=0,Visible=false,ZIndex=35})
new("UISizeConstraint",meter,{MinSize=Vector2.new(150,4),MaxSize=Vector2.new(330,4)})
local fill = new("Frame",meter,{Size=UDim2.fromScale(0,1),BackgroundColor3=C.White,BorderSizePixel=0,ZIndex=36})
new("UIGradient",fill,{Color=ColorSequence.new(C.Blue,C.Red)})
local meterText = new("TextLabel",meter,{Size=UDim2.new(1,0,0,22),Position=UDim2.fromOffset(0,-27),
    BackgroundTransparency=1,Text="",TextColor3=C.White,TextSize=12,Font=Enum.Font.GothamMedium,ZIndex=36})
local reticle = new("Frame",gui,{AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),
    Size=UDim2.fromOffset(6,6),BackgroundColor3=C.White,BackgroundTransparency=0.3,
    BorderSizePixel=0,Visible=false,ZIndex=19})
new("UICorner",reticle,{CornerRadius=UDim.new(1,0)})

-- These locally-created effects survive replacement of CurrentCamera.
-- Authored Lighting effects are untouched; shutdown removes only our instances.
local cc = new("ColorCorrectionEffect",Lighting,{Name="Purple_CC",Enabled=true})
local bloom = new("BloomEffect",Lighting,{Name="Purple_Bloom",Intensity=0,Size=32,Threshold=1.15})
local blur = new("BlurEffect",Lighting,{Name="Purple_Blur",Size=0})
local flashAt, flashPower = -100, 0
local titleAt = -100
local function impactFrame(power)
    flashAt, flashPower = os.clock(), power * CONFIG.FlashStrength
end
local function shake(amount)
    shakeEnergy = math.min(1.4,math.max(shakeEnergy,amount*CONFIG.CameraShake))
end
local function restoreCamera()
    local cam = cameraState.camera
    if not cam or not cam.Parent then
        cameraState.delta, cameraState.applied, cameraState.lastFov = nil,nil,nil
        cameraState.fov=0
        return
    end
    -- Remove only our own last offset; preserve writes made by other camera systems.
    if cameraState.applied and cam.CFrame == cameraState.applied then
        cam.CFrame = cam.CFrame * cameraState.delta:Inverse()
    end
    if cameraState.lastFov and math.abs(cam.FieldOfView-cameraState.lastFov)<0.001 then
        cam.FieldOfView = cam.FieldOfView-cameraState.fov
    end
    cameraState.delta, cameraState.applied, cameraState.lastFov = nil,nil,nil
    cameraState.fov = 0
end

local function characterParts()
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health<=0 then return nil end
    return char,root,humanoid
end
local function rayParams(character)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = character and {world,character} or {world}
    params.IgnoreWater = true
    return params
end
local function aim(root)
    local cam = workspace.CurrentCamera
    if not cam then return root.CFrame.LookVector end
    local v = cam.ViewportSize
    local ray = cam:ViewportPointToRay(v.X/2,v.Y/2)
    local hit = workspace:Raycast(ray.Origin,ray.Direction*1000,rayParams(player.Character))
    return unit((hit and hit.Position or ray.Origin+ray.Direction*1000)
        -(root.Position+Y*CONFIG.MuzzleHeight),root.CFrame.LookVector)
end
local function muzzlePosition(root,direction)
    local forward=CONFIG.MuzzleForward
    if direction.Y<0 then
        -- Remain on the aim ray, but form steep downward shots closer above
        -- the caster instead of creating a six-stud-radius sphere in the floor.
        local clearance=math.max(0,CONFIG.MuzzleHeight-CONFIG.ProjectileRadius-0.5)
        forward=math.min(forward,clearance/-direction.Y)
    end
    return root.Position+Y*CONFIG.MuzzleHeight+direction*forward
end
local function chargeBasis(root)
    local direction = aim(root)
    local chest = root.Position+Y*1.5
    local target = muzzlePosition(root,direction)
    local offset = target-chest
    local hit = workspace:Raycast(chest,offset,rayParams(player.Character))
    local pos = hit and hit.Position-unit(offset,direction)*0.6 or target
    return facing(pos,direction),direction
end

local function burstDebris(position,normal)
    local s = scope("Aftermath",3.2,true)
    if not s then return end
    local hit = workspace:Raycast(position+normal*2,-Y*48,rayParams(player.Character))
    -- Only decorate real nearby surfaces; no floating craters in mid-air.
    if not hit then s:destroy(); return end
    local ground, n = hit.Position+hit.Normal*0.06, hit.Normal
    local basis = facing(ground,n)
    local groundColor = hit.Instance:IsA("BasePart") and hit.Instance.Color or Color3.fromRGB(80,76,86)
    local material = hit.Material
    for i = 1,(LOW and 12 or 22) do
        local angle = i/(LOW and 12 or 22)*TAU + RNG:NextNumber(-0.1,0.1)
        local radial = basis.RightVector*math.cos(angle)+basis.UpVector*math.sin(angle)
        local distance = RNG:NextNumber(12,28)
        local p = part(s.folder,groundColor,V3(RNG:NextNumber(1.5,4.5),RNG:NextNumber(0.8,2),RNG:NextNumber(1.5,3.8)),0,material)
        local spin = V3(RNG:NextNumber(-3,3),RNG:NextNumber(-3,3),RNG:NextNumber(-3,3))
        local start = ground+radial*distance
        local velocity = radial*RNG:NextNumber(18,34)+n*RNG:NextNumber(22,40)
        animate(s,1.6+RNG:NextNumber(0,0.6),function(t,_,elapsed)
            p.CFrame = CFrame.new(start+velocity*elapsed-Y*22*elapsed*elapsed)
                *CFrame.Angles(spin.X*elapsed,spin.Y*elapsed,spin.Z*elapsed)
            p.Transparency = smooth((t-0.5)*2)
        end)
    end
    -- Jagged emissive cracks, drawn just above the sampled ground plane.
    for i = 1,(LOW and 6 or 10) do
        local angle = i/(LOW and 6 or 10)*TAU
        local radial = basis.RightVector*math.cos(angle)+basis.UpVector*math.sin(angle)
        local tangent = basis.RightVector*(-math.sin(angle))+basis.UpVector*math.cos(angle)
        local a = ground+radial*1.5
        for j = 1,3 do
            local b = ground+radial*(1.5+j*RNG:NextNumber(6,9))+tangent*RNG:NextNumber(-2,2)
            local crack = linePart(s.folder,C.Lilac,a,b,0.16,0.15)
            animate(s,2.7,function(p) crack.Transparency=lerp(0.15,1,p^0.65) end)
            a=b
        end
    end
    local smokePart = part(s.folder,C.Ink,ONE*0.1,1)
    smokePart.Position=ground
    local smoke=particles(smokePart,groundColor:Lerp(C.Purple,0.18),0,14,36,2.7,SMOKE)
    smoke.LightEmission=0.05
    smoke.LightInfluence=0.7
    smoke.Acceleration=Y*6
    smoke:Emit(LOW and 14 or 26)
end

local function detonate(position,normal,power,isOwn)
    local cam=workspace.CurrentCamera
    local distance=cam and (cam.CFrame.Position-position).Magnitude or 999
    if distance>CONFIG.VisibleDistance then return end
    local strength=clamp(1-distance/280)
    if isOwn then strength=math.max(strength,0.4) end
    impactPulse=math.max(impactPulse,strength)
    if strength>0.15 then impactFrame(strength); shake(strength) end
    local s=scope("Impact",3,true)
    if not s then return end
    local center=part(s.folder,C.Purple,ONE,1)
    center.Position=position
    local light=new("PointLight",center,{Color=C.Purple,Brightness=7,Range=60,Shadows=false})
    local sparks=particles(center,C.Lilac,0,1.7,115,1.4)
    sparks:Emit(LOW and 40 or 85)
    sound(center,CONFIG.ImpactSound,0.8)
    animate(s,0.55,function(p) light.Brightness=6*(1-p)^2 end)
    local radius=lerp(CONFIG.VisualBlastRadius*0.6,CONFIG.VisualBlastRadius,power)
    expandingBall(position,C.White,radius*1.4,0.3)
    expandingBall(position,C.Purple,radius*2,0.8)
    wave(position,CFrame.Angles(math.pi/2,0,0),C.Lilac,radius*1.6,1.15,1.05)
    wave(position,facing(ZERO,normal),C.Purple,radius,0.75,1.2)
    wave(position,CFrame.Angles(0,0,math.pi/4),C.White,radius*0.9,0.55,0.38)
    impactColumn(position,radius)
    -- Follow-through ring starts after the first flash instead of stacking
    -- every layer into a single unreadable frame.
    animate(s,0.18,function() end,function()
        wave(position+Y*1.5,CFrame.Angles(math.pi/2,0,0),C.Purple,radius*1.42,1.25,0.7)
    end)
    for i=1,(LOW and 8 or 14) do
        local direction=unit(V3(RNG:NextNumber(-1,1),RNG:NextNumber(-0.25,1),RNG:NextNumber(-1,1)),Y)
        local start=position+direction*2
        bolt(start,position+direction*radius*RNG:NextNumber(0.65,1.1),i%3==0 and C.White or C.Lilac,0.25,0.35)
    end
    burstDebris(position,normal)
end

local function projectileKey(userId,id) return tostring(userId)..":"..id end
local function removeProjectile(key)
    local p=projectiles[key]
    if p then p.scope:destroy(); projectiles[key]=nil end
end
local function launch(userId,id,origin,direction,power,authoritative)
    local key=projectileKey(userId,id)
    if projectiles[key] then return end
    local own=userId==player.UserId
    local count=0
    for _ in pairs(projectiles) do count=count+1 end
    if count>=CONFIG.MaxProjectiles and not own then return end
    local cam=workspace.CurrentCamera
    if not own and cam and (cam.CFrame.Position-origin).Magnitude>CONFIG.VisibleDistance then return end
    local flightTimeout=CONFIG.MaxRange/CONFIG.Speed+1.6
    local s=scope("Projectile",flightTimeout+0.25,false)
    local core=orb(s.folder,C.Purple,C.White)
    local ring2=ring(s.folder,C.Lilac)
    core.trail.Lifetime=LOW and 0.42 or 0.6
    core.emitter.Rate=LOW and 32 or 64
    local satelliteA=ball(s.folder,C.Blue,1.3,0.15)
    local satelliteB=ball(s.folder,C.Red,1.3,0.15)
    trail(satelliteA,1.8,C.Blue,0.5)
    trail(satelliteB,1.8,C.Red,0.5)
    local sourcePlayer=Players:GetPlayerByUserId(userId)
    local params=rayParams(sourcePlayer and sourcePlayer.Character)
    local p={scope=s,pos=origin,direction=direction,travelled=0,arcAt=0,waveAt=0,own=own,
        lastWakePos=origin,nextWake=0,nextGround=0}
    projectiles[key]=p
    local diameter=lerp(CONFIG.ProjectileDiameter*0.72,CONFIG.ProjectileDiameter,power)
    core.trail.Attachment0.Position=V3(0,diameter*0.4,0)
    core.trail.Attachment1.Position=V3(0,-diameter*0.4,0)
    -- Set the emitter's position before starting audio or the first render.
    core:pose(facing(origin,direction),diameter,0)
    satelliteA.Position, satelliteB.Position=origin,origin
    sound(core.part,CONFIG.ReleaseSound,0.75)
    if own then
        state="Recovery"
        pending=nil
        releasePulse=1
        titleAt=os.clock()
        impactFrame(0.7)
        shake(0.65)
    end
    wave(origin,facing(ZERO,direction),C.Lilac,28,0.5,0.7)
    wave(origin-direction*2,facing(ZERO,direction),C.White,18,0.32,0.35)
    launchFlare(origin)
    animate(s,flightTimeout,function(_,dt,t)
        if projectiles[key]~=p then return end
        local step=math.min(CONFIG.Speed*dt,CONFIG.MaxRange-p.travelled)
        if step>0 then
            local hit=workspace:Spherecast(p.pos,CONFIG.ProjectileRadius,direction*step,params)
            if not authoritative and hit then
                removeProjectile(key)
                detonate(hit.Position,hit.Normal,power,own)
                return
            end
            -- With the companion server, stop local prediction at a hit while
            -- waiting for the authoritative Impact; never invent client damage.
            if hit then step=math.max(0,hit.Distance); p.travelled=CONFIG.MaxRange-step end
            p.pos=p.pos+direction*step
            p.travelled=p.travelled+step
        end
        local cf=facing(p.pos,direction)
        local pulse=1+0.035*math.sin(t*35)
        core:pose(cf,diameter*pulse,t*2.5)
        ring2:pose(cf*CFrame.Angles(0.5,t*5,t*2),diameter,0.24,0.3)
        local spin=t*17
        local offset=(cf.RightVector*math.cos(spin)+cf.UpVector*math.sin(spin))*diameter*0.65
        satelliteA.CFrame=facing(p.pos+offset,direction)
        satelliteB.CFrame=facing(p.pos-offset,direction)
        if t>=p.arcAt then
            p.arcAt=t+(LOW and 0.12 or 0.075)
            local v=cf.RightVector*RNG:NextNumber(-16,16)+cf.UpVector*RNG:NextNumber(-16,16)-direction*12
            bolt(p.pos,p.pos+v,C.Lilac,0.16,0.18)
        end
        if t>=p.waveAt and p.travelled<CONFIG.MaxRange then
            p.waveAt=t+(LOW and 0.3 or 0.19)
            wave(p.pos,facing(ZERO,direction),C.Purple,diameter*1.6,0.45,0.25)
        end
        if p.travelled>=p.nextWake and (p.pos-p.lastWakePos).Magnitude>0.05 then
            p.nextWake=p.travelled+(LOW and 28 or 18)
            energyWake(p.lastWakePos,p.pos,diameter)
            p.lastWakePos=p.pos
        end
        if p.travelled>=p.nextGround and p.travelled<CONFIG.MaxRange then
            p.nextGround=p.travelled+(LOW and 48 or 30)
            wakeGround(p.pos,direction)
        end
        if not authoritative and p.travelled>=CONFIG.MaxRange then
            removeProjectile(key)
            detonate(p.pos,-direction,power,own)
        end
    end,function() removeProjectile(key) end)
end

local function clearCharge()
    if charge then charge.scope:destroy(); charge=nil end
    chargeAmount=0
    meter.Visible=false
    reticle.Visible=false
    activeInput=nil
end
local function cancel()
    if state~="Charging" and state~="Merging" then return end
    if remote then remote:FireServer("Cancel") end
    clearCharge()
    state="Idle"
end
local function startCharge(input)
    if not alive or state~="Idle" or os.clock()<nextCastAt then return end
    local char,root=characterParts()
    if not root then return end
    local s=scope("Charge",nil,false)
    local blue=orb(s.folder,C.Blue,C.Cyan)
    local red=orb(s.folder,C.Red,C.Pink)
    local purple=orb(s.folder,C.Purple,C.White)
    purple.emitter.Enabled=false
    purple.trail.Enabled=false
    local halo=ring(s.folder,C.Lilac)
    local halo2=ring(s.folder,C.Purple)
    local stones={}
    for i=1,(LOW and 5 or 9) do
        local angle=i/(LOW and 5 or 9)*TAU
        local sample=root.Position+V3(math.cos(angle),0,math.sin(angle))*RNG:NextNumber(7,12)+Y*3
        local hit=workspace:Raycast(sample,-Y*14,rayParams(char))
        if hit then
            local color=hit.Instance:IsA("BasePart") and hit.Instance.Color or Color3.fromRGB(80,75,91)
            local rock=part(s.folder,color,V3(0.7,0.4,1.1)*RNG:NextNumber(0.8,1.6),0,hit.Material)
            rock.Position=hit.Position
            stones[#stones+1]={part=rock,offset=hit.Position-root.Position,seed=angle}
        end
    end
    local highlight=new("Highlight",s.folder,{Adornee=char,FillColor=C.Purple,
        FillTransparency=1,OutlineColor=C.Lilac,OutlineTransparency=0.6,
        DepthMode=Enum.HighlightDepthMode.Occluded})
    charge={scope=s,start=os.clock(),blue=blue,red=red,purple=purple,halo=halo,halo2=halo2,stones=stones,
        root=root,char=char,arcAt=0,sparkAt=0,highlight=highlight,ready=false}
    local basis=chargeBasis(root)
    blue:pose(basis*CFrame.new(6.4,0,0),1.8,0)
    red:pose(basis*CFrame.new(-6.4,0,0),1.8,0)
    blue.trail.Attachment0.Position=V3(0,0.9,0)
    blue.trail.Attachment1.Position=V3(0,-0.9,0)
    red.trail.Attachment0.Position=V3(0,0.9,0)
    red.trail.Attachment1.Position=V3(0,-0.9,0)
    purple:pose(basis,0.05,0,1)
    charge.loop=sound(blue.part,CONFIG.ChargeSound,0.45,true)
    state="Charging"
    activeInput=input
    meter.Visible=true
    reticle.Visible=true
    if remote then remote:FireServer("Begin") end
end
local function releaseCharge()
    if state~="Charging" or not charge then return end
    activeInput=nil
    local elapsed=os.clock()-charge.start
    if elapsed<CONFIG.MinCharge then cancel(); return end
    local char,root=characterParts()
    if not root or char~=charge.char then cancel(); return end
    state="Merging"
    charge.mergeAt=os.clock()
    charge.power=math.clamp(elapsed/CONFIG.ChargeTime,0.15,1)
    charge.direction=aim(root)
    local mergeBasis=facing(muzzlePosition(root,charge.direction),charge.direction)
    charge.blueOffset=mergeBasis:PointToObjectSpace(charge.blue.part.Position)
    charge.redOffset=mergeBasis:PointToObjectSpace(charge.red.part.Position)
    charge.startSize=charge.blue.part.Size.X
    charge.blue.trail.Enabled=false
    charge.red.trail.Enabled=false
    charge.blue.emitter.Enabled=false
    charge.red.emitter.Enabled=false
    if charge.loop then charge.loop:Stop() end
    meter.Visible=false
    titleAt=-100
end

local function updateCharge(now)
    if not charge then return end
    local ch=charge
    local char,root=characterParts()
    if char~=ch.char or root~=ch.root then cancel(); return end
    local elapsed=now-ch.start
    local p=clamp(elapsed/CONFIG.ChargeTime)
    local basis,direction=chargeBasis(root)
    local merge=state=="Merging" and clamp((now-ch.mergeAt)/CONFIG.MergeTime) or 0
    for _,rock in ipairs(ch.stones) do
        local home=root.Position+rock.offset+Y*(ease(p)*6+math.sin(elapsed*2+rock.seed)*p*0.4)
        local position=home:Lerp(basis.Position,smooth(merge)*0.88)
        rock.part.CFrame=CFrame.new(position)*CFrame.Angles(elapsed*0.9,rock.seed+elapsed*0.6,elapsed*0.4)
        rock.part.Transparency=smooth((merge-0.45)/0.45)
    end
    if state=="Charging" then
        chargeAmount=p
        local angle=elapsed*(1.8+p*1.8)
        local radius=lerp(6.4,5.0,p)
        local offset=V3(math.cos(angle)*radius,math.sin(angle)*radius*0.64,0)
        local size=lerp(1.8,5.2,p)*(1+0.025*math.sin(elapsed*27))
        ch.blue:pose(basis*CFrame.new(offset),size,elapsed)
        ch.red:pose(basis*CFrame.new(-offset),size,-elapsed)
        ch.purple:pose(basis,0.05,elapsed,1)
        ch.halo:pose(basis*CFrame.Angles(0,0,elapsed*0.4),13.5-p*1.5,0.12,0.85-p*0.35)
        ch.halo2:pose(basis*CFrame.Angles(0.5,0.6,-elapsed*0.7),10.5+p*1.5,0.09,0.92-p*0.32)
        ch.highlight.OutlineTransparency=lerp(0.8,0.15,p)
        fill.Size=UDim2.fromScale(p,1)
        meterText.Text=p>=1 and "200%  /  RELEASE" or string.format("OUTPUT     %03d%%",p*200)
        if p>=1 and not ch.ready then
            ch.ready=true
            wave(basis.Position,basis-basis.Position,C.White,22,0.6,0.3)
            shake(0.2)
        end
        if now>=ch.arcAt then
            ch.arcAt=now+lerp(0.25,0.11,p)*(LOW and 1.4 or 1)
            bolt(ch.blue.part.Position,ch.red.part.Position,C.Lilac,0.055+p*0.09,0.13)
        end
        if now>=ch.sparkAt then
            ch.sparkAt=now+(LOW and 0.1 or 0.045)
            local s=scope("InwardStreak",0.45,true)
            if s then
                local a=RNG:NextNumber(0,TAU)
                local start=basis.Position+(basis.RightVector*math.cos(a)+basis.UpVector*math.sin(a))*RNG:NextNumber(14,22)
                local target=basis.Position
                local shard=part(s.folder,a<math.pi and C.Blue or C.Red,V3(0.11,0.11,2),0.1)
                animate(s,0.4,function(q)
                    local pos=start:Lerp(target,q*q)
                    shard.CFrame=facing(pos,unit(target-start,Y))
                    shard.Transparency=q^3
                end)
            end
        end
        if elapsed>=CONFIG.MaxHold then releaseCharge() end
    elseif state=="Merging" then
        local t=now-ch.mergeAt
        local q=clamp(t/CONFIG.MergeTime)
        local directionFixed=ch.direction
        basis=facing(muzzlePosition(root,directionFixed),directionFixed)
        local closing=ease(q/0.68)
        local rotation=CFrame.Angles(0,0,q*math.pi*1.5)
        local blueOffset=rotation:VectorToWorldSpace(ch.blueOffset)*(1-closing)
        local redOffset=rotation:VectorToWorldSpace(ch.redOffset)*(1-closing)
        local fade=smooth((q-0.46)/0.3)
        ch.blue:pose(basis*CFrame.new(blueOffset),lerp(ch.startSize,0.1,closing),elapsed,fade)
        ch.red:pose(basis*CFrame.new(redOffset),lerp(ch.startSize,0.1,closing),-elapsed,fade)
        local born=smooth((q-0.35)/0.3)
        ch.purple:pose(basis,math.max(0.05,lerp(0.1,CONFIG.ProjectileDiameter*0.85,born)
            *(1-0.18*smooth((q-0.85)/0.15))),elapsed,1-born)
        ch.halo:pose(basis*CFrame.Angles(q*1.2,0,-q*4),lerp(12,0.6,closing),0.2,q)
        ch.halo2:pose(basis*CFrame.Angles(0.5,q,-q*5),lerp(12,6,born),0.16,lerp(0.45,1,q))
        chargeAmount=lerp(ch.power,1,q)
        if q>0.62 and not ch.merged then
            ch.merged=true
            wave(basis.Position,basis-basis.Position,C.White,26,0.4,0.4)
            launchFlare(basis.Position)
            shake(0.3)
        end
        if q>=1 then
            local id=HttpService:GenerateGUID(false)
            local power=ch.power
            local origin=basis.Position
            clearCharge()
            nextCastAt=now+CONFIG.Cooldown
            if remote then
                state="Awaiting"
                pending={id=id,expires=now+3}
                remote:FireServer("Fire",directionFixed,id)
            else
                local params=rayParams(char)
                local chest=root.Position+Y*1.5
                local muzzleOffset=origin-chest
                local blocked=workspace:Raycast(chest,muzzleOffset,params)
                    or workspace:Spherecast(chest,CONFIG.MuzzleCorridorRadius,muzzleOffset,params)
                local overlap=OverlapParams.new()
                overlap.FilterType=Enum.RaycastFilterType.Exclude
                overlap.FilterDescendantsInstances={world,char}
                muzzleProbe.Position=origin
                local inside=workspace:GetPartsInPart(muzzleProbe,overlap)
                muzzleProbe.Position=V3(0,-10000,0)
                if blocked or #inside>0 then
                    state="Recovery"
                    releasePulse=1
                    detonate(blocked and blocked.Position or origin,
                        blocked and blocked.Normal or -directionFixed,power,true)
                else
                    launch(player.UserId,id,origin,directionFixed,power,false)
                end
            end
        end
    end
end

local function bindRemote(candidate)
    if not candidate:IsA("RemoteEvent") or candidate.Name~="ISAGI_PurpleRemote" then return end
    if remote==candidate then return end
    if remoteConnection then remoteConnection:Disconnect() end
    -- A mid-charge server appearance must not turn an unregistered preview into
    -- a gameplay request. Cancel the preview and let the next press start cleanly.
    if charge then cancel() end
    remote=candidate
    remoteConnection=candidate.OnClientEvent:Connect(function(action,userId,id,position,direction,power)
        if not alive then return end
        if action=="Rejected" then
            if pending and pending.id==userId then
                pending=nil; state="Idle"; titleAt=-100
                nextCastAt=math.max(nextCastAt,os.clock()+0.5)
            end
            return
        end
        if action=="Launch" then
            if userId==player.UserId then
                if not pending or pending.id~=id then return end
                ownNetworkId=id
            end
            launch(userId,id,position,direction,power,true)
        elseif action=="Impact" then
            if userId==player.UserId and id~=ownNetworkId then return end
            removeProjectile(projectileKey(userId,id))
            detonate(position,direction,power,userId==player.UserId)
            if userId==player.UserId then ownNetworkId=nil end
        end
    end)
end
local foundRemote=ReplicatedStorage:FindFirstChild("ISAGI_PurpleRemote")
if foundRemote then bindRemote(foundRemote) end
connect(ReplicatedStorage.ChildAdded,bindRemote)
connect(ReplicatedStorage.ChildRemoved,function(child)
    if child==remote then
        if remoteConnection then remoteConnection:Disconnect(); remoteConnection=nil end
        remote=nil
        cancel()
    end
end)

connect(button.InputBegan,function(input)
    if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseButton1 then
        startCharge(input)
    end
end)
connect(UIS.InputBegan,function(input,processed)
    if input.KeyCode==Enum.KeyCode.Escape then cancel(); return end
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode==Enum.KeyCode.G then startCharge(input) end
end)
connect(UIS.InputEnded,function(input)
    -- Global release also works when the finger / pointer has left the button.
    local sameMouse=activeInput and activeInput.UserInputType==Enum.UserInputType.MouseButton1
        and input.UserInputType==Enum.UserInputType.MouseButton1
    if activeInput and (input==activeInput or sameMouse) then releaseCharge() end
end)
connect(UIS.WindowFocusReleased,cancel)

local function resetCharacter()
    cancel()
    clearCharge()
    state="Idle"; pending=nil; ownNetworkId=nil; titleAt=-100; flashAt=-100
    chargeAmount=0; releasePulse=0; impactPulse=0; shakeEnergy=0
    for key in pairs(projectiles) do removeProjectile(key) end
    for _,s in ipairs(scopes) do s:destroy() end
    table.clear(jobs)
    restoreCamera()
end
connect(player.CharacterRemoving,resetCharacter)
connect(player.CharacterAdded,resetCharacter)

local token="PurpleAnime_"..HttpService:GenerateGUID(false)
local renderBefore=token.."_Before"
local renderAfter=token.."_After"
RunService:BindToRenderStep(renderBefore,Enum.RenderPriority.Camera.Value-1,restoreCamera)

local function render(dt)
    if not alive then return end
    local now=os.clock()
    local camera=workspace.CurrentCamera
    if camera~=cameraState.camera then
        restoreCamera()
        cameraState.camera=camera
    end
    updateCharge(now)
    for i=#jobs,1,-1 do
        local job=jobs[i]
        if not job.owner.alive then table.remove(jobs,i)
        else
            local elapsed=now-job.start
            local p=clamp(elapsed/job.duration)
            job.callback(p,dt,elapsed)
            if p>=1 then
                table.remove(jobs,i)
                if job.onComplete and job.owner.alive then job.onComplete() end
            end
        end
    end
    for i=#scopes,1,-1 do
        local s=scopes[i]
        if s.alive and s.expires and now>=s.expires then s:destroy() end
        if not s.alive then table.remove(scopes,i) end
    end
    if pending and now>pending.expires then pending=nil; state="Idle"; titleAt=-100 end
    if state=="Recovery" and releasePulse<0.03 then state="Idle" end
    releasePulse=releasePulse*math.exp(-dt*7)
    impactPulse=impactPulse*math.exp(-dt*5.5)
    shakeClock=shakeClock+dt
    shakeEnergy=shakeEnergy*math.exp(-dt*8)
    local activity=math.max(chargeAmount*0.48,releasePulse,impactPulse)
    local bar=CONFIG.CinematicBars and (state=="Charging" or state=="Merging" or state=="Awaiting") and 0.045 or 0
    local height=lerp(topBar.Size.Y.Scale,bar,1-math.exp(-dt*10))
    topBar.Size=UDim2.fromScale(1,height)
    bottomBar.Size=UDim2.fromScale(1,height)
    for _,edge in ipairs(edges) do edge.BackgroundTransparency=1-activity*0.32 end
    local titleAge=now-titleAt
    local titleVisibility=titleAge>=0 and clamp(titleAge/0.09)*(1-smooth((titleAge-0.32)/0.35)) or 0
    title.TextTransparency=1-titleVisibility
    title.TextStrokeTransparency=1-titleVisibility*0.7
    subtitle.TextTransparency=1-titleVisibility
    title.Position=UDim2.fromScale(0.5,0.24-0.012*ease(math.max(titleAge,0)/0.5))
    gradient.Offset=Vector2.new(math.sin(now)*0.1,0)
    local flashAge=now-flashAt
    local visibility=0
    if flashAge>=0 and flashAge<0.035 then
        flash.BackgroundColor3=C.Ink; visibility=flashPower*0.8
    elseif flashAge<0.115 and flashAge>=0.035 then
        flash.BackgroundColor3=C.White; visibility=flashPower*(1-(flashAge-0.035)/0.08)
    end
    flash.BackgroundTransparency=1-clamp(visibility)
    local cooldown=math.max(0,nextCastAt-now)
    buttonText.Text=state=="Charging" and string.format("%d%%",clamp(chargeAmount)*200)
        or ((state=="Merging" or state=="Awaiting") and "PURPLE" or (cooldown>0 and string.format("%.1f",cooldown) or "PURPLE"))
    buttonStroke.Color=C.Blue:Lerp(C.Red,chargeAmount)
    buttonStroke.Transparency=cooldown>0 and 0.65 or 0.15
    if camera then
        local viewport=camera.ViewportSize
        local small=math.min(viewport.X,viewport.Y)<500
        button.Size=UDim2.fromOffset(small and 76 or 94,small and 76 or 94)
        button.Position=UDim2.new(1,-(small and 20 or 28),1,-(small and 128 or 190))
        local pulse=math.max(releasePulse,impactPulse*0.8,chargeAmount*0.16)
        for _,item in ipairs(speedLines) do
            local theta=item.angle+math.sin(now*1.3+item.seed)*0.025
            local radius=0.77+((item.seed-now*(1+pulse*2))*0.8)%0.36
            local x=math.cos(theta)*viewport.X*0.62*radius
            local y=math.sin(theta)*viewport.Y*0.72*radius
            item.frame.Position=UDim2.fromOffset(viewport.X/2+x,viewport.Y/2+y)
            item.frame.Rotation=math.deg(math.atan2(y,x))
            item.frame.Size=UDim2.fromOffset((0.1+item.seed*0.13)*math.min(viewport.X,viewport.Y),item.width)
            item.frame.BackgroundTransparency=1-pulse*(0.25+item.seed*0.45)
        end
        cc.TintColor=Color3.new(1,1,1):Lerp(C.Lilac,activity*0.11)
        cc.Contrast=activity*0.2
        cc.Saturation=-chargeAmount*0.28+impactPulse*0.14
        cc.Brightness=releasePulse*0.015-chargeAmount*0.025
        bloom.Intensity=activity*(LOW and 0.55 or 0.85)
        blur.Size=(releasePulse+impactPulse)*1.7
        local magnitude=shakeEnergy
        local delta=CFrame.new(math.noise(shakeClock*29,0)*magnitude*0.22,
            math.noise(0,shakeClock*31)*magnitude*0.18,0)
            *CFrame.Angles(0,0,math.noise(shakeClock*22,7)*magnitude*0.012)
        local fov=CONFIG.FovKick*(releasePulse*0.9+chargeAmount*0.45)
        local desired=math.clamp(camera.FieldOfView+fov,1,120)
        cameraState.fov=desired-camera.FieldOfView
        camera.FieldOfView=desired
        cameraState.lastFov=desired
        camera.CFrame=camera.CFrame*delta
        cameraState.delta=delta
        cameraState.applied=camera.CFrame
    end
end

local function shutdown()
    if not alive then return end
    alive=false
    if remote and (state=="Charging" or state=="Merging") then remote:FireServer("Cancel") end
    RunService:UnbindFromRenderStep(renderBefore)
    RunService:UnbindFromRenderStep(renderAfter)
    restoreCamera()
    for _,connection in ipairs(connections) do connection:Disconnect() end
    if remoteConnection then remoteConnection:Disconnect() end
    for _,s in ipairs(scopes) do s:destroy() end
    cc:Destroy(); bloom:Destroy(); blur:Destroy()
    world:Destroy(); gui:Destroy()
end
connect(shutdownEvent.Event,shutdown)
if typeof(script)=="Instance" then
    connect(script.Destroying,shutdown)
end
RunService:BindToRenderStep(renderAfter,Enum.RenderPriority.Camera.Value+1,function(dt)
    local ok,message=xpcall(function() render(dt) end,debug.traceback)
    if not ok then
        warn("[HollowPurple] VFX stopped cleanly after an error:\n"..tostring(message))
        shutdown()
    end
end)
