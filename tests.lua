local LibSerialize = LibStub and LibStub:GetLibrary("LibSerialize") or require("LibSerialize")

local assert = assert
local coroutine = coroutine
local ipairs = ipairs
local math = math
local next = next
local pairs = pairs
local pcall = pcall
local print = print
local require = require
local select = select
local setmetatable = setmetatable
local string = string
local table = table
local tonumber = tonumber
local tostring = tostring
local type = type
local unpack = unpack or table.unpack -- Compatibility with Lua 5.4

-- If in an environment that supports `require` and `_ENV` (note: WoW does not),
-- then block reading/writing of globals. All needed globals should have been
-- converted to upvalues above.
if require and _ENV then
    _ENV = setmetatable({}, {
        __newindex = function(t, k, v)
            assert(false, "Attempt to write to global variable: " .. k)
        end,
        __index = function(t, k)
            assert(false, "Attempt to read global variable: " .. k)
        end
    })
end

function LibSerialize:RunTests()
    --[[---------------------------------------------------------------------------
        Examples from the top of LibSerialize.lua
    --]]---------------------------------------------------------------------------

    do
        local t = { "test", [false] = {} }
        t[ t[false] ] = "hello"
        local serialized = LibSerialize:Serialize(t, "extra")
        local success, tab, str = LibSerialize:Deserialize(serialized)
        assert(success)
        assert(tab[1] == "test")
        assert(tab[ tab[false] ] == "hello")
        assert(str == "extra")
    end

    do
        local serialized = LibSerialize:SerializeEx(
            { errorOnUnserializableType = false },
            print, { a = 1, b = print })
        local success, fn, tab = LibSerialize:Deserialize(serialized)
        assert(success)
        assert(fn == nil)
        assert(tab.a == 1)
        assert(tab.b == nil)
    end

    do
        local t = { a = 1 }
        t.t = t
        t[t] = "test"
        local serialized = LibSerialize:Serialize(t)
        local success, tab = LibSerialize:Deserialize(serialized)
        assert(success)
        assert(tab.t.t.t.t.t.t.a == 1)
        assert(tab[tab.t] == "test")
    end

    do
        local t = { a = 1, b = print, c = 3 }
        local nested = { a = 1, b = print, c = 3 }
        t.nested = nested
        setmetatable(nested, { __LibSerialize = {
            filter = function(t, k, v) return k ~= "c" end
        }})
        local opts = {
            filter = function(t, k, v) return LibSerialize:IsSerializableType(k, v) end
        }
        local serialized = LibSerialize:SerializeEx(opts, t)
        local success, tab = LibSerialize:Deserialize(serialized)
        assert(success)
        assert(tab.a == 1)
        assert(tab.b == nil)
        assert(tab.c == 3)
        assert(tab.nested.a == 1)
        assert(tab.nested.b == nil)
        assert(tab.nested.c == nil)
    end

    do
        local t = { "test", [false] = {} }
        t[ t[false] ] = "hello"
        local co_handler = LibSerialize:SerializeAsync(t, "extra")
        local completed, serialized
        repeat
            completed, serialized = co_handler()
        until completed

        local completed, success, tab, str
        local co_handler = LibSerialize:DeserializeAsync(serialized)
        repeat
            completed, success, tab, str = co_handler()
        until completed

        assert(success)
        assert(tab[1] == "test")
        assert(tab[ tab[false] ] == "hello")
        assert(str == "extra")
    end

    do
        local t = { a = 1, b = 2, c = 3 }

        local StandardWriter = {}
        function StandardWriter:Initialize()
            self.buffer = {}
            self.bufferSize = 0
        end
        function StandardWriter:WriteString(str)
            self.bufferSize = self.bufferSize + 1
            self.buffer[self.bufferSize] = str
        end
        function StandardWriter:Flush()
            local flushed = table.concat(self.buffer, "", 1, self.bufferSize)
            self.bufferSize = 0
            return flushed
        end

        local StandardReader = {}
        function StandardReader:Initialize(input)
            self.input = input
        end
        function StandardReader:ReadBytes(startOffset, endOffset)
            return string.sub(self.input, startOffset, endOffset)
        end
        function StandardReader:AtEnd(offset)
            return offset > #self.input
        end

        StandardWriter:Initialize()
        local serialized = LibSerialize:SerializeEx({ writer = StandardWriter }, t)

        StandardReader:Initialize(serialized)
        local success, tab = LibSerialize:Deserialize(StandardReader)

        assert(success)
        assert(tab.a == 1)
        assert(tab.b == 2)
        assert(tab.c == 3)
    end


    --[[---------------------------------------------------------------------------
        Test of stable serialization
    --]]---------------------------------------------------------------------------

    do
        local t = { a = 1, b = print, c = 3 }
        local nested = { a = 1, b = print, c = 3 }
        t.nested = nested
        setmetatable(nested, { __LibSerialize = {
            filter = function(t, k, v) return k ~= "c" end
        }})
        local opts = {
            filter = function(t, k, v) return LibSerialize:IsSerializableType(k, v) end,
            stable = true
        }
        local serialized = LibSerialize:SerializeEx(opts, t)
        local success, tab = LibSerialize:Deserialize(serialized)
        assert(success)
        assert(tab.a == 1)
        assert(tab.b == nil)
        assert(tab.c == 3)
        assert(tab.nested.a == 1)
        assert(tab.nested.b == nil)
        assert(tab.nested.c == nil)
    end

    do
        local t1 = { x = "y", "test", [false] = { 1, 2, 3, a = "b" } }
        local opts = {
            stable = true,
            filter = function(t, k, v) return not tonumber(k) or tonumber(k) < 100 end
        }
        local serialized1 = LibSerialize:SerializeEx(opts, t1)
        local success1, tab1 = LibSerialize:Deserialize(serialized1)
        assert(success1)
        assert(tab1[1] == "test")
        assert(tab1.x == "y")
        assert(tab1[false][1] == 1)
        assert(tab1[false][2] == 2)
        assert(tab1[false][3] == 3)
        assert(tab1[false].a == "b")

        -- Make a copy of the original table, but first insert a bunch of extra
        -- keys (which we'll filter out) to force the order of the hashes to be
        -- different. Modern Lua runtimes randomize the string-hash seed per
        -- process, so a given construction's iteration order isn't predictable;
        -- we retry with varying filler until we observe a different iteration
        -- order, which is what makes the stability check meaningful.
        --
        -- Each attempt uses a distinct range of numeric-string keys (so the
        -- shared keys collide/land differently) and a filler count that spans
        -- several hash-table capacity boundaries. All filler keys are numeric
        -- and >= 100, so the `opts` filter removes them from the serialization.
        local fillerSizes = { 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383 }

        local function buildCopy(attempt)
            local t2 = {}
            local base = 100 + attempt * 100000
            local count = fillerSizes[((attempt - 1) % #fillerSizes) + 1]
            for i = 0, count - 1 do
                t2[tostring(base + i)] = i
            end
            t2.x = "y"
            t2[1] = "test"
            t2[false] = { 1, 2, 3, a = "b" }
            return t2
        end

        local function iteratesDifferently(t2)
            local isDifferent = false
            local k1, k2 = nil, nil
            while true do
                k1 = next(t1, k1)
                -- get the next key from t2 that's not going to be filtered
                while true do
                    k2 = next(t2, k2)
                    if k2 == nil or not tonumber(k2) or tonumber(k2) < 100 then
                        break
                    end
                end
                if k1 == nil and k2 == nil then
                    break
                end
                assert(k1 ~= nil and k2 ~= nil)
                isDifferent = isDifferent or k1 ~= k2
            end
            return isDifferent
        end

        -- ensure the iteration order is different, retrying a bounded number of
        -- times to be robust against hash-seed randomization
        local t2, isDifferent
        for attempt = 1, 100 do
            t2 = buildCopy(attempt)
            if iteratesDifferently(t2) then
                isDifferent = true
                break
            end
        end
        assert(isDifferent, "could not produce a differing iteration order after 100 attempts")

        -- serialize the copy and ensure the result is the same
        local serialized2 = LibSerialize:SerializeEx(opts, t2)
        assert(serialized2 == serialized1)
    end


    --[[---------------------------------------------------------------------------
        Utilities
    --]]---------------------------------------------------------------------------

    local function isnan(value)
        return (value < 0) == (value >= 0)
    end

    local function tCompare(lhsTable, rhsTable, depth)
        depth = depth or 1
        for key, value in pairs(lhsTable) do
            if type(value) == "table" then
                local rhsValue = rhsTable[key]
                if type(rhsValue) ~= "table" then
                    return false
                end
                if depth > 1 then
                    if not tCompare(value, rhsValue, depth - 1) then
                        return false
                    end
                end
            elseif value ~= rhsTable[key] then
                -- print("mismatched value: " .. key .. ": " .. tostring(value) .. ", " .. tostring(rhsTable[key]))
                return false
            end
        end
        -- Check for any keys that are in rhsTable and not lhsTable.
        for key, value in pairs(rhsTable) do
            if lhsTable[key] == nil then
                -- print("mismatched key: " .. key)
                return false
            end
        end
        return true
    end

    local function Mixin(obj, ...)
        for i = 1, select("#", ...) do
            for k, v in pairs((select(i, ...))) do
                obj[k] = v
            end
        end

        return obj
    end

    local function PackTable(...)
        return { n = select("#", ...), ... }
    end


    --[[---------------------------------------------------------------------------
        Test of Async Mode
    --]]---------------------------------------------------------------------------

    do
        -- Test the async mode by calling it on the same table with two different approaches for
        -- yielding - always and never. They should both produce the same results, but never yielding
        -- should only take a single call to the handler, whereas always yielding will require calling
        -- it one more time than the number of times it yields.

        local t = { "test", [false] = {}, a = 1, b = 2, { c = { 3, d = 4 } } }
        local extra = "extra"
        local expectedYieldChecks = 22

        local callCountNever, callCountAlways = 0, 0
        local function yieldNever()
            callCountNever = callCountNever + 1
            return false
        end
        local function yieldAlways()
            callCountAlways = callCountAlways + 1
            return true
        end

        local serialized
        do
            callCountNever, callCountAlways = 0, 0
            local co_handlerNever = LibSerialize:SerializeAsyncEx({ yieldCheck = yieldNever }, t, extra)
            local completedNever, serializedNever
            local loopCountNever = 0
            repeat
                loopCountNever = loopCountNever + 1
                completedNever, serializedNever = co_handlerNever()
            until completedNever

            local co_handlerAlways = LibSerialize:SerializeAsyncEx({ yieldCheck = yieldAlways }, t, extra)
            local completedAlways, serializedAlways
            local loopCountAlways = 0
            repeat
                loopCountAlways = loopCountAlways + 1
                completedAlways, serializedAlways = co_handlerAlways()
            until completedAlways

            assert(loopCountNever == 1)
            assert(loopCountAlways == callCountAlways + 1)
            assert(callCountAlways == callCountNever)
            assert(serializedNever == serializedAlways)
            assert(callCountAlways == expectedYieldChecks)

            serialized = serializedAlways
        end

        local tab, str
        do
            callCountNever, callCountAlways = 0, 0
            local co_handlerNever = LibSerialize:DeserializeAsync(serialized, { yieldCheck = yieldNever })
            local completedNever, successNever, tabNever, strNever
            local loopCountNever = 0
            repeat
                loopCountNever = loopCountNever + 1
                completedNever, successNever, tabNever, strNever = co_handlerNever()
            until completedNever

            local co_handlerAlways = LibSerialize:DeserializeAsync(serialized, { yieldCheck = yieldAlways })
            local completedAlways, successAlways, tabAlways, strAlways
            local loopCountAlways = 0
            repeat
                loopCountAlways = loopCountAlways + 1
                completedAlways, successAlways, tabAlways, strAlways = co_handlerAlways()
            until completedAlways

            assert(successNever)
            assert(successAlways)
            assert(tCompare(tabNever, tabAlways))
            assert(strNever == strAlways)
            assert(loopCountNever == 1)
            assert(loopCountAlways == callCountAlways + 1)
            assert(callCountAlways == callCountNever)
            assert(callCountAlways == expectedYieldChecks)

            tab = tabAlways
            str = strAlways
        end

        assert(tCompare(t, tab))
        assert(str == extra)

        -- Validate that async calls can properly handle multiple simultaneous operations.
        local t2 = { x = "y", "test", [false] = { 1, 2, 3, a = "b" } }

        local serialized1, serialized2
        do
            local co_handler1 = LibSerialize:SerializeAsyncEx({ yieldCheck = yieldAlways }, t)
            local co_handler2 = LibSerialize:SerializeAsyncEx({ yieldCheck = yieldAlways }, t2)

            local completed1, completed2
            repeat
                if not completed1 then
                    completed1, serialized1 = co_handler1()
                end
                if not completed2 then
                    completed2, serialized2 = co_handler2()
                end
            until completed1 and completed2
        end

        local tab1, tab2
        do
            local co_handler1 = LibSerialize:DeserializeAsync(serialized1, { yieldCheck = yieldAlways })
            local co_handler2 = LibSerialize:DeserializeAsync(serialized2, { yieldCheck = yieldAlways })

            local completed1, completed2, success1, success2
            repeat
                if not completed1 then
                    completed1, success1, tab1 = co_handler1()
                end
                if not completed2 then
                    completed2, success2, tab2 = co_handler2()
                end
            until completed1 and completed2

            assert(success1)
            assert(success2)
        end

        assert(tCompare(t, tab1))
        assert(tCompare(t2, tab2))
    end


    --[[---------------------------------------------------------------------------
        Misc test cases
    --]]---------------------------------------------------------------------------

    do
        -- Verify that encoding nils are handled properly. They should be properly encoded
        -- when serialized and returned when deserialized. The latter is only detectable
        -- via varargs, as other tricks like capturing the returns in a table will strip
        -- the trailing nils.

        local function validate(async, ...)
            local args = {...}
            if async then
                -- completed = true, success = true, then four nils
                assert(select("#", ...) == 6)
                assert(#args == 2)
                assert(args[1] == true)
                assert(args[2] == true)
            else
                -- success = true, then four nils
                assert(select("#", ...) == 5)
                assert(#args == 1)
                assert(args[1] == true)
            end
        end

        local serialized = LibSerialize:Serialize(nil, nil, nil, nil)
        validate(false, LibSerialize:Deserialize(serialized))

        local co_handler = LibSerialize:DeserializeAsync(serialized)
        validate(true, co_handler())

        co_handler = LibSerialize:SerializeAsync(nil, nil, nil, nil)
        local completed, serializedAsync = co_handler()
        assert(completed)
        assert(serialized == serializedAsync)
    end


    --[[---------------------------------------------------------------------------
        Failure test cases
    --]]---------------------------------------------------------------------------

    do
        local failCases = {
            { print },
            { [print] = true },
            { [true] = print },
            print,
        }

        local function doAsyncSerialize(value)
            local co_handler = LibSerialize:SerializeAsync({ yieldCheck = function() return true end }, value)
            repeat
                completed, serialized = co_handler()
            until completed
        end

        for _, testCase in ipairs(failCases) do
            local success = pcall(LibSerialize.Serialize, LibSerialize, testCase)
            assert(success == false)

            local success = pcall(doAsyncSerialize, testCase)
            assert(success == false)
        end
    end


    --[[---------------------------------------------------------------------------
        Test coverage of supported serialization types
    --]]---------------------------------------------------------------------------

    do
        local function fail(index, fromVer, toVer, value, desc, async)
            assert(false, ("Test #%d failed (serialization ver: %s, deserialization ver: %s, async: %s) (%s): %s"):format(index, fromVer, toVer, tostring(async), tostring(value), desc))
        end

        local function testfilter(t, k, v)
            return k ~= "banned" and v ~= "banned"
        end

        local function check(index, fromVer, from, toVer, to, value, bytelen, cmp, async)
            local completed, success, serialized, deserialized

            if async then
                local co_handler = from:SerializeAsyncEx({ errorOnUnserializableType = false, filter = testfilter, yieldCheck = function() return true end }, value)
                repeat
                    completed, serialized = co_handler()
                until completed
            else
                serialized = from:SerializeEx({ errorOnUnserializableType = false, filter = testfilter }, value)
            end

            if #serialized ~= bytelen then
                fail(index, fromVer, toVer, value, ("Unexpected serialized length (%d, expected %d)"):format(#serialized, bytelen), true)
            end

            if async then
                local co_handler = to:DeserializeAsync(serialized, { yieldCheck = function() return true end })
                repeat
                    completed, success, deserialized = co_handler()
                until completed
            else
                success, deserialized = to:Deserialize(serialized)
            end

            if not success then
                fail(index, fromVer, toVer, value, ("Deserialization failed: %s"):format(deserialized), true)
            end

            -- Tests involving NaNs or negative zero will be compared in string
            -- form: `==` treats NaN as unequal to itself and -0.0 as equal to
            -- +0.0, so a direct comparison can't distinguish either case.
            if type(value) == "number" and (isnan(value) or (value == 0 and 1 / value < 0)) then
                value = tostring(value)
                deserialized = tostring(deserialized)
            end

            local typ = type(value)
            if typ == "table" and not tCompare(cmp or value, deserialized) then
                fail(index, fromVer, toVer, value, "Non-matching deserialization result")
            elseif typ ~= "table" and value ~= deserialized then
                fail(index, fromVer, toVer, value, ("Non-matching deserialization result: %s"):format(tostring(deserialized)))
            end
        end

        local function checkLatest(index, value, bytelen, cmp)
            check(index, "latest", LibSerialize, "latest", LibSerialize, value, bytelen, cmp)
            check(index, "latest", LibSerialize, "latest", LibSerialize, value, bytelen, cmp, true)
        end

        -- Format: each test case is { value, bytelen, cmp, earliest }. The value will be serialized
        -- and then deserialized, checking for success and equality, and the length of
        -- the serialized string will be compared against bytelen. If `cmp` is provided,
        -- it will be used for comparison against the deserialized result instead of `value`.
        -- Note that the length always contains one extra byte for the version number.
        -- `earliest` is an index into the `versions` table below, indicating the earliest
        -- version that supports the test case.
        local testCases = {
            { nil, 2 },
            { true, 2 },
            { false, 2 },
            { 0, 2 },
            { 1, 2 },
            { 127, 2 },
            { 128, 3 },
            { 4095, 3 },
            { 4096, 4 },
            { 65535, 4 },
            { 65536, 5 },
            { 16777215, 5 },
            { 16777216, 6 },
            { 4294967295, 6 },
            { 4294967296, 9 },
            { 9007199254740992, 9 },
            { 1.5, 6 },
            { 27.32, 8 },
            { 123.45678901235, 10 },
            { 148921291233.23, 10 },
            { -1 / math.huge, 7, nil, 6 }, -- -0.0
            { -1, 3 },
            { -4095, 3 },
            { -4096, 4 },
            { -65535, 4 },
            { -65536, 5 },
            { -16777215, 5 },
            { -16777216, 6 },
            { -4294967295, 6 },
            { -4294967296, 9 },
            { -9007199254740992, 9 },
            { -1.5, 6 },
            { -123.45678901235, 10 },
            { -148921291233.23, 10 },
            { 0/0, 10, nil, 3 },  -- -1.#IND or -nan(ind)
            { 1/0, 10, nil, 3 },  -- 1.#INF or inf
            { -1/0, 10, nil, 3 }, -- -1.#INF or -inf
            { "", 2 },
            { "a", 3 },
            { "abcdefghijklmno", 17 },
            { "abcdefghijklmnop", 19 },
            { ("1234567890"):rep(30), 304 },
            { {}, 2 },
            { { 1 }, 3 },
            { { 1, 2, 3, 4, 5 }, 7 },
            { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, 17 },
            { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, 19 },
            { { 1, 2, 3, 4, a = 1, b = 2, [true] = 3, d = 4 }, 17 },
            { { 1, 2, 3, 4, 5, a = 1, b = 2, c = true, d = 4 }, 21 },
            { { 1, 2, 3, 4, 5, a = 1, b = 2, c = 3, d = 4, e = false }, 24 },
            { { a = 1, b = 2, c = 3 }, 11 },
            { { "aa", "bb", "aa", "bb" }, 14 },
            { { "aa1", "bb2", "aa3", "bb4" }, 18 },
            { { "aa1", "bb2", "aa1", "bb2" }, 14 },
            { { "aa1", "bb2", "bb2", "aa1" }, 14 },
            { { "abcdefghijklmno", "abcdefghijklmno", "abcdefghijklmno", "abcdefghijklmno" }, 24 },
            { { "abcdefghijklmno", "abcdefghijklmno", "abcdefghijklmno", "abcdefghijklmnop" }, 40 },
            { { 1, 2, 3, print, print, 6 }, 7, { 1, 2, 3, nil, nil, 6 } },
            { { 1, 2, 3, print, 5, 6 }, 8, { 1, 2, 3, nil, 5, 6 } },
            { { a = print, b = 1, c = print }, 5, { b = 1 } },
            { { a = print, [print] = "a" }, 2, {} },
            { { "banned", 1, 2, 3, banned = 4, test = "banned", a = 1 }, 9, { nil, 1, 2, 3, a = 1 } },
            { { 1, 2, [math.huge] = "f", [3] = 3 }, 16, nil, 3 },
            { { 1, 2, [-math.huge] = "f", [3] = 3 }, 16, nil, 3 },
        }

        do
            local t = { a = 1, b = 2 }
            table.insert(testCases, { { t, t, t }, 13 })
            table.insert(testCases, { { { a = 1, b = 2 }, { a = 1, b = 2 }, { a = 1, b = 2 } }, 23 })
        end

        for i, testCase in ipairs(testCases) do
            checkLatest(i, unpack(testCase))
        end

        if require then
            local versions = {
                { "v1.0.0", require("archive.LibSerialize-v1-0-0") },
                { "v1.1.0", require("archive.LibSerialize-v1-1-0") },
                -- v1.1.1 skipped due to bug with serialization version causing known failures.
                { "v1.1.2", require("archive.LibSerialize-v1-1-2") },
                { "v1.1.3", require("archive.LibSerialize-v1-1-3") },
                { "v1.2.1", require("archive.LibSerialize-v1-2-1") },
                { "latest", LibSerialize },
            }

            for i = 1, #versions do
                for j = i + 1, #versions do
                    local fromVer, from = unpack(versions[i])
                    local toVer, to = unpack(versions[j])

                    for k, testCase in ipairs(testCases) do
                        local value, bytelen, cmp, earliest = unpack(testCase)
                        if not earliest or (i >= earliest and j >= earliest) then
                            check(k, fromVer, from, toVer, to, value, bytelen, cmp)
                            check(k, toVer, to, fromVer, from, value, bytelen, cmp)
                        end
                    end
                end
            end
        end
    end


    --[[---------------------------------------------------------------------------
        Test cases for generic readers
    --]]---------------------------------------------------------------------------

    -- This test will verify that we don't attempt to deserialize beyond
    -- the end of the 'data' string which has some unprocessable text
    -- after it.

    do
        local LimitedReader = {}

        function LimitedReader:ReadBytes(i, j)
            return string.sub(self.bytes, i, j)
        end

        function LimitedReader:AtEnd(i)
            return i > self.limit
        end

        local function CreateLimitedReader(bytes, limit)
            return Mixin({ bytes = bytes, limit = limit }, LimitedReader)
        end

        local value = "banana"
        local bytes = LibSerialize:Serialize(value)
        local input = CreateLimitedReader(bytes .. "WithSomeExtraData", #bytes)

        local output = PackTable(LibSerialize:DeserializeValue(input))

        assert(output.n == 1, "expected one value to be deserialized")
        assert(output[1] == value, "expected original value to be deserialized")
    end

    -- This test verifies that we can read a sequence of numeric bytes from a
    -- table as our input stream. No custom 'AtEnd' logic is needed as the
    -- table will support the default length operator test.

    do
        local ByteReader = {}

        function ByteReader:ReadBytes(i, j)
            assert(i >= 1)      -- 'i' should always be a non-zero positive integer.
            assert(j >= i)      -- 'j' will always be after or at the same place as 'i'
            assert(j <= #self)  -- 'j' will never exceed the length of the input.

            return table.concat({ string.char(unpack(self, i, j)) }, "")
        end

        local function CreateByteReader(bytes)
            return Mixin({ string.byte(bytes, 1, #bytes) }, ByteReader)
        end

        local value = { 1, true, false, "banana" }
        local bytes = LibSerialize:Serialize(value)
        local input = CreateByteReader(bytes)

        local output = LibSerialize:DeserializeValue(input)

        assert(tCompare(output, value), "expected 'output' to be identical to 'value'")
    end

    -- This test verifies that a stream of a potentially-unknown length can
    -- be fed through LibSerialize, such as reading data from a network and
    -- processing it within a coroutine.

    do
        local StreamReader = {}

        function StreamReader:ReadBytes(i, j)
            -- For testing simplicity, our "bytes" buffer is just append-only.

            while self.canReadMore and j > #self.bytes do
                local bytes, finished = assert(coroutine.yield())
                self.bytes = self.bytes .. bytes
                self.canReadMore = not finished
            end

            return string.sub(self.bytes, i, j)
        end

        function StreamReader:AtEnd(i)
            return not self.canReadMore and i > #self.bytes
        end

        local function CreateStreamReader()
            return Mixin({ canReadMore = true, bytes = "" }, StreamReader)
        end

        -- Use a large table for 'value' with a large range of numbers as
        -- this gives the best coverage for testing multiple ReadBytes
        -- calls between each yield, as well as a good range of sizes for
        -- the range (i, j).

        local value = {}

        for i = 1, 1000 do
            value[i] = i * 1000
        end

        local bytes = LibSerialize:Serialize(value)
        local input = CreateStreamReader()
        local thread = coroutine.create(function() return LibSerialize:DeserializeValue(input) end)

        -- The thread is expected to suspend on the first call into ReadBytes.

        assert(coroutine.resume(thread))
        assert(coroutine.status(thread) == "suspended", "expected 'thread' to have suspended")

        -- Now resume the thread repeatedly feeding in a large chunk each
        -- time it yields back to us, until we've run out of data.

        local output

        do
            local remaining = bytes
            local chunkSize = 100

            while remaining ~= "" do
                local chunk = string.sub(remaining, 1, chunkSize)
                local after = string.sub(remaining, chunkSize + 1)
                local finished = (after == "")
                local ok

                ok, output = coroutine.resume(thread, chunk, finished)
                assert(ok, output)  -- If not ok, 'output' will be an error.

                remaining = after
            end
        end

        -- At this point the thread is expected to be dead and we should have
        -- obtained the result of deserialization.

        assert(coroutine.status(thread) == "dead", "expected 'thread' to have finished executing")
        assert(type(output) == type(value), "expected 'output' to be same type as 'value'")
        assert(tCompare(output, value), "expected 'output' to be identical to 'value'")
    end

    -- This test verifies that while reading we can throttle the rate of
    -- processing by yielding the current thread, allowing deserialization
    -- to be batched into chunks based on the number of bytes processed.

    do
        local ThrottledReader = {}

        function ThrottledReader:ReadBytes(i, j)
            if self.read >= self.rate then
                coroutine.yield()
                self.read = self.read - self.rate
            end

            local length = (j - i) + 1
            self.read = self.read + length
            return string.sub(self.bytes, i, j)
        end

        function ThrottledReader:AtEnd(i)
            return i > #self.bytes
        end

        local function CreateThrottledReader(bytes, rate)
            return Mixin({ bytes = bytes, rate = rate, read = 0 }, ThrottledReader)
        end

        -- Use a large table for 'value' so that the thread the deserializer
        -- runs into will yield a good number of times.

        local value = {}

        for i = 1, 1000 do
            value[i] = i * 1000
        end

        local bytes = LibSerialize:Serialize(value)
        local input = CreateThrottledReader(bytes, 256)
        local thread = coroutine.create(function() return LibSerialize:DeserializeValue(input) end)

        -- This test mostly serves as an example, but...

        local output

        while coroutine.status(thread) ~= "dead" do
            local ok
            ok, output = coroutine.resume(thread)
            assert(ok, output)  -- If not ok, 'output' will be an error.
        end

        assert(type(output) == type(value), "expected 'output' to be same type as 'value'")
        assert(tCompare(output, value), "expected 'output' to be identical to 'value'")
    end


    --[[---------------------------------------------------------------------------
        Test cases for generic writers
    --]]---------------------------------------------------------------------------

    -- This test verifies the basic functionality of a custom writer that
    -- writes to a reusable buffer and returns its concatenated result to
    -- the serializer.

    do
        local PersistentBuffer = {}

        function PersistentBuffer:WriteString(str)
            self.n = self.n + 1
            self[self.n] = str
        end

        function PersistentBuffer:Flush()
            local flushed = table.concat(self, "", 1, self.n)
            self.n = 0
            return flushed
        end

        local function CreatePersistentBuffer()
            return Mixin({ n = 0 }, PersistentBuffer)
        end

        local value = { 1, 2, 3, 4, 5, true, false, "banana" }
        local writer = CreatePersistentBuffer()
        local bytes = LibSerialize:SerializeEx({ writer = writer }, value)

        assert(type(bytes) == "string", "expected 'bytes' to be a string")
        assert(writer.n == 0, "expected 'writer' to have been flushed")

        local output = LibSerialize:DeserializeValue(bytes)

        assert(type(output) == type(value), "expected 'output' to be of the same type as 'value'")
        assert(tCompare(output, value), "expected 'output' to be fully comparable to 'value'")
    end

    -- This test verifies that if no Flush implementation is given, the default
    -- will return nothing from the Serialize function. As documented in the
    -- library, it's expected that such a writer would likely be submitting
    -- string as it gets them to another destination.

    do
        local NullWriter = {}

        function NullWriter:WriteString(str)
            assert(type(str) == "string")  -- 'str' should always be a string
            self.writes = self.writes + 1
        end

        local function CreateNullWriter()
            return Mixin({ writes = 0 }, NullWriter)
        end

        local value = { 1, 2, 3, 4, 5, true, false, "banana" }
        local writer = CreateNullWriter()
        local result = PackTable(LibSerialize:SerializeEx({ writer = writer }, value))

        assert(result.n == 0, "expected no return values from 'SerializeEx' call")
        assert(writer.writes > 0, "expected 'WriteString' to have been called at least once")
    end

    -- This test verifies that the pace at which serialization occurs can be
    -- throttled within a coroutine.

    do
        local ThrottledWriter = {}

        function ThrottledWriter:WriteString(str)
            if self.written > self.rate then
                coroutine.yield()
                self.written = self.written - self.rate
            end

            local length = #str
            self.written = self.written + length
            self.size = self.size + 1
            self.buffer[self.size] = str
        end

        function ThrottledWriter:Flush()
            local flushed = table.concat(self.buffer, "", 1, self.size)
            self.size = 0
            return flushed
        end

        local function CreateThrottledWriter(rate)
            return Mixin({ buffer = {}, size = 0, written = 0, rate = rate }, ThrottledWriter)
        end

        -- Use a large table for 'value' so that the thread the serializer
        -- yields a few times.

        local value = {}

        for i = 1, 1000 do
            value[i] = i * 1000
        end

        local writer = CreateThrottledWriter(100)
        local thread = coroutine.create(function() return LibSerialize:SerializeEx({ writer = writer }, value) end)

        local bytes

        while coroutine.status(thread) ~= "dead" do
            local ok
            ok, bytes = coroutine.resume(thread)
            assert(ok, bytes)  -- If not ok, 'bytes' will be an error.
        end

        assert(type(bytes) == "string", "expected 'bytes' to be a string")
        assert(writer.size == 0, "expected 'writer' to have been flushed")

        local output = LibSerialize:DeserializeValue(bytes)

        assert(type(output) == type(value), "expected 'output' to be of the same type as 'value'")
        assert(tCompare(output, value), "expected 'output' to be fully comparable to 'value'")
    end

    --[[---------------------------------------------------------------------------
        Regression: stable serialization with reference-type keys
    --]]---------------------------------------------------------------------------

    -- Sorting map keys for `stable` serialization previously errored whenever a
    -- table contained two or more keys whose types have no value ordering
    -- (tables, functions, ...) or an incomparable mix (e.g. boolean + table).

    do
        local k1, k2 = {}, {}
        local value = { [k1] = "one", [k2] = "two", plain = 3 }

        local bytes = LibSerialize:SerializeEx({ stable = true }, value)
        local success, out = LibSerialize:Deserialize(bytes)
        assert(success, "stable serialization with table keys should not error")
        assert(out.plain == 3, "expected plain key to round-trip")

        local tableKeyCount, seenValues = 0, {}
        for k, v in pairs(out) do
            if type(k) == "table" then
                tableKeyCount = tableKeyCount + 1
                seenValues[v] = true
            end
        end
        assert(tableKeyCount == 2, "expected two table keys to round-trip")
        assert(seenValues["one"] and seenValues["two"], "expected table-key values to round-trip")

        -- Determinism within a run: re-serializing the same object is identical.
        assert(LibSerialize:SerializeEx({ stable = true }, value) == bytes,
            "expected stable serialization to be deterministic within a run")

        -- Mixed incomparable key types (boolean vs table, table vs table).
        local mixed = { [true] = 1, [{}] = 2, [{}] = 3, s = "x" }
        assert(pcall(LibSerialize.SerializeEx, LibSerialize, { stable = true }, mixed),
            "stable serialization with mixed incomparable keys should not error")

        -- Two reference-type keys surviving a filter must still sort cleanly.
        local filtered = { [{}] = 1, [{}] = 2, [print] = 3 }
        assert(pcall(LibSerialize.SerializeEx, LibSerialize,
            { stable = true, errorOnUnserializableType = false }, filtered),
            "stable serialization must not crash when sorting filtered reference keys")
    end


    --[[---------------------------------------------------------------------------
        Regression: whole numbers too large for the integer encoding
    --]]---------------------------------------------------------------------------

    -- Whole numbers with magnitude >= 2^56 don't fit the 56-bit integer encoding
    -- and were previously truncated silently (and math.mininteger errored). They
    -- now fall back to the lossless double encoding.

    do
        local function roundtrip(value)
            local success, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
            assert(success, "expected large-number serialization to succeed")
            return out
        end

        -- Whole doubles too large for the 56-bit integer encoding round-trip
        -- exactly via the lossless double encoding.
        assert(roundtrip(2^56) == 2^56, "expected 2^56 to round-trip")
        assert(roundtrip(-(2^56)) == -(2^56), "expected -2^56 to round-trip")
        assert(roundtrip(2^60) == 2^60, "expected 2^60 to round-trip")
        assert(roundtrip(2^63) == 2^63, "expected 2^63 to round-trip")

        -- 2^53 is the largest power of two still handled by the exact integer
        -- byte path (values below the 2^56 float-fallback threshold).
        assert(roundtrip(9007199254740992) == 9007199254740992,
            "expected 2^53 to round-trip via the integer path")

        -- Native 64-bit integers (Lua 5.3+) are encoded as their exact decimal
        -- string, so they round-trip exactly and preserve the integer subtype.
        if math.maxinteger then
            local integerCases = {
                9007199254740993,     -- 2^53 + 1
                72057594037927935,    -- 2^56 - 1 (previously corrupted to 255)
                72057594037927937,    -- 2^56 + 1
                1152921504606846977,  -- 2^60 + 1
                1311768467294899695,  -- 0x1234567890ABCDEF
                math.maxinteger,      -- 2^63 - 1
                math.mininteger,      -- -2^63
            }
            for _, value in ipairs(integerCases) do
                local out = roundtrip(value)
                assert(out == value,
                    ("expected integer %s to round-trip exactly (got %s)"):format(
                        tostring(value), tostring(out)))
                assert(math.type(out) == "integer",
                    ("expected %s to remain an integer"):format(tostring(value)))
            end
        end
    end


    --[[---------------------------------------------------------------------------
        Regression: subnormal (denormal) floating point values
    --]]---------------------------------------------------------------------------

    -- Subnormal values were previously flushed to zero on serialization.

    do
        local function roundtrip(value)
            local success, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
            assert(success, "expected subnormal serialization to succeed")
            return out
        end

        local smallestSubnormal = 2^-1074
        local largestSubnormal = (2^-1022) - (2^-1074)

        assert(smallestSubnormal ~= 0, "sanity: smallest subnormal is non-zero")
        assert(roundtrip(smallestSubnormal) == smallestSubnormal,
            "expected smallest subnormal to round-trip")
        assert(roundtrip(-smallestSubnormal) == -smallestSubnormal,
            "expected negative smallest subnormal to round-trip")
        assert(roundtrip(2^-1050) == 2^-1050, "expected mid-range subnormal to round-trip")
        assert(roundtrip(2^-1023) == 2^-1023, "expected subnormal near boundary to round-trip")
        assert(roundtrip(largestSubnormal) == largestSubnormal,
            "expected largest subnormal to round-trip")

        -- The smallest normal value must remain unaffected.
        assert(roundtrip(2^-1022) == 2^-1022, "expected smallest normal to round-trip")
    end


    --[[---------------------------------------------------------------------------
        Regression: non-table __LibSerialize metatable field
    --]]---------------------------------------------------------------------------

    -- A non-table (but truthy) __LibSerialize field was indexed unconditionally,
    -- raising an error. It should now be ignored gracefully.

    do
        for _, marker in ipairs({ true, 42, "nope" }) do
            local value = setmetatable({ a = 1, b = 2 }, { __LibSerialize = marker })
            local success, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
            assert(success, "expected serialization to ignore non-table __LibSerialize")
            assert(out.a == 1 and out.b == 2, "expected contents to round-trip")
        end
    end


    --[[---------------------------------------------------------------------------
        Regression: integer subtype preservation (Lua 5.3+)
    --]]---------------------------------------------------------------------------

    -- Embedded integers previously decoded as floats (the decoder used float
    -- division), so `math.type` wasn't preserved and was inconsistent across the
    -- value range. All integer values should now decode back as integers, across
    -- every encoding path (embedded 7-bit / 12-bit, multi-byte, decimal string).

    do
        if math.type then
            local integerValues = {
                0, 1, 127,                       -- embedded 7-bit
                128, 4095, -1, -128, -4095,      -- embedded 12-bit (+/-)
                4096, 65535, -4096, -65535,      -- 16-bit
                65536, 16777215, -16777215,      -- 24-bit
                16777216, 4294967295, -4294967295, -- 32-bit
                4294967296, 9007199254740992,    -- 56-bit (<= 2^53)
                -9007199254740992,
                9007199254740993, -- 2^53 + 1 (decimal string path)
                72057594037927935, -- 2^56 - 1
                math.maxinteger, math.mininteger,
            }
            for _, value in ipairs(integerValues) do
                local ok, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
                assert(ok, "expected integer serialization to succeed")
                assert(out == value,
                    ("expected %s to round-trip"):format(tostring(value)))
                assert(math.type(out) == "integer",
                    ("expected %s to decode as an integer (got %s)"):format(
                        tostring(value), math.type(out) or "nil"))
            end

            -- Whole-valued floats normalize to integers (the format doesn't
            -- distinguish 2 from 2.0); fractional and non-finite values stay floats.
            assert(math.type((select(2, LibSerialize:Deserialize(LibSerialize:Serialize(2.0))))) == "integer",
                "expected whole float 2.0 to normalize to an integer")
            for _, value in ipairs({ 1.5, -27.32, 1/0, -1/0, 0/0 }) do
                local ok, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
                assert(ok and math.type(out) == "float",
                    ("expected %s to decode as a float"):format(tostring(value)))
            end
        end
    end


    --[[---------------------------------------------------------------------------
        Coverage: multi-byte counts and lengths (16-bit and 24-bit paths)
    --]]---------------------------------------------------------------------------

    -- ARRAY_16 and STR_16 are exercised elsewhere (the 1000-element streaming
    -- tests and the 300-byte string). These cover the larger map counts and the
    -- 24-bit count/length paths for arrays, strings, tables, and mixed tables.

    do
        local function roundtrip(v)
            local ok, out = LibSerialize:Deserialize(LibSerialize:Serialize(v))
            assert(ok, "large-structure serialization failed")
            return out
        end

        -- Map with 300 string keys -> TABLE_16 (2-byte count)
        local map16 = {}
        for i = 1, 300 do map16["k" .. i] = i end
        assert(tCompare(roundtrip(map16), map16), "300-key map (TABLE_16) round-trip")

        -- Map with 70000 string keys -> TABLE_24 (3-byte count)
        local map24 = {}
        for i = 1, 70000 do map24["k" .. i] = i end
        assert(tCompare(roundtrip(map24), map24), "70000-key map (TABLE_24) round-trip")

        -- Array with 70000 elements -> ARRAY_24 (3-byte count)
        local array24 = {}
        for i = 1, 70000 do array24[i] = i end
        assert(tCompare(roundtrip(array24), array24), "70000-element array (ARRAY_24) round-trip")

        -- String of 70000 bytes -> STR_24 (3-byte length)
        local string24 = ("ab"):rep(35000)
        assert(roundtrip(string24) == string24, "70000-byte string (STR_24) round-trip")

        -- Mixed table with 300 array + 300 map entries -> MIXED_16
        local mixed16 = {}
        for i = 1, 300 do mixed16[i] = i end
        for i = 1, 300 do mixed16["m" .. i] = i end
        assert(tCompare(roundtrip(mixed16), mixed16), "mixed table (MIXED_16) round-trip")

        -- Mixed table with 70000 array entries + a few map entries -> MIXED_24
        local mixed24 = {}
        for i = 1, 70000 do mixed24[i] = i end
        mixed24.a, mixed24.b, mixed24.c = 1, 2, 3
        assert(tCompare(roundtrip(mixed24), mixed24), "mixed table (MIXED_24) round-trip")
    end


    --[[---------------------------------------------------------------------------
        Coverage: multi-byte reference indices (STRINGREF_16 / TABLEREF_16)
    --]]---------------------------------------------------------------------------

    -- With more than 255 unique interned strings/tables, later references must
    -- use a 2-byte index, exercising the 16-bit reference paths (the 8-bit paths
    -- are covered by the existing interning tests).

    do
        -- 400 distinct >2-byte strings, each referenced twice.
        local strings = {}
        for i = 1, 400 do strings[i] = "unique-string-" .. i end
        local strValue = {}
        for i = 1, 400 do
            strValue[#strValue + 1] = strings[i]
            strValue[#strValue + 1] = strings[i]
        end
        local sok, sout = LibSerialize:Deserialize(LibSerialize:Serialize(strValue))
        assert(sok, "string-ref-heavy value should deserialize")
        for i = 1, 400 do
            assert(sout[2 * i - 1] == strings[i] and sout[2 * i] == strings[i],
                "STRINGREF_16 round-trip")
        end

        -- 400 distinct shared subtables, each referenced twice.
        local subtables = {}
        for i = 1, 400 do subtables[i] = { id = i } end
        local tblValue = {}
        for i = 1, 400 do
            tblValue[#tblValue + 1] = subtables[i]
            tblValue[#tblValue + 1] = subtables[i]
        end
        local tok, tout = LibSerialize:Deserialize(LibSerialize:Serialize(tblValue))
        assert(tok, "table-ref-heavy value should deserialize")
        for i = 1, 400 do
            assert(tout[2 * i - 1].id == i, "TABLEREF_16 value round-trip")
            assert(tout[2 * i - 1] == tout[2 * i], "TABLEREF_16 identity/dedup preserved")
        end
    end


    --[[---------------------------------------------------------------------------
        Coverage: malformed / adversarial input is handled gracefully
    --]]---------------------------------------------------------------------------

    -- The safe Deserialize API must never crash on bad input (it decodes
    -- untrusted data, e.g. from addon comms); it should return false instead.

    do
        local valid = LibSerialize:Serialize({ 1, 2, 3, "hello", { a = 1 } })

        -- Truncated input.
        assert(LibSerialize:Deserialize(valid:sub(1, #valid - 1)) == false,
            "truncated input should fail gracefully")

        -- Empty input (no version byte).
        assert(LibSerialize:Deserialize("") == false,
            "empty input should fail gracefully")

        -- Unknown (too-high) serialization version.
        assert(LibSerialize:Deserialize(string.char(255) .. valid:sub(2)) == false,
            "unknown version should fail gracefully")

        -- Out-of-range string reference: STRINGREF_8 (type 26) with index 5 and
        -- nothing interned. This is defined to decode to nil, not to error.
        local badRef = string.char(1, 26 * 8, 5)
        local okRef = LibSerialize:Deserialize(badRef)
        assert(okRef == true, "out-of-range reference should decode gracefully (to nil)")

        -- Deeply nested input: 200000 nested single-element arrays. Should be
        -- caught as a stack overflow rather than crashing the process.
        local embeddedArray1 = string.char(16 * 1 + 4 * 2 + 2)
        local deep = string.char(1) .. string.rep(embeddedArray1, 200000) .. string.char(0)
        assert(LibSerialize:Deserialize(deep) == false,
            "deeply nested input should fail gracefully (stack overflow caught)")
    end


    --[[---------------------------------------------------------------------------
        Coverage: DeserializeValue vs Deserialize error semantics
    --]]---------------------------------------------------------------------------

    do
        local truncated = LibSerialize:Serialize({ 1, 2, 3 })
        truncated = truncated:sub(1, #truncated - 1)

        -- Deserialize catches errors and returns (false, message).
        local ok, err = LibSerialize:Deserialize(truncated)
        assert(ok == false, "Deserialize should catch errors and return false")
        assert(type(err) == "string", "Deserialize should return an error message")

        -- DeserializeValue does not catch; it raises (must be wrapped in pcall).
        assert(pcall(function() return LibSerialize:DeserializeValue(truncated) end) == false,
            "DeserializeValue should raise on malformed input")

        -- DeserializeAsync always catches: it completes with success = false.
        local handler = LibSerialize:DeserializeAsync(truncated)
        local completed, success
        repeat
            completed, success = handler()
        until completed
        assert(success == false, "DeserializeAsync should complete with success = false")
    end


    --[[---------------------------------------------------------------------------
        Coverage: IsSerializableType
    --]]---------------------------------------------------------------------------

    do
        assert(LibSerialize:IsSerializableType() == true, "no arguments is serializable")
        assert(LibSerialize:IsSerializableType(nil) == true, "nil is serializable")
        assert(LibSerialize:IsSerializableType(true) == true, "boolean is serializable")
        assert(LibSerialize:IsSerializableType(42) == true, "number is serializable")
        assert(LibSerialize:IsSerializableType("s") == true, "string is serializable")
        assert(LibSerialize:IsSerializableType({}) == true, "table is serializable")
        assert(LibSerialize:IsSerializableType(1, "a", true) == true, "all-serializable varargs")

        assert(LibSerialize:IsSerializableType(print) == false, "function is not serializable")
        assert(LibSerialize:IsSerializableType(coroutine.create(function() end)) == false,
            "thread is not serializable")
        assert(LibSerialize:IsSerializableType(1, print) == false,
            "any unserializable argument makes the result false")

        -- Documented: a table argument is considered serializable even if it
        -- contains unserializable keys or values (only the arg types are checked).
        assert(LibSerialize:IsSerializableType({ [print] = print, a = print }) == true,
            "a table is serializable regardless of its contents")
    end


    --[[---------------------------------------------------------------------------
        Coverage: incomplete writer is ignored
    --]]---------------------------------------------------------------------------

    -- A writer object without WriteString does not satisfy the Writer protocol
    -- and must be ignored, falling back to the default buffered-string result.

    do
        local incompleteWriter = { Flush = function() return "should-not-be-used" end }
        local value = { 1, 2, 3, "test" }
        local bytes = LibSerialize:SerializeEx({ writer = incompleteWriter }, value)
        assert(type(bytes) == "string", "incomplete writer should fall back to a buffered string")
        assert(bytes ~= "should-not-be-used", "incomplete writer's Flush should be ignored")
        local ok, out = LibSerialize:Deserialize(bytes)
        assert(ok and tCompare(out, value), "fallback result should round-trip")
    end


    --[[---------------------------------------------------------------------------
        Coverage: Flush return values are passed through verbatim
    --]]---------------------------------------------------------------------------

    do
        -- Multiple values (including a nil in the middle) are all returned.
        local multiWriter = {
            WriteString = function() end,
            Flush = function() return "a", 2, nil, true end,
        }
        local r = PackTable(LibSerialize:SerializeEx({ writer = multiWriter }, { 1 }))
        assert(r.n == 4, "expected all four Flush values to be returned")
        assert(r[1] == "a" and r[2] == 2 and r[3] == nil and r[4] == true,
            "Flush values should pass through verbatim")

        -- A writer with no Flush returns nothing from SerializeEx.
        local noFlushWriter = { WriteString = function() end }
        local r2 = PackTable(LibSerialize:SerializeEx({ writer = noFlushWriter }, { 1 }))
        assert(r2.n == 0, "expected no return values when Flush is absent")
    end


    --[[---------------------------------------------------------------------------
        Coverage: large integers as table keys (Lua 5.3+)
    --]]---------------------------------------------------------------------------

    -- The large-integer regression tests use these values as table values; this
    -- exercises them as keys (key encoding + integer-subtype key round-trip).

    do
        if math.type then
            local key1 = 72057594037927935 -- 2^56 - 1
            local key2 = math.maxinteger
            local key3 = math.mininteger
            local value = { [key1] = "a", [key2] = "b", [key3] = "c" }

            local ok, out = LibSerialize:Deserialize(LibSerialize:Serialize(value))
            assert(ok, "large-integer-keyed table should serialize")
            assert(out[key1] == "a", "2^56-1 key round-trip")
            assert(out[key2] == "b", "math.maxinteger key round-trip")
            assert(out[key3] == "c", "math.mininteger key round-trip")
            for k in pairs(out) do
                assert(math.type(k) == "integer", "large integer keys keep the integer subtype")
            end
        end
    end


    print("All tests passed!")
end

-- Run tests immediately when executed from a non-WoW environment.
if require then
    LibSerialize:RunTests()
end
