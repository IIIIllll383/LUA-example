-- Discord: f1reworks
--Roblox: F1reworksBot and F1re_Studios


--[[
	TrollHandler.lua

	Client-side controller for the in-game troll menu. Lives under the
	HUD controllers folder and is required by the parent Controllers
	module during HUD setup.

	WHAT THE PLAYER SEES
	The HUD has a "Troll" button on the left side. Clicking it opens a
	menu containing left/right cycle arrows, an exit button, and 6
	action tiles (Kill, Explode, Fling, BecomeSmall, GrowHuge,
	QuickSand). While the menu is open the camera detaches from their
	own character and follows another player. The cycle arrows step
	through the other players in the server. Clicking an action tile
	prompts a Robux purchase aimed at whoever is currently being
	watched.

	HOW THE PIECES INTERACT

	The module is split into 3 layers:

	  Maid       (lowest)   pure utility, no Roblox knowledge beyond
	                        recognising connection/instance types.
	                        used by the other two layers.

	  Spectator  (middle)   owns the camera + playerlist state. uses
	                        a Maid internally to keep its own
	                        connections tidy. exposes a small public
	                        surface (Start / Stop / Cycle / GetTarget
	                        / Destroy) that the top layer drives.

	  TrollHandler (top)    wires the HUDs buttons to a Spectator
	                        instance and to the TrollTarget remote.
	                        owns its own Maid for the UI listeners.

	Data flow when the player clicks an action tile:
	  HUD button then TrollHandler click handler then Spectator:GetTarget()
	  then TrollTarget:FireServer(userId) then server stores intent
	  then MarketplaceService:PromptProductPurchase then player buys
	  then ProcessReceipt on server reads stored intent, applies effect.

	Data flow when the spectated player dies:
	  Humanoid.Died fires Spectators per-target Maid callback then
	  waits for CharacterAdded, rebinds the camera to the new
	  Humanoid via _transitionCameraTo.

	Why split this way:
	The original was a single flat scope with module-level upvalues
	for state. Two problems with that. First, connection lifetimes
	were scattered (some manually disconnected, some leaked on
	respawn). Second, the camera/state code was tangled with UI code,
	so changing one risked breaking the other. Pushing the camera
	state into a class (Spectator) and the cleanup into a Maid means
	the UI layer is just plumbing -- it doesnt have to know how
	cleanup works or how the camera transitions, it just calls
	methods.

	Lifetime guarantee:
	Every connection / tween made in this module is registered with
	either the Spectator's Maid or TrollHandler's Maid. Calling
	Destroy on the returned handle tears them all down. No manual
	disconnect calls are needed anywhere outside the Maid.
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Controllers = require(script.Parent)
local MonetizationList = require(ReplicatedStorage.Shared.Misc.Monetization)
local Notification = require(ReplicatedStorage.Shared.Misc.Notification)
local TweenFov = require(ReplicatedStorage.Shared.Tweens.TweenFOV)

local Player = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local Remotes = ReplicatedStorage.Remotes


-- Maid
-- Generic disposable manager. Holds a list of "tasks" and cleans them
-- all in one go. A task can be:
--   RBXScriptConnection -- gets :Disconnect()
--   Instance            -- gets :Destroy()
--   function            -- just runs (in pcall for safety if it errors)
--
-- Inspired by NevermoreEngine but kept tiny since i
-- only need three task types here. The Spectator class uses one Maid
-- for per-target state (cleared on every target switch) and a second
-- Maid for global state (cleared on Destroy). TrollHandler.Init uses
-- its own Maid for the UI button listeners.
--
-- Why metatables: setmetatable({}, Maid) creates a
-- new table whose missing keys fall through to the Maid table via
-- __index. So instance:GiveTask(...) actually finds GiveTask on Maid
-- and calls it with the instance as `self´. Without __index = Maid
-- the lookup would return nil and the call would error.

local Maid = {}
Maid.__index = Maid

function Maid.new()
	local self = setmetatable({}, Maid)
	self._tasks = {}
	return self
end

-- registers a task. returns it back so callers can chain or store it
-- without a separate local var:  local conn = maid:GiveTask(sig:Connect(...))
function Maid:GiveTask(item)
	table.insert(self._tasks, item)
	return item
end

-- runs all registered cleanups, then forgets them.
-- the snapshot-swap trick: if a cleanup callback queues a NEW task
-- (e.g. a tween that, on cancel, schedules a follow-up), it lands
-- in the fresh _tasks list rather than the one we're iterating.
-- without this you can get re-entrant cleanup loops.
function Maid:DoCleaning()
	local snapshot = self._tasks
	self._tasks = {}

	for _, item in ipairs(snapshot) do
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			item:Disconnect()
		elseif kind == "Instance" then
			item:Destroy()
		elseif kind == "function" then
			-- pcall isolates failures: one bad cleanup wont take the
			-- rest of the cleanup chain down with it
			pcall(item)
		end
	end
end

-- alias so callers can use either name. Roblox API uses :Destroy() as
-- the standard "release this resource" verb so we mirror it.
Maid.Destroy = Maid.DoCleaning


-- Spectator 
-- Owns the camera while the troll menu is open. Internal state:
--   _active      bool   are we currently spectating
--   _index       int    where in _players we are
--   _players     list   snapshot of valid targets (rebuilt as needed)
--   _maid        Maid   per-target connections, cleared on switch
--   _globalMaid  Maid   spectator-lifetime, cleared on Destroy
--
-- Camera transition explained:
-- When we switch to a new target we briefly take scriptable control of
-- the camera and tween its CFrame to a third-person spot behind the
-- target, then hand control back to the engine by setting CameraSubject.
-- The relevant CFrame math:
--
--   root.CFrame * CFrame.new(0, 5, 8)
--     post-multiplying a translation puts the offset in the targets
--     LOCAL space, so it stays "5 up, 8 behind" no matter which way
--     they face. pre-multiplying would put it in world space, which
--     would mean the camera always sits at world +Z regardless of
--     player rotation -- not what we want.
--
--   CFrame.lookAt(eye, focus)
--     builds a CFrame whose -Z axis points from eye to focus. we focus
--     2 studs above the root part so the camera frames the torso /
--     head instead of the feet.
--
-- Why scriptable during the tween:
-- on CameraType.Custom the engine continuously snaps the camera back
-- to whatever CameraSubject is set to, every frame. if we tweened on
-- Custom the engine would fight the tween and the user would see
-- stuttering. Scriptable disables that auto-follow so the tween runs
-- cleanly. once the tween completes we set CameraType back to Custom
-- and CameraSubject to the new humanoid -- from there the engine's
-- normal third-person follow takes over.

local Spectator = {}
Spectator.__index = Spectator

local TRANSITION_TIME = 0.35
local TRANSITION_STYLE = Enum.EasingStyle.Quad
local TRANSITION_DIRECTION = Enum.EasingDirection.Out

-- 5 studs up, 8 studs behind, expressed in the target's local frame
local LOCAL_CAMERA_OFFSET = CFrame.new(0, 5, 8)
-- look slightly above the root part so the framing isnt feet-first
local FOCUS_OFFSET = Vector3.new(0, 2, 0)

function Spectator.new()
	local self = setmetatable({}, Spectator)
	self._active = false
	self._index = 0
	self._players = {}
	self._maid = Maid.new()
	self._globalMaid = Maid.new()
	return self
end

-- builds a fresh list of valid targets. valid = not us, and has a
-- humanoid loaded. we rebuild on demand (rather than keeping a live
-- list) because the player set changes infrequently and an O(n) scan
-- of <50 players is cheap.
function Spectator:_collectPlayers()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= Player then
			local character = plr.Character
			if character and character:FindFirstChildOfClass("Humanoid") then
				table.insert(list, plr)
			end
		end
	end
	return list
end

-- builds the destination CFrame for the camera tween.
-- pulled out into its own function so the math is in one readable
-- place instead of inline. takes the rootPart whose space we're
-- positioning relative to, returns a world-space CFrame ready to
-- assign to Camera.CFrame.
function Spectator:_buildCameraCFrame(rootPart)
	local desiredPos = (rootPart.CFrame * LOCAL_CAMERA_OFFSET).Position
	local focusPos = rootPart.Position + FOCUS_OFFSET
	return CFrame.lookAt(desiredPos, focusPos)
end

-- tweens the camera to a third-person view of the given humanoid.
-- if the humanoid has no root part (rare, mid-respawn) we just
-- assign the subject directly so the camera doesnt end up frozen
-- in scriptable mode with no tween running.
function Spectator:_transitionCameraTo(humanoid)
	local character = humanoid.Parent
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	if not rootPart then
		Camera.CameraType = Enum.CameraType.Custom
		Camera.CameraSubject = humanoid
		return
	end

	Camera.CameraType = Enum.CameraType.Scriptable

	local targetCF = self:_buildCameraCFrame(rootPart)
	local tweenInfo = TweenInfo.new(TRANSITION_TIME, TRANSITION_STYLE, TRANSITION_DIRECTION)
	local tween = TweenService:Create(Camera, tweenInfo, { CFrame = targetCF })

	-- on completion, hand control back to the engine. but only if
	-- the tween finished naturally AND we still want to spectate.
	-- Cancelled = user cycled to another target before this tween
	-- finished -- in that case the next _transitionCameraTo call
	-- already set up the new state, so we shouldnt overwrite it.
	self._maid:GiveTask(tween.Completed:Connect(function(state)
		if self._active and state == Enum.PlaybackState.Completed then
			Camera.CameraType = Enum.CameraType.Custom
			Camera.CameraSubject = humanoid
		end
	end))

	-- if we tear down before completion (user closed the menu, target
	-- left, etc) cancel the tween so the camera isnt stuck animating
	-- to a stale destination.
	self._maid:GiveTask(function() tween:Cancel() end)

	tween:Play()
end

-- sets up the listeners that keep the camera glued to a target
-- across respawns. called every time we switch targets. clears
-- the per-target Maid first so old listeners dont stack up.
function Spectator:_attach(target)
	self._maid:DoCleaning()

	if not target or not self._active then return end

	-- helper: bind to one specific character. used both for the
	-- initial attach and every respawn after. pulled out because
	-- we need the same logic in two places.
	local function bind(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or not self._active then return end

		self:_transitionCameraTo(humanoid)

		-- when this character dies, wait for the next one and rebind.
		-- WaitForChild has a 5s timeout so a stuck respawn cant pin
		-- this thread forever. CharacterAdded:Wait yields until they
		-- actually respawn.
		self._maid:GiveTask(humanoid.Died:Connect(function()
			if not self._active then return end
			local nextChar = target.Character or target.CharacterAdded:Wait()
			local nextHum = nextChar:WaitForChild("Humanoid", 5)
			if nextHum and self._active then
				self:_transitionCameraTo(nextHum)
			end
		end))
	end

	-- attach immediately if the target already has a character
	if target.Character then
		bind(target.Character)
	end

	-- catch any later character replacement (manual LoadCharacter,
	-- dev-triggered respawn etc.). the Died handler above only fires
	-- when a humanoid dies normally; CharacterAdded covers everything
	-- else.
	self._maid:GiveTask(target.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid and self._active then
			bind(character)
		end
	end))
end

-- public: begin spectating. returns false if no valid targets exist
-- so callers can show an error notification instead of leaving the
-- camera in a weird state.
function Spectator:Start()
	self._players = self:_collectPlayers()
	if #self._players == 0 then
		self._active = false
		return false
	end

	self._active = true

	-- random start so two clients opening the menu simultaneously
	-- dont always end up on the same player. small detail but it
	-- makes the spectator feel less mechanical.
	self._index = math.random(1, #self._players)
	self:_attach(self._players[self._index])
	return true
end

-- public: stop spectating, return camera to local player. ordering
-- matters: set _active = false BEFORE DoCleaning so any callbacks
-- that fire mid-teardown see the right state.
function Spectator:Stop()
	self._active = false
	self._maid:DoCleaning()

	Camera.CameraType = Enum.CameraType.Custom

	local character = Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		Camera.CameraSubject = humanoid
	end
end

-- public: step through the player list. +1 = next, -1 = prev.
-- list is rebuilt every cycle so newly-joined players become
-- selectable and leavers fall out automatically. wraps around at
-- the ends -- holding the cycle button just rotates instead of
-- getting stuck.
function Spectator:Cycle(direction)
	self._players = self:_collectPlayers()
	if #self._players == 0 then return end

	self._index = self._index + direction

	if self._index > #self._players then
		self._index = 1
	elseif self._index < 1 then
		self._index = #self._players
	end

	self:_attach(self._players[self._index])
end

-- public: who are we currently watching? returns nil when inactive.
function Spectator:GetTarget()
	if self._active and self._players[self._index] then
		return self._players[self._index]
	end
	return nil
end

-- public: how fast is the target moving, in studs/sec.
-- AssemblyLinearVelocity is the post-physics-step velocity Roblox
-- uses internally for collision response and replication, so its
-- the most accurate "true speed" reading. .Magnitude collapses the
-- Vector3 to its scalar length.
function Spectator:GetTargetSpeed()
	local target = self:GetTarget()
	if not target or not target.Character then return 0 end
	local root = target.Character:FindFirstChild("HumanoidRootPart")
	if not root then return 0 end
	return root.AssemblyLinearVelocity.Magnitude
end

-- public: distance from us to the target in studs. (a - b).Magnitude
-- is the standard Roblox idiom for euclidean distance between two
-- Vector3 positions.
function Spectator:GetTargetDistance()
	local target = self:GetTarget()
	if not target or not target.Character then return 0 end
	if not Player.Character then return 0 end

	local theirRoot = target.Character:FindFirstChild("HumanoidRootPart")
	local ourRoot = Player.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot or not ourRoot then return 0 end

	return (theirRoot.Position - ourRoot.Position).Magnitude
end

-- public: called from TrollHandler when ANY player leaves. only acts
-- if the leaver was our current target -- otherwise we ignore. clamp
-- (instead of resetting to 1) so the user keeps roughly their place
-- in the list when someone leaves.
function Spectator:HandlePlayerRemoving(removed)
	if not self._active then return end
	if self:GetTarget() ~= removed then return end

	self._players = self:_collectPlayers()
	if #self._players == 0 then
		self:Stop()
		return
	end

	self._index = math.clamp(self._index, 1, #self._players)
	self:_attach(self._players[self._index])
end

-- public: full teardown. Stop releases the per-target maid, then we
-- clear the global maid in case anything was registered there.
function Spectator:Destroy()
	self:Stop()
	self._globalMaid:DoCleaning()
end


-- == TrollHandler ==
-- Public module. The HUD setup code calls TrollHandler.Init with the
-- HUD ScreenGui and the player's data replica. Init wires up all the
-- buttons and returns a handle with a Destroy method.
--
-- Init is broken into helper functions below to keep each concern in
-- its own scope. Order they're called in: setupSpeedReadout,
-- setupTrollToggle, setupVisibilityHook, setupPlayerLeaveHook,
-- setupCycleButtons, setupActionButtons.

local TrollHandler = {}

-- helper: returns true if any other player exists in the server.
-- used as a precondition before opening the menu. cheaper than
-- _collectPlayers because we dont care if their humanoids are
-- loaded yet -- we just want to know if youre alone.
local function anyOtherPlayersPresent()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= Player then
			return true
		end
	end
	return false
end

-- helper: removes the background blur (if any) and resets FOV to 70.
-- other menus in this game blur/zoom for dramatic effect; the troll
-- menu specifically wants a clean view of the world so the user can
-- see the player theyre watching.
local function clearBlurAndResetFov()
	local blur = Lighting:FindFirstChildOfClass("BlurEffect")
	if blur then
		TweenService:Create(blur, TweenInfo.new(0.1), { Size = 0 }):Play()
	end
	TweenFov(70, 0.1)
end

-- helper: asynchronously fetch the Robux price for a developer
-- product and write it into the matching button label. spawned in
-- a separate thread because GetProductInfo is a yielding web call
-- that can take a few hundred ms; running it sequentially would
-- delay the rest of the UI setup.
local function populatePriceLabel(actionFrame, productId)
	task.spawn(function()
		local ok, info = pcall(
			MarketplaceService.GetProductInfo,
			MarketplaceService,
			productId,
			Enum.InfoType.Product
		)
		if ok and info and info.PriceInRobux then
			local robuxIcon = actionFrame:FindFirstChild("RobuxIcon")
			local robuxLabel = robuxIcon and robuxIcon:FindFirstChild("RobuxLabel")
			if robuxLabel then
				robuxLabel.Text = info.PriceInRobux .. "R$"
			end
		end
	end)
end

-- helper: wires up one action tile (Kill, Explode, etc.).
-- returns silently if the tile is missing, has no product id, or has
-- no clickable button child. registers the click listener on the
-- given Maid so it gets cleaned up with the rest of the handler.
local function setupActionButton(actionFrame, productId, spectator, trollTargetRemote, maid)
	if not actionFrame then return end
	if not productId or productId == 0 then return end

	populatePriceLabel(actionFrame, productId)

	local button = actionFrame:FindFirstChildWhichIsA("TextButton")
	if not button then return end

	maid:GiveTask(button.MouseButton1Click:Connect(function()
		local target = spectator:GetTarget()
		if not target then return end

		-- two-step interaction:
		-- 1) tell the server who the target is. we send UserId rather
		--    than the Player instance because the server validates the
		--    id against its own Players list -- never trust an instance
		--    ref from the client, it could be tampered with.
		-- 2) open the purchase prompt. if the player completes payment,
		--    the server's ProcessReceipt callback reads the stored
		--    target and applies the troll effect there.
		if trollTargetRemote then
			trollTargetRemote:FireServer(target.UserId)
		end

		MarketplaceService:PromptProductPurchase(Player, productId)
	end))
end

-- helper: wires up the optional speed/distance readout label. only
-- runs if the troll frame has a child named "SpeedLabel" of type
-- TextLabel. uses RenderStepped so the velocity read happens after
-- physics step, giving us the freshest value. skips the work
-- entirely while the menu is hidden to avoid wasted updates.
local function setupSpeedReadout(trollFrame, spectator, maid)
	local speedLabel = trollFrame:FindFirstChild("SpeedLabel")
	if not speedLabel or not speedLabel:IsA("TextLabel") then return end

	maid:GiveTask(RunService.RenderStepped:Connect(function()
		if not trollFrame.Visible then return end
		local speed = spectator:GetTargetSpeed()
		local distance = spectator:GetTargetDistance()
		speedLabel.Text = string.format("Speed: %.1f studs/s | Dist: %.0f", speed, distance)
	end))
end

-- helper: wires the main HUD button that opens/closes the menu.
-- behaviour:
--   already open then close (toggle)
--   no other players then show error notif, dont open
--   otherwise then open, then clear blur + reset FOV
local function setupTrollToggle(trollButton, trollFrame, maid)
	maid:GiveTask(trollButton.MouseButton1Click:Connect(function()
		if trollFrame.Visible then
			Controllers.ToggleFrame(trollFrame)
			return
		end

		if not anyOtherPlayersPresent() then
			Notification:New("No other players in the server!", 2, "Error")
			return
		end

		Controllers.ToggleFrame(trollFrame)

		if trollFrame.Visible then
			clearBlurAndResetFov()
		end
	end))
end

-- helper: makes frame visibility the single source of truth for
-- spectating. any code path that hides the frame (Exit button, ESC
-- key, parent destroy) will trigger Stop without that code path
-- having to know about the spectator. likewise any path that shows
-- the frame triggers Start.
local function setupVisibilityHook(trollFrame, spectator, maid)
	maid:GiveTask(trollFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if trollFrame.Visible then
			spectator:Start()
		else
			spectator:Stop()
		end
	end))
end

-- helper: forwards Players.PlayerRemoving to the spectator so the
-- "what do we do when someone leaves" policy lives next to the
-- rest of the spectator state instead of being smeared across
-- TrollHandler.
local function setupPlayerLeaveHook(spectator, maid)
	maid:GiveTask(Players.PlayerRemoving:Connect(function(removed)
		spectator:HandlePlayerRemoving(removed)
	end))
end

-- helper: wires the left/right cycle buttons + the exit button.
-- left = previous target, right = next target, exit = close menu
-- (which through setupVisibilityHook triggers Stop).
local function setupCycleButtons(buttonsHold, trollFrame, spectator, maid)
	maid:GiveTask(buttonsHold.LeftButton.MouseButton1Click:Connect(function()
		spectator:Cycle(-1)
	end))

	maid:GiveTask(buttonsHold.RightButton.MouseButton1Click:Connect(function()
		spectator:Cycle(1)
	end))

	maid:GiveTask(buttonsHold.Exit.MouseButton1Click:Connect(function()
		Controllers.ToggleFrame(trollFrame)
	end))
end

-- helper: walks the list of action names, looks each one up in the
-- HUD's holdFrame, and wires up the click handler via setupActionButton.
local function setupActionButtons(holdFrame, spectator, maid)
	local trollActions = { "Kill", "Explode", "Fling", "BecomeSmall", "GrowHuge", "QuickSand" }
	local trollTargetRemote = Remotes:WaitForChild("TrollTarget", 10)

	for _, actionName in ipairs(trollActions) do
		local actionFrame = holdFrame:FindFirstChild(actionName)
		local productId = MonetizationList.products[actionName]
		setupActionButton(actionFrame, productId, spectator, trollTargetRemote, maid)
	end
end

-- public entry point. called by the parent Controllers module during
-- HUD initialisation. constructs a Spectator + Maid pair, then runs
-- each setup helper in order. returns a handle whose Destroy method
-- fully tears the handler down.
function TrollHandler.Init(hud, dataReplica)
	local trollFrame = hud.Frames.Troll
	local trollButton = hud.HUD.Left.Troll
	local holdFrame = trollFrame.Hold
	local buttonsHold = trollFrame.ButtonsHold

	local spectator = Spectator.new()
	local maid = Maid.new()

	-- order matters slightly:
	--  1) speed readout first so its already polling by the time
	--     anything else might trigger spectating
	--  2) toggle hook before visibility hook so the toggle doesnt
	--     fire visibility on a half-set-up state (defensive only;
	--     these are decoupled but still nice to have a clear order)
	--  3) action buttons last because they depend on the remote,
	--     which has a 10s WaitForChild that could block briefly
	setupSpeedReadout(trollFrame, spectator, maid)
	setupTrollToggle(trollButton, trollFrame, maid)
	setupVisibilityHook(trollFrame, spectator, maid)
	setupPlayerLeaveHook(spectator, maid)
	setupCycleButtons(buttonsHold, trollFrame, spectator, maid)
	setupActionButtons(holdFrame, spectator, maid)

	-- handle for the parent module. calling Destroy on the returned
	-- table tears down both the spectator (camera + per-target conns)
	-- and the UI maid (every button listener registered above). this
	-- is the SOLE teardown path -- nothing in this module needs to
	-- be cleaned up manually outside of these two calls.
	return {
		Destroy = function()
			spectator:Destroy()
			maid:DoCleaning()
		end,
	}
end

-- didn't think I would need this many comments. not used to make that many since I'm a solo dev :)

return TrollHandler
