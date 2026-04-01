# RollbackHitbox

Server-authoritative rollback lag compensation for Roblox shooters. The server rewinds hitbox positions to the exact moment the client fired, then validates the shot using oriented bounding-box (OBB) math — no physics simulation, no ghost parts moved at runtime.

## Installation

**Roblox Studio** — Download `RollbackHitbox.rbxm` from the [latest release](https://github.com/michaelvqq/RollbackHitbox/releases/latest) and drag it into `ServerScriptService`.

**Rojo** — Copy the `RollbackHitbox/` folder into your project and reference it in your `default.project.json`:

```json
"RollbackHitbox": {
    "$path": "path/to/RollbackHitbox"
}
```

## Quick Start

### 1. Record snapshots every frame

```lua
local RollbackHitbox = require(path.to.RollbackHitbox)
local RunService = game:GetService("RunService")

RunService.Heartbeat:Connect(function()
    RollbackHitbox.RecordAll(workspace:GetServerTimeNow())
end)
```

### 2. Register characters on spawn

```lua
Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function(character)
        character:WaitForChild("HumanoidRootPart")
        character:WaitForChild("Head")

        RollbackHitbox.AttachHitboxes(character)
        RollbackHitbox.RegisterCharacter(character)

        character:WaitForChild("Humanoid").Died:Once(function()
            RollbackHitbox.UnregisterCharacter(character)
            RollbackHitbox.RemoveHitboxes(character)
        end)
    end)
end)
```

### 3. Validate hits on the server

```lua
-- Inside your hit RemoteEvent handler
local isValid, isHeadshot, hitDistance = RollbackHitbox.ValidateHit(
    shooter,
    target.Character,
    shotOrigin,
    shotDirection,
    gunConfig.Range,
    gunConfig.MuzzleOffset,
    clientTimestamp
)

if isValid then
    local damage = isHeadshot and gunConfig.HeadDamage or gunConfig.Damage
    target.Character.Humanoid:TakeDamage(damage)
end
```

### 4. Send the timestamp from the client

```lua
local fireTimestamp = workspace:GetServerTimeNow()
-- ... raycast, effects ...
CombatRemotes.PlayerHit:FireServer(targetUserId, shotOrigin, shotDirection, fireTimestamp)
```

## How it works

```
CLIENT fires
├─ Capture timestamp = workspace:GetServerTimeNow()
├─ Local raycast for instant visual feedback
└─ Send: origin, direction, timestamp → server

SERVER receives
├─ rewindAmount = clamp(serverNow - timestamp + buffer, 0, maxRewind)
├─ Retrieve shooter's rewound position  → validate origin distance
├─ Retrieve target's rewound hitboxes   → binary-search + lerp snapshot buffer
├─ Ray-OBB intersection on rewound positions
└─ Apply damage only if valid
```

Every server Heartbeat (~60 Hz), each registered character's hitbox CFrames are written into a circular buffer. `GetInterpolatedSnapshot()` binary-searches that buffer and lerps between the two bracketing entries — giving sub-frame accuracy without storing every frame.

## API Reference

### Hitbox lifecycle

| Function | Description |
|---|---|
| `AttachHitboxes(character: Model)` | Attach `HitboxBody` and `HitboxHead` parts; disable `CanQuery` on all other BaseParts. |
| `RemoveHitboxes(character: Model)` | Destroy hitbox parts and clean up listeners. |
| `GetHitboxParts(character: Model)` | Returns `{ body: BasePart, head: BasePart }?` |

### Position history

| Function | Description |
|---|---|
| `RegisterCharacter(character: Model)` | Allocate snapshot buffer. Call after `AttachHitboxes`. |
| `UnregisterCharacter(character: Model)` | Free snapshot buffer. |
| `RecordAll(timestamp: number)` | Record one snapshot for every registered character. Call in `RunService.Heartbeat`. |
| `RecordSnapshot(character: Model, timestamp: number)` | Record one snapshot for a single character. |
| `GetInterpolatedSnapshot(character: Model, targetTime: number)` | Returns `{ PartHitbox }?` — interpolated hitboxes at `targetTime`. |

```lua
export type PartHitbox = {
    cframe:  CFrame,   -- hitbox position at the rewound time
    size:    Vector3,  -- hitbox dimensions
    isHead:  boolean,  -- true = head, false = body
}
```

### Hit validation

```lua
RollbackHitbox.ValidateHit(
    shooter:         Player,
    targetCharacter: Model,
    shotOrigin:      Vector3?,
    shotDirection:   Vector3?,
    gunRange:        number,
    muzzleOffset:    Vector3,
    clientTimestamp: number?
) → (isValid: boolean, isHeadshot: boolean, hitDistance: number?)
```

| Parameter | Notes |
|---|---|
| `shooter` | The firing `Player`. Used to validate shot origin against their rewound position. |
| `targetCharacter` | The `Model` being shot. Must be registered. |
| `shotOrigin` | World-space muzzle position at fire time (client-sent). |
| `shotDirection` | Normalised shot direction (client-sent). |
| `gunRange` | Max effective range in studs. |
| `muzzleOffset` | `Vector3` from character root to muzzle tip. Widens origin tolerance. |
| `clientTimestamp` | `workspace:GetServerTimeNow()` captured on the client at fire time. Pass `nil` to skip rewind. |

**Returns:** `isValid`, `isHeadshot`, `hitDistance` (studs to hit point — use for damage falloff).

## Config

Edit `Config.luau` to tune the system for your game.

| Constant | Default | Purpose |
|---|---|---|
| `MAX_REWIND_SECONDS` | `0.5` s | Hard cap on rewind. Raise for high-latency players; lower to tighten the anti-cheat window. |
| `INTERPOLATION_BUFFER` | `0.1` s | Extra rewind to compensate for Roblox's ~20 Hz character replication delay. |
| `MAX_ORIGIN_DISTANCE` | `12` studs | Base tolerance for shot origin vs. the shooter's rewound position. |
| `MAX_PLAYER_SPEED` | `60` studs/s | Scales origin tolerance with latency. Set to your fastest character speed. |
| `BUFFER_CAPACITY` | `24` | Snapshots per character (~400 ms at 60 Hz). Increase if you raise `MAX_REWIND_SECONDS`. |
| `BODY_HITBOX_SIZE` | `(4, 4, 3)` | Body hitbox dimensions (W × H × D in studs). |
| `HEAD_HITBOX_SIZE` | `(2.5, 1.3, 2.5)` | Head hitbox dimensions. |
| `BODY_HITBOX_OFFSET` | `(0, -1, 0)` | Body hitbox offset from `HumanoidRootPart`. |
| `HEAD_HITBOX_OFFSET` | `(0, 0.2, 0)` | Head hitbox offset from `Head`. |
| `ROLLBACK_FORGIVENESS` | `(3, 3, 0)` | Extra hitbox size during the OBB test. Tune down for tighter accuracy. |
| `DEBUG` | `false` | Spawn visible ghost boxes and ray parts per validation. |
| `DEBUG_DURATION` | `1.5` s | How long debug visuals persist. |

## Security

**What this protects against**

- **Hit teleportation** — origin distance check bounds the shot to within reasonable range of the shooter's rewound position.
- **Timestamp manipulation** — `clientTimestamp` is clamped to `[0, MAX_REWIND_SECONDS]`; a client cannot claim an arbitrarily old position.
- **Headshot spoofing** — the server independently determines headshot vs. body-shot by which hitbox the rewound ray intersects.

**What this does not protect against**

- Fabricated `shotDirection` — direction is trusted. Add a server-side line-of-sight raycast for stronger guarantees.
- Aimbots — this system ensures the claimed shot is geometrically plausible, not that it was aimed by a human.

## License

MIT
