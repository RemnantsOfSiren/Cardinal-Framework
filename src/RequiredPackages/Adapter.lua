local HttpService = game:GetService('HttpService')
local RunService = game:GetService('RunService');
local PlayerService = game:GetService('Players');
local Promise = require(script.Parent.Promise);
local Serialization = require(script.Parent.Serialization);

local IsServer = RunService:IsServer();

local Adapter = {};
Adapter.__index = Adapter;

local function Count(Table: {any})
    local _Count = 0;
    
    for _ in pairs(Table) do
        _Count += 1;
    end

    return _Count;
end

if IsServer then
    export type PlayerStatistic = {
        Caller: Player;
        ["1"]: {[string]: {[string]: any}};
        ["2"]: {[string]: {[string]: any}}
    }

    function Adapter:_CreatePlayerStatistics(Player: Player)
        local Statistics = {
            [1] = {
                Caller = Player;

                Requests = {
                    Success = 0;
                    Total = 0;
                };

                Last = {
                    Time = tick() - 1000;
                    Status = false;
                }
            };

            [2] = {
                Caller = Player;

                Requests = {
                    Success = 0;
                    Total = 0;
                };
                
                Last = {
                    Time = tick() - 1000;
                    Status = false;
                }
            }
        };

        self._PlayerStatistics[Player] = Statistics;

        return Statistics :: PlayerStatistic;
    end

    function Adapter:FireFilter(Filter: (Player) -> boolean, Event: string, ...)
        local Success, Args = self:_CheckMiddleware('Outbound', {...});

        if Success then
            for _, Player in pairs(PlayerService:GetPlayers()) do
                task.spawn(function()
                    if Player and Filter(Player) then
                        self._REvent:FireClient(Player, Event, Args);
                    end
                end)
            end
        end
    end

    function Adapter:Fire(Player: Player | Model, Event: string, ...)
        Player = if Player:IsA("Player") then Player else PlayerService:GetPlayerFromCharacter(Player);

        if Player then
            local Success, Args = self:_CheckMiddleware('Outbound', {...});
            if Success then
                self._REvent:FireClient(Player, Event, Args);
            end
        end
    end

    function Adapter:FireAll(Event: string, ...)
        local Success, Args = self:_CheckMiddleware('Outbound', {...});

        if Success then
            self._REvent:FireAllClients(Event, Args);
        end
    end
else
    function Adapter:ListenTo(Event: string, Callback)
        if not self._Listeners then
            self._Listeners = {};
        end

        if not self._Listeners[Event] then
            self._Listeners[Event] = {};
        end

        local Id = HttpService:GenerateGUID(false);

        self._Listeners[Event][Id] = Callback;

        return function()
            self._Listeners[Event][Id] = nil;
        end
    end
end

function Adapter:_CheckMiddleware(Category: string, Args: {[any]: any})
    local Pass = false;

    for _, Middleware in pairs(self._Middleware[Category]) do
        Pass, Args = Middleware(Args);
        if not Pass then
            break
        end
    end

    return Pass, Args;
end

function Adapter:AddMiddleware(Category: string, Callbacks: {any})
    local Middlewares = self._Middleware[Category];
    if Middlewares then
        for _, Callback in pairs(Callbacks) do
            table.insert(Middlewares, Callback);
        end
    end
end

function Adapter.new(Parent, Provider)
    local self = setmetatable({}, Adapter);

    self._Events = {};
    self._Functions = {};
    self._PlayerStatistics = {};

    self._Middleware = {
        ["Inbound"] = {
            [1] = function(Args)
                Args = Serialization:DeserializeData(Args);
                return true, Args;
            end
        };

        ["Outbound"] = {
            [1] = function(Args)
                Args = Serialization:SerializeData(Args);
                return true, Args;
            end
        };
    }

    if IsServer then
        assert(typeof(Provider) == "table", "Table is expected for Server Handler");
        assert(Provider.Client, "Client table couldn't found.");
        assert(typeof(Provider.Client) == "table", "Client data provided is not of type 'table'.")

        local Folder = Instance.new("Folder");
        Folder.Name = Provider.Name;

        local REvent = Instance.new("RemoteEvent");
        REvent.Parent = Folder;

        local RFunction = Instance.new("RemoteFunction");
        RFunction.Parent = Folder;

        self._REvent = REvent;
        self._RFunction = RFunction;
        Folder.Parent = Parent;

        RFunction.OnServerInvoke = function(Player, Todo, Args)
            local Statistics = self._PlayerStatistics[Player];

            if not Statistics then
                Statistics = self:_CreatePlayerStatistics(Player);
            end

            local CurrentStatistics = Statistics[1];
            local Res = {Success = false};

            if Todo == "GetEvents" then
                local List = {};
                for Index in pairs(Provider.Client) do
                    if Index ~= "Server" then
                        table.insert(List, Index);
                    end
                end
                Res.Success = true;
                Res.Response = List;
            elseif Provider.Client[Todo] then
                table.insert(Args, 1, CurrentStatistics);
                local Passed;
                Passed, Args = self:_CheckMiddleware("Inbound", Args);

                if Passed then
                    table.remove(Args, 1);
                    Res.Success, Res.Response = self:_CheckMiddleware("Outbound", table.pack(Provider.Client[Todo](Provider.Client, Player, unpack(Args))));
                end
            end

            CurrentStatistics.Requests.Total += 1;
            CurrentStatistics.Requests.Success += if Res.Success then 1 else 0;
            CurrentStatistics.Last.Time = if Res.Success then tick() else CurrentStatistics.Last.Time;
            CurrentStatistics.Last.Status = Res.Success;

            return Res;
        end
    else
        assert(typeof(Provider) == "string", "String is expected for Client Handler");
        local Folder = Parent:FindFirstChild(Provider);
        if not Folder then return end

        self._REvent = Folder:FindFirstChild("RemoteEvent");
        self._RFunction = Folder:FindFirstChild("RemoteFunction");

        local Res = self._RFunction:InvokeServer("GetEvents");
        
        if Res.Success then
            self._Events = Res.Response;

            for _, Event in pairs(self._Events) do
                local function Call(...)
                    local Pass, Args = self:_CheckMiddleware("Outbound", {...});

                    if not Pass then
                        return Promise.reject();
                    else
                        return Promise.new(function(Resolve, Reject)
                            local Res;
                            local Success = pcall(function()
                                Res = self._RFunction:InvokeServer(Event, Args);
                            end)
                            
                            if not Success then
                                return Reject();
                            elseif not Res.Success then
                                return Reject();
                            else
                                local Success, Args = self:_CheckMiddleware("Inbound", Res.Response);
                                
                                if not Success then
                                    return Reject(unpack(Args));
                                else
                                    return Resolve(unpack(Args));
                                end
                            end
                        end);
                    end
                end
                
                self[Event .. "Async"] = function(_, ...)
                    return Call(...);
                end
                
                self[Event] = function(_, ...)
                    local Success, Res = Call(...):await();
                    if not Success then
                        warn(Res);
                        return
                    end
                    return Res;
                end
            end
        end

        self._REvent.OnClientEvent:Connect(function(Event, Args)
            local Listeners = self._Listeners and self._Listeners[Event];
            if Listeners and Count(Listeners) > 0 then
                local Passed;
                Passed, Args = self:_CheckMiddleware("Inbound", Args);

                if Passed then
                    for _, Callback in pairs(Listeners) do
                        task.spawn(Callback, unpack(Args));
                    end
                end
            end
        end)
    end

    return self;
end

return Adapter;