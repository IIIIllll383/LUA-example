-- Discord: f1reworks
--Roblox: F1reworksBot and F1re_Studios


--[[
	clientside controller for the troll menu. parent Controllers module
	requires it when the hud loads

	whats happening: theres a Troll button on the left of the HUD, click it
	and a menu opens with left/right arrows, an exit button and 6 action
	tiles (Kill Explode Fling BecomeSmall GrowHuge QuickSand). while its open
	your cam detaches from your char and follows someone else, the arrows
	cycle through everyone in the server. click a tile and it opens a robux
	prompt on whoever youre watching

	split into 3 layers so it doesnt become spagetti
	Maid: tiny cleanup helper, knows nothing about the game
	spectator: owns the cam + playerlist, has a Maid inside
	TrollHandler: hooks the hud buttons to a Spectator

	why split it: had it all in one scope before and conns kept leaking on
	respawn + the camera stuff was tangled with the ui stuff so touching one
	broke the other. now the ui layer is just plumbing, doesnt care how the
	cleanup or cam transitions work

	cleanup: every conn/tween gets handed to a Maid, call Destroy on the
	handle and it all tears down. no manual disconnects anywhere
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
-- tiny cleanup helper, track stuff and it kills it all at once
-- a task is one of:
-- connection -> :Disconnect()
-- instance -> :Destroy()
-- function -> just call it (pcall so a bad one doesnt kill the rest)
-- saw this in nevermore, mines way smaller i only need those 3
-- Spectator uses one for per target stuff and one for its lifetime
-- TrollHandler uses one for the button listeners

local Maid = {}
Maid.__index = Maid

-- metatable so :GiveTask etc resolve to the funcs below
function Maid.new()
	local self = setmetatable({}, Maid)
	self._tasks = {}
	return self
end

-- track a task and hand it back so you can do local c = maid:GiveTask(...)
function Maid:GiveTask(item)
	table.insert(self._tasks, item)
	return item
end

-- run all the cleanups then forget them
--[[ swap the list out first or you get re-entrant loops, if a cleanup
queues a new task it lands in the fresh list not the one were iterating ]]
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
			-- pcall so one bad cleanup doesnt kill the others
			pcall(item)
		end
	end
end

-- alias, roblox uses :Destroy() everywhere so might aswell match
Maid.Destroy = Maid.DoCleaning


-- Spectator
-- owns the cam while the menu is open. state:
-- _active: are we spectating rn
-- _index: where we are in _players
-- _players: snapshot of valid targets, rebuilt when needed
-- _maid: per target conns, wiped on every target switch
-- _globalMaid: lasts the whole spectator, wiped on Destroy

--[[ camera stuff: on a target switch we grab scriptable control, tween the
cam to a spot behind them then hand control back to the engine. two things
that took me forever:
  root.CFrame * offset -> post multiply keeps the offset in THEIR local
  space so it stays behind them no matter which way they face. pre
  multiplying put it in world space (cam always at world +Z, bad)
  has to be Scriptable while it tweens, on Custom the engine snaps the cam
  back to CameraSubject every frame and fights the tween = stutter. set it
  back to Custom when its done ]]

local Spectator = {}
Spectator.__index = Spectator

local TRANSITION_TIME = 0.35
local TRANSITION_STYLE = Enum.EasingStyle.Quad
local TRANSITION_DIRECTION = Enum.EasingDirection.Out

-- 5 up 8 back, in the targets local frame
local LOCAL_CAMERA_OFFSET = CFrame.new(0, 5, 8)
-- aim a bit above the root so its not all feet
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

-- fresh list of valid targets. valid = not me and has a humanoid
-- just rebuild on demand instead of a live list, looping <50 players is nothing
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

-- where the cam should end up, pulled the math out so its in one place
-- give it the root part, get a world cframe back for Camera.CFrame
function Spectator:_buildCameraCFrame(rootPart)
	local desiredPos = (rootPart.CFrame * LOCAL_CAMERA_OFFSET).Position
	local focusPos = rootPart.Position + FOCUS_OFFSET
	return CFrame.lookAt(desiredPos, focusPos)
end

-- tween the cam to a 3rd person view of the humanoid
-- no root part (mid respawn) -> just set the subject so we dont get stuck frozen in scriptable
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

	-- hand control back when its done, but only if it finished by itself and we still want to spectate
	-- Cancelled = they cycled away before this finished, next transition already set up so dont stomp it
	self._maid:GiveTask(tween.Completed:Connect(function(state)
		if self._active and state == Enum.PlaybackState.Completed then
			Camera.CameraType = Enum.CameraType.Custom
			Camera.CameraSubject = humanoid
		end
	end))

	-- if we tear down mid tween (menu closed, target left) cancel it or the cam keeps animating to an old spot
	self._maid:GiveTask(function() tween:Cancel() end)

	tween:Play()
end

-- listeners that keep the cam stuck to a target through respawns
-- runs on every target switch. wipe the per target maid first or they pile up
function Spectator:_attach(target)
	self._maid:DoCleaning()

	if not target or not self._active then return end

	-- bind to one char. need the same thing on first attach and every respawn so its its own func
	local function bind(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or not self._active then return end

		self:_transitionCameraTo(humanoid)

		-- on death wait for the next char and rebind. WaitForChild 5s timeout so a stuck respawn cant hang this thread
		self._maid:GiveTask(humanoid.Died:Connect(function()
			if not self._active then return end
			local nextChar = target.Character or target.CharacterAdded:Wait()
			local nextHum = nextChar:WaitForChild("Humanoid", 5)
			if nextHum and self._active then
				self:_transitionCameraTo(nextHum)
			end
		end))
	end

	-- attach now if they already got a char
	if target.Character then
		bind(target.Character)
	end

	-- catch later char swaps (LoadCharacter, dev respawns). Died only covers normal deaths, this gets the rest
	self._maid:GiveTask(target.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 5)
		if humanoid and self._active then
			bind(character)
		end
	end))
end

-- start spectating. returns false if theres no one to watch so the caller can show an error instead
function Spectator:Start()
	self._players = self:_collectPlayers()
	if #self._players == 0 then
		self._active = false
		return false
	end

	self._active = true

	-- random start so 2 ppl opening the menu at once dont always land on the same guy. tiny thing but feels less robotic
	self._index = math.random(1, #self._players)
	self:_attach(self._players[self._index])
	return true
end

-- stop and give the cam back to us
-- set _active false BEFORE cleaning or stuff firing mid teardown sees the wrong state
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

-- step through the list, +1 next -1 prev
-- rebuild each time so new joins show up and leavers drop out
-- wraps at the ends so you just loop instead of getting stuck
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

-- who were watching, nil if not active
function Spectator:GetTarget()
	if self._active and self._players[self._index] then
		return self._players[self._index]
	end
	return nil
end

-- target speed in studs/s
-- AssemblyLinearVelocity is the real post physics velocity, most accurate one. .Magnitude makes it a single number
function Spectator:GetTargetSpeed()
	local target = self:GetTarget()
	if not target or not target.Character then return 0 end
	local root = target.Character:FindFirstChild("HumanoidRootPart")
	if not root then return 0 end
	return root.AssemblyLinearVelocity.Magnitude
end

-- distance from us to the target in studs
function Spectator:GetTargetDistance()
	local target = self:GetTarget()
	if not target or not target.Character then return 0 end
	if not Player.Character then return 0 end

	local theirRoot = target.Character:FindFirstChild("HumanoidRootPart")
	local ourRoot = Player.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot or not ourRoot then return 0 end

	return (theirRoot.Position - ourRoot.Position).Magnitude
end

-- called from TrollHandler when anyone leaves
-- only do something if it was the guy were watching
-- clamp instead of resetting to 1 so you keep roughly your spot
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

-- nuke everything. Stop does the per target maid, then clear the global one incase smth got added there
function Spectator:Destroy()
	self:Stop()
	self._globalMaid:DoCleaning()
end


-- TrollHandler
-- the actual module. HUD setup calls TrollHandler.Init with the HUD gui and the data replica
-- it wires up the buttons and hands back a handle with a Destroy
-- split the setup into helper funcs below so each thing stays in its own scope

local TrollHandler = {}

-- true if anyone else is in the server, checked before opening the menu
-- lighter than _collectPlayers, dont care if their humanoid loaded here just if youre alone
local function anyOtherPlayersPresent()
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= Player then
			return true
		end
	end
	return false
end

-- kill the bg blur and put fov back to 70
-- other menus blur/zoom for effect, here we want a clean view so you can see the guy youre watching
local function clearBlurAndResetFov()
	local blur = Lighting:FindFirstChildOfClass("BlurEffect")
	if blur then
		TweenService:Create(blur, TweenInfo.new(0.1), { Size = 0 }):Play()
	end
	TweenFov(70, 0.1)
end

-- grab the robux price for a product and slap it on the button
-- own thread since GetProductInfo yields (web call, few hundred ms) and i dont want it holding up the rest of setup
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

-- wire up one action tile (Kill Explode etc)
-- bails quietly if the tile is missing, has no product id, or no button inside
-- click listener on the maid so it cleans up with the rest
local function setupActionButton(actionFrame, productId, spectator, trollTargetRemote, maid)
	if not actionFrame then return end
	if not productId or productId == 0 then return end

	populatePriceLabel(actionFrame, productId)

	local button = actionFrame:FindFirstChildWhichIsA("TextButton")
	if not button then return end

	maid:GiveTask(button.MouseButton1Click:Connect(function()
		local target = spectator:GetTarget()
		if not target then return end

		-- 2 steps:
		-- 1) tell the server the target. send UserId not the Player instance, server rechecks the id against its own list. never trust a client instance
		-- 2) open the prompt. if they pay, ProcessReceipt on the server reads the stored target and applies the effect
		if trollTargetRemote then
			trollTargetRemote:FireServer(target.UserId)
		end

		MarketplaceService:PromptProductPurchase(Player, productId)
	end))
end

-- optional speed/dist label, only runs if theres a SpeedLabel TextLabel in the frame
-- RenderStepped so we read velocity after the physics step (freshest)
-- skips everything while the menu is hidden, no point updating
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

-- main open/close button
--   already open -> close it
--   nobody else here -> error notif, dont open
--   else -> open + clear blur/reset fov
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

-- frame visibility is the one source of truth for spectating
-- anything that hides the frame (exit, esc, parent destroy) fires Stop without knowing the spectator exists
-- anything that shows it fires Start
local function setupVisibilityHook(trollFrame, spectator, maid)
	maid:GiveTask(trollFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if trollFrame.Visible then
			spectator:Start()
		else
			spectator:Stop()
		end
	end))
end

-- pass PlayerRemoving to the spectator so the someone-left logic lives with the rest of it not spread out here
local function setupPlayerLeaveHook(spectator, maid)
	maid:GiveTask(Players.PlayerRemoving:Connect(function(removed)
		spectator:HandlePlayerRemoving(removed)
	end))
end

-- left/right cycle buttons + exit. left = prev right = next, exit closes the menu (fires Stop via the visibility hook)
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

-- run through the action names, find each in holdFrame and hook it up with setupActionButton
local function setupActionButtons(holdFrame, spectator, maid)
	local trollActions = { "Kill", "Explode", "Fling", "BecomeSmall", "GrowHuge", "QuickSand" }
	local trollTargetRemote = Remotes:WaitForChild("TrollTarget", 10)

	for _, actionName in ipairs(trollActions) do
		local actionFrame = holdFrame:FindFirstChild(actionName)
		local productId = MonetizationList.products[actionName]
		setupActionButton(actionFrame, productId, spectator, trollTargetRemote, maid)
	end
end

-- entry point, parent Controllers calls this during HUD setup
-- make a Spectator + Maid, run the setup helpers in order, hand back a handle whose Destroy tears it all down
function TrollHandler.Init(hud, dataReplica)
	local trollFrame = hud.Frames.Troll
	local trollButton = hud.HUD.Left.Troll
	local holdFrame = trollFrame.Hold
	local buttonsHold = trollFrame.ButtonsHold

	local spectator = Spectator.new()
	local maid = Maid.new()

	-- order matters a bit:
	--  1) speed readout first so its already polling before anything can trigger spectating
	--  2) toggle before the visibility hook so it doesnt fire visibility on a half built state (mostly defensive, theyre decoupled anyway)
	--  3) action buttons last, they wait on the remote (10s WaitForChild) which can block for a sec
	setupSpeedReadout(trollFrame, spectator, maid)
	setupTrollToggle(trollButton, trollFrame, maid)
	setupVisibilityHook(trollFrame, spectator, maid)
	setupPlayerLeaveHook(spectator, maid)
	setupCycleButtons(buttonsHold, trollFrame, spectator, maid)
	setupActionButtons(holdFrame, spectator, maid)

	-- handle for the parent
	-- Destroy tears down the spectator (cam + per target conns) and the ui maid (every listener above)
	-- this is the only teardown path, nothing else needs manual cleanup
	return {
		Destroy = function()
			spectator:Destroy()
			maid:DoCleaning()
		end,
	}
end

-- didn't think I would need this many comments.

return TrollHandler
