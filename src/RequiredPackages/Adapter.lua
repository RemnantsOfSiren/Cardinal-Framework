local RunService = game:GetService('RunService');
local PlayerService = game:GetService('Players');
local Promise = require(script.Parent.Promise);
local Serialization = require(script.Parent.Serialization);

local IsServer = RunService:IsServer();

local Adapter = {};
Adapter.__index = Adapter;

function Adapter:_CheckMiddleware(Category: string, Args: {[any]: any})

end

if IsServer then
    export type PlayerStatistic = {
        Caller: Player;
        ["1"]: {[string]: {[string]: any}};
        ["2"]: {[string]: {[string]: any}}
    }

    -- [[ This will pertain to middleware exclusively ]] --
    function Adapter:_CreatePlayerStatistics(Player: Player)
        local Statistics = {
            Caller = Player;

            [1] = {
                Requests = {
                    Success = 0;
                    Total = 0;
                };
                Last = {
                    Time = tick() - 10;
                    Status = false;
                }
            };

            [2] = {
                Requests = {
                    Success = 0;
                    Total = 0;
                };
                Last = {
                    Time = tick() - 10;
                    Status = false;
                }
            }
        };

        self._PlayerStatistics[Player] = Statistics;

        return Statistics :: PlayerStatistic;
    end

    function Adapter:Fire(Filter: (Player) -> boolean, Event: string, ...)
        local Args = {...};
        for _, Player in pairs(PlayerService:GetPlayers()) do
            if Filter(Player) then
                self._REvent:FireClient(Player, Event, Args);
            end
        end
    end
end

function Adapter.new(Parent, Provider)
    local self = setmetatable({}, Adapter);
    self._Events = {};
    self._Functions = {};
    self._Middleware = {
        ["Inbound"] = {
            [1] = function(Args)
                if IsServer then
                    table.remove(Args, 1);
                end
                Args = Serialization:DeserializeData(Args);
                return true, Args;
            end
        };
        ["Outbound"] = {
            [1] = function(Args)
                if IsServer then
                    table.remove(Args, 1);
                end

                Args = Serialization:SerializeData(Args);
                return true, Args;
            end
        };
    }
    self._PlayerStatistics = {};

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
            local Res = {Success = false};
            local Statistics = self._PlayerStatistics[Player];

            if not Statistics then
                Statistics = self:_CreatePlayerStatistics(Player);
            end

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
                table.insert(Args, 1, Statistics);
                local Passed;
                Passed, Args = self:_CheckMiddleware("Inbound", Args);

                if Passed then
                    Res.Success = true;
                    Res.Response = Provider.Client[Todo](Provider.Client, IsServer and Player or nil, unpack(Args));
                end
            end

            local CurrentStatistics = Statistics[1];
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
            self.Events = Res.Response;

            for _, Event in pairs(self.Events) do
                local function Call(...)
                    local Args = Serialization:SerializeData({...});

                    return Promise.new(function(Resolve, Reject)
                        local Res;
                        local Success = pcall(function()
                            Res = self._RFunction:InvokeServer(Event, Args);
                        end)

                        if Success and Res and Res.Response then
                            Res.Response = Serialization:DeserializeData(Res.Response);
                        end

                        return Res.Success and Resolve(Res.Response) or Reject();
                    end);
                end
                
                self[Event .. "Async"] = function(_, ...)
                    return Call(...);
                end
                
                self[Event] = function(_, ...)
                    local _, Res = Call(...):await();
                    return Res;
                end
            end
        end
    end

    return self;
end

return Adapter;