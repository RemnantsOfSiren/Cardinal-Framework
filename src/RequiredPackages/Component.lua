local CollectionService = game:GetService("CollectionService");
local RunService = game:GetService("RunService");
local Janitor = require(script.Parent.Janitor);

local function IsValidInstance(Expected: {string}, Object: Instance)
    local IsInstance = false;
    for _, Type in pairs(Expected) do
        if not IsInstance and Object:IsA(Type) then
            IsInstance = true;
        end
    end
    return IsInstance;
end

local function IsDescendantOf(Ancestors, Instance)
    local IsDescendant = false;

    for _, Ancestor in pairs(Ancestors) do
        if not IsDescendant and Instance:IsDescendantOf(Ancestor) then
            IsDescendant = true;
        end
    end

    return IsDescendant;
end

local Handler = {};
Handler.__index = Handler;

function Handler:GetComponentFromInstance(Object: Instance)
    return self._Components[Object];
end

function Handler:GetComponents()
    return self._Components;
end

local function CreateHandler(ComponentDetails)
    local Tag = ComponentDetails.Tag or ComponentDetails.Name;
    assert(Tag, "A Name/Tag wasn't specified.");
    local Handler = setmetatable({}, Handler);

    Handler._Janitor = Janitor.new();
    Handler.Tag = Tag;
    Handler.Ancestors = ComponentDetails.Ancestors or { workspace };
    Handler.InstanceTypes = ComponentDetails.InstanceTypes or {"Instance"};

    ComponentDetails.Tag = nil;
    ComponentDetails.Name = nil;
    ComponentDetails.Ancestors = nil;
    ComponentDetails.InstanceTypes = nil;

    return Handler;
end

return function(Framework: {any}, ComponentDetails: {any}) -- Passing framework so that I can sync to the internal system for Services.
    assert(ComponentDetails.Name, "Expected Name (of type string) for Component");
    assert(Framework, "Framework wasn't properly specified.");
    assert(Framework.AddEvent, "Framework doesn't supply an AddEvent function");

    local Handler = CreateHandler(ComponentDetails);

    local function CreateComponent(Object: Instance)
        if typeof(Object) ~= "Instance" or IsValidInstance(Handler.InstanceTypes, Object) == false then
            warn(string.format("Component(%s) expected the following InstanceTypes: %s but %s was given.", Handler.Tag, table.concat(Handler.InstanceTypes, ","), typeof(Object) ~= "Instance" and typeof(Object) or Object.ClassName));
            return
        end

        local Component = setmetatable({}, ComponentDetails);

        Component._Instance = Object;

        local _Janitor = Janitor.new();
        _Janitor:LinkToInstance(Object);

        if Component.OnHeartbeat then
            local Id = Framework:AddEvent(RunService, "Heartbeat", function(...)
                Component:OnHeartbeat(...);
            end);

            _Janitor:Add(function()
                Framework:RemoveEvent(Id);
            end, true);
        end

        if Component.OnStepped then
            local Id = Framework:AddEvent(RunService, "Stepped", function(...)
                Component:OnHeartbeat(...);
            end);

            _Janitor:Add(function()
                Framework:RemoveEvent(Id);
            end, true);
        end

        if Component.OnRenderStepped then
            local Id = Framework:AddEvent(RunService, "RenderStepped", function(...)
                Component:OnHeartbeat(...);
            end);

            _Janitor:Add(function()
                Framework:RemoveEvent(Id);
            end, true);
        end

        function Component:Destroy()
            _Janitor:Destroy();
        end

        Component._Janitor = _Janitor;
        Component:OnInit();

        return Component;
    end

    local function Added(Instance: Instance)
        local Destroyed = false;

        local DestroyedConnection = Instance.Destroying:Connect(function()
            Destroyed = true;
        end)

        if not IsDescendantOf(Handler.Ancestors, Instance) then
            repeat
                Instance.AncestryChanged:Wait();
            until IsDescendantOf(Handler.Ancestors, Instance) or Destroyed;
        end

        local Component = if not Destroyed then CreateComponent(Instance) else nil;
        if Component then
            Component._Janitor:Add(DestroyedConnection, "Disconnect");
        end
    end

    Handler._Janitor:Add(CollectionService:GetInstanceAddedSignal(Handler.Tag):Connect(Added), "Disconnect");
    Handler._Janitor:Add(CollectionService:GetInstanceRemovedSignal(Handler.Tag):Connect(function(Instance)
        local Component = Handler._Components[Instance];
        if Component then
            Component:Destroy();
        end
    end), "Disconnect");

    for _, Instance in pairs(CollectionService:GetTagged(Handler.Tag)) do
        Added(Instance);
    end

    return Handler;
end