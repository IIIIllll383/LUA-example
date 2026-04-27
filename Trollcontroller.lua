

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local TweenService = game:GetService("TweenService")

local Controllers = require(script.Parent)
local MonetizationList = require(ReplicatedStorage.Shared.Misc.Monetization)
local Notification = require(ReplicatedStorage.Shared.Misc.Notification)
local TweenFov = require(ReplicatedStorage.Shared.Tweens.TweenFOV)

local Player = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local Remotes = ReplicatedStorage.Remotes


local TrollHandler = {}

local spectatingIndex = 0
local playerList = {}
local spectating = false
local charAddedConn = nil
local charDiedConn = nil

local function getOtherPlayers()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= Player and p.Character and p.Character:FindFirstChild("Humanoid") then
			table.insert(list, p)
		end
	end
	return list
end

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

local function spectatePlayer(targetPlayer)
	cleanupConnections()

	if not targetPlayer then return end

	local function attachCamera(character)
		local humanoid = character and character:FindFirstChild("Humanoid")
		if humanoid and spectating then
			Camera.CameraSubject = humanoid

			-- Watch for this character dying so we follow the respawn
			if charDiedConn then charDiedConn:Disconnect() end
			charDiedConn = humanoid.Died:Connect(function()
				-- Wait for respawn and reattach
				if not spectating then return end
				local newChar = targetPlayer.Character or targetPlayer.CharacterAdded:Wait()
				local newHumanoid = newChar:WaitForChild("Humanoid", 5)
				if newHumanoid and spectating then
					Camera.CameraSubject = newHumanoid
				end
			end)
		end
	end

	if targetPlayer.Character then
		attachCamera(targetPlayer.Character)
	end

	-- Watch for character respawn
	charAddedConn = targetPlayer.CharacterAdded:Connect(function(newChar)
		local humanoid = newChar:WaitForChild("Humanoid", 5)
		if humanoid and spectating then
			attachCamera(newChar)
		end
	end)
end

local function stopSpectating()
	spectating = false
	cleanupConnections()
	if Player.Character and Player.Character:FindFirstChild("Humanoid") then
		Camera.CameraSubject = Player.Character.Humanoid
	end
end

local function startSpectating()
	playerList = getOtherPlayers()
	if #playerList == 0 then
		spectating = false
		return
	end

	spectating = true
	spectatingIndex = math.random(1, #playerList)
	spectatePlayer(playerList[spectatingIndex])
end

local function cyclePlayer(direction)
	playerList = getOtherPlayers()
	if #playerList == 0 then return end

	spectatingIndex = spectatingIndex + direction

	if spectatingIndex > #playerList then
		spectatingIndex = 1
	elseif spectatingIndex < 1 then
		spectatingIndex = #playerList
	end

	spectatePlayer(playerList[spectatingIndex])
end

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

	-- Handle Troll button click to toggle frame
	trollButton.MouseButton1Click:Connect(function()
		-- If already open, just close it
		if trollFrame.Visible then
			Controllers.ToggleFrame(trollFrame)
			return
		end

		-- Check for other players before opening
		local others = getOtherPlayers()
		if #others == 0 then
			Notification:New("No other players in the server!", 2, "Error")
			return
		end

		Controllers.ToggleFrame(trollFrame)

		-- Remove blur and reset FOV so the player can see who they're spectating
		if trollFrame.Visible then
			local blur = game.Lighting:FindFirstChildOfClass("BlurEffect")
			if blur then
				TweenService:Create(blur, TweenInfo.new(0.1), {Size = 0}):Play()
			end
			TweenFov(70, 0.1)
		end
	end)

	-- Listen for frame visibility to start/stop spectating
	trollFrame:GetPropertyChangedSignal("Visible"):Connect(function()
		if trollFrame.Visible then
			startSpectating()
		else
			stopSpectating()
		end
	end)

	-- Handle spectated player leaving
	Players.PlayerRemoving:Connect(function(removedPlayer)
		if not spectating then return end

		local target = getSpectatedPlayer()
		if target == removedPlayer then
			playerList = getOtherPlayers()
			if #playerList == 0 then
				stopSpectating()
				return
			end

			spectatingIndex = math.clamp(spectatingIndex, 1, #playerList)
			spectatePlayer(playerList[spectatingIndex])
		end
	end)

	-- Navigation buttons
	buttonsHold.LeftButton.MouseButton1Click:Connect(function()
		cyclePlayer(-1)
	end)

	buttonsHold.RightButton.MouseButton1Click:Connect(function()
		cyclePlayer(1)
	end)

	-- Exit button
	buttonsHold.Exit.MouseButton1Click:Connect(function()
		Controllers.ToggleFrame(trollFrame)
	end)

	-- Setup troll action buttons and prices
	local trollActions = {"Kill", "Explode", "Fling", "BecomeSmall", "GrowHuge", "QuickSand"}

	local TrollTarget = Remotes:WaitForChild("TrollTarget", 10)

	for _, actionName in ipairs(trollActions) do
		local actionFrame = holdFrame:FindFirstChild(actionName)
		if not actionFrame then continue end

		local productId = MonetizationList.products[actionName]
		if not productId or productId == 0 then continue end

		-- Set price label from DevProduct info
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

		-- Connect action button click
		local button = actionFrame:FindFirstChildWhichIsA("TextButton")
		if button then
			button.MouseButton1Click:Connect(function()
				local target = getSpectatedPlayer()
				if not target then return end

				if TrollTarget then
					TrollTarget:FireServer(target.UserId)
				end

				MarketplaceService:PromptProductPurchase(Player, productId)
			end)
		end
	end
end

return TrollHandler
