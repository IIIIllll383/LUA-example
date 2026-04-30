local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")

local Controllers = require(script.Parent)
local MonetizationList = require(ReplicatedStorage.Shared.Misc.Monetization)
local Notification = require(ReplicatedStorage.Shared.Misc.Notification)
local TweenFov = require(ReplicatedStorage.Shared.Tweens.TweenFOV)

local Player = Players.LocalPlayer -- local player
local Camera = workspace.CurrentCamera -- current camera

local Remotes = ReplicatedStorage.Remotes

local TrollHandler = {}

-- spectating state
local spectatingIndex = 0 -- current index in player list
local playerList = {} -- list of players we can spectate
local spectating = false -- are we spectating right now

-- connections (so we can clean them up)
local charAddedConn = nil
local charDiedConn = nil

-- get all other alive players (ignore yourself)
local function getOtherPlayers()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		-- make sure player has a character + humanoid
		if p ~= Player and p.Character and p.Character:FindFirstChild("Humanoid") then
			table.insert(list, p)
		end
	end
	return list
end

-- disconnect old connections to avoid memory leaks
local function cleanupConnections()
	if charAddedConn then
		charAddedConn:Disconnect()
		charAddedConn = nil
	end
	if charDiedConn then
		charDiedConn:Disconnect()
		charDiedConn = nil
	end
end

-- spectate a specific player
local function spectatePlayer(targetPlayer)
	cleanupConnections() -- reset old listeners

	if not targetPlayer then return end

	-- attach camera to character
	local function attachCamera(character)
		local humanoid = character and character:FindFirstChild("Humanoid")

		if humanoid and spectating then
			Camera.CameraSubject = humanoid -- follow them

			-- if they die, reattach to new character
			if charDiedConn then charDiedConn:Disconnect() end
			charDiedConn = humanoid.Died:Connect(function()
				if not spectating then return end

				-- wait for respawn
				local newChar = targetPlayer.Character or targetPlayer.CharacterAdded:Wait()
				local newHumanoid = newChar:WaitForChild("Humanoid", 5)

				-- switch camera to new humanoid
				if newHumanoid and spectating then
					Camera.CameraSubject = newHumanoid
				end
			end)
		end
	end

	-- if already spawned, attach instantly
	if targetPlayer.Character then
		attachCamera(targetPlayer.Character)
	end

	-- also listen for respawns
	charAddedConn = targetPlayer.CharacterAdded:Connect(function(newChar)
		local humanoid = newChar:WaitForChild("Humanoid", 5)
		if humanoid and spectating then
			attachCamera(newChar)
		end
	end)
end

-- stop spectating and go back to your character
local function stopSpectating()
	spectating = false
	cleanupConnections()

	-- reset camera to yourself
	if Player.Character and Player.Character:FindFirstChild("Humanoid") then
		Camera.CameraSubject = Player.Character.Humanoid
	end
end

-- start spectating a random player
local function startSpectating()
	playerList = getOtherPlayers()

	-- no players = cancel
	if #playerList == 0 then
		spectating = false
		return
	end

	spectating = true
	spectatingIndex = math.random(1, #playerList) -- pick random player
	spectatePlayer(playerList[spectatingIndex])
end

-- switch between players (left/right buttons)
local function cyclePlayer(direction)
	playerList = getOtherPlayers()
	if #playerList == 0 then return end

	spectatingIndex = spectatingIndex + direction

	-- loop around list
	if spectatingIndex > #playerList then
		spectatingIndex = 1
	elseif spectatingIndex < 1 then
		spectatingIndex = #playerList
	end

	spectatePlayer(playerList[spectatingIndex])
end

-- get current target player
local function getSpectatedPlayer()
	if spectating and playerList[spectatingIndex] then
		return playerList[spectatingIndex]
	end
	return nil
end

function TrollHandler.Init(hud, dataReplica)
	local trollFrame = hud.Frames.Troll
	local trollButton = hud.HUD.Left.Troll
	local holdFrame = trollFrame.Hold
	local buttonsHold = trollFrame.ButtonsHold

	-- toggle troll menu
	trollButton.MouseButton1Click:Connect(function()
		-- if already open -> close
		if trollFrame.Visible then
			Controllers.ToggleFrame(trollFrame)
			return
		end

		-- check if there are players to troll
		local others = getOtherPlayers()
		if #others == 0 then
			Notification:New("No other players in the server!", 2, "Error")
			return
		end

		Controllers.ToggleFrame(trollFrame)

		-- remove blur + reset FOV so you can see
		if trollFrame.Visible then
			local blur = game.Lighting:FindFirstChildOfClass("BlurEffect")
			if blur then
				TweenService:Create(blur, TweenInfo.new(0.1), {Size = 0}):Play()
			end
			TweenFov(70, 0.1)
		end
	end)

	-- when UI opens/closes -> start/stop spectating
	trollFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if trollFrame.Visible then
			startSpectating()
		else
			stopSpectating()
		end
	end)

	-- if target leaves server, switch to another
	Players.PlayerRemoving:Connect(function(removedPlayer)
		if not spectating then return end

		local target = getSpectatedPlayer()
		if target == removedPlayer then
			playerList = getOtherPlayers()

			-- no players left
			if #playerList == 0 then
				stopSpectating()
				return
			end

			-- clamp index so it doesnt break
			spectatingIndex = math.clamp(spectatingIndex, 1, #playerList)
			spectatePlayer(playerList[spectatingIndex])
		end
	end)

	-- left button (previous player)
	buttonsHold.LeftButton.MouseButton1Click:Connect(function()
		cyclePlayer(-1)
	end)

	-- right button (next player)
	buttonsHold.RightButton.MouseButton1Click:Connect(function()
		cyclePlayer(1)
	end)

	-- exit button (close menu)
	buttonsHold.Exit.MouseButton1Click:Connect(function()
		Controllers.ToggleFrame(trollFrame)
	end)

	-- all troll actions
	local trollActions = {"Kill", "Explode", "Fling", "BecomeSmall", "GrowHuge", "QuickSand"}

	local TrollTarget = Remotes:WaitForChild("TrollTarget", 10)

	for _, actionName in ipairs(trollActions) do
		local actionFrame = holdFrame:FindFirstChild(actionName)
		if not actionFrame then continue end

		-- get product id for this action
		local productId = MonetizationList.products[actionName]
		if not productId or productId == 0 then continue end

		-- fetch robux price and display it
		task.spawn(function()
			local success, productInfo = pcall(
				MarketplaceService.GetProductInfo, MarketplaceService, productId, Enum.InfoType.Product
			)
			if success and productInfo and productInfo.PriceInRobux then
				local robuxIcon = actionFrame:FindFirstChild("RobuxIcon")
				if robuxIcon then
					local robuxLabel = robuxIcon:FindFirstChild("RobuxLabel")
					if robuxLabel then
						robuxLabel.Text = productInfo.PriceInRobux .. "R$"
					end
				end
			end
		end)

		-- when clicking a troll action
		local button = actionFrame:FindFirstChildWhichIsA("TextButton")
		if button then
			button.MouseButton1Click:Connect(function()
				local target = getSpectatedPlayer()
				if not target then return end

				-- send target to server (who to troll)
				if TrollTarget then
					TrollTarget:FireServer(target.UserId)
				end

				-- open purchase prompt
				MarketplaceService:PromptProductPurchase(Player, productId)
			end)
		end
	end
end

return TrollHandler
