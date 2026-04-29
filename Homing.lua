-- Single-script homing missile system. Pooled visuals, single Heartbeat for the whole swarm
-- of active projectiles, predictive intercept (leads moving targets), clamped turn rate,


local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
-- Tunables


local SPEED             = 220
local MAX_TURN_RATE     = math.rad(360)
local LIFETIME          = 6
local ACQUISITION_CONE  = math.rad(25)
local ACQUISITION_RANGE = 400
local INITIAL_POOL      = 16
local MAX_STEP_DT       = 1 / 30          -- clamp dt prevents tunneling on frame hitches.
local TARGET_TAG        = "HomingTarget"

-- State


local pool: { BasePart } = {}
local active: { any } = {}
local heartbeat: RBXScriptConnection? = nil
local graveyard: Folder? = nil

type Projectile = {
    visual:    BasePart,
    target:    Instance,
    aliveFor:  number,
    position:  Vector3,
    velocity:  Vector3,
    onHit:     ((Instance) -> ())?,
    onExpire:  (() -> ())?,
}


-- Predictive intercept.
-- Solve |D + V*t| = s*t  ->  (V.V - s^2)t^2 + 2(D.V)t + D.D = 0. Smallest positive root.


local function solveInterceptTime(missilePos: Vector3, speed: number, targetPos: Vector3, targetVel: Vector3): number?
    local D = targetPos - missilePos
    local a = targetVel:Dot(targetVel) - speed * speed
    local b = 2 * D:Dot(targetVel)
    local c = D:Dot(D)

    if math.abs(a) < 1e-6 then
        -- target speed == missile speed: equation is linear, not quadratic.
        if math.abs(b) < 1e-6 then return nil end
        local t = -c / b
        return t > 0 and t or nil
    end

    local disc = b * b - 4 * a * c
    if disc < 0 then return nil end -- target uncatchable.

    local sq = math.sqrt(disc)
    local t1 = (-b - sq) / (2 * a)
    local t2 = (-b + sq) / (2 * a)
    if t1 > 0 and t2 > 0 then return math.min(t1, t2) end
    if t1 > 0 then return t1 end
    if t2 > 0 then return t2 end
    return nil
end

-- Slerp via CFrame:Lerp on rotation-only frames. A normalized vector lerp would give
-- non-uniform angular speed, which reads as robotic acceleration mid-turn.
local function rotateToward(currentLook: Vector3, desiredLook: Vector3, maxAngle: number): Vector3
    local dot = math.clamp(currentLook:Dot(desiredLook), -1, 1)
    local angle = math.acos(dot)
    if angle <= maxAngle then return desiredLook end

    local up = math.abs(currentLook.Y) < 0.99 and Vector3.yAxis or Vector3.xAxis
    local fromCF = CFrame.lookAt(Vector3.zero, currentLook, up)
    local toCF = CFrame.lookAt(Vector3.zero, desiredLook, up)
    return fromCF:Lerp(toCF, maxAngle / angle).LookVector
end

-- Pool


local function ensureGraveyard(): Folder
    if graveyard and graveyard.Parent then return graveyard end
    local f = Instance.new("Folder")
    f.Name = "_HomingProjectilePool"
    f.Parent = Workspace
    graveyard = f
    return f
end

local function buildVisual(): BasePart
    local part = Instance.new("Part")
    part.Name = "Projectile"
    part.Size = Vector3.new(0.4, 0.4, 1.6)
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(255, 170, 60)
    part.CanCollide = false
    part.CanQuery = false   -- skip our own raycasts.
    part.CanTouch = false
    part.Anchored = true
    part.CastShadow = false

    local a0 = Instance.new("Attachment")
    a0.Name = "TrailA0"
    a0.Position = Vector3.new(0, 0, 0.7)
    a0.Parent = part
    local a1 = Instance.new("Attachment")
    a1.Name = "TrailA1"
    a1.Position = Vector3.new(0, 0, -0.7)
    a1.Parent = part

    local trail = Instance.new("Trail")
    trail.Attachment0 = a0
    trail.Attachment1 = a1
    trail.Lifetime = 0.25
    trail.MinLength = 0
    trail.LightEmission = 1
    trail.Color = ColorSequence.new(Color3.fromRGB(255, 200, 100), Color3.fromRGB(255, 60, 0))
    trail.Transparency = NumberSequence.new(0, 1)
    trail.Enabled = false
    trail.Parent = part

    return part
end

local function acquireVisual(): BasePart
    local v = table.remove(pool) or buildVisual()
    local trail = v:FindFirstChildOfClass("Trail")
    if trail then trail.Enabled = true end
    v.Parent = Workspace
    return v
end

local function releaseVisual(v: BasePart)
    local trail = v:FindFirstChildOfClass("Trail")
    if trail then trail.Enabled = false end
    -- park far away so a stale frame doesn't streak the trail across the map.
    v.CFrame = CFrame.new(0, -1000, 0)
    v.Parent = ensureGraveyard()
    table.insert(pool, v)
end

do
    -- prebuild so the first shot doesn't pay construction cost.
    for _ = 1, INITIAL_POOL do
        local v = buildVisual()
        v.Parent = ensureGraveyard()
        table.insert(pool, v)
    end
end

-- Targets


local function getTargetPart(target: Instance): BasePart?
    if target:IsA("BasePart") then return target end
    if target:IsA("Model") then
        return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end


-- Per-step simulation


local function buildRaycastParams(self: Projectile): RaycastParams
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { self.visual, ensureGraveyard() }
    rp.IgnoreWater = true
    return rp
end

local function stepProjectile(self: Projectile, dt: number): boolean
    self.aliveFor += dt
    if self.aliveFor >= LIFETIME then
        if self.onExpire then pcall(self.onExpire) end
        return false
    end

    local targetPart = getTargetPart(self.target)
    if targetPart then
        local interceptT = solveInterceptTime(self.position, SPEED, targetPart.Position, targetPart.AssemblyLinearVelocity)
        local aimAt = interceptT and (targetPart.Position + targetPart.AssemblyLinearVelocity * interceptT) or targetPart.Position

        local desired = aimAt - self.position
        if desired.Magnitude > 1e-4 then
            local newDir = rotateToward(self.velocity.Unit, desired.Unit, MAX_TURN_RATE * dt)
            self.velocity = newDir * SPEED
        end
    end

    -- Sweep current -> next as a single ray. As long as dt*SPEED < target hitbox we can't tunnel.
    local nextPos = self.position + self.velocity * dt
    local rayDir = nextPos - self.position
    local hit = Workspace:Raycast(self.position, rayDir, buildRaycastParams(self))

    if hit then
        self.position = hit.Position
        self.visual.CFrame = CFrame.lookAt(self.position, self.position + self.velocity.Unit)
        if self.onHit then pcall(self.onHit, hit.Instance) end
        return false
    end

    self.position = nextPos
    self.visual.CFrame = CFrame.lookAt(self.position, self.position + self.velocity.Unit)
    return true
end

local function updateAll(rawDt: number)
    local dt = math.min(rawDt, MAX_STEP_DT)

    -- iterate backwards so swap-remove doesn't skip elements.
    local i = #active
    while i >= 1 do
        local proj = active[i]
        if not stepProjectile(proj, dt) then
            releaseVisual(proj.visual)
            local last = #active
            if i ~= last then active[i] = active[last] end
            active[last] = nil
        end
        i -= 1
    end

    if #active == 0 and heartbeat then
        heartbeat:Disconnect()
        heartbeat = nil
    end
end

-- Public API


local HomingProjectile = {}

function HomingProjectile.fire(opts: {
    origin:   Vector3,
    target:   Instance,
    onHit:    ((Instance) -> ())?,
    onExpire: (() -> ())?,
}): Projectile?
    if typeof(opts.origin) ~= "Vector3" then return nil end
    if typeof(opts.target) ~= "Instance" then return nil end
    if not getTargetPart(opts.target) then return nil end

    local visual = acquireVisual()

    local startPart = getTargetPart(opts.target) :: BasePart
    local initialDir = startPart.Position - opts.origin
    if initialDir.Magnitude < 1e-4 then initialDir = Vector3.zAxis else initialDir = initialDir.Unit end

    local proj: Projectile = {
        visual = visual,
        target = opts.target,
        aliveFor = 0,
        position = opts.origin,
        velocity = initialDir * SPEED,
        onHit = opts.onHit,
        onExpire = opts.onExpire,
    }

    visual.CFrame = CFrame.lookAt(proj.position, proj.position + initialDir)
    table.insert(active, proj)

    if not heartbeat then
        heartbeat = RunService.Heartbeat:Connect(updateAll)
    end
    return proj
end

-- Find best target: prefer something inside the aim cone; if nothing in cone, fall back to the
-- nearest target within range. Without the fallback, F just silently no-ops when you aren't
-- precisely aimed, which feels broken.
function HomingProjectile.findBestTarget(origin: Vector3, look: Vector3): Instance?
    local bestCone, bestConeScore = nil :: Instance?, -math.huge
    local bestNear, bestNearDist  = nil :: Instance?, math.huge
    local maxCos = math.cos(ACQUISITION_CONE)

    for _, target in CollectionService:GetTagged(TARGET_TAG) do
        local part = getTargetPart(target)
        if part then
            local toT = part.Position - origin
            local dist = toT.Magnitude
            if dist > 0 and dist <= ACQUISITION_RANGE then
                local cosA = look:Dot(toT) / dist
                if cosA >= maxCos and cosA > bestConeScore then
                    bestConeScore = cosA
                    bestCone = target
                end
                if dist < bestNearDist then
                    bestNearDist = dist
                    bestNear = target
                end
            end
        end
    end

    return bestCone or bestNear
end

function HomingProjectile.spawnExplosion(at: Vector3)
    local exp = Instance.new("Explosion")
    exp.BlastRadius = 6
    exp.BlastPressure = 0       -- visual only pressure feels bad in PvP.
    exp.DestroyJointRadiusPercent = 0
    exp.Position = at
    exp.Parent = Workspace
    Debris:AddItem(exp, 2)
end

return HomingProjectile
