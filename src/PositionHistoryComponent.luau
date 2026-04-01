--!strict
-- RollbackHitbox / PositionHistoryComponent.luau
--
-- Maintains a per-character circular buffer of hitbox snapshots sampled every
-- Heartbeat.  GetInterpolatedSnapshot() binary-searches the buffer and lerps
-- between the two nearest entries to reconstruct hitbox positions at any past time.
--
-- Usage (server, inside RunService.Heartbeat):
--   PositionHistoryComponent.RecordAll(workspace:GetServerTimeNow())
--
-- Usage (register / unregister when characters spawn / die):
--   PositionHistoryComponent.RegisterCharacter(character)
--   PositionHistoryComponent.UnregisterCharacter(character)

local Config = require(script.Parent.Config)
local HitboxComponent = require(script.Parent.HitboxComponent)

local PositionHistoryComponent = {}

-- ─── Types ─────────────────────────────────────────────────────────────────────

export type PartHitbox = {
	cframe: CFrame,    -- Hitbox position at the rewound time
	size: Vector3,     -- Hitbox dimensions (constant per character)
	isHead: boolean,   -- true = head hitbox, false = body hitbox
}

type HitboxSnapshot = {
	timestamp: number,
	bodyCFrame: CFrame,
	headCFrame: CFrame,
}

type CharacterHistory = {
	buffer: { HitboxSnapshot },
	writeIndex: number,
	count: number,
}

type CharacterHitboxInfo = {
	bodySize: Vector3,
	headSize: Vector3,
	hitboxBody: BasePart,
	hitboxHead: BasePart,
}

-- ─── Module state ──────────────────────────────────────────────────────────────

local CAPACITY = Config.BUFFER_CAPACITY
local OFFSCREEN_CF = CFrame.new(0, -1000, 0)

local _histories: { [Model]: CharacterHistory } = {}
local _characterInfo: { [Model]: CharacterHitboxInfo } = {}

-- ─── Public API ───────────────────────────────────────────────────────────────

--- Register `character` for snapshot recording.
--- Call this after HitboxComponent.AttachHitboxes().
function PositionHistoryComponent.RegisterCharacter(character: Model)
	local hitboxParts = HitboxComponent.GetHitboxParts(character)
	if not hitboxParts then
		warn("[RollbackHitbox] RegisterCharacter: no hitbox parts for " .. character.Name
			.. " — call HitboxComponent.AttachHitboxes() first")
		return
	end

	_characterInfo[character] = {
		bodySize = Config.BODY_HITBOX_SIZE,
		headSize = Config.HEAD_HITBOX_SIZE,
		hitboxBody = hitboxParts.body,
		hitboxHead = hitboxParts.head,
	}

	-- Pre-allocate the buffer so no GC pressure occurs during gameplay
	local buffer: { HitboxSnapshot } = table.create(CAPACITY)
	for i = 1, CAPACITY do
		buffer[i] = { timestamp = 0, bodyCFrame = OFFSCREEN_CF, headCFrame = OFFSCREEN_CF }
	end
	_histories[character] = {
		buffer = buffer,
		writeIndex = 1,
		count = 0,
	}

	-- Record an initial snapshot immediately so ValidateHit never sees an empty buffer
	PositionHistoryComponent.RecordSnapshot(character, workspace:GetServerTimeNow())
end

--- Unregister `character` and free its snapshot buffer.
--- Call this when the character dies or is removed.
function PositionHistoryComponent.UnregisterCharacter(character: Model)
	_histories[character] = nil
	_characterInfo[character] = nil
end

--- Record one snapshot for `character` at `timestamp`.
--- Normally called via RecordAll() inside RunService.Heartbeat.
function PositionHistoryComponent.RecordSnapshot(character: Model, timestamp: number)
	local history = _histories[character]
	local info = _characterInfo[character]
	if not history or not info then
		return
	end

	local entry = history.buffer[history.writeIndex]
	entry.timestamp = timestamp
	entry.bodyCFrame = if info.hitboxBody.Parent then info.hitboxBody.CFrame else OFFSCREEN_CF
	entry.headCFrame = if info.hitboxHead.Parent then info.hitboxHead.CFrame else OFFSCREEN_CF

	history.writeIndex = (history.writeIndex % CAPACITY) + 1
	if history.count < CAPACITY then
		history.count += 1
	end
end

--- Record snapshots for every registered character at `timestamp`.
--- Wire this to RunService.Heartbeat on the server:
---   RunService.Heartbeat:Connect(function()
---       PositionHistoryComponent.RecordAll(workspace:GetServerTimeNow())
---   end)
function PositionHistoryComponent.RecordAll(timestamp: number)
	for character in _histories do
		PositionHistoryComponent.RecordSnapshot(character, timestamp)
	end
end

--- Return interpolated body and head hitboxes for `character` at `targetTime`.
--- Returns nil if the character has no history.
--- Never modifies game state — reads from stored snapshots only.
function PositionHistoryComponent.GetInterpolatedSnapshot(
	character: Model,
	targetTime: number
): { PartHitbox }?
	local history = _histories[character]
	local info = _characterInfo[character]
	if not history or not info or history.count == 0 then
		return nil
	end

	local count = history.count
	local oldestPhysical: number
	if count < CAPACITY then
		oldestPhysical = 1
	else
		oldestPhysical = history.writeIndex
	end

	local function physicalIndex(logical: number): number
		return ((oldestPhysical - 1 + logical) % CAPACITY) + 1
	end

	local oldestSnap = history.buffer[physicalIndex(0)]
	local newestSnap = history.buffer[physicalIndex(count - 1)]

	local interpBody: CFrame
	local interpHead: CFrame

	if targetTime <= oldestSnap.timestamp then
		-- Clamp to oldest available snapshot
		interpBody = oldestSnap.bodyCFrame
		interpHead = oldestSnap.headCFrame
	elseif targetTime >= newestSnap.timestamp then
		-- Clamp to newest available snapshot
		interpBody = newestSnap.bodyCFrame
		interpHead = newestSnap.headCFrame
	else
		-- Binary search for the two snapshots that bracket targetTime
		local lo = 0
		local hi = count - 1
		while lo < hi - 1 do
			local mid = math.floor((lo + hi) / 2)
			if history.buffer[physicalIndex(mid)].timestamp <= targetTime then
				lo = mid
			else
				hi = mid
			end
		end

		local snapA = history.buffer[physicalIndex(lo)]
		local snapB = history.buffer[physicalIndex(hi)]
		local dt = snapB.timestamp - snapA.timestamp
		if dt <= 0 then
			interpBody = snapA.bodyCFrame
			interpHead = snapA.headCFrame
		else
			local alpha = math.clamp((targetTime - snapA.timestamp) / dt, 0, 1)
			interpBody = snapA.bodyCFrame:Lerp(snapB.bodyCFrame, alpha)
			interpHead = snapA.headCFrame:Lerp(snapB.headCFrame, alpha)
		end
	end

	local result: { PartHitbox } = table.create(2)
	result[1] = { cframe = interpBody, size = info.bodySize, isHead = false }
	result[2] = { cframe = interpHead, size = info.headSize, isHead = true }
	return result
end

return PositionHistoryComponent
