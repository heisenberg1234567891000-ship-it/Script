-- RETURN BY DEATH / CHECKPOINT + CINEMATIC REWIND / 1.0
-- LocalScript -> StarterPlayer > StarterPlayerScripts.
-- B / button saves a server checkpoint. Ordinary game death activates the effect.
-- Without ReturnByDeath.server.lua: cosmetic respawn effects ONLY, never teleport.
-- No forced death, respawn, remote probing, anti-cheat bypass, inventory or world rollback.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
assert(RunService:IsClient() and player, "Return By Death must run in a Roblox client context")
local CONFIG = {Quality = "Auto", FlashStrength = 0.25, ShowMarker = true, MarkerDistance = 450}
local playerGui = player:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("ReturnByDeath_UI")
if old then
    local event = old:FindFirstChild("Shutdown")
    if event and event:IsA("BindableEvent") then event:Fire() end
    old:Destroy()
end
local function new(class, parent, props)
    local instance = Instance.new(class)
    for k, v in pairs(props or {}) do instance[k] = v end
    instance.Parent = parent
    return instance
end
local gui = new("ScreenGui", playerGui, {Name = "ReturnByDeath_UI", ResetOnSpawn = false,
    IgnoreGuiInset = true, DisplayOrder = 100, ZIndexBehavior = Enum.ZIndexBehavior.Global})
local stop = new("BindableEvent", gui, {Name = "Shutdown"})
local world = new("Folder", workspace, {Name = "ReturnByDeath_LocalFX_" .. player.UserId})
local token = "ReturnByDeath_" .. HttpService:GenerateGUID(false)
local alive, enabled = true, true
local connections, characterConnections = {}, {}
local remote, remoteConnection, syncAt = nil, nil, -math.huge
local characterToken, character, characterHumanoid = 0, nil, nil
local checkpoint, readyAt, cycle, serverCycle = nil, 0, 0, 0
local pendingRequest, deadCycle, waitAt, returnedCycle = nil, false, nil, -1
local pendingReturned, serverWaiting, pendingSpawn, timedOut = nil, false, nil, false
local lastUi = -1
local WHITE, VIOLET, INK = Color3.fromRGB(247, 242, 255), Color3.fromRGB(175, 142, 255), Color3.fromRGB(11, 8, 20)
local function connect(signal, fn)
    local c = signal:Connect(fn); connections[#connections + 1] = c; return c
end
local function disconnectCharacter()
    for _, c in ipairs(characterConnections) do c:Disconnect() end
    characterConnections = {}
end
local function label(parent, props)
    local p = {Text = "", Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = WHITE,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ZIndex = 110}
    for k, v in pairs(props) do p[k] = v end
    return new("TextLabel", parent, p)
end
local button = new("TextButton", gui, {Name = "CheckpointButton", Size = UDim2.fromOffset(88,88),
    AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.new(0,67,0.35,0),
    Text = "", BackgroundColor3 = INK, BackgroundTransparency = 0.1, BorderSizePixel = 0,
    AutoButtonColor = false, ZIndex = 110})
new("UICorner",button,{CornerRadius = UDim.new(1,0)})
local stroke = new("UIStroke",button,{Color=VIOLET,Thickness=1.5,Transparency=0.2})
local symbol = label(button,{Size=UDim2.fromScale(1,0.58),Position=UDim2.fromScale(0,0.03),
    Text="↶",TextSize=43,Font=Enum.Font.GothamBlack})
local caption = label(button,{Size=UDim2.fromScale(1,0.22),Position=UDim2.fromScale(0,0.64),
    Text="ТОЧКА",TextSize=10,Font=Enum.Font.GothamBold,TextColor3=VIOLET})
local hint = label(gui,{AnchorPoint=Vector2.new(0.5,0),Position=UDim2.new(0,82,0.35,52),
    Size=UDim2.fromOffset(155,43),TextSize=10,TextWrapped=true,TextColor3=VIOLET})
local status = label(gui,{AnchorPoint=Vector2.new(0.5,0),Position=UDim2.fromScale(0.5,0.1),
    Size=UDim2.fromScale(0.76,0.035),TextSize=13,TextColor3=VIOLET,TextTransparency=1})
local messageUntil=0
local function showMessage(text)
    status.Text=text; messageUntil=os.clock()+3.5
end

local marker = new("Part",world,{Name="CheckpointLight",Size=Vector3.new(0.1,0.1,0.1),
    Anchored=true,CanCollide=false,CanTouch=false,CanQuery=false,CastShadow=false,Transparency=1})
local markerGui=new("BillboardGui",marker,{Adornee=marker,Size=UDim2.fromOffset(150,64),
    StudsOffset=Vector3.new(0,1.1,0),AlwaysOnTop=false,MaxDistance=CONFIG.MarkerDistance,Enabled=false})
label(markerGui,{Size=UDim2.fromScale(1,0.6),Text="↶",TextColor3=VIOLET,TextSize=35})
label(markerGui,{Size=UDim2.fromScale(1,0.32),Position=UDim2.fromScale(0,0.65),
    Text="ТОЧКА ВОЗВРАТА",TextSize=10,Font=Enum.Font.GothamBold,TextColor3=VIOLET})
local attachments, beams = {}, {}
for i=1,4 do
    local angle=(i-1)*math.pi/2
    attachments[i]=new("Attachment",marker,{CFrame=CFrame.fromMatrix(
        Vector3.new(math.cos(angle)*2.8,-2.55,math.sin(angle)*2.8),
        Vector3.new(-math.sin(angle),0,math.cos(angle)),Vector3.new(0,1,0))})
end
for i=1,4 do
    beams[i]=new("Beam",marker,{Attachment0=attachments[i],Attachment1=attachments[i%4+1],
        Color=ColorSequence.new(VIOLET,WHITE),CurveSize0=2.8*0.55228475,CurveSize1=2.8*0.55228475,
        Width0=0.055,Width1=0.055,Segments=10,FaceCamera=true,LightEmission=1,LightInfluence=0,Enabled=false})
end


-- UI-only time-rewind vignette. Call update(os.clock(), dt) from the host.
-- Everything is preallocated; no camera, physics, audio, or input interception.
local function createRewindFX(gui, CONFIG)
    local Lighting = game:GetService("Lighting")
    local UIS = game:GetService("UserInputService")
    local HttpService = game:GetService("HttpService")
    local quality = CONFIG.Quality or "Auto"
    local low = quality == "Low" or (quality == "Auto" and UIS.TouchEnabled)
    local flashStrength = math.clamp(tonumber(CONFIG.FlashStrength) or 0.25, 0, 0.5)
    local INK = Color3.fromRGB(7, 5, 17)
    local VIOLET = Color3.fromRGB(159, 119, 248)
    local PALE = Color3.fromRGB(224, 217, 250)
    local WHITE = Color3.fromRGB(249, 245, 255)
    local TAU = math.pi * 2
    local own = {}
    local fx = { destroyed = false, mode = nil, started = 0 }

    local function make(class, parent, props)
        local instance = Instance.new(class)
        for key, value in pairs(props) do instance[key] = value end
        instance.Parent = parent
        return instance
    end

    local root = make("Frame", gui, {
        Name = "ReturnByDeath_Cinematic", Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Active = false, Selectable = false, Visible = false,
        ClipsDescendants = true, ZIndex = 35,
    })
    own[#own + 1] = root
    local veil = make("Frame", root, {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = INK,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false,
        ZIndex = 35,
    })
    local edgeTop = make("Frame", root, {
        Size = UDim2.fromScale(1, 0.32), BackgroundColor3 = INK,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false,
        ZIndex = 36,
    })
    make("UIGradient", edgeTop, {
        Rotation = 90, Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        }),
    })
    local edgeBottom = make("Frame", root, {
        AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1),
        Size = UDim2.fromScale(1, 0.32), BackgroundColor3 = INK,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false,
        ZIndex = 36,
    })
    make("UIGradient", edgeBottom, {
        Rotation = 90, Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        }),
    })

    local stage = make("Frame", root, {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.47),
        Size = UDim2.fromOffset(360, 360), BackgroundTransparency = 1,
        BorderSizePixel = 0, Active = false, ZIndex = 40,
    })
    local rings = {}
    for i = 1, 4 do
        local diameter = ({0.98, 0.865, 0.80, 0.46})[i]
        local disc = make("Frame", stage, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(diameter, diameter),
            BackgroundTransparency = 1, BorderSizePixel = 0,
            Active = false, ZIndex = 40 + i,
        })
        make("UICorner", disc, {CornerRadius = UDim.new(1, 0)})
        local stroke = make("UIStroke", disc, {
            Color = i == 2 and WHITE or VIOLET,
            Thickness = i == 2 and 1.6 or 1,
            Transparency = 1,
        })
        rings[i] = {frame = disc, stroke = stroke, diameter = diameter}
    end

    local tickLayer = make("Frame", stage, {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        BorderSizePixel = 0, Active = false, ZIndex = 45,
    })
    local ticks = {}
    local tickCount = low and 36 or 60
    for i = 1, tickCount do
        local angle = (i - 1) / tickCount * TAU
        local major = (i - 1) % (tickCount / 12) == 0
        local mark = make("Frame", tickLayer, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.405,
                0.5 + math.sin(angle) * 0.405),
            Size = UDim2.new(major and 0.035 or 0.016, 0, 0, major and 2 or 1),
            Rotation = math.deg(angle), BorderSizePixel = 0,
            BackgroundColor3 = major and WHITE or VIOLET,
            BackgroundTransparency = 1, Active = false, ZIndex = 45,
        })
        ticks[i] = {frame = mark, phase = angle, major = major}
    end

    local numerals = {}
    local digits = {"XII", "III", "VI", "IX"}
    for i = 1, 4 do
        local angle = (i - 1) / 4 * TAU - math.pi / 2
        local label = make("TextLabel", stage, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.32,
                0.5 + math.sin(angle) * 0.32),
            Size = UDim2.fromScale(0.15, 0.08), BackgroundTransparency = 1,
            Text = digits[i], Font = Enum.Font.GothamMedium,
            TextSize = 14, TextColor3 = PALE, TextTransparency = 1,
            Active = false, ZIndex = 46,
        })
        numerals[i] = label
    end
    local hands = {}
    for i = 1, 3 do
        local pivot = make("Frame", stage, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
            BorderSizePixel = 0, Active = false, ZIndex = 47,
        })
        local line = make("Frame", pivot, {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.fromScale(0.48, 0.5),
            Size = UDim2.new(i == 1 and 0.33 or 0.23, 0, 0, i == 3 and 1 or 2),
            BackgroundColor3 = i == 3 and VIOLET or WHITE,
            BackgroundTransparency = 1, BorderSizePixel = 0,
            Active = false, ZIndex = 47,
        })
        hands[i] = {pivot = pivot, line = line}
    end
    local center = make("Frame", stage, {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(5, 5), BackgroundColor3 = WHITE,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ZIndex = 48,
    })
    make("UICorner", center, {CornerRadius = UDim.new(1, 0)})

    -- Fine disconnected fractures: symbolic broken time, never screen-sized glare.
    local cracks = {}
    local rng = Random.new(137)
    local branches = low and 4 or 7
    for branch = 1, branches do
        local angle = branch / branches * TAU + rng:NextNumber(-0.17, 0.17)
        local px, py = math.cos(angle) * 0.13, math.sin(angle) * 0.13
        for segment = 1, 4 do
            local distance = 0.13 + segment * 0.125
            local bend = angle + rng:NextNumber(-0.16, 0.16)
            local nx, ny = math.cos(bend) * distance, math.sin(bend) * distance
            local dx, dy = nx - px, ny - py
            local piece = make("Frame", stage, {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5 + (px + nx) / 2, 0.5 + (py + ny) / 2),
                Size = UDim2.new(math.sqrt(dx * dx + dy * dy), 0, 0, segment == 1 and 1.6 or 1),
                Rotation = math.deg(math.atan2(dy, dx)),
                BackgroundColor3 = segment % 2 == 0 and PALE or VIOLET,
                BackgroundTransparency = 1, BorderSizePixel = 0,
                Active = false, ZIndex = 49,
            })
            cracks[#cracks + 1] = {frame = piece, delay = (segment - 1) * 0.06 + branch * 0.013}
            px, py = nx, ny
        end
    end

    local dust = {}
    for i = 1, (low and 18 or 36) do
        local shard = make("Frame", root, {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.fromOffset(rng:NextNumber(4, 20), 1),
            BackgroundColor3 = i % 3 == 0 and VIOLET or PALE,
            BackgroundTransparency = 1, BorderSizePixel = 0,
            Active = false, ZIndex = 38,
        })
        dust[i] = {frame = shard, angle = rng:NextNumber(0, TAU),
            radius = rng:NextNumber(0.3, 0.95), phase = rng:NextNumber(0, TAU)}
    end

    local title = make("TextLabel", root, {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.73),
        Size = UDim2.new(0.92, 0, 0, 48), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, Text = "ВОЗВРАЩЕНИЕ", TextSize = 30,
        TextColor3 = WHITE, TextTransparency = 1, TextStrokeColor3 = INK,
        TextStrokeTransparency = 1, Active = false, ZIndex = 55,
    })
    local subtitle = make("TextLabel", root, {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.79),
        Size = UDim2.new(0.9, 0, 0, 26), BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium, Text = "ПЕТЛЯ 001", TextSize = 12,
        TextColor3 = PALE, TextTransparency = 1, Active = false, ZIndex = 55,
    })
    local flash = make("Frame", root, {
        Size = UDim2.fromScale(1, 1), BackgroundColor3 = PALE,
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ZIndex = 60,
    })

    local cc, bloom
    if CONFIG.EnablePostFX ~= false then
        local token = HttpService:GenerateGUID(false)
        cc = make("ColorCorrectionEffect", Lighting, {
            Name = "RBD_CC_" .. token, Enabled = false,
            TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0,
        })
        bloom = make("BloomEffect", Lighting, {
            Name = "RBD_Bloom_" .. token, Enabled = false,
            Intensity = 0, Size = 18, Threshold = 1.15,
        })
        own[#own + 1] = cc
        own[#own + 1] = bloom
    end

    local width, height, scale = 0, 0, 1
    local function smooth(value)
        value = math.clamp(value, 0, 1)
        return value * value * (3 - 2 * value)
    end
    local function alpha(object, opacity)
        object.BackgroundTransparency = 1 - math.clamp(opacity, 0, 1)
    end

    function fx:cancel()
        if self.destroyed then return end
        self.mode = nil
        root.Visible = false
        if cc then
            cc.Enabled = false
            cc.Saturation = 0
            cc.Contrast = 0
            cc.Brightness = 0
            cc.TintColor = Color3.new(1, 1, 1)
        end
        if bloom then bloom.Enabled = false; bloom.Intensity = 0 end
    end

    function fx:rewind(cycle, now)
        if self.destroyed then return end
        self.mode, self.started = "rewind", now
        title.Text = "ВОЗВРАЩЕНИЕ"
        subtitle.Text = string.format("ПЕТЛЯ ВРЕМЕНИ  /  %03d", math.max(0, math.floor(cycle or 0)))
        root.Visible = true
        if cc then cc.Enabled = true end
        if bloom then bloom.Enabled = true end
        self:update(now, 0)
    end

    function fx:returned(cycle, now, actualReturnBool)
        if self.destroyed then return end
        self.mode, self.started = "returned", now
        title.Text = actualReturnBool and "ВОЗВРАЩЕНИЕ" or "ВОЗРОЖДЕНИЕ"
        subtitle.Text = string.format("%s  /  %03d", actualReturnBool and "ТОЧКА ВОЗВРАТА" or "НОВЫЙ ЦИКЛ",
            math.max(0, math.floor(cycle or 0)))
        root.Visible = true
        if cc then cc.Enabled = true end
        if bloom then bloom.Enabled = true end
        self:update(now, 0)
    end

    function fx:update(now, dt)
        if self.destroyed or not self.mode then return end
        if not root.Parent then self:destroy(); return end
        local elapsed = math.max(0, now - self.started)
        local returning = self.mode == "returned"
        local duration = returning and 1.5 or 1.95
        if elapsed >= duration then self:cancel(); return end
        local fadeIn = smooth(elapsed / (returning and 0.10 or 0.18))
        local fadeOut = 1 - smooth((elapsed - (returning and 0.65 or 1.24)) / (returning and 0.85 or 0.71))
        local envelope = fadeIn * fadeOut
        local size = root.AbsoluteSize
        if size.X ~= width or size.Y ~= height then
            width, height = size.X, size.Y
            scale = math.clamp(math.min(width, height) / 720, 0.50, 1.35)
            title.TextSize = math.floor(30 * scale)
            subtitle.TextSize = math.max(10, math.floor(12 * scale))
            title.Size = UDim2.new(0.94, 0, 0, math.floor(48 * scale))
            for i = 1, #numerals do numerals[i].TextSize = math.max(9, math.floor(14 * scale)) end
        end
        local side = math.min(width, height) * 0.55
        local expansion = returning and (0.78 + elapsed * 0.5) or (1.035 - smooth(elapsed / 1.5) * 0.11)
        stage.Size = UDim2.fromOffset(side * expansion, side * expansion)
        stage.Rotation = returning and elapsed * 7 or -elapsed * 9
        alpha(veil, envelope * (returning and 0.12 or 0.38))
        alpha(edgeTop, envelope * 0.53)
        alpha(edgeBottom, envelope * 0.53)

        for i = 1, #rings do
            local ring = rings[i]
            local pulse = returning and (1 + elapsed * 0.18 * i) or (1 + math.sin(elapsed * 5 + i) * 0.006)
            ring.frame.Size = UDim2.fromScale(ring.diameter * pulse, ring.diameter * pulse)
            ring.stroke.Transparency = 1 - envelope * (i == 2 and 0.92 or 0.4)
        end
        tickLayer.Rotation = returning and -elapsed * 18 or -math.floor(elapsed * 20) * 2
        for i = 1, #ticks do
            local tick = ticks[i]
            local wave = 0.76 + 0.24 * math.sin(tick.phase + elapsed * 4)
            alpha(tick.frame, envelope * wave * (tick.major and 0.96 or 0.55))
        end
        for i = 1, #numerals do numerals[i].TextTransparency = 1 - envelope * 0.72 end
        local handTime = returning and elapsed * 0.18 or math.floor(elapsed * 24) / 24
        for i = 1, #hands do
            hands[i].pivot.Rotation = -90 - handTime * (i == 1 and 340 or (i == 2 and 84 or 540))
            alpha(hands[i].line, envelope * (i == 3 and 0.42 or 0.86))
        end
        alpha(center, envelope)
        for i = 1, #cracks do
            local crack = cracks[i]
            local reveal = smooth((elapsed - (returning and 0 or 0.54) - crack.delay) / 0.24)
            alpha(crack.frame, envelope * reveal * (returning and 0.22 or 0.62))
        end
        for i = 1, #dust do
            local mote = dust[i]
            local angle = mote.angle - elapsed * (returning and 0.08 or 0.28)
            local radius = mote.radius * (returning and (1 + elapsed * 0.28) or (1 - elapsed * 0.12))
            mote.frame.Position = UDim2.fromOffset(width * 0.5 + math.cos(angle) * radius * side,
                height * 0.47 + math.sin(angle) * radius * side)
            mote.frame.Rotation = math.deg(angle) + (returning and 0 or 90)
            alpha(mote.frame, envelope * (0.12 + 0.16 * (0.5 + 0.5 * math.sin(elapsed * 2 + mote.phase))))
        end
        local textAlpha = envelope * smooth(elapsed / 0.30)
        title.TextTransparency = 1 - textAlpha
        title.TextStrokeTransparency = 1 - textAlpha * 0.6
        subtitle.TextTransparency = 1 - textAlpha * 0.72
        title.Position = UDim2.new(0.5, 0, 0.73, (1 - smooth(elapsed / 0.45)) * 12 * scale)
        local flashEnvelope = returning and math.max(0, 1 - elapsed / 0.4) or math.max(0, 1 - elapsed / 0.12)
        alpha(flash, flashEnvelope * flashStrength * (returning and 0.45 or 0.30))
        if cc then
            cc.Saturation = envelope * (returning and 0.10 or -0.77)
            cc.Contrast = envelope * (returning and 0.025 or 0.09)
            cc.Brightness = envelope * (returning and 0.012 or -0.025)
            cc.TintColor = Color3.new(1 - envelope * 0.055, 1 - envelope * 0.075, 1)
        end
        if bloom then bloom.Intensity = envelope * (returning and 0.17 or 0.065) end
    end

    function fx:destroy()
        if self.destroyed then return end
        self:cancel()
        self.destroyed = true
        for i = #own, 1, -1 do own[i]:Destroy() end
        table.clear(own)
    end
    return fx
end


local fx = createRewindFX(gui, CONFIG)
local function finiteNumber(value)
    return type(value)=="number" and value==value and math.abs(value)<math.huge
end
local function validPosition(value)
    return typeof(value)=="Vector3" and finiteNumber(value.X) and finiteNumber(value.Y)
        and finiteNumber(value.Z) and value.Magnitude<10000000
end
local function isLiving(model)
    local h=model and model:FindFirstChildOfClass("Humanoid")
    return h and h.Health>0 and model.Parent~=nil
end
local function setCheckpoint(payload)
    if payload and validPosition(payload.position) then
        checkpoint={position=payload.position,version=payload.version or 0}
        marker.Position=payload.position
    else checkpoint=nil end
end
local function beginRewind(number)
    if finiteNumber(number) then cycle=math.max(0,math.floor(number)) end
    if not deadCycle then
        deadCycle=true; waitAt=os.clock(); timedOut=false
        if enabled then fx:rewind(cycle,os.clock()) end
    end
end
local function completeReturn(payload, actual)
    if actual then
        if not finiteNumber(payload.cycle) or payload.cycle<=returnedCycle then return end
        returnedCycle=payload.cycle
        serverCycle=math.max(serverCycle,payload.cycle)
        cycle=payload.cycle
        if validPosition(payload.position) then setCheckpoint(payload) end
    end
    if enabled and (deadCycle or actual) then fx:returned(cycle,os.clock(),actual) end
    deadCycle,waitAt,serverWaiting,pendingReturned,pendingSpawn=false,nil,false,nil,nil
    timedOut=false
    if actual then showMessage("ВОЗВРАТ К ТОЧКЕ · ЦИКЛ " .. tostring(cycle)) end
end
local function tryReturned()
    if not pendingReturned or not character or not isLiving(character) then return end
    if pendingReturned.character and pendingReturned.character~=character then return end
    completeReturn(pendingReturned,true)
end
local requestSync
local function bindCharacter(model)
    characterToken=characterToken+1
    local version=characterToken
    disconnectCharacter()
    character,characterHumanoid=model,nil
    if deadCycle then pendingSpawn=os.clock() end
    task.spawn(function()
        local h=model:WaitForChild("Humanoid",10)
        if not alive or version~=characterToken or player.Character~=model or not h or not h:IsA("Humanoid") then return end
        characterHumanoid=h
        characterConnections[#characterConnections+1]=h.Died:Connect(function()
            if not alive or player.Character~=model then return end
            if not deadCycle then beginRewind(math.max(cycle,serverCycle)+1) end
        end)
        if h.Health<=0 then
            if not deadCycle then beginRewind(math.max(cycle,serverCycle)+1) end
        elseif remote then
            tryReturned()
            requestSync()
        elseif deadCycle then
            completeReturn({},false)
        end
    end)
end
requestSync=function()
    if not remote or not remote.Parent then return end
    local now=os.clock()
    if now-syncAt<1.1 then return end
    syncAt=now
    remote:FireServer("Sync")
end
local function receive(action,payload)
    if not alive or type(payload)~="table" then return end
    if action=="State" then
        if payload.hasCheckpoint then setCheckpoint(payload) else setCheckpoint(nil) end
        if finiteNumber(payload.readyAt) then readyAt=payload.readyAt end
        if finiteNumber(payload.cycle) then
            serverCycle=math.max(serverCycle,payload.cycle)
            cycle=math.max(cycle,serverCycle)
        end
        serverWaiting=payload.waitingForRespawn==true
        if serverWaiting and not isLiving(character) then
            beginRewind(serverCycle)
        elseif not serverWaiting and deadCycle and isLiving(character) and not pendingReturned then
            -- Handles Rewind arriving after CharacterAdded followed by a refused restore.
            completeReturn({},false)
        end
    elseif action=="Checkpoint" then
        pendingRequest=nil
        setCheckpoint(payload)
        if finiteNumber(payload.readyAt) then readyAt=payload.readyAt end
        showMessage("ТОЧКА ВОЗВРАТА СОХРАНЕНА")
    elseif action=="Rewind" then
        if not finiteNumber(payload.cycle) or payload.cycle<=returnedCycle then return end
        serverCycle=math.max(serverCycle,payload.cycle)
        serverWaiting=true
        beginRewind(payload.cycle)
    elseif action=="Returned" then
        if not finiteNumber(payload.cycle) or payload.cycle<=returnedCycle then return end
        pendingReturned=payload
        tryReturned()
    elseif action=="Invalidated" then
        setCheckpoint(nil)
        pendingReturned,serverWaiting,pendingRequest,pendingSpawn=nil,false,nil,nil
        deadCycle,waitAt=false,nil
        fx:cancel()
        showMessage(payload.reason=="TeamChanged" and "СМЕНА КОМАНДЫ · НОВАЯ ТОЧКА"
            or "НОВЫЙ РАУНД · НОВАЯ ТОЧКА")
    elseif action=="Denied" then
        pendingRequest=nil
        if finiteNumber(payload.readyAt) then readyAt=payload.readyAt end
        local messages={GroundRequired="Встань на устойчивую свободную поверхность",
            CharacterUnavailable="Точка доступна живому персонажу",
            Interrupted="Сейчас нельзя обновить точку",Cooldown="Подожди перед новой точкой",
            CheckpointBlocked="Точка перекрыта · обычное возрождение",
            RoundChanged="Раунд изменился · точка сброшена",TeamChanged="Команда изменилась · точка сброшена",
            Timeout="Персонаж ещё не готов к возврату"}
        if payload.reason=="CheckpointBlocked" and not (deadCycle or serverWaiting or pendingSpawn) then
            messages.CheckpointBlocked="ЗДЕСЬ НЕЛЬЗЯ СОХРАНИТЬ НОВУЮ ТОЧКУ"
        end
        showMessage(messages[payload.reason] or "Точку сейчас сохранить нельзя")
        if payload.reason=="CheckpointBlocked" or payload.reason=="Timeout" then
            -- Failed B-save does not invalidate an older good checkpoint.
            -- Only authoritative State/Invalidated messages clear the saved marker.
            serverWaiting=false; pendingReturned=nil
            requestSync()
            if isLiving(character) and deadCycle then completeReturn({},false) end
        end
    end
end
local function bindRemote(candidate)
    if candidate.Name~="ISAGI_ReturnByDeathRemote" or not candidate:IsA("RemoteEvent") or candidate==remote then return end
    if remoteConnection then remoteConnection:Disconnect() end
    -- A restarted server controller starts its own sequence at zero.
    cycle,serverCycle,returnedCycle=0,0,-1
    pendingReturned,serverWaiting,pendingRequest,pendingSpawn=nil,false,nil,nil
    deadCycle,waitAt,readyAt=false,nil,0
    setCheckpoint(nil)
    fx:cancel()
    remote=candidate
    remoteConnection=candidate.OnClientEvent:Connect(function(action,payload)
        if remote==candidate then receive(action,payload) end
    end)
    syncAt=-math.huge
    requestSync()
end
local function activate()
    if not alive then return end
    if not remote or not remote.Parent then
        enabled=not enabled
        if not enabled then fx:cancel() end
        showMessage(enabled and "ЭФФЕКТ ВОЗРОЖДЕНИЯ ВКЛЮЧЁН" or "ЭФФЕКТ ВЫКЛЮЧЕН")
        return
    end
    if pendingRequest or workspace:GetServerTimeNow()<readyAt then return end
    if not isLiving(character) then return end
    pendingRequest=os.clock()
    remote:FireServer("Checkpoint")
end
connect(button.Activated,activate)
connect(UIS.InputBegan,function(input,processed)
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode==Enum.KeyCode.B then activate() end
end)
connect(player.CharacterAdded,bindCharacter)
connect(player.CharacterRemoving,function(model)
    if character~=model then return end
    characterToken=characterToken+1
    disconnectCharacter()
    character,characterHumanoid=nil,nil
end)
connect(ReplicatedStorage.ChildAdded,bindRemote)
connect(ReplicatedStorage.ChildRemoved,function(candidate)
    if candidate==remote then
        if remoteConnection then remoteConnection:Disconnect();remoteConnection=nil end
        remote=nil
        setCheckpoint(nil)
        pendingReturned,serverWaiting,pendingRequest=nil,false,nil
        if isLiving(character) and deadCycle then completeReturn({},false) end
    end
end)
local found=ReplicatedStorage:FindFirstChild("ISAGI_ReturnByDeathRemote")
if found then bindRemote(found) end
if player.Character then bindCharacter(player.Character) end

local function render(dt)
    local now=os.clock()
    fx:update(now,dt)
    tryReturned()
    if pendingRequest and now-pendingRequest>4 then
        pendingRequest=nil
        showMessage("СЕРВЕР НЕ ПОДТВЕРДИЛ ТОЧКУ")
    end
    if pendingSpawn and now-pendingSpawn>4 and deadCycle and isLiving(character) then
        -- A custom respawn system may reject the restore. Never claim success without Returned.
        completeReturn({},false)
    end
    if waitAt and now-waitAt>12 and not timedOut then
        timedOut=true
        showMessage("ОЖИДАНИЕ ВОЗРОЖДЕНИЯ В ЭТОМ РЕЖИМЕ")
    end
    status.TextTransparency=1-math.clamp((messageUntil-now)/0.25,0,1)
    local root=character and character:FindFirstChild("HumanoidRootPart")
    local visible=CONFIG.ShowMarker and checkpoint~=nil and root~=nil
        and (root.Position-checkpoint.position).Magnitude<CONFIG.MarkerDistance
    markerGui.Enabled=visible
    for _,beam in ipairs(beams) do
        beam.Enabled=visible
        if visible then beam.Transparency=NumberSequence.new(0.25+0.1*math.sin(now*2)) end
    end
    local tick=math.floor(now*5)
    if tick~=lastUi then
        lastUi=tick
        if remote then
            local remaining=math.max(0,readyAt-workspace:GetServerTimeNow())
            caption.Text="ТОЧКА"
            symbol.Text=pendingRequest and "…" or (remaining>0 and tostring(math.ceil(remaining)) or "↶")
            symbol.TextSize=remaining>0 and 29 or 43
            if serverWaiting or deadCycle then hint.Text="ВОЗВРАТ ПОСЛЕ ВОЗРОЖДЕНИЯ"
            elseif checkpoint then hint.Text="B · ОБНОВИТЬ ТОЧКУ\nЦИКЛ " .. tostring(cycle)
            else hint.Text="B · СОХРАНИТЬ ТОЧКУ" end
        else
            caption.Text=enabled and "ЭФФЕКТ ВКЛ" or "ЭФФЕКТ ВЫКЛ"
            symbol.Text="↶";symbol.TextSize=43
            hint.Text="БЕЗ СЕРВЕРА\nТОЛЬКО ВИЗУАЛЬНЫЙ ЭФФЕКТ"
        end
        stroke.Transparency=enabled and 0.2 or 0.72
    end
end
local function shutdown()
    if not alive then return end
    alive=false
    characterToken=characterToken+1
    RunService:UnbindFromRenderStep(token)
    disconnectCharacter()
    for _,c in ipairs(connections) do c:Disconnect() end
    if remoteConnection then remoteConnection:Disconnect() end
    fx:destroy()
    world:Destroy();gui:Destroy()
end
connect(stop.Event,shutdown)
connect(gui.Destroying,shutdown)
if typeof(script)=="Instance" then connect(script.Destroying,shutdown) end
RunService:BindToRenderStep(token,Enum.RenderPriority.Last.Value,function(dt)
    if not alive then return end
    local ok,err=xpcall(function() render(dt) end,debug.traceback)
    if not ok then warn("Return By Death stopped: "..tostring(err));shutdown() end
end)
