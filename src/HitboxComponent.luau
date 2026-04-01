--!strict
-- RollbackHitbox / HitboxComponent.luau
--
-- Attaches two invisible hitbox parts (HitboxBody, HitboxHead) to a character
-- and disables CanQuery on every other BasePart so raycasts only hit the hitboxes.
--
-- Usage:
--   HitboxComponent.AttachHitboxes(character)
--   HitboxComponent.RemoveHitboxes(character)
--   HitboxComponent.GetHitboxParts(character)  → { body: BasePart, head: BasePart }?

local Config = require(script.Parent.Config)

local HitboxComponent = {}

local _hitboxParts: { [Model]: { body: BasePart, head: BasePart } } = {}
local _descendantConnections: { [Model]: RBXScriptConnection } = {}

-- ─── Internal helpers ──────────────────────────────────────────────────────────

local function createHitboxPart(name: string, size: Vector3, parentPart: BasePart, offset: CFrame): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true   -- raycasts CAN hit this
	part.Massless = true
	part.Anchored = false
	part.CFrame = parentPart.CFrame * offset
	part.Parent = parentPart.Parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = parentPart
	weld.Part1 = part
	weld.Parent = part

	return part
end

local function isHitboxPart(part: BasePart): boolean
	local name = part.Name
	return name == "HitboxBody" or name == "HitboxHead"
end

-- ─── Public API ───────────────────────────────────────────────────────────────

--- Attach invisible hitbox parts to `character` and disable CanQuery on all
--- other BaseParts so raycasts exclusively hit HitboxBody / HitboxHead.
function HitboxComponent.AttachHitboxes(character: Model)
	if _hitboxParts[character] then
		return -- already attached
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local headPart = character:FindFirstChild("Head") :: BasePart?
	if not rootPart or not headPart then
		warn("[RollbackHitbox] AttachHitboxes: missing HumanoidRootPart or Head for " .. character.Name)
		return
	end

	local body = createHitboxPart("HitboxBody", Config.BODY_HITBOX_SIZE, rootPart, Config.BODY_HITBOX_OFFSET)
	local head = createHitboxPart("HitboxHead", Config.HEAD_HITBOX_SIZE, headPart, Config.HEAD_HITBOX_OFFSET)

	-- Disable CanQuery on all existing non-hitbox parts (mesh, accessories, etc.)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and not isHitboxPart(descendant :: BasePart) then
			(descendant :: BasePart).CanQuery = false
		end
	end

	-- Handle accessories / tools that load after character spawn
	_descendantConnections[character] = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") and not isHitboxPart(descendant :: BasePart) then
			(descendant :: BasePart).CanQuery = false
		end
	end)

	_hitboxParts[character] = { body = body, head = head }
end

--- Returns the hitbox parts for `character`, or nil if not attached.
function HitboxComponent.GetHitboxParts(character: Model): { body: BasePart, head: BasePart }?
	return _hitboxParts[character]
end

--- Destroy hitbox parts and clean up connections for `character`.
--- Call this when the character dies or is removed.
function HitboxComponent.RemoveHitboxes(character: Model)
	local conn = _descendantConnections[character]
	if conn then
		conn:Disconnect()
		_descendantConnections[character] = nil
	end

	local parts = _hitboxParts[character]
	if not parts then
		return
	end

	parts.body:Destroy()
	parts.head:Destroy()
	_hitboxParts[character] = nil
end

return HitboxComponent
