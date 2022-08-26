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

local AcceptedEvents = {
    ["Init"] = {"OnInit"};
    ["DeInit"] = {"OnDeinit"};
    ["RenderStepped"] = {"OnRenderStepped", "OnRender"};
    ["Stepped"] = {"OnStepped"};
    ["Heartbeat"] = {"OnHeartbeat"};
}

local HandlerExclusive = {
    "Name",
    "Tag",
    "GetComponents",
    "GetComponentByInstance",
    "Ancestors",
    "_Janitor",
    "_Components",
    "InstanceTypes",
    "_Template"
}

local function CreateHandler(ComponentDetails)
    local Tag = ComponentDetails.Tag or ComponentDetails.Name;
    assert(Tag, "A Name/Tag wasn't specified.");
    local Handler = {};
    Handler.__index = Handler;

    local Temp = {};
    Temp.__index = Temp;

    Handler.__newindex = function(_, Index, Value)
        if table.find(HandlerExclusive, Index) then
            rawset(Handler, Index, Value);
        else
            rawset(Temp, Index, Value);
        end
    end

    local NewHandler = setmetatable({}, Handler);
    NewHandler._Template = Temp;

    function NewHandler:GetComponentByInstance(Object: Instance)
        return self._Components[Object];
    end

    function NewHandler:GetComponents()
        return self._Components;
    end

    NewHandler._Components = {};
    NewHandler._Janitor = Janitor.new();
    NewHandler.Name = ComponentDetails.Name;
    NewHandler.Tag = Tag;
    NewHandler.Ancestors = ComponentDetails.Ancestors or { workspace };
    NewHandler.InstanceTypes = ComponentDetails.InstanceTypes or {"Instance"};
    Handlers[Tag] = NewHandler;

    return NewHandler;
end

return {
    GetComponent = function(Name: string)
        return Handlers[Name];
    end;

    CreateComponent = function (Framework: {any}, ComponentDetails: {any}) -- Passing framework so that I can sync to the internal system for Services.
        assert(Framework, "Framework wasn't properly specified.");
        assert(Framework.AddEvent, "Framework doesn't supply an AddEvent function");

        local Handler = CreateHandler(ComponentDetails);

        local function CreateComponent(Object: Instance)
            if typeof(Object) ~= "Instance" or IsValidInstance(Handler.InstanceTypes, Object) == false then
                warn(string.format("Component(%s) expected the following InstanceTypes: %s but %s was given.", Handler.Tag, table.concat(Handler.InstanceTypes, ","), typeof(Object) ~= "Instance" and typeof(Object) or Object.ClassName));
                return
            end
            print(Handler._Template);

            local Component = setmetatable({
                _Instance = Object;
                _Janitor = Janitor.new();
            }, Handler._Template);
            

            Handler._Components[Object] = Component;
            local _Janitor = Component._Janitor;
            _Janitor:LinkToInstance(Object);

            _Janitor:Add(function()
                Handler._Components[Object] = nil;
            end, true);

            for Event, Aliases in pairs(AcceptedEvents) do
                if Component[Event] then
                    local Id = Framework:AddEvent(RunService, Event, function(...)
                        Component[Event](Component, ...);
                    end);

                    _Janitor:Add(function()
                        Framework:RemoveEvent(Id);
                    end, true)
                else
                    for _, Alias in pairs(Aliases) do
                        if Component[Alias] then
                            local Id = Framework:AddEvent(RunService, Event, function(...)
                                Component[Alias](Component, ...);
                            end);
        
                            _Janitor:Add(function()
                                Framework:RemoveEvent(Id);
                            end, true)
                        end
                    end
                end
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
            task.defer(Added, Instance);
        end

        return Handler;
    end
}