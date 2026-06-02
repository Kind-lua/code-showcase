-- Handles physical destruction, visual feedback, and smooth automatic reconstruction of the city.

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local SmallCity = Workspace:WaitForChild("SmallCity")

-- Helper function to retrieve or create RemoteEvents for network replication
local function getOrCreateRemote(className, name, parent)
    local remote = parent:FindFirstChild(name)
    if not remote then
        remote = Instance.new(className)
        remote.Name = name
        remote.Parent = parent
    end
    return remote
end

local LaunchRocketEvent = getOrCreateRemote("RemoteEvent", "LaunchRocketEvent", ReplicatedStorage)
local RebuildCityEvent = getOrCreateRemote("RemoteEvent", "RebuildCityEvent", ReplicatedStorage)

-- Cache to store initial transformations, visual states, and collision properties
local originalStates = {}

local function cachePartState(part)
    if not part:IsA("BasePart") then return end
    originalStates[part] = {
        CFrame = part.CFrame,
        Size = part.Size,
        Color = part.Color,
        Transparency = part.Transparency,
        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        Parent = part.Parent,
        Anchored = part.Anchored,
        BrickColor = part.BrickColor,
        Material = part.Material,
        MaterialVariant = part.MaterialVariant
    }
end

-- Initialize the original state database at script startup
for _, part in ipairs(SmallCity:GetDescendants()) do
    if part:IsA("BasePart") then
        cachePartState(part)
    end
end

-- Server-side rocket projectile handler and travel simulation
LaunchRocketEvent.OnServerEvent:Connect(function(player, spawnPos, targetPos)
    local char = player.Character
    if not char then return end
    
    local rocket = Instance.new("Part")
    rocket.Name = "RocketProjectile"
    rocket.Size = Vector3.new(0.6, 0.6, 2.0)
    rocket.BrickColor = BrickColor.new("Bright red")
    rocket.Color = rocket.BrickColor.Color
    rocket.Material = Enum.Material.Plastic
    rocket.TopSurface = Enum.SurfaceType.Smooth
    rocket.BottomSurface = Enum.SurfaceType.Smooth
    rocket.CFrame = CFrame.new(spawnPos, targetPos)
    rocket.CanCollide = false
    rocket.Anchored = true
    rocket.Parent = Workspace
    
    local attachment = Instance.new("Attachment")
    attachment.Parent = rocket
    
    local smoke = Instance.new("Smoke")
    smoke.Color = Color3.fromRGB(150, 150, 150)
    smoke.Opacity = 0.5
    smoke.RiseSpeed = 2
    smoke.Size = 0.4
    smoke.Parent = rocket
    
    local speed = 75
    local dir = (targetPos - spawnPos).Unit
    local totalDist = (targetPos - spawnPos).Magnitude
    local distTraveled = 0
    
    task.spawn(function()
        local lastTime = os.clock()
        while distTraveled < totalDist and rocket.Parent do
            local now = os.clock()
            local dt = now - lastTime
            lastTime = now
            
            local step = speed * dt
            if distTraveled + step > totalDist then
                step = totalDist - distTraveled
            end
            
            rocket.CFrame = rocket.CFrame + dir * step
            distTraveled = distTraveled + step
            
            -- Dynamic raycasting to handle mid-air collisions with moving objects or barriers
            local raycastParams = RaycastParams.new()
            raycastParams.FilterType = Enum.RaycastFilterType.Exclude
            raycastParams.FilterDescendantsInstances = {char, rocket}
            local result = workspace:Raycast(rocket.Position - dir * 1, dir * (step + 1.5), raycastParams)
            
            if result then
                targetPos = result.Position
                break
            end
            task.wait()
        end
        
        local hitPos = targetPos
        rocket:Destroy()
        
        -- Create the visual and physical Roblox explosion
        local exp = Instance.new("Explosion")
        exp.ExplosionType = Enum.ExplosionType.NoCraters
        exp.BlastRadius = 12
        exp.BlastPressure = 150000
        exp.Position = hitPos
        exp.Parent = Workspace
        
        -- Identify eligible parts in blast radius and de-anchor them for physics simulation
        local parts = Workspace:GetPartBoundsInRadius(hitPos, 12)
        for _, part in ipairs(parts) do
            if part:IsDescendantOf(SmallCity) and not part:GetAttribute("DestructionImmune") then
                part:SetAttribute("BlastedTime", os.clock())
                part.Anchored = false
                part.CanCollide = true
                part.CanTouch = true
                
                -- Set burnt visuals on non-glass objects or increase transparency for glass panes
                if part.Name:find("Pane") or part.Name:find("Glass") then
                    part.Transparency = 0.85
                else
                    TweenService:Create(part, TweenInfo.new(0.5), {Color = Color3.fromRGB(45, 45, 45)}):Play()
                end
                
                -- Temporary fire particles to indicate combustion
                local fire = Instance.new("Fire")
                fire.Size = part.Size.Magnitude * 0.4
                fire.Heat = 5
                fire.Parent = part
                Debris:AddItem(fire, 4)
            end
        end
    end)
end)

-- Automated self-repair system running on a continuous background thread
task.spawn(function()
    while true do
        task.wait(0.5)
        local now = os.clock()
        
        for part, startState in pairs(originalStates) do
            if part and part.Parent then
                local blastedTime = part:GetAttribute("BlastedTime")
                
                -- If 12 seconds have elapsed since impact, reconstruct the part
                if blastedTime and (now - blastedTime) > 12 then
                    part:SetAttribute("BlastedTime", nil)
                    
                    task.spawn(function()
                        if not part or not part.Parent then return end
                        -- Temporarily turn off collision to prevent parts getting stuck in obstacles during transit
                        part.CanCollide = false
                        part.CanTouch = false
                        
                        part.AssemblyLinearVelocity = Vector3.zero
                        part.AssemblyAngularVelocity = Vector3.zero
                        part.Anchored = true
                        
                        -- Animate the part's restoration back to its initial CFrame and color
                        local tweenInfo = TweenInfo.new(2.0, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
                        local moveTween = TweenService:Create(part, tweenInfo, {
                            CFrame = startState.CFrame,
                            Color = startState.Color,
                            Transparency = startState.Transparency
                        })
                        
                        moveTween:Play()
                        moveTween.Completed:Wait()
                        
                        if not part or not part.Parent then return end
                        -- Restore physical collision and original material settings
                        part.CanCollide = startState.CanCollide
                        part.CanTouch = startState.CanTouch
                        part.BrickColor = startState.BrickColor
                        part.Material = startState.Material
                        part.MaterialVariant = startState.MaterialVariant
                    end)
                end
            end
        end
    end
end)

-- Full manual city rebuild action triggered via client event
RebuildCityEvent.OnServerEvent:Connect(function(player)
    for part, startState in pairs(originalStates) do
        if part and part.Parent then
            part:SetAttribute("BlastedTime", nil)
            part.Anchored = true
            part.CFrame = startState.CFrame
            part.Size = startState.Size
            part.Color = startState.Color
            part.BrickColor = startState.BrickColor
            part.Material = startState.Material
            part.MaterialVariant = startState.MaterialVariant
            part.Transparency = startState.Transparency
            part.CanCollide = startState.CanCollide
            part.CanTouch = startState.CanTouch
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
            
            -- Remove any temporary visual assets that were parented to the part
            for _, child in ipairs(part:GetChildren()) do
                if child:IsA("Fire") or child:IsA("Smoke") or child:IsA("Sparkles") then
                    child:Destroy()
                end
            end
        end
    end
    print("Magical restoration completed for SmallCity parts!")
end)

print("CityDestructionAndRepair Server Runtime Engine successfully initialized!")
