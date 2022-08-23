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

local Handlers = {};

local Handler = {};
Handler.__index = Handler;

function Handler:GetComponentByInstance(Object: Instance)
    return self._Components[Object];
end

function Handler:GetComponents()
    return self._Components;
end

local function CreateHandler(ComponentDetails)
    assert(ComponentDetails.Name, "Component wasn't provided a name.");
    local Tag = ComponentDetails.Tag or ComponentDetails.Name;
    assert(Tag, "A Name/Tag wasn't specified.");
    local Handler = setmetatable({}, Handler);

    Handler._Janitor = Janitor.new();
    Handler.Name = ComponentDetails.Name;
    Handler.Tag = Tag;
    Handler.Ancestors = ComponentDetails.Ancestors or { workspace };
    Handler.InstanceTypes = ComponentDetails.InstanceTypes or {"Instance"};

    ComponentDetails.Tag = nil;
    ComponentDetails.Name = nil;
    ComponentDetails.Ancestors = nil;
    ComponentDetails.InstanceTypes = nil;

    Handlers[Handler.Name] = Handler;

    return Handler, ComponentDetails;
end

return {
    GetComponent = function(Name: string)
        return Handlers[Name];
    end;

    CreateComponent = function (Framework: {any}, ComponentDetails: {any}) -- Passing framework so that I can sync to the internal system for Services.
        assert(ComponentDetails.Name, "Expected Name (of type string) for Component");
        assert(Framework, "Framework wasn't properly specified.");
        assert(Framework.AddEvent, "Framework doesn't supply an AddEvent function");

        local Handler, ComponentDetails = CreateHandler(ComponentDetails);

        local Template = {};

        ComponentDetails.__newindex = function(Self, Index, Value)
            print(Index, Value);
            rawset(Self, Index, Value);
            rawset(Template, Index, Value);
        end

        local function CreateComponent(Object: Instance)
            if typeof(Object) ~= "Instance" or IsValidInstance(Handler.InstanceTypes, Object) == false then
                warn(string.format("Component(%s) expected the following InstanceTypes: %s but %s was given.", Handler.Tag, table.concat(Handler.InstanceTypes, ","), typeof(Object) ~= "Instance" and typeof(Object) or Object.ClassName));
                return
            end

            print(Template);

            local Component = setmetatable({}, Template);

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
            if Component.OnInit then Component:OnInit(); end
            if Component.OnDeinit then _Janitor:Add(function() Component:OnDeInit() end, true); end

            return Component;
        end

        local function Added(Object: Instance)
            local Destroyed = false;

            local DestroyedConnection = Object.Destroying:Connect(function()
                Destroyed = true;
            end)

            if not IsDescendantOf(Handler.Ancestors, Object) then
                repeat
                    Object.AncestryChanged:Wait();
                until IsDescendantOf(Handler.Ancestors, Object) or Destroyed;
            end

            local Component = if not Destroyed then CreateComponent(Object) else nil;
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
            task.delay(.1, Added, Instance);
        end

        return ComponentDetails;
    end
}