-- [[ Services ]] --
local RunService = game:GetService('RunService');
local PlayerService = game:GetService('Players');
local HttpService = game:GetService('HttpService');

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
    Resources[Package.Name] = require(Package);
end

local Promise = Resources["Promise"];
local Janitor = Resources["Janitor"];
local Adapter = Resources["Adapter"];

local IsServer = RunService:IsServer();
local Handler;

local CardinalSystem = {};
CardinalSystem.__index = CardinalSystem;

function CardinalSystem.new()
    local self = setmetatable({
        _Janitor = Janitor.new();
    }, CardinalSystem);

    self.new = nil;
    self._Events = {
        [RunService] = {};
        [PlayerService] = {};
    };

    local Folder;
    if IsServer then
        self._Networking = true;
        self._Performance = true;

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
else
    local Adapters = {};

    function CardinalSystem:GetServiceAsync(Name: string)
        if not self._Networking then
            return Promise.reject("Networking isn't enabled.");
        end

        if Adapters[Name] then
            return Promise.resolve(Adapters[Name]);
        else
            return Promise.new(function(Resolve, Reject)
                local Adapter = Adapter.new(self._ServiceFolder, Name);
                if not Adapter then
                    return Reject("Adapter couldn't be made.");
                end
                Adapters[Name] = Adapter;
                return Resolve(Adapter);
            end)
        end
    end

    function CardinalSystem:GetService(Name: string)
        local _, NetworkAdapter = self:GetServiceAsync(Name):catch(warn):await();
        return NetworkAdapter;
    end
    -- [[ Client Exclusive ]] --
    function CardinalSystem:CreateController(ControllerInfo: {[any]: any})
        assert(ControllerInfo.Name, "Controller Requires Name");
        local NewController = ControllerInfo;
        Runnables[NewController.Name] = NewController;
        return NewController;
    end
end

-- [[ Generics ]] --
local function Get(Data: Folder | {ModuleScript} | ModuleScript, Descendants: boolean?)
    local T = if typeof(Data) == "table" then Data else Data:GetChildren();

     if T and Descendants then
        for _, Object in pairs(T) do
            if not Object:IsA("ModuleScript") then
                table.remove(T, table.find(T, Object));
                continue
            end

            for _, Descendant in pairs(Object:GetDescendants()) do
                if Descendant:IsA("ModuleScript") then
                    table.insert(T, Descendant);
                end
            end
        end
    end

    return T;
end

local function ProcessObject(Object, Table: {any}?)
    if Object and Object:IsA("ModuleScript") then
        table.insert(LoadCache, Object.Name);
        if Table then
            Table[Object.Name] = require(Object);
        else
            require(Object);
        end
        table.remove(LoadCache, table.find(LoadCache, Object.Name));
    end
end

function CardinalSystem:AddResources(_Resources: Folder | {ModuleScript} | ModuleScript | nil, Descendants: boolean?)
    if _Resources ~= nil and typeof(_Resources) ~= "boolean" then
        for _, Module in pairs(Get(_Resources, Descendants)) do
            task.spawn(ProcessObject, Module, Resources);
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

function CardinalSystem:LoadLibrary(Name: string)
    if Resources[Name] then
        return Resources[Name];
    else
        warn(string.format("Resource(%s) Not Found.", Name));
    end
end

function CardinalSystem:_Init()
    local Promises = {};

    for Name, Runnable in pairs(Runnables) do
        Runnable.__Clock = os.clock();

        if Runnable.OnInit ~= nil then
            table.insert(Promises, Promise.async(function(Resolve, Reject)
                local Success, Error = pcall(function()
                    Runnable:OnInit();
                end)

                if not Success then
                    warn(string.format("%s Couldn't be Initialized: %s", Name, tostring(Error)));
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
        if Config then
            self._Performance = Config.Performance ~= nil and Config.Performance or true;
        end
        script:WaitForChild("ServerReady");
        self._Networking = if script:FindFirstChild("ServiceFolder") then true else false;
    end

    local InitSuccessful = self:_Init():await();
    if not InitSuccessful then
        return Promise.reject("Couldn't Initialize all Runnables.");
    end

    local Promises = {};

    for Name, Runnable in pairs(Runnables) do
        if Runnable.OnStart ~= nil then
            table.insert(Promises, Promise.async(function(Resolve, Reject)
                local Success, Error = pcall(function()
                    Runnable:OnStart();
                end);
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

    return Promise.resolve("Finished");
end

if not Handler then
    return CardinalSystem.new();
else
    return Handler;
end