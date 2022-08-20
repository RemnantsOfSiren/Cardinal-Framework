local RunService = game:GetService('RunService');

local IsServer = RunService:IsServer();

local Adapter = {};
Adapter.__index = Adapter;

function Adapter:_CheckMiddleware(Category: string, Args: {[any]: any})

end

-- [[ This will pertain to middleware exclusively ]] --
function Adapter:_CreatePlayerStatistics(Player: Player)
    local Statistics = {
        Caller = Player;

        [self._RFunction] = {
            Requests = {
                Success = 0;
                Total = 0;
            };
            Last = {
                Time = tick() - 10;
                Status = false;
            }
        };

        [self._REvent] = {
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

    return Statistics;
end

function Adapter.new(Parent, Provider)
    local self = setmetatable({}, Adapter);
    self._Events = {};
    self._Functions = {};
    self._Middleware = {
        ["Inbound"] = {};
        ["Outbound"] = {};
    }
    self._PlayerStatistics = {};

    if IsServer then
        assert(typeof(Provider) == "table", "Table is expected for Server Handler");
        if not Provider.Client then return end

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

            if Todo == "IsValid" then
                local Event = table.remove(Args, 1);
                Res.Success = true;
                Res.Response = Provider.Client[Event];
            elseif Provider.Client[Todo] then
                if #self._Middleware["Inbound"] == 0 then
                    Res.Success = true;
                    Res.Response = Provider.Client[Todo](Provider.Client, IsServer and Player or nil, unpack(Args));
                else
                    table.insert(Args, 1, Statistics);
                    local Passed;
                    Passed, Args = self:_CheckMiddleware("Inbound", Args);

                    if Passed then
                        Res.Success = true;
                        Res.Response = Provider.Client[Todo](Provider.Client, IsServer and Player or nil, unpack(Args));
                    end
                end
            end

            local CurrentStatistics = Statistics[RFunction];
            CurrentStatistics.Requests.Total += 1;
            CurrentStatistics.Requests.Success += if Res.Success then 1 else 0;
            CurrentStatistics.Last.Time = if Res.Success then tick() else CurrentStatistics.Last.Time;
            CurrentStatistics.Last.Status = Res.Success;

            return Res;
        end

        REvent.OnServerEvent:Connect(function(Player, Todo, Args)
            local Success = false;

            local Statistics = self._PlayerStatistics[Player];

            if not Statistics then
                Statistics = self:_CreatePlayerStatistics(Player);
            end
        
            if Provider.Client[Todo] then
                if #self._Middleware["Inbound"] == 0 then
                    Success = true;
                    task.spawn(Provider.Client[Todo], Provider.Client, IsServer and Player or nil, unpack(Args));
                else
                    table.insert(Args, 1, Statistics);
                    local Passed;
                    Passed, Args = self:_CheckMiddleware("Inbound", Args);

                    if Passed then
                        Success = true;
                        task.spawn(Provider.Client[Todo], Provider.Client, IsServer and Player or nil, unpack(Args));
                    end
                end
            end

            local CurrentStatistics = Statistics[REvent];
            CurrentStatistics.Requests.Total += 1;
            CurrentStatistics.Requests.Success += if Success then 1 else 0;
            CurrentStatistics.Last.Time = if Success then tick() else CurrentStatistics.Last.Time;
            CurrentStatistics.Last.Status = Success;
        end)
    else
        assert(typeof(Provider) == "string", "String is expected for Client Handler");
        local Folder = Parent:FindFirstChild(Provider);
        if not Folder then return end

        self._REvent = Folder:FindFirstChild("RemoteEvent");
        self._RFunction = Folder:FindFirstChild("RemoteFunction");
    end

    return self;
end

return Adapter;