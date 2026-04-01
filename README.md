# RollbackHitbox

Server-authoritative rollback lag compensation for Roblox FPS games.

Clients fire immediately with no latency feel. The server rewinds both the shooter's and target's hitbox positions to the exact moment the client pulled the trigger, then validates the shot using oriented bounding-box (OBB) math. No physics simulation, no ghost parts moved at runtime — pure math on pre-recorded snapshots.

---

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

---

## Quick Start

### 1. Drop the folder

Copy `RollbackHitbox/` anywhere reachable from server scripts (e.g. `ServerScriptService`).

### 2. Wire the Heartbeat recorder

```lua
-- In your combat service Start() or equivalent:
local RollbackHitbox = require(path.to.RollbackHitbox)
local RunService = game:GetService("RunService")

RunService.Heartbeat:Connect(function()
    RollbackHitbox.RecordAll(workspace:GetServerTimeNow())
end)
```

### 3. Register characters on spawn

```lua
Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function(character)
        character:WaitForChild("HumanoidRootPart")
        character:WaitForChild("Head")

        RollbackHitbox.AttachHitboxes(character)
        RollbackHitbox.RegisterCharacter(character)

        local humanoid = character:WaitForChild("Humanoid") :: Humanoid
        humanoid.Died:Once(function()
            RollbackHitbox.UnregisterCharacter(character)
            RollbackHitbox.RemoveHitboxes(character)
        end)
    end)
end)
```

### 4. Validate hits in your RemoteEvent handler

```lua
-- Client fires this remote with: origin, direction, timestamp
CombatRemotes.PlayerHit.OnServerEvent:Connect(function(
    shooter, targetUserId, shotOrigin, shotDirection, clientTimestamp
)
    local target = Players:GetPlayerByUserId(targetUserId)
    if not target or not target.Character then return end

    local isValid, isHeadshot, hitDistance = RollbackHitbox.ValidateHit(
        shooter,
        target.Character,
        shotOrigin,
        shotDirection,
        gunConfig.Range,         -- studs
        gunConfig.MuzzleOffset,  -- Vector3 offset from root to muzzle
        clientTimestamp          -- workspace:GetServerTimeNow() from client
    )

    if not isValid then return end

    local damage = isHeadshot and gunConfig.HeadDamage or gunConfig.Damage
    if hitDistance then
        -- Optional: linear falloff from 100% at 0 studs to 30% at max range
        local falloff = math.clamp(1 - 0.7 * (hitDistance / gunConfig.Range), 0.3, 1.0)
        damage *= falloff
    end

    target.Character.Humanoid:TakeDamage(damage)
end)
```

### 5. Client: send the timestamp

```lua
-- CombatController (client), inside your fire function:
local fireTimestamp = workspace:GetServerTimeNow()

-- ... raycast, visual effects ...

CombatRemotes.PlayerHit:FireServer(
    target.UserId,
    hitPoint,
    isHeadshot,
    shotOrigin,
    shotDirection,
    fireTimestamp   -- ← this is the key
)
```

---

## API Reference

All functions are accessed through the top-level `RollbackHitbox` module (`init.luau`).

### Hitbox lifecycle

| Function | Description |
|---|---|
| `AttachHitboxes(character: Model)` | Attach invisible `HitboxBody` and `HitboxHead` parts; disable `CanQuery` on all other BaseParts. |
| `RemoveHitboxes(character: Model)` | Destroy hitbox parts and clean up listeners. |
| `GetHitboxParts(character: Model)` | Returns `{ body: BasePart, head: BasePart }?` |

### Position history

| Function | Description |
|---|---|
| `RegisterCharacter(character: Model)` | Allocate snapshot buffer. Call after `AttachHitboxes`. |
| `UnregisterCharacter(character: Model)` | Free snapshot buffer. |
| `RecordAll(timestamp: number)` | Record one snapshot for every registered character. Call in `RunService.Heartbeat`. |
| `RecordSnapshot(character, timestamp)` | Record one snapshot for a single character. |
| `GetInterpolatedSnapshot(character, targetTime)` | Returns `{ PartHitbox }?` — interpolated body + head hitboxes at `targetTime`. |

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
| `shotOrigin` | World-space muzzle position at the moment of fire (client-sent). |
| `shotDirection` | Normalised shot direction (client-sent). |
| `gunRange` | Max effective range in studs. |
| `muzzleOffset` | `Vector3` from character root to muzzle tip. Used to widen origin tolerance. |
| `clientTimestamp` | `workspace:GetServerTimeNow()` captured on the client at fire time. Encodes latency implicitly — no separate ping measurement needed. Pass `nil` to skip rewind (treat as zero latency). |

**Returns:**
- `isValid` — `true` if the ray hit a rewound hitbox within range.
- `isHeadshot` — `true` if the head hitbox was hit (valid only when `isValid = true`).
- `hitDistance` — distance in studs along the ray to the hit point. Use for damage falloff.

---

## Config Reference

Edit `Config.luau` to tune the system for your game.

| Constant | Default | Unit | Purpose |
|---|---|---|---|
| `MAX_REWIND_SECONDS` | `0.5` | seconds | Hard cap on how far back the server will rewind. Raise for high-latency players; lower to tighten the anti-cheat window. |
| `INTERPOLATION_BUFFER` | `0.1` | seconds | Extra rewind to compensate for Roblox's ~20 Hz character replication delay. The client sees remote players delayed by at least one replication frame. |
| `MAX_ORIGIN_DISTANCE` | `12` | studs | Base tolerance for shot origin distance from the shooter's rewound position. |
| `MAX_PLAYER_SPEED` | `60` | studs/sec | Used to scale origin tolerance with latency. Set to the fastest your characters can move. |
| `BUFFER_CAPACITY` | `24` | snapshots | Circular buffer size per character. At 60 Hz this stores ~400 ms of history. Increase if you raise `MAX_REWIND_SECONDS`. |
| `BODY_HITBOX_SIZE` | `(4, 4, 3)` | studs | Width × height × depth of the body hitbox part. |
| `HEAD_HITBOX_SIZE` | `(2.5, 1.3, 2.5)` | studs | Dimensions of the head hitbox part. |
| `BODY_HITBOX_OFFSET` | `(0, -1, 0)` | CFrame | Body hitbox offset relative to `HumanoidRootPart`. |
| `HEAD_HITBOX_OFFSET` | `(0, 0.2, 0)` | CFrame | Head hitbox offset relative to `Head`. |
| `ROLLBACK_FORGIVENESS` | `(3, 3, 0)` | studs | Extra size added to each hitbox during the OBB test. Compensates for minor position prediction errors. Tune down for tighter accuracy. |
| `DEBUG` | `false` | bool | Spawn visible ghost boxes and ray parts in workspace for each validation. |
| `DEBUG_DURATION` | `1.5` | seconds | How long debug visuals persist before auto-cleanup. |

---

## Security notes

### What this protects against

- **Hit teleportation** — origin distance check bounds the shot to within reasonable range of the shooter's rewound position.
- **Timestamp manipulation** — `clientTimestamp` is clamped to `[0, MAX_REWIND_SECONDS]` before use; a client cannot claim an arbitrarily old position.
- **Headshot spoofing** — the server independently determines headshot vs. body-shot by which hitbox the rewound ray intersects; client claims are only used as a hint and are downgraded if unconfirmed.
- **Burst/pellet exploits** — rate-limit your hit remote on top of this (see the KLAD `CombatService` for an example using `_playerShotLog`).

### What this does not protect against

- A client can still send fabricated `shotOrigin` / `shotDirection` values. Origin is bounded by the distance check, but direction is trusted. Combine with server-side line-of-sight raycasts if you need stronger guarantees.
- This system does not prevent aimbots — it only ensures the shot the client claimed is geometrically plausible at the time it was fired.

---

## Rojo / Wally integration

The package has no external dependencies. To sync it with Rojo, add an entry to your `default.project.json`:

```json
"RollbackHitbox": {
    "$path": "Systems/RollbackHitbox"
}
```

Place it somewhere your server scripts can `require()` it (e.g. under `ServerScriptService`).

---

## License

MIT — free to use in any Roblox project, commercial or otherwise.
