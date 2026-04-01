--!strict
-- RollbackHitbox / init.luau
-- Public API — see README for usage.

local HitboxComponent = require(script.HitboxComponent)
local PositionHistoryComponent = require(script.PositionHistoryComponent)
local Validator = require(script.Validator)

export type PartHitbox = PositionHistoryComponent.PartHitbox

local RollbackHitbox = {}

-- ─── Hitbox lifecycle ─────────────────────────────────────────────────────────

--- Attach invisible hitbox parts to `character` and disable CanQuery on all
--- other BaseParts.  Call before RegisterCharacter().
function RollbackHitbox.AttachHitboxes(character: Model)
	HitboxComponent.AttachHitboxes(character)
end

--- Destroy hitbox parts for `character` and clean up listeners.
function RollbackHitbox.RemoveHitboxes(character: Model)
	HitboxComponent.RemoveHitboxes(character)
end

--- Returns the raw hitbox parts for `character`, or nil.
function RollbackHitbox.GetHitboxParts(character: Model): { body: BasePart, head: BasePart }?
	return HitboxComponent.GetHitboxParts(character)
end

-- ─── Position history ─────────────────────────────────────────────────────────

--- Start recording position snapshots for `character`.
--- Must be called after AttachHitboxes().
function RollbackHitbox.RegisterCharacter(character: Model)
	PositionHistoryComponent.RegisterCharacter(character)
end

--- Stop recording and free snapshot memory for `character`.
function RollbackHitbox.UnregisterCharacter(character: Model)
	PositionHistoryComponent.UnregisterCharacter(character)
end

--- Record one snapshot for all registered characters at `timestamp`.
--- Wire this to RunService.Heartbeat:
---   RunService.Heartbeat:Connect(function()
---       RollbackHitbox.RecordAll(workspace:GetServerTimeNow())
---   end)
function RollbackHitbox.RecordAll(timestamp: number)
	PositionHistoryComponent.RecordAll(timestamp)
end

--- Record a single snapshot for one character.  Use RecordAll() in most cases.
function RollbackHitbox.RecordSnapshot(character: Model, timestamp: number)
	PositionHistoryComponent.RecordSnapshot(character, timestamp)
end

--- Return interpolated hitboxes for `character` at a past `targetTime`.
--- Returns nil if the character has no history.
function RollbackHitbox.GetInterpolatedSnapshot(character: Model, targetTime: number): { PartHitbox }?
	return PositionHistoryComponent.GetInterpolatedSnapshot(character, targetTime)
end

-- ─── Hit validation ───────────────────────────────────────────────────────────

--- Validate a hit claim from `shooter` against `targetCharacter`.
---
--- Parameters:
---   shooter          Player   — the firing player
---   targetCharacter  Model    — the character being hit
---   shotOrigin       Vector3  — world-space muzzle position at fire time
---   shotDirection    Vector3  — normalised shot direction
---   gunRange         number   — max range in studs
---   muzzleOffset     Vector3  — offset from character root to muzzle
---   clientTimestamp  number   — workspace:GetServerTimeNow() captured on the client
---
--- Returns: (isValid, isHeadshot, hitDistance)
function RollbackHitbox.ValidateHit(
	shooter: Player,
	targetCharacter: Model,
	shotOrigin: Vector3?,
	shotDirection: Vector3?,
	gunRange: number,
	muzzleOffset: Vector3,
	clientTimestamp: number?
): (boolean, boolean, number?)
	return Validator.ValidateHit(
		shooter, targetCharacter,
		shotOrigin, shotDirection,
		gunRange, muzzleOffset,
		clientTimestamp
	)
end

return RollbackHitbox
