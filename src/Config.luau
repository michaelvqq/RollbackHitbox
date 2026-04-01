--!strict
-- RollbackHitbox / Config.luau
-- All tunable constants for the rollback lag-compensation system.
-- Tweak these to fit your game's speed, hitbox sizes, and network conditions.

return table.freeze({
	-- ─── Timing ──────────────────────────────────────────────────
	MAX_REWIND_SECONDS = 0.5,
	-- Furthest back in time (seconds) the server will rewind for a hit claim.
	-- Raise for high-latency tolerance; lower to tighten the anti-cheat window.

	INTERPOLATION_BUFFER = 0.1,
	-- Extra rewind (seconds) to compensate for Roblox's ~20 Hz character replication delay.
	-- The client sees remote characters delayed by at least one replication frame;
	-- this constant adds that back so the rewind lines up correctly.

	-- ─── Shot-origin validation ───────────────────────────────────
	MAX_ORIGIN_DISTANCE = 12,
	-- Base tolerance (studs): how far a shot origin can deviate from the shooter's
	-- rewound position before being rejected.  Scaled up at runtime by latency × speed.

	MAX_PLAYER_SPEED = 60,
	-- Assumed top movement speed (studs/sec) used to widen origin tolerance at high latency.
	-- Set this to the fastest your characters can legitimately travel.

	-- ─── Snapshot buffer ─────────────────────────────────────────
	BUFFER_CAPACITY = 24,
	-- Snapshot slots per character.  At 60 Hz this is ~400 ms of history, which comfortably
	-- exceeds MAX_REWIND_SECONDS.  Increase if you raise MAX_REWIND_SECONDS significantly.

	-- ─── Hitbox geometry ─────────────────────────────────────────
	BODY_HITBOX_SIZE = Vector3.new(4, 4, 3),
	-- Width × height × depth (studs) of the invisible body hitbox part.

	HEAD_HITBOX_SIZE = Vector3.new(2.5, 1.3, 2.5),
	-- Dimensions of the invisible head hitbox part.

	BODY_HITBOX_OFFSET = CFrame.new(0, -1, 0),
	-- Body hitbox offset relative to the character's HumanoidRootPart.

	HEAD_HITBOX_OFFSET = CFrame.new(0, 0.2, 0),
	-- Head hitbox offset relative to the character's Head part.

	-- ─── Validation leniency ─────────────────────────────────────
	ROLLBACK_FORGIVENESS = Vector3.new(3, 3, 0),
	-- Extra size (studs) added to each hitbox during the ray-OBB test.
	-- Compensates for minor position prediction errors; tune down to tighten accuracy.

	-- ─── Debug ───────────────────────────────────────────────────
	DEBUG = false,
	-- Spawn visible ghost boxes and rays in workspace for each validation call.
	-- Useful during development; leave false in production.

	DEBUG_DURATION = 1.5,
	-- Seconds the debug visuals persist before being auto-removed.
})
