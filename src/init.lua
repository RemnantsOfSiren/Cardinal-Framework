--[[
    This framework is Property of Silent Studios,
    Liscensed through an MIT for public use.
    Currently still in development working out some kinks.
]]--

-- [[ Services ]] --
local RunService = game:GetService('RunService');
local PlayerService = game:GetService('Players');
local HttpService = game:GetService('HttpService');
local ReplicatedStorage = game:GetService('ReplicatedStorage');
local WallyPackages = ReplicatedStorage:FindFirstChild("Packages");

local Runnables = {};
local Resources = {};
local LoadCache = {};

local AcceptedEvents = {
    [RunService] = {
        ["Heartbeat"] = {"OnHeartbeat"};
        ["Stepped"] = {"OnStepped"};
        ["RenderStepped"] = {"OnRender", "OnRenderStepped"};
    };

    [PlayerService] = {
        ["PlayerAdded"] = {"OnPlayerAdded"};
        ["CharacterAdded"] = {"OnCharacterAdded"};
    }
}

for _, Package in pairs(script.RequiredPackages:GetChildren()) do
    if Package:IsA("ModuleScript") then
        Resources[Package.Name] = require(Package);
    end
end

local Promise = Resources["Promise"];
local Janitor = Resources["Janitor"];
local Adapter = Resources["Adapter"];
local Component = Resources["Component"];
local Signal = Resources["Signal"];

local IsServer = RunService:IsServer();
local Handler;

if IsServer then
    local ServerStorage = game:GetService('ServerStorage')
    local ServerPackages = ServerStorage:FindFirstChild("Packages");
    if ServerPackages then
        for _, Package in pairs(ServerPackages:GetChildren()) do
            if Package:IsA("ModuleScript") then
                Resources[Package.Name] = require(Package);
            end
        end
    end
end

local CardinalSystem = {};
CardinalSystem.__index = CardinalSystem;

function CardinalSystem.new()
    local self = setmetatable({
        _Janitor = Janitor.new();
        Initialized = Signal.new();
        Started = Signal.new();
    }, CardinalSystem);

    self.new = nil;
    self._Events = {
        [RunService] = {};
        [PlayerService] = {};
    };

    local Folder;
    self._Performance = true;

    if IsServer then
        self._Networking = true;
        Folder = Instance.new("Folder");
        Folder.Name = "ServiceFolder";
        Folder.Parent = script;
        self._ServiceFolder = Folder;
    else
        self._ServiceFolder = script:WaitForChild("ServiceFolder");
    end

    Handler = self;
    return self;
end

local function GetRunnableAsync(_: typeof(CardinalSystem), Name: string, Timeout: number?)
    if not Timeout then
        Timeout = 10;
    end

    local Runnable = Runnables[Name];

    if Runnable then
        return Promise.resolve(Runnable);
    else
        return Promise.new(function(Resolve, Reject)
            local T = tick();
            repeat
                Runnable = Runnables[Name];
                task.wait();
            until tick() - T >= Timeout or Runnable ~= nil;
            if Runnable ~= nil then
                return Resolve(Runnable);
            else
                return Reject(string.format("Couldn't find %s: %s", if IsServer then "Service" else "Controller", Name));
            end
        end)
    end
end

local function GetRunnable(_: typeof(CardinalSystem), Name: string, Timeout: number?)
    local Success, Runnable = GetRunnableAsync(_, Name, Timeout):await();
    if not Success then
        warn(Runnable);
        return
    end
    return Runnable;
end

function CardinalSystem:CreateComponent(ComponentDetails)
    if Component then
        return Component.CreateComponent(self, ComponentDetails);
    end
end

function CardinalSystem:GetComponentAsync(Tag: string, Timeout: number?)
    assert(Component, "Component Resource wasn't found.");
    assert(Tag, 'No "Name" string given to GetComponent.');
    assert(typeof(Tag) == "string", 'Tag is not of type string.');
    if not Timeout then
        Timeout = 10;
    end

    local Handler = Component.GetComponent(Tag);
    
    if Handler then
        return Promise.resolve(Handler);
    else
        return Promise.new(function(Resolve, Reject)
            local T = tick();
            repeat
                Handler = Component.GetComponent(Tag);
                task.wait();
            until Handler ~= nil or tick() - T >= Timeout;
            if Handler ~= nil then
                return Resolve(Handler);
            else
                return Reject(string.format("Couldn't find ComponentHandler: %s", Tag));
            end
        end)
    end
end

function CardinalSystem:GetComponent(Tag: string, Timeout: number?)
    local Success, Component = self:GetComponentAsync(Tag, Timeout):await();

    if not Success then
        warn(Component);
        return
    end
    return Component;
end

if IsServer then
    -- [[ Server Exclusive ]] --
    function CardinalSystem:CreateService(ServiceInfo: {[any]: any})
        assert(ServiceInfo.Name, "Service Requires Name");
        local NewService = ServiceInfo;

        if self._Networking and Adapter and NewService.Client ~= nil then
            if typeof(NewService.Client) ~= "table" then
                NewService.Client = {Server = NewService};
            else
                NewService.Client.Server = NewService;
            end

            NewService._Network = Adapter.new(self._ServiceFolder, NewService);
        end

        Runnables[NewService.Name] = NewService;
        return NewService;
    end

    CardinalSystem.GetServiceAsync = GetRunnableAsync;
    CardinalSystem.GetService = GetRunnable;
else
    local Adapters = {};

    function CardinalSystem:GetServiceAsync(Name: string)
        if not script:FindFirstChild("ServerReady") then
            script:WaitForChild("ServerReady");
        end
        
        if not self._Networking then
            return Promise.reject(string.format("Networking is disabled: %s", debug.traceback(nil, 2)));
        end

        local _Adapter = Adapters[Name];

        if _Adapter then
            return Promise.resolve(_Adapter);
        else
            return Promise.new(function(Resolve, Reject)
                _Adapter = Adapter.new(self._ServiceFolder, Name);
                if not _Adapter then
                    return Reject(string.format("Error trying to make ClientAdapter for %s: %s", Name, debug.traceback(nil, 2)));
                end
                Adapters[Name] = _Adapter;
                return Resolve(_Adapter);
            end)
        end
    end

    function CardinalSystem:GetService(Name: string)
        local Success, NetworkAdapter = self:GetServiceAsync(Name):await();
        if not Success then
            warn(NetworkAdapter);
            return
        end
        return NetworkAdapter;
    end
    -- [[ Client Exclusive ]] --
    function CardinalSystem:CreateController(ControllerInfo: {[any]: any})
        assert(ControllerInfo.Name, "Controller Requires Name");
        local NewController = ControllerInfo;
        Runnables[NewController.Name] = NewController;
        return NewController;
    end

    CardinalSystem.GetControllerAsync = GetRunnableAsync;
    CardinalSystem.GetController = GetRunnable;
end

-- [[ Generics ]] --
local function Get(Data: Folder | {ModuleScript} | ModuleScript, Descendants: boolean?)
    local T;

    if typeof(Data) == "table" then
        T = Data;
    elseif Data:IsA("Folder") then
        T = Data:GetChildren();
    else
        T = {Data};
    end

    if T and Descendants then
        for _, Object in pairs(T) do
            for _, Descendant in pairs(Object:GetDescendants()) do
                if Descendant:IsA("ModuleScript") and not table.find(T, Descendant) then
                    table.insert(T, Descendant);
                end
            end
        end
    end

    return T;
end

local function ProcessObject(Object, IsResource: boolean?)
    if Object and Object:IsA("ModuleScript") then
        if IsResource and Resources[Object.Name] then
            return
        end

        table.insert(LoadCache, Object.Name);
        if IsResource then
            Resources[Object.Name] = require(Object);
        else
            require(Object);
        end
        table.remove(LoadCache, table.find(LoadCache, Object.Name));
    end
end

function CardinalSystem:AddResources(_Resources: Folder | {ModuleScript} | ModuleScript | nil, Descendants: boolean?)
    if _Resources ~= nil and typeof(_Resources) ~= "boolean" then
        for _, Module in pairs(Get(_Resources, Descendants)) do
            task.spawn(ProcessObject, Module, true);
        end
    end
end

function CardinalSystem:AddRunnables(_Runnables: Folder | {ModuleScript} | ModuleScript | nil, Descendants: boolean?)
    if _Runnables ~= nil and typeof(_Runnables) ~= "boolean" then
        for _, Module in pairs(Get(_Runnables, Descendants)) do
            task.spawn(ProcessObject, Module);
        end
    end
end

function CardinalSystem:AddEvent(Service: ServiceProvider, Event: string, Callback: (...any) -> nil): string?
    local ProviderCache = self._Events[Service];
    if not ProviderCache then return nil end

    if not self._Events[Service][Event] then
        local Table = {};

        if Service ~= PlayerService then
            local LogicalEvent;
            
            local Success = pcall(function()
                LogicalEvent = Service[Event];
            end)
        
            if not Success then return nil end

            self._Janitor:Add(LogicalEvent:Connect(function(...)
                for _, _Callback in pairs(Table) do
                    task.spawn(_Callback, ...);
                end
            end), "Disconnect");
        end

        self._Events[Service][Event] = Table;
    end

    local Unique = HttpService:GenerateGUID(false);

    self._Events[Service][Event][Unique] = Callback;

    return Unique;
end

function CardinalSystem:RemoveEvent(Id: string)
    for Service, Events in pairs(self._Events) do
        for Event, UniqueIds in pairs(Events) do
            if table.find(UniqueIds, Id) then
                self._Events[Service][Event][Id] = nil;
            end
        end
    end
end

function CardinalSystem:LoadLibraryAsync(Name: string, Timeout: number?)
    if type(Name) ~= "string" then
        return Promise.reject(string.format("Invalid type %s, expected: string", type(Name)));
    end

    if not Timeout then
        Timeout = 10;
    end

    local Found = Resources[Name];

    if Found then
        return Promise.resolve(Found);
    else
        return Promise.new(function(Resolve, Reject)
            local T = tick();
            repeat
                Found = Resources[Name];
                task.wait();
            until Found ~= nil or tick() - T > Timeout;
            if Found then
                return Resolve(Found);
            else
                return Reject(string.format("Couldn't find Resource: %s", Name))
            end
        end)
    end
end

function CardinalSystem:LoadLibrary(Name: string, Timeout: number?)
    local Success, Library = self:LoadLibraryAsync(Name, Timeout):await();
    if not Success then
        warn(Library);
        return
    end
    return Library;
end

function CardinalSystem:_Init()
    while #LoadCache > 0 do
        task.wait();
    end

    local Promises = {};

    for Name, Runnable in pairs(Runnables) do
        Runnable.__Clock = os.clock();

        if Runnable.OnInit ~= nil then
            table.insert(Promises, Promise.new(function(Resolve, Reject)
                local Success, Error = pcall(Runnable.OnInit, Runnable);

                if not Success then
                    warn(string.format("%s Couldn't be Initialized: %s", Name, tostring(Error)), debug.traceback(nil, 2));
                    return Reject();
                end

                if self._Performance then
                    print(string.format("%s Initialized In: %2.7fs", Name, os.clock() - Runnable.__Clock))
                end
                return Resolve();
            end))
        end
    end

    return Promise.allSettled(Promises);
end

function CardinalSystem:Start(Config: {[string]: any}?)
    if IsServer then
        if Config then
            self._Networking = Config.Networking ~= nil and Config.Networking or true;
            self._Performance = Config.Performance ~= nil and Config.Performance or true;
        end

        if not self._Networking then
            self._ServiceFolder:Destroy();
        end
    else
        script:WaitForChild("ServerReady");
        if Config then
            self._Performance = Config.Performance ~= nil and Config.Performance or true;
        end
        self._Networking = if script:FindFirstChild("ServiceFolder") then true else false;
    end

    local InitSuccessful = self:_Init():await();

    if not InitSuccessful then
        return Promise.reject("Couldn't Initialize all Runnables.");
    end

    self.Initialized:Fire();

    local Promises = {};

    for Name, Runnable in pairs(Runnables) do
        if Runnable.OnStart ~= nil then
            table.insert(Promises, Promise.new(function(Resolve, Reject)
                local Success, Error = pcall(Runnable.OnStart, Runnable);

                if not Success then
                    warn(string.format("%s Couldn't be Started: %s", Name, tostring(Error)));
                    return Reject();
                end

                if self._Performance then
                    print(string.format("%s Started In: %2.7fs", Name, os.clock() - Runnable.__Clock))
                end

                return Resolve();
            end))
        end
    end

    local Started = Promise.allSettled(Promises):await();

    if not Started then
        return Promise.reject("Couldn't Start all Runnables.");
    end

    for _, Runnable in pairs(Runnables) do
        Runnable.__Clock = os.clock();

        for Provider, Events in pairs(AcceptedEvents) do
            for EventName, Aliases in pairs(Events) do
                if Runnable[EventName] then
                    self:AddEvent(Provider, EventName, function(...)
                        Runnable[EventName](Runnable, ...);
                    end)
                else
                    for _, Alias in pairs(Aliases) do
                        if Runnable[Alias] then
                            self:AddEvent(Provider, EventName, function(...)
                                Runnable[Alias](Runnable, ...);
                            end)
                        end
                    end
                end
            end
        end
    end

	local function PlayerAdded(Player)
		if self._Events[PlayerService]["PlayerAdded"] then
        	for _, Callback in pairs(self._Events[PlayerService]["PlayerAdded"]) do
            	task.spawn(Callback, Player);
			end
		end

        local _Janitor = Janitor.new();
        _Janitor:LinkToInstance(Player);

		local function CharacterAdded(Character)
			if self._Events[PlayerService]["CharacterAdded"] then
	            if not Character:IsDescendantOf(workspace) or not Character.PrimaryPart then
	                repeat
	                    task.wait();
	                until Character:IsDescendantOf(workspace) and Character.PrimaryPart ~= nil;
	            end

	            for _, Callback in pairs(self._Events[PlayerService]["CharacterAdded"]) do
	                task.spawn(Callback, Character, Player);
	            end
			end
        end

        if PlayerService.CharacterAutoLoads then
            local Character = Player.Character or Player.CharacterAdded:Wait();
            CharacterAdded(Character);
        end

        _Janitor:Add(Player.CharacterAdded:Connect(CharacterAdded), "Disconnect");
    end

    self._Janitor:Add(PlayerService.PlayerAdded:Connect(PlayerAdded));

    for _, Player in pairs(PlayerService:GetPlayers()) do
        PlayerAdded(Player);
    end

    if IsServer then
        local Finished = Instance.new("BoolValue");
        Finished.Name = "ServerReady";
        Finished.Value = true;
        Finished.Parent = script;
    end

    self.Started:Fire();
    return Promise.resolve("Finished");
end

if not Handler then
    return CardinalSystem.new();
else
    return Handler;
end