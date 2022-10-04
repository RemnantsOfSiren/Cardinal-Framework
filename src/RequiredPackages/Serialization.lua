do
    -- [[ Library ]] --
    local Serializer = {};

    local Callables;

    Callables = {
        ["Vector2"] = {
            Serialize = function(Data)
                return {[1] = Data.X, [2] = Data.Y};
            end;
            
            Deserialize = function(Data)
                return Vector2.new(Data[1], Data[2]);
            end;
        };

        ["Vector3"] = {
            Serialize = function(Data)
                return {[1] = Data.X, [2] = Data.Y, [3] = Data.Z};
            end;
            
            Deserialize = function(Data)
                return Vector3.new(Data[1], Data[2], Data[3]);
            end;
        };

        ["CFrame"] = {
            Serialize = function(Data)
                local Callable = Callables.Vector3.Serialize;
                return {
                    [1] = Callable(Data.Position);
                    [2] = Callable(Data.RightVector);
                    [3] = Callable(Data.UpVector);
                    [4] = Callable(-Data.LookVector);
                }
            end;

            Deserialize = function(Data)
                local Callable = Callables.Vector3.Deserialize;
                return CFrame.new(
                    Callable(Data[1]),
                    Callable(Data[2]),
                    Callable(Data[3]),
                    Callable(Data[4])
                )
            end
        };

        ["Color3"] = {
            Serialize = function(Data)
                return {Data:toHSV()};
            end;

            Deserialize = function(Data)
                return Color3.fromHSV(unpack(Data));
            end;
        };

        ["BrickColor"] = {
            Serialize = function(Data)
                return Callables.Color3.Serialize(Data.Color);
            end;

            Deserialize = function(Data)
                return Callables.Color3.Deserialize(Data);
            end;
        }
    }

    function Serializer:SerializeData(Table: table)
        if not Table then
            return nil;
        end

        local Data = {};

        for Index, Value in pairs(Table) do
            local Type = typeof(Value);
            local Serializer = Callables[Type] and Callables[Type].Serialize;

            if Serializer then
                Data[Index] = {Type = Type, Serializer(Value)};
            elseif Type == "table" then
                Data[Index] = self:SerializeData(Value);
            else
                Data[Index] = Value;
            end
        end

        return Data;
    end

    function Serializer:DeserializeData(Table: table)
        if not Table then
            return nil;
        end

        local Data = {};

        for Index, Info in pairs(Table) do
            local Type;
            if typeof(Info) == "table" then
                if Info.Type then
                    Type = Info.Type;
                else
                    Data[Index] = self:DeserializeData(Info);
                    continue
                end
            end
            
            if not Type then
                Data[Index] = Info;
                continue
            end

            local Deserializer = Callables[Type] and Callables[Type].Deserialize;
            if Deserializer then
                Data[Index] = Deserializer(Info.Value);
            end
        end

        return Data;
    end

    return Serializer;
end