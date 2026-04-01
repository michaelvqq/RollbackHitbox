--!strict
-- RollbackHitbox / Validator.luau
--
-- Server-authoritative hit validation using rollback lag compensation.
--
-- ValidateHit() rewinds both the shooter's and target's hitbox positions to the
-- moment the client fired, then tests the claimed ray against those rewound
-- positions using oriented bounding-box (OBB) intersection math.
-- No physics simulation is required — all geometry is pure math.
--
-- Returns: (isValid, isHeadshot, hitDistance)
--   isValid      — true if the ray intersected a rewound hitbox within range
--   isHeadshot   — true if the ray hit the head hitbox (only meaningful when isValid)
--   hitDistance  — distance along the ray to the hit point (use for damage falloff)

local Debris = game:GetService("Debris")

local Config = require(script.Parent.Config)
local PositionHistoryComponent = require(script.Parent.PositionHistoryComponent)

local Validator = {}

-- ─── Debug visualization ──────────────────────────────────────────────────────

local _debugFolder: Folder? = nil

local function getDebugFolder(): Folder
	if _debugFolder and _debugFolder.Parent then
		return _debugFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "RollbackHitboxDebug"
	folder.Parent = workspace
	_debugFolder = folder
	return folder
end

local function debugBox(cf: CFrame, size: Vector3, color: Color3, transparency: number)
	if not Config.DEBUG then return end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = cf
	part.Size = size
	part.Color = color
	part.Transparency = transparency
	part.Material = Enum.Material.ForceField
	part.Parent = getDebugFolder()
	Debris:AddItem(part, Config.DEBUG_DURATION)
end

local function debugRay(origin: Vector3, direction: Vector3, length: number, color: Color3)
	if not Config.DEBUG then return end
	local midpoint = origin + direction * (length / 2)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.lookAt(midpoint, midpoint + direction)
	part.Size = Vector3.new(0.15, 0.15, length)
	part.Color = color
	part.Transparency = 0.3
	part.Material = Enum.Material.Neon
	part.Parent = getDebugFolder()
	Debris:AddItem(part, Config.DEBUG_DURATION)
end

-- ─── Ray-OBB intersection ─────────────────────────────────────────────────────
-- Transforms the ray into the box's local space, then uses the slab method.
-- Returns the entry distance along the ray, or nil on miss.

local function rayOBBIntersect(
	rayOrigin: Vector3,
	rayDir: Vector3,
	obbCFrame: CFrame,
	obbSize: Vector3
): number?
	local localOrigin = obbCFrame:PointToObjectSpace(rayOrigin)
	local localDir = obbCFrame:VectorToObjectSpace(rayDir)
	local half = obbSize * 0.5

	local ox, oy, oz = localOrigin.X, localOrigin.Y, localOrigin.Z
	local dx, dy, dz = localDir.X, localDir.Y, localDir.Z
	local hx, hy, hz = half.X, half.Y, half.Z

	local tMin = -math.huge
	local tMax = math.huge

	-- X slab
	if math.abs(dx) < 1e-8 then
		if ox < -hx or ox > hx then return nil end
	else
		local t1 = (-hx - ox) / dx
		local t2 = (hx - ox) / dx
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	-- Y slab
	if math.abs(dy) < 1e-8 then
		if oy < -hy or oy > hy then return nil end
	else
		local t1 = (-hy - oy) / dy
		local t2 = (hy - oy) / dy
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	-- Z slab
	if math.abs(dz) < 1e-8 then
		if oz < -hz or oz > hz then return nil end
	else
		local t1 = (-hz - oz) / dz
		local t2 = (hz - oz) / dz
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	if tMin < 0 then
		if tMax < 0 then return nil end
		return 0
	end
	return tMin
end

-- ─── Public API ───────────────────────────────────────────────────────────────

--- Validate a hit claim from `shooter` against `targetCharacter`.
---
--- @param shooter          Player — the player claiming the hit
--- @param targetCharacter  Model  — the character being hit
--- @param shotOrigin       Vector3 — muzzle world position at fire time (client-sent)
--- @param shotDirection    Vector3 — normalised shot direction (client-sent)
--- @param gunRange         number  — max effective range in studs
--- @param muzzleOffset     Vector3 — offset from root to muzzle (used to widen origin tolerance)
--- @param clientTimestamp  number  — workspace:GetServerTimeNow() captured on the client at fire time
---
--- @return isValid         boolean
--- @return isHeadshot      boolean  (only meaningful when isValid = true)
--- @return hitDistance     number?  (studs along the ray; use for damage falloff)
function Validator.ValidateHit(
	shooter: Player,
	targetCharacter: Model,
	shotOrigin: Vector3?,
	shotDirection: Vector3?,
	gunRange: number,
	muzzleOffset: Vector3,
	clientTimestamp: number?
): (boolean, boolean, number?)
	if not shotOrigin or not shotDirection then
		if Config.DEBUG then
			print("[RollbackHitbox] REJECT", shooter.Name, "→ missing origin/direction")
		end
		return false, false, nil
	end

	local shooterChar = shooter.Character
	if not shooterChar then return false, false, nil end
	local shooterRoot = shooterChar:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not shooterRoot then return false, false, nil end

	-- ── Compute rewind time ──────────────────────────────────────────────────
	-- clientTimestamp is workspace:GetServerTimeNow() sampled on the client,
	-- which is clock-synchronized — no round-trip measurement needed.
	-- INTERPOLATION_BUFFER compensates for Roblox's ~20 Hz character replication delay.
	local serverNow = workspace:GetServerTimeNow()
	local rewindAmount = if clientTimestamp
		then math.clamp(
			serverNow - clientTimestamp + Config.INTERPOLATION_BUFFER,
			0,
			Config.MAX_REWIND_SECONDS
		)
		else 0
	local rewindTime = serverNow - rewindAmount

	if Config.DEBUG then
		print(string.format("[RollbackHitbox] %s → rewind %dms", shooter.Name, math.floor(rewindAmount * 1000)))
	end

	-- ── Check 1: shot origin must be near the shooter's rewound position ──────
	local shooterRewound = PositionHistoryComponent.GetInterpolatedSnapshot(shooterChar, rewindTime)
	local shooterCheckPos = if shooterRewound then shooterRewound[1].cframe.Position else shooterRoot.Position
	local originDist = (shotOrigin - shooterCheckPos).Magnitude
	local maxOriginDist = Config.MAX_ORIGIN_DISTANCE + muzzleOffset.Magnitude + (rewindAmount * Config.MAX_PLAYER_SPEED)

	if originDist > maxOriginDist then
		if Config.DEBUG then
			print(string.format(
				"[RollbackHitbox] REJECT %s → origin too far (%.1f studs, threshold %.1f)",
				shooter.Name, originDist, maxOriginDist
			))
		end
		return false, false, nil
	end

	-- ── Check 2: retrieve rewound hitbox positions for target ─────────────────
	local rewoundHitboxes = PositionHistoryComponent.GetInterpolatedSnapshot(targetCharacter, rewindTime)
	if not rewoundHitboxes then
		if Config.DEBUG then
			print("[RollbackHitbox] REJECT", shooter.Name, "→ no history for", targetCharacter.Name)
		end
		return false, false, nil
	end

	-- ── Check 3: ray-OBB intersection against rewound hitboxes ───────────────
	local rayLength = gunRange + muzzleOffset.Magnitude + 3
	local dirUnit = shotDirection.Unit

	local bodyHitbox: PositionHistoryComponent.PartHitbox? = nil
	local headHitbox: PositionHistoryComponent.PartHitbox? = nil
	for _, hitbox in rewoundHitboxes do
		if hitbox.isHead then
			headHitbox = hitbox
		else
			bodyHitbox = hitbox
		end
	end

	if not bodyHitbox or not headHitbox then
		return false, false, nil
	end

	if Config.DEBUG then
		print("[RollbackHitbox] ray origin=" .. tostring(shotOrigin) .. " dir=" .. tostring(dirUnit) .. " len=" .. tostring(rayLength))
		print("[RollbackHitbox] BODY pos=" .. tostring(bodyHitbox.cframe.Position) .. " size=" .. tostring(bodyHitbox.size))
		print("[RollbackHitbox] HEAD pos=" .. tostring(headHitbox.cframe.Position) .. " size=" .. tostring(headHitbox.size))
	end

	local hitAny = false
	local confirmedHeadshot = false
	local hitDistance: number? = nil
	local forgiveness = Config.ROLLBACK_FORGIVENESS

	-- Test head first — if both hit, headshot wins
	local headDist = rayOBBIntersect(shotOrigin, dirUnit, headHitbox.cframe, headHitbox.size + forgiveness)
	if headDist and headDist <= rayLength then
		hitAny = true
		confirmedHeadshot = true
		hitDistance = headDist
	end

	if not hitAny then
		local bodyDist = rayOBBIntersect(shotOrigin, dirUnit, bodyHitbox.cframe, bodyHitbox.size + forgiveness)
		if bodyDist and bodyDist <= rayLength then
			hitAny = true
			hitDistance = bodyDist
		end
	end

	-- ── Debug visualization ───────────────────────────────────────────────────
	if Config.DEBUG then
		local COLOR_HIT  = Color3.fromRGB(0, 255, 0)
		local COLOR_HEAD = Color3.fromRGB(255, 255, 0)
		local COLOR_MISS = Color3.fromRGB(255, 0, 0)
		local COLOR_IDLE = Color3.fromRGB(100, 100, 255)

		debugRay(shotOrigin, dirUnit, rayLength, if hitAny then COLOR_HIT else COLOR_MISS)
		debugBox(bodyHitbox.cframe, bodyHitbox.size + forgiveness, if hitAny and not confirmedHeadshot then COLOR_HIT else COLOR_IDLE, 0.6)
		debugBox(headHitbox.cframe, headHitbox.size + forgiveness, if confirmedHeadshot then COLOR_HEAD else COLOR_IDLE, 0.6)

		if hitAny then
			print("[RollbackHitbox] VALID", shooter.Name, "→", if confirmedHeadshot then "headshot" else "hit", "on", targetCharacter.Name)
		else
			print("[RollbackHitbox] REJECT", shooter.Name, "→ missed", targetCharacter.Name)
		end
	end

	return hitAny, confirmedHeadshot, hitDistance
end

return Validator
