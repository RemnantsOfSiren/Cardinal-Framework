-- [[ Services ]] --
local RunService = game:GetService('RunService');
local PlayerService = game:GetService('Players');
local HttpService = game:GetService('HttpService');
local ComponentHandlers = {};

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
local Signal = Resources["Signal"];
local IsServer = RunService:IsServer();
local Handler;

local Cardinal = {};
Cardinal.__index = Cardinal;

function Cardinal.new()
    local self = setmetatable({
        _Janitor = Janitor.new();
        Initialized = Signal.new();
        Started = Signal.new();
    }, Cardinal);

    self.new = nil;
    self._Events = {
        [RunService] = {};
        [PlayerService] = {};
    };

    self._Networking = true;
    self._Performance = true;

    if self._Networking then
        if IsServer then
            local Folder = Instance.new("Folder");
            Folder.Name = "Services";
            Folder.Parent = script;
            self._ServiceFolder = Folder;
        else
            self._ServiceFolder = script:WaitForChild("Services");
        end
    end

    local _Janitor = self._Janitor;
    _Janitor:Add(self.Initialized, "Destroy");
    _Janitor:Add(self.Started, "Destroy");

    Handler = self;
    return self;
end

local Custom = {};
Custom.__index = Custom;
Custom.ClassName = IsServer and "Service" or "Controller";
Custom.__tostring = function()
    return Custom.ClassName;
end

if IsServer then
    -- [[ Server Exclusive ]] --
    function Cardinal:CreateService(ServiceInfo: {[any]: any})
        assert(ServiceInfo.Name, "Service Requires Name");
        local NewService = ServiceInfo;
        NewService.Dependencies = {};

        if self._Networking and NewService.Client then
            local Adapter = Resources["Adapter"];

            if Adapter then
                NewService._NetworkAdapter = Adapter.new(NewService);

                if typeof(NewService.Client) ~= "table" then
                    NewService.Client = {Server = NewService};
                else
                    NewService.Client.Server = NewService;
                end
            end
        end

        Runnables[NewService.Name] = NewService;
        return NewService;
    end
else
    -- [[ Client Exclusive ]] --
    function Cardinal:CreateController(ControllerInfo: {[any]: any})
        assert(ControllerInfo.Name, "Controller Requires Name");
        local NewController = ControllerInfo;
        NewController.Dependencies = {};
        Runnables[NewController.Name] = NewController;
        return NewController;
    end
end

-- [[ Generics ]] --
local function GetAllDescendants(Data: Folder | {ModuleScript} | ModuleScript)
    local Table;

    if typeof(Data) == "Instance" then
        Table = {Data, Data:GetDescendants()};
    else
        Table = Data;
        for _, Object in pairs(Data) do
            if typeof(Object) == "Instance" then
                for _, Descendant in pairs(Object:GetDescendants()) do
                    Table = {unpack(Table), Descendant};
                end
            end
        end
    end

    return Table;
end

local function ProcessObject(Object, Table: {any}?)
    if Object and Object:IsA("ModuleScript") then
        table.insert(LoadCache, Object.Name);
        if Table then
            Table[Object.Name] = require(Object);
        else
            require(Object.Name);
        end
        table.remove(LoadCache, table.find(LoadCache, Object.Name));
    end
end

function Cardinal:AddResources(_Resources: Folder | {ModuleScript} | ModuleScript, Descendants: boolean?)
    if Descendants then
        _Resources = GetAllDescendants(_Resources);
    else
        if typeof(_Resources) == "Instance" then
            if _Resources:IsA("Folder") then
                _Resources = _Resources:GetChildren();
            else
                _Resources = { _Resources };
            end
        end
    end

    for _, Module in pairs(_Resources) do
        task.spawn(ProcessObject, Module, Resources);
    end
end

function Cardinal:AddRunnables(_Runnables: Folder | {ModuleScript} | ModuleScript, Descendants: boolean?)
    if Descendants then
        _Runnables = GetAllDescendants(_Runnables);
    else
        if typeof(_Runnables) == "Instance" then
            if _Runnables:IsA("Folder") then
                _Runnables = _Runnables:GetChildren();
            else
                _Runnables = { _Runnables };
            end
        end
    end

    for _, Module in pairs(_Runnables) do
        task.spawn(ProcessObject, Module);
    end
end

function Cardinal:AddEvent(Service: ServiceProvider, Event: string, Callback: (...any) -> nil): string?
    local ProviderCache = self._Events[Service];
    if not ProviderCache then return nil end

    local LogicalEvent;
    local Success = pcall(function()
        LogicalEvent = Service[Event];
    end)

    if not Success then return nil end
    if not self._Events[Service][Event] then
        local Table = {};

        if Service ~= PlayerService then
            self._Janitor:Add(LogicalEvent:Connect(function(...)
                for _, _Callback in pairs(Table) do
                    task.spawn(_Callback, ...);
                end
            end), "Disconnect")
        end

        self._Events[Service][Event] = Table;
    end


    local Unique = HttpService:GenerateGUID(false);

    self._Events[Service][Event][Unique] = Callback;

    return Unique;
end

function Cardinal:LoadLibrary(Name: string, TimeOut: number?)
    if Resources[Name] then
        return Resources[Name];
    else
        TimeOut = if TimeOut then TimeOut else 10;
        local Found = nil;

        task.delay(TimeOut, function()
            Found = false;
        end)
        
        local Success, Result = Promise.new(function(Resolve, Reject)
            repeat
                Found = Resources[Name];
                task.wait(.1);
            until Found ~= nil;
            if not Found then
                return Reject("Package not found");
            end
            return Resolve(Found);
        end):await();

        assert(Success, string.format("%s couldn't be found.", Name));
        return Result;
    end
end

function Cardinal:_Init()
    local Promises = {};

    for Name, Runnable in pairs(Runnables) do
        Runnable.__Clock = os.clock();

        if Runnable.OnInit ~= nil then
            table.insert(Promises, Promise.new(function(Resolve, Reject)
                local Success, Error = pcall(Runnable.OnInit, Runnable);
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

    local Finished = Promise.allSettled(Promises);

    if Finished.Status == Promise.Status.Rejected then
        return Promise.reject();
    else
        self.Initialized:Fire();
        return Promise.resolve();
    end
end

function Cardinal:Start(Config: {[string]: any}?)
    if Config then
        self._Networking = Config.Networking ~= nil and Config.Networking or true;
        self._Performance = Config.Performance ~= nil and Config.Performance or true;
    end

    if not IsServer then
        script:WaitForChild("ServerReady");
    end

    local Initialized = self:_Init();

    if Initialized.Status == Promise.Status.Rejected then
        return Promise.reject("Initialization Failed");
    end

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

    local Started = Promise.allSettled(Promises);

    if Started.Status == Promise.Status.Rejected then
        return Promise.reject();
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
        for _, Callback in pairs(self._Events[PlayerService]["PlayerAdded"]) do
            task.spawn(Callback, Player);
        end

        local _Janitor = Janitor.new();
        _Janitor:LinkToInstance(Player);

        local function CharacterAdded(Character)
            if not Character:IsDescendantOf(workspace) then
                repeat
                    task.wait(.05);
                until Character:IsDescendantOf(workspace) and Character.PrimaryPart;
            end

            for _, Callback in pairs(self._Events[PlayerService]["CharacterAdded"]) do
                task.spawn(Callback, Character, Player);
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
        task.spawn(PlayerAdded, Player);
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
    return Cardinal.new();
else
    return Handler;
end