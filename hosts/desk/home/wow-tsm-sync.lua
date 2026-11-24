-- wow-tsm-sync: copy every TradeSkillMaster setting from one WoW account's
-- SavedVariables to another's (hosts/desk/home/wow-tsm-sync.nix).
--
--   lua wow-tsm-sync.lua SRC.lua DST.lua OUT.lua
--
-- A setting is a TradeSkillMasterDB key of the global, profile, factionrealm
-- or realm scope ("g@", "p@", "f@", "r@") that is not internal data. The
-- destination keeps its own characters ("c@"), sync data ("s@"), internal
-- data, item-info cache (TSMItemInfoDB) and the "_" bookkeeping keys, except
-- that _lastModifiedVersion takes the source's entries for the copied
-- settings. Both files must be of the same TSM build (_version and _hash).
--
-- Exit status: 0 and "unchanged" when the destination already holds every
-- setting (OUT is not written); 0 and "wrote OUT" after OUT was written and
-- read back equal to the merge; 1 on any error, OUT left unwritten or removed.

local src, dst, out = arg[1], arg[2], arg[3]
assert(src and dst and out, "usage: lua wow-tsm-sync.lua SRC.lua DST.lua OUT.lua")

-- Each file's globals, loaded in a sandbox: SavedVariables are plain data.
local function load(path)
  local f = assert(loadfile(path))
  local env = {}
  setfenv(f, env)
  f()
  return env
end

local function eq(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, v in pairs(a) do if not eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end

local S, D = load(src), load(dst)
local SD, DD = S.TradeSkillMasterDB, D.TradeSkillMasterDB
assert(type(SD) == "table", src .. " has no TradeSkillMasterDB")
assert(type(DD) == "table", dst .. " has no TradeSkillMasterDB")
assert(SD._version == DD._version and SD._hash == DD._hash,
  "the two accounts have different TSM builds; log in once on each with the same TSM")

local function setting(k)
  return type(k) == "string" and k:match("^[gpfr]@") ~= nil and k:match("@internalData@") == nil
end

local M = copy(D)
local MD = M.TradeSkillMasterDB
for k in pairs(MD) do if setting(k) then MD[k] = nil end end
for k, v in pairs(SD) do if setting(k) then MD[k] = copy(v) end end
if type(SD._lastModifiedVersion) == "table" then
  MD._lastModifiedVersion = MD._lastModifiedVersion or {}
  for k, v in pairs(SD._lastModifiedVersion) do
    -- these keys have no scope name: "g@coreOptions@x"
    if k:match("^[gpfr]@") and not k:match("^%a@internalData@") then MD._lastModifiedVersion[k] = v end
  end
end

if eq(M, D) then print("unchanged"); return end

-- Serialize, in the shape WoW writes (WoW rewrites the file on its next save).
local buf = {}
local function put(s) buf[#buf + 1] = s end
local function num(v)
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
  return string.format("%.17g", v)
end
local function key(k)
  if type(k) == "number" then return "[" .. num(k) .. "]" end
  if type(k) == "string" then return "[" .. string.format("%q", k):gsub("\\\n", "\\n") .. "]" end
  if type(k) == "boolean" then return "[" .. tostring(k) .. "]" end
  error("unexpected key type " .. type(k))
end
local function val(v)
  local t = type(v)
  if t == "string" then return (string.format("%q", v):gsub("\\\n", "\\n")) end
  if t == "number" then return num(v) end
  if t == "boolean" then return tostring(v) end
  error("unexpected value type " .. t)
end
local function ser(t)
  local n = #t
  for i = 1, n do
    local v = t[i]
    if type(v) == "table" then put("{\n"); ser(v); put("}, -- [" .. i .. "]\n")
    else put(val(v) .. ", -- [" .. i .. "]\n") end
  end
  for k, v in pairs(t) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
      if type(v) == "table" then put(key(k) .. " = {\n"); ser(v); put("},\n")
      else put(key(k) .. " = " .. val(v) .. ",\n") end
    end
  end
end
local names = {}
for g in pairs(M) do names[#names + 1] = g end
table.sort(names, function(a, b)
  if a == "TradeSkillMasterDB" then return b ~= a end
  if b == "TradeSkillMasterDB" then return false end
  return a < b
end)
put("\n")
for _, g in ipairs(names) do
  assert(type(g) == "string" and g:match("^[%a_][%w_]*$"), "unexpected global name")
  if type(M[g]) == "table" then put(g .. " = {\n"); ser(M[g]); put("}\n")
  else put(g .. " = " .. val(M[g]) .. "\n") end
end

local f = assert(io.open(out, "w"))
f:write(table.concat(buf))
f:close()
local ok, R = pcall(load, out)
if not ok or not eq(R, M) then
  os.remove(out)
  error("the written file does not read back as the merge; nothing changed")
end
print("wrote " .. out)
