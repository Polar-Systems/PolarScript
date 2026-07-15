--[[
██████╗  ██████╗ ██╗      █████╗ ██████╗ ███████╗ ██████╗██████╗ ██╗██████╗ ████████╗
██╔══██╗██╔═══██╗██║     ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██║██╔══██╗╚══██╔══╝
██████╔╝██║   ██║██║     ███████║██████╔╝███████╗██║     ██████╔╝██║██████╔╝   ██║
██╔═══╝ ██║   ██║██║     ██╔══██║██╔══██╗╚════██║██║     ██╔══██╗██║██╔═══╝    ██║
██║     ╚██████╔╝███████╗██║  ██║██║  ██║███████║╚██████╗██║  ██║██║██║        ██║
╚═╝      ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝
--]]



--[[
PolarScript server addon.

Handles auth (no-workshop server, self-built vehicles only), vehicle limits,
antisteal/PvP toggles, an antilag system that despawns oversized creations,
warn/kick/ban moderation, a live debug log stream, map markers, and a small
set of admin tools.

Two things worth knowing before touching this file:

1. Vehicle titles can't be read. server.getVehicleName was pulled from the
   addon API in the Space DLC update and hasn't come back. The "MADE BY"
   ownership check only sees component NAME fields typed in the editor, not
   a vehicle's actual saved title or a sign's displayed text.

2. server.httpGet only reaches localhost on the machine running the server.
   The verified/admin access lists and the Discord warn webhook need a small
   local relay server running on the same box to actually reach the internet.
   See CONFIG.HTTP_* below.

playtime, pvp, and warn/kick counts persist in g_savedata (keyed by steam_id).
Everything else resets on reload.
]]

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CONFIG
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local CONFIG                 = {
    SERVER_NAME                    = "(server name)",
    SCRIPT_NAME                    = "PolarScript",
    SCRIPT_VERSION                 = "1.0",
    DEFAULT_VEHICLE_LIMIT          = 1,
    UI_REFRESH_TICKS               = 30,
    HEAL_CHECK_TICKS               = 30,
    TPS_WINDOW_TICKS               = 60,
    DESPAWN_VEHICLES_ON_LEAVE      = true,
    APPLY_PER_TICK                 = 4,
    FLIP_Y_OFFSET                  = 2.0,
    VTP_HEIGHT                     = 5.0,
    VTP_VERIFY_TOLERANCE           = 15.0,
    VTP_MOVED_MIN                  = 5.0,
    VTP_VERIFY_DELAY_MS            = 300,
    DEFAULT_UI_ON                  = true,
    DEFAULT_ANTISTEAL              = true,
    DEFAULT_PVP                    = false,

    ANTILAG_ENABLED                = true,
    SPAWN_POPUP                    = true,

    LAG_W_VOXELS                   = 1.0,
    LAG_W_MASS                     = 2.0,
    LAG_W_COMPONENTS               = 15.0,
    LAG_W_SUBBODY                  = 400.0,

    LAG_PLAYER_FACTOR              = 0.15,
    LAG_AGE_WEIGHT                 = 0.5,
    LAG_AGE_DECAY                  = 600,

    -- Untuned guess, retune from real ?dbg readings.
    LAG_MAX_COST                   = 240000,

    MAX_SUBBODIES_PER_GROUP        = 25,
    MAX_BLOCKS_PER_GROUP           = 100000,
    ANTILAG_MAX_SPAWN_TIME_SEC     = 2.5,

    ANTILAG_COUNTDOWN_SEC          = 3,

    LAG_SPAWN_GRACE_SEC            = 5.0,

    -- Two tiers: below NORMAL_TPS despawns the single worst group, below CRITICAL_TPS
    -- sustained for CRITICAL_SUSTAIN_SEC despawns everything at once.
    ANTILAG_NORMAL_TPS             = 40,
    ANTILAG_CRITICAL_TPS           = 10,
    ANTILAG_CRITICAL_SUSTAIN_SEC   = 5,

    NUKE_MAGNITUDE                 = 10.0,
    GRID_SPACING                   = 12.0,
    HYPER_GRID                     = 5,
    MEGA_GRID                      = 9,
    NUKE_PER_TICK                  = 15,

    PROFANITY_BAN                  = true,
    MAX_LIMIT                      = 10,
    CLEAN_VEHICLES_ON_LOAD         = true,

    -- No API to scan the whole map, so ?flares can only retry drops this script has seen.
    AUTO_DESPAWN_DROPPED_EQUIPMENT = true,

    WARNS_BEFORE_KICK              = 3,
    KICKS_BEFORE_BAN               = 3,

    -- server.httpGet only reaches localhost; needs a local relay server on HTTP_PORT to reach the internet.
    HTTP_ENABLED                   = false,
    HTTP_PORT                      = 8080,
    HTTP_PATH_VERIFIED             = "/verified",
    HTTP_PATH_ADMINS               = "/admins",
    HTTP_PATH_WARN                 = "/warn",
    HTTP_POLL_SEC                  = 60,

    -- Keys MUST be quoted STRINGS ("76561198...") -- a bare numeric key silently never matches.
    OWNERS                         = { ["76561198305443102"] = true },
    ADMINS                         = {},
    MODERATORS                     = {},

    TELEPORT_ARID_DLC              = true,

    HOLD_RADIUS                    = 3.0,
    HOLD_HEIGHT                    = 1.0,
    FREEZE_UPDATE_TICKS            = 3,

    ECONOMY_ENABLED                = true,
    ECONOMY_STARTING_BALANCE       = 500,
    PAYREQUEST_TTL_SEC             = 300,

    -- No API to detect a real trailer -- jobs verify by mass parked at the destination instead.
    CARGO_PAYOUT_BASE              = 50,
    CARGO_PAYOUT_PER_KM            = 8,
    CARGO_PAYOUT_CAP               = 600,
    CARGO_MASS_REQUIRED_BASE       = 500,
    CARGO_MASS_REQUIRED_PER_KM     = 20,
    CARGO_PICKUP_RADIUS            = 40.0,
    CARGO_DELIVERY_RADIUS          = 40.0,
    CARGO_COOLDOWN_SEC             = 60,

    -- Purely a visual marker on ?cargo accept -- delivery is still verified by mass. 0 = disabled.
    CARGO_CONTAINER_COMPONENT_ID   = 0,

    FUEL_PRICE_PER_UNIT            = 2,
    FUEL_STATION_RADIUS            = 40.0,

    TOOL_PRICE_OUTFIT              = 150,
    TOOL_PRICE_WEAPON              = 100,
    TOOL_PRICE_ITEM                = 40,
}

-- Stored normalized (lowercase a-z, after leet substitution), whole-word match only.
local SLURS                  = {
    ["nigger"] = true,
    ["nigga"]  = true,
    ["faggot"] = true,
    ["fag"]    = true,
    ["retard"] = true,
    ["chink"]  = true,
    ["spic"]   = true,
    ["kike"]   = true,
}

-- Only server.notify() toasts can be colored. IDs are undocumented, inferred from testing.
local NOTIFY                 = {
    GREEN  = 4,
    YELLOW = 2,
    ORANGE = 1,
    RED    = 3,
}

-- TAJIN is an image-to-vehicle converter that tags its own output this way, not a stolen build.
local MADE_BY_EXCEPTIONS     = {
    ["TAJIN"] = true,
}

-- ?tp location list; array index is the id a player types.
local TELEPORT_NAMES_DLC     = {
    "Multiplayer Hangar", "Multiplayer Dock", "Creative Island", "ONeill", "Harrison",
    "North Harbour Terminal", "North Harbour Dock", "Arctic Hangar", "Arctic Dock",
    "Uran Wind", "Clarke Hangar", "30 Dollar Train Yard", "FJ Warner Dock",
    "Etrain Terminal", "FJ Warner Hangar", "Endair",
}
local TELEPORT_NAMES         = {
    "Multiplayer Hangar", "Multiplayer Dock", "Creative Island", "ONeill", "Harrison",
    "North Harbour Terminal", "North Harbour Dock", "Arctic Hangar", "Arctic Dock",
}

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- UI IDs / positions
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local UI_MAIN                = 9001
local UI_CENTER              = 9003
-- LEGACY, kept only to clear stale client popups.
local UI_COUNTDOWN           = 9005
local UI_ANTILAG_NORMAL      = 9006
local UI_ANTILAG_CRITICAL    = 9007

local UI_X_MAIN              = -0.89
local UI_Y_MAIN              = 0.60
local UI_X_CENTER            = 0.0
local UI_Y_CENTER            = 0.0
local UI_X_COUNTDOWN         = 0.0
local UI_Y_COUNTDOWN         = 0.15

-- Smaller Y = lower on screen in this UI system.
local UI_X_ANTILAG_NORMAL    = UI_X_MAIN
local UI_Y_ANTILAG_NORMAL    = UI_Y_MAIN - 0.60
local UI_X_ANTILAG_CRITICAL  = UI_X_MAIN
local UI_Y_ANTILAG_CRITICAL  = UI_Y_MAIN - 0.50

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- STATE (in-memory)
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- players:  [peer_id] = { steam_id, name, is_admin, authed, ui, pvp, antisteal, limit, speed, alt, last_pos }
-- groups:   [group_id] = { owner_steam, vehicles={[vid]=true}, bodyCount, spawn_tick, cost, voxels, announced }
-- bodyCount is a LIVE counter, never recompute it by looping g.vehicles.
local players                = {}
local steamToPeer            = {}
local groups                 = {}
local vehicleToGroup         = {}
local vehicleCost            = {}
local vehicleVoxels          = {}
local pendingApply           = {}
local popupCache             = {}
local frozen                 = {}
local nukeQueue              = {}
-- blockedGroups: group failed a hard limit, stays blocked for every straggler sub-body too.
local blockedGroups          = {}
local looseEquipment         = {}
-- pendingDestroy: [group_id] = { deadline_ms, ownerPeer, ownerName, publicReason, ownerReason }.
local pendingDestroy         = {}
-- pendingVtpVerify: [group_id] = { peer_id, target, beforePos, repVid, verify_ms }.
local pendingVtpVerify       = {}

local verifiedSet            = {}
local adminSet               = {}
-- httpQueue drains 1 request/tick -- SW allows 1 httpGet/tick.
local httpQueue              = {}
local teleportCache          = nil
local cargoZoneCache         = nil

local globalLimit            = CONFIG.DEFAULT_VEHICLE_LIMIT
local lastPlayerCount        = 0

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COUNTERS / TIMERS
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local tickCount              = 0
local uiTimer                = 0
local healTimer              = 0
local tpsTimer               = 0
local freezeTimer            = 0
local dbgHeartbeatTimer      = 0
local httpPollTimer          = 0
local tpsLastMs              = 0
local tpsNow                 = 60
local tpsAvg                 = 60
local startMs                = 0
-- Runtime override for CONFIG.ANTILAG_NORMAL_TPS, set via ?antilag <n>; nil = use config default.
local antilagNormalTps       = nil
local criticalWasHealthy     = true
-- Wall-clock ms when tps first dropped below ANTILAG_CRITICAL_TPS.
local criticalSinceMs        = 0
local antilagNormalUiShown   = false
local antilagCriticalUiShown = false

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PERSISTENT STATE
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- All keyed by steam_id. warns resets to 0 on auto-kick; kicks is a lifetime count.
g_savedata                   = g_savedata or {}
g_savedata.playtime          = g_savedata.playtime or {}
g_savedata.pvp               = g_savedata.pvp or {}
g_savedata.warns             = g_savedata.warns or {}
g_savedata.kicks             = g_savedata.kicks or {}
g_savedata.wallet            = g_savedata.wallet or {}

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- UTILITIES
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function say(peer_id, msg)
    server.announce("[" .. CONFIG.SERVER_NAME .. "]", msg, peer_id)
end

local function notify(peer_id, title, msg, kind)
    server.notify(peer_id, title, msg, NOTIFY[kind] or NOTIFY.YELLOW)
end

local function broadcastNotify(title, msg, kind)
    for peer_id in pairs(players) do
        notify(peer_id, title, msg, kind)
    end
end

-- Leveled debug stream, per-admin via "?dbg <0-5>". Cumulative: level N shows everything <= N.
local function dbgLog(level, tag, msg)
    for peer_id, p in pairs(players) do
        if p.is_admin and (p.dbgLevel or 0) >= level then
            server.announce("[DBG" .. level .. "/" .. tag .. "]", msg, peer_id)
        end
    end
end

-- No pcall in this sandbox, so a call to a missing server function is an uncatchable crash;
-- checking the type first turns that into a logged no-op instead.
local function safeServer(fnName, ...)
    local fn = server[fnName]
    if type(fn) ~= "function" then
        dbgLog(1, "ERROR", "server." .. fnName .. " is unavailable in this build, skipped")
        for peer_id, p in pairs(players) do
            if p.is_admin then
                notify(peer_id, "Script Error",
                    "server." .. fnName .. " is unavailable, a feature relying on it was skipped.", "RED")
            end
        end
        return false
    end
    fn(...)
    return true
end

-- Same guard as safeServer, but keeps the return value.
local function safeServerQuery(fnName, ...)
    local fn = server[fnName]
    if type(fn) ~= "function" then
        dbgLog(1, "ERROR", "server." .. fnName .. " is unavailable in this build, skipped")
        return false
    end
    return true, fn(...)
end

local function onOff(v) return v and "on" or "off" end

local function fmtHMSShort(seconds)
    local s   = math.floor(seconds or 0)
    local h   = math.floor(s / 3600)
    local m   = math.floor((s % 3600) / 60)
    local sec = s % 60
    return h .. "h " .. m .. "m " .. sec .. "s"
end

local function fmtCost(c) return string.format("%.0f", c or 0) end

-- Defined here (not down in ECONOMY) so it's in scope for requestVtpTeleport() further up.
local function dist3(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function getP(peer_id) return players[peer_id] end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- WALLET
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local function fmtMoney(n) return string.format("%.0f", n or 0) end

-- Lazily seeds a new steam_id at CONFIG.ECONOMY_STARTING_BALANCE on first read -- every
-- other wallet function routes through this rather than touching g_savedata.wallet directly.
local function getBalance(steam_id)
    g_savedata.wallet = g_savedata.wallet or {}
    if g_savedata.wallet[steam_id] == nil then
        g_savedata.wallet[steam_id] = CONFIG.ECONOMY_STARTING_BALANCE
    end
    return g_savedata.wallet[steam_id]
end

local function hasBalance(steam_id, amount)
    return getBalance(steam_id) >= (amount or 0)
end

local function setBalance(steam_id, amount)
    g_savedata.wallet = g_savedata.wallet or {}
    g_savedata.wallet[steam_id] = math.max(0, amount or 0)
    return g_savedata.wallet[steam_id]
end

-- Clamped at 0, never lets a balance go negative.
local function addBalance(steam_id, amount)
    return setBalance(steam_id, getBalance(steam_id) + (amount or 0))
end

-- Deducts only if funds are sufficient; callers must check the return value.
local function deductBalance(steam_id, amount)
    if not hasBalance(steam_id, amount) then return false end
    g_savedata.wallet[steam_id] = getBalance(steam_id) - amount
    return true
end

local function isModerator(p)
    return p ~= nil and CONFIG.MODERATORS[p.steam_id] == true
end

-- The only tier that can touch root access.
local function isOwner(p)
    return p ~= nil and CONFIG.OWNERS[p.steam_id] == true
end

-- Rank string, used on the map marker. OWNER > ADMIN > MODERATOR > PLAYER (authed) > GUEST.
local function rankOf(p)
    if not p then return "GUEST" end
    if CONFIG.OWNERS[p.steam_id] then return "OWNER" end
    if p.is_admin then return "ADMIN" end
    if isModerator(p) then return "MODERATOR" end
    if p.authed then return "PLAYER" end
    return "GUEST"
end

-- Only ever grants access, never revokes.
local function applyAccess(peer_id)
    local p = players[peer_id]
    if not p then return end
    local isAdmin = adminSet[p.steam_id] or CONFIG.OWNERS[p.steam_id] or CONFIG.ADMINS[p.steam_id]
    if isAdmin then
        if not p.is_admin then
            p.is_admin = true
            safeServer("addAdmin", peer_id)
        end
        if not p.authed then
            p.authed = true
            server.addAuth(peer_id)
        end
    elseif verifiedSet[p.steam_id] then
        if not p.authed then
            p.authed = true
            server.addAuth(peer_id)
        end
    end
end

local function applyAccessToAll()
    for peer_id in pairs(players) do applyAccess(peer_id) end
end

-- Format-agnostic: a steam64 id is always a 17-digit number, so any 17+ digit run matches.
local function parseSteamIds(reply)
    local set = {}
    if type(reply) == "string" then
        for id in reply:gmatch("%d+") do
            if #id >= 17 then set[id] = true end
        end
    end
    return set
end

-- Guarded so we never stack duplicates if a poll fires while requests are still pending.
local function queueHttpLists()
    if not CONFIG.HTTP_ENABLED then return end
    local want = { CONFIG.HTTP_PATH_VERIFIED, CONFIG.HTTP_PATH_ADMINS }
    for _, path in ipairs(want) do
        local already = false
        for i = 1, #httpQueue do
            if httpQueue[i] == path then
                already = true
                break
            end
        end
        if not already then httpQueue[#httpQueue + 1] = path end
    end
end

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- No dedup, unlike queueHttpLists -- each warn has distinct steam_id/reason and should always fire.
local function queueHttpRequest(path)
    if not CONFIG.HTTP_ENABLED then return end
    httpQueue[#httpQueue + 1] = path
end

local function ownerName(g)
    local op = steamToPeer[g.owner_steam]
    return (op and players[op] and players[op].name) or "offline"
end

-- Exact matches are checked in a full pass before substring matches, so "?tp Sam" can't
-- resolve to "Samantha" instead depending on table iteration order.
local function resolveTarget(arg)
    if arg == nil then return nil end
    local asNum = tonumber(arg)
    if asNum and players[asNum] then return asNum end
    local needle = tostring(arg):lower()
    for peer_id, p in pairs(players) do
        if p.name and p.name:lower() == needle then return peer_id end
    end
    for peer_id, p in pairs(players) do
        if p.name and p.name:lower():find(needle, 1, true) then return peer_id end
    end
    return nil
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PROFANITY
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local LEET = { ["0"] = "o", ["1"] = "i", ["3"] = "e", ["4"] = "a", ["5"] = "s", ["7"] = "t", ["@"] = "a", ["$"] = "s" }

local function normalizeWord(w)
    w = w:lower()
    w = w:gsub(".", function(ch) return LEET[ch] or ch end)
    w = w:gsub("[^a-z]", "")
    return w
end

-- A run of consecutive short tokens (<=2 letters) glues together too, to catch
-- "n i g g e r" spacing evasion without false-positiving on normal short words.
local function containsSlur(message)
    local run = ""
    for word in message:gmatch("%S+") do
        local nw = normalizeWord(word)
        if nw ~= "" and SLURS[nw] then return true end

        if nw ~= "" and #nw <= 2 then
            run = run .. nw
            if SLURS[run] then return true end
        else
            run = ""
        end
    end
    return false
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- OWNERSHIP / GROUPS
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function countGroupsOwned(steam_id)
    local n = 0
    for _, g in pairs(groups) do
        if g.owner_steam == steam_id then n = n + 1 end
    end
    return n
end

local function groupsOwnedBy(steam_id)
    local list = {}
    for group_id, g in pairs(groups) do
        if g.owner_steam == steam_id then list[#list + 1] = group_id end
    end
    return list
end

local function getOrCreateGroup(group_id, steam_id)
    local g = groups[group_id]
    if not g then
        g = {
            owner_steam = steam_id,
            vehicles    = {},
            bodyCount   = 0,
            spawn_tick  = tickCount,
            spawn_ms    = server.getTimeMillisec(),
            cost        = 0,
            voxels      = 0,
        }
        groups[group_id] = g
    end
    return g
end

-- Forward-declared: defined in MAP MARKERS below, but destroyGroup needs it above that.
local updateGroupMarker, removeGroupMarker, updatePlayerMarker, removePlayerMarker

-- `silent` skips the generic despawn broadcast, for callers that send their own toast.
local function destroyGroup(group_id, silent)
    local g = groups[group_id]
    if not g then return false end
    local nm = ownerName(g)
    server.despawnVehicleGroup(group_id, true)
    for vehicle_id in pairs(g.vehicles) do
        vehicleToGroup[vehicle_id] = nil
        vehicleCost[vehicle_id] = nil
        vehicleVoxels[vehicle_id] = nil
        pendingApply[vehicle_id] = nil
    end
    groups[group_id] = nil
    blockedGroups[group_id] = nil
    removeGroupMarker(group_id)
    if not silent then
        broadcastNotify("Vehicle Despawned", "Owner: " .. nm .. "\nGroup ID: " .. group_id, "YELLOW")
    end
    return true
end

-- Instant removal for a hard-limit violation -- no warning, no countdown.
local function smiteHardLimit(group_id, reason)
    local g = groups[group_id]
    if not g then return end
    local nm = ownerName(g)
    blockedGroups[group_id] = true
    destroyGroup(group_id, true)
    broadcastNotify("Antilag", nm .. "'s creation was removed, " .. reason .. ".", "ORANGE")
    dbgLog(2, "ANTILAG", "instant smite: group " .. group_id .. " (" .. nm .. "), " .. reason)
end

local function destroyAllGroupsOf(steam_id)
    local ids = groupsOwnedBy(steam_id)
    for i = 1, #ids do destroyGroup(ids[i]) end
    return #ids
end

-- cancelIfHealthy marks a TPS-cull entry that gets spared if TPS recovers before the deadline;
-- hard-limit triggers never pass this.
local function scheduleGroupDestroy(group_id, ownerPeer, ownerReason, publicReason, cancelIfHealthy)
    pendingDestroy[group_id] = {
        deadline_ms = server.getTimeMillisec() + CONFIG.ANTILAG_COUNTDOWN_SEC * 1000,
        ownerPeer = ownerPeer,
        ownerReason = ownerReason,
        publicReason = publicReason,
        cancelIfHealthy = cancelIfHealthy or false,
    }
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- WARN / KICK / BAN
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- De-auths the target (needs ?auth, not ?noworkshop, to get back in); escalates every
-- WARNS_BEFORE_KICK-th warning to a kick, every KICKS_BEFORE_BAN-th kick to a ban.
local function warnPlayer(target_peer, reason, byName)
    local tp = players[target_peer]
    if not tp then return false end
    local steam_id = tp.steam_id
    reason = (reason and reason ~= "") and reason or "No reason given"

    g_savedata.warns = g_savedata.warns or {}
    g_savedata.kicks = g_savedata.kicks or {}

    g_savedata.warns[steam_id] = (g_savedata.warns[steam_id] or 0) + 1
    local warnCount = g_savedata.warns[steam_id]

    notify(target_peer, "Warned",
        "Reason: " .. reason ..
        "\nWarnings: " .. warnCount .. "/" .. CONFIG.WARNS_BEFORE_KICK, "RED")
    tp.authed = false
    tp.revoked = true
    server.removeAuth(target_peer)
    local removed = destroyAllGroupsOf(steam_id)
    server.announce("[MODERATION]",
        tp.name .. " was warned (" .. warnCount .. "/" .. CONFIG.WARNS_BEFORE_KICK .. "): " .. reason, -1)
    dbgLog(2, "MODERATION", byName .. " warned " .. tp.name .. " (" .. warnCount .. "/" ..
        CONFIG.WARNS_BEFORE_KICK .. ", removed " .. removed .. " vehicle group(s)): " .. reason)
    queueHttpRequest(CONFIG.HTTP_PATH_WARN .. "?steam_id=" .. steam_id .. "&reason=" .. urlEncode(reason))

    if warnCount >= CONFIG.WARNS_BEFORE_KICK then
        g_savedata.warns[steam_id] = 0
        g_savedata.kicks[steam_id] = (g_savedata.kicks[steam_id] or 0) + 1
        local kickCount = g_savedata.kicks[steam_id]

        if kickCount >= CONFIG.KICKS_BEFORE_BAN then
            server.announce("[MODERATION]", tp.name .. " reached " .. CONFIG.KICKS_BEFORE_BAN .. " kicks, BANNED.", -1)
            dbgLog(2, "MODERATION", tp.name .. " auto-banned (kick #" .. kickCount .. ")")
            safeServer("banPlayer", target_peer)
        else
            server.announce("[MODERATION]",
                tp.name .. " reached " .. CONFIG.WARNS_BEFORE_KICK .. " warnings, KICKED (" ..
                kickCount .. "/" .. CONFIG.KICKS_BEFORE_BAN .. " kicks).", -1)
            dbgLog(2, "MODERATION", tp.name .. " auto-kicked (" .. kickCount .. "/" .. CONFIG.KICKS_BEFORE_BAN .. ")")
            safeServer("kickPlayer", target_peer)
        end
    end
    return true
end

local function enforceLimit(steam_id)
    local peer_id = steamToPeer[steam_id]
    local p = peer_id and players[peer_id]
    local limit = (p and p.limit) or globalLimit
    while countGroupsOwned(steam_id) > limit do
        local oldestId, oldestTick = nil, math.huge
        for group_id, g in pairs(groups) do
            if g.owner_steam == steam_id and g.spawn_tick < oldestTick then
                oldestId, oldestTick = group_id, g.spawn_tick
            end
        end
        if not oldestId then break end
        dbgLog(2, "LIMIT", "group " .. oldestId .. " (steam " .. steam_id .. ") despawned, over limit " .. limit)
        destroyGroup(oldestId)
        if peer_id then say(peer_id, "Vehicle limit (" .. limit .. ") reached, despawned your oldest creation.") end
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LAG COST
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function normalizeName(s)
    return (s or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
end

-- server.getVehicleName was removed from the API, so a vehicle's real saved title can't be
-- read -- this only catches a maker tag someone typed into a component's name field.
local function analyzeVehicle(vehicle_id)
    local d, ok = server.getVehicleComponents(vehicle_id)
    if not ok or not d then return 0, 0, nil end
    local voxels = d.voxels or 0
    local mass = d.mass or 0

    local componentCount = 0
    local maker = nil
    if d.components then
        for _, category in pairs(d.components) do
            for _, comp in pairs(category) do
                componentCount = componentCount + 1
                if not maker and comp.name then
                    -- Stops at the first punctuation, so "MADE BY TAJIN - v2" captures just "TAJIN".
                    local m = comp.name:upper():match("MADE BY%s+([%w][%w%s]*)")
                    if m then maker = normalizeName(m) end
                end
            end
        end
    end
    if d.characters then
        for _ in pairs(d.characters) do componentCount = componentCount + 1 end
    end

    local cost = voxels * CONFIG.LAG_W_VOXELS + mass * CONFIG.LAG_W_MASS + componentCount * CONFIG.LAG_W_COMPONENTS
    return cost, voxels, maker
end

local function normalTpsThreshold()
    return antilagNormalTps or CONFIG.ANTILAG_NORMAL_TPS
end

-- Reads g.bodyCount (O(1)) rather than counting g.vehicles each call.
local function effectiveCost(group_id)
    local g = groups[group_id]
    if not g then return 0 end
    local raw = (g.cost or 0) + (g.bodyCount or 0) * CONFIG.LAG_W_SUBBODY
    -- Fresh spawns cost more, decaying to 0 over LAG_AGE_DECAY ticks.
    local age = tickCount - (g.spawn_tick or tickCount)
    local ageBonus = math.max(0, 1 - age / CONFIG.LAG_AGE_DECAY) * CONFIG.LAG_AGE_WEIGHT
    return raw * (1 + lastPlayerCount * CONFIG.LAG_PLAYER_FACTOR) * (1 + ageBonus)
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- VEHICLE SETTINGS (antisteal / pvp / tooltip)
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function applyVehicleSettings(vehicle_id)
    local group_id = vehicleToGroup[vehicle_id]
    if not group_id then return end
    local g = groups[group_id]
    if not g then return end

    local peer_id = steamToPeer[g.owner_steam]
    local p = peer_id and players[peer_id]

    local antisteal = (p and p.antisteal)
    if antisteal == nil then antisteal = CONFIG.DEFAULT_ANTISTEAL end
    local pvp = (p and p.pvp)
    if pvp == nil then pvp = g_savedata.pvp[g.owner_steam] end
    if pvp == nil then pvp = CONFIG.DEFAULT_PVP end
    local nm = (p and p.name) or "offline"

    server.setVehicleEditable(vehicle_id, not antisteal)
    server.setVehicleInvulnerable(vehicle_id, not pvp)
    server.setVehicleTooltip(vehicle_id,
        "Owner: " .. nm ..
        "\nVehicle ID: " .. tostring(group_id) ..
        "\nLag cost: " .. fmtCost(effectiveCost(group_id)))
    dbgLog(5, "APPLY", "vehicle " .. vehicle_id .. ", antisteal=" .. tostring(antisteal) .. " pvp=" .. tostring(pvp))
end

local function queueApplyAllOf(steam_id)
    for _, g in pairs(groups) do
        if g.owner_steam == steam_id then
            for vehicle_id in pairs(g.vehicles) do pendingApply[vehicle_id] = true end
        end
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MAP MARKERS (?hide) -- green for vehicle groups, orange for players
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Markers are PARENTED to a vehicle_id/character object_id rather than a raw x/z, so the
-- engine follows the vehicle/player on its own.
local MAP_POS_VEHICLE    = 1
local MAP_POS_OBJECT     = 2
local MAP_ICON_VEHICLE   = 12
local MAP_ICON_PLAYER    = 1
local MAP_ID_PLAYER_BASE = 20000
local MAP_ID_GROUP_BASE  = 30000

local function clearMapObject(id, alsoPeer)
    safeServer("removeMapObject", -1, id)
    if alsoPeer then safeServer("removeMapObject", alsoPeer, id) end
end

-- Idempotent: g.mapVid/g.mapTarget track what's already placed so a 20-body creation
-- doesn't re-place its marker 20 times in one spawn burst.
function updateGroupMarker(group_id)
    local g = groups[group_id]
    local id = MAP_ID_GROUP_BASE + group_id
    if not g then
        clearMapObject(id, nil)
        return
    end
    local ownerPeer = steamToPeer[g.owner_steam]
    local ownerP = ownerPeer and players[ownerPeer]
    local hidden = (ownerP and ownerP.hidden) or false
    local target = hidden and ownerPeer or -1

    local haveVid = g.mapVid and g.vehicles[g.mapVid]
    local firstVid = haveVid and g.mapVid or next(g.vehicles)
    if not firstVid or (hidden and not ownerPeer) then
        if g.mapVid then
            clearMapObject(id, nil)
            g.mapVid, g.mapTarget = nil, nil
        end
        return
    end

    if g.mapVid == firstVid and g.mapTarget == target then return end

    clearMapObject(id, ownerPeer)
    local nm = ownerName(g)
    safeServer("addMapObject", target, id, MAP_POS_VEHICLE, MAP_ICON_VEHICLE, 0, 0, 0, 0, firstVid, 0,
        nm .. " | Group " .. group_id, 0,
        "Owner: " .. nm .. "\nGroup ID: " .. group_id .. "\nVehicle: " .. firstVid, 0, 255, 0, 255)
    g.mapVid, g.mapTarget = firstVid, target
    dbgLog(5, "MARKER", "group " .. group_id .. " marker placed on vehicle " .. firstVid)
end

function removeGroupMarker(group_id)
    clearMapObject(MAP_ID_GROUP_BASE + group_id, nil)
end

-- Called every UI refresh but only touches the map API when something actually changed.
function updatePlayerMarker(peer_id)
    local p = getP(peer_id)
    if not p then return end
    local id = MAP_ID_PLAYER_BASE + peer_id

    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then
        if p.mapCharId then
            clearMapObject(id, peer_id)
            p.mapCharId, p.mapHidden, p.mapRank = nil, nil, nil
        end
        return
    end

    local rank = rankOf(p)
    -- Also re-places when RANK changes (auth granted, promoted to admin, etc).
    if p.mapCharId == charId and p.mapHidden == p.hidden and p.mapRank == rank then return end

    clearMapObject(id, peer_id)
    local target = p.hidden and peer_id or -1
    local label = p.name .. " [" .. rank .. "]"
    safeServer("addMapObject", target, id, MAP_POS_OBJECT, MAP_ICON_PLAYER, 0, 0, 0, 0, 0, charId,
        label, 0, label .. " (peer " .. peer_id .. ")", 255, 140, 0, 255)
    p.mapCharId, p.mapHidden, p.mapRank = charId, p.hidden, rank
    dbgLog(5, "MARKER", peer_id .. " marker placed (" .. rank .. ")")
end

function removePlayerMarker(peer_id)
    clearMapObject(MAP_ID_PLAYER_BASE + peer_id, peer_id)
    local p = getP(peer_id)
    if p then p.mapCharId, p.mapHidden, p.mapRank = nil, nil, nil end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- EQUIPMENT (?tool)
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local OUTFIT_IDS = {
    [1] = true,
    [2] = true,
    [3] = true,
    [4] = true,
    [5] = true,
    [29] = true,
    [74] = true,
    [75] = true,
    [76] = true,
    [77] = true,
    [78] = true,
    [79] = true,
    [80] = true,
    [149] = true,
}

-- Used only to pick a ?tool price tier (CONFIG.TOOL_PRICE_WEAPON).
local WEAPON_IDS = {
    [13] = true,
    [14] = true,
    [31] = true,
    [32] = true,
    [33] = true,
    [34] = true,
    [35] = true,
    [36] = true,
    [37] = true,
    [38] = true,
    [39] = true,
    [40] = true,
    [41] = true,
}

local function toolPrice(eqId)
    if OUTFIT_IDS[eqId] then return CONFIG.TOOL_PRICE_OUTFIT end
    if WEAPON_IDS[eqId] then return CONFIG.TOOL_PRICE_WEAPON end
    return CONFIG.TOOL_PRICE_ITEM
end
local EQUIPMENT_NAMES   = {
    -- Outfits
    [1] = "diving",
    [2] = "firefighter",
    [3] = "scuba",
    [4] = "parachute",
    [5] = "arctic",
    [29] = "hazmat",
    [74] = "bomb_disposal",
    [75] = "chest_rig",
    [76] = "black_hawk_vest",
    [77] = "plate_vest",
    [78] = "armor_vest",
    [79] = "space_suit",
    [80] = "space_suit_exploration",
    [149] = "firefighter_scba",
    -- Items
    [6] = "binoculars",
    [7] = "cable",
    [8] = "compass",
    [9] = "defibrillator",
    [10] = "fire_extinguisher",
    [11] = "first_aid",
    [12] = "flare",
    [13] = "flaregun",
    [14] = "flaregun_ammo",
    [15] = "flashlight",
    [16] = "hose",
    [17] = "night_vision_binoculars",
    [18] = "oxygen_mask",
    [19] = "radio",
    [20] = "radio_signal_locator",
    [21] = "remote_control",
    [22] = "rope",
    [23] = "strobe_light",
    [24] = "strobe_light_infrared",
    [25] = "transponder",
    [26] = "underwater_welding_torch",
    [27] = "welding_torch",
    [28] = "coal_ore_ingot",
    [30] = "radiation_detector",
    [31] = "c4",
    [32] = "c4_detonator",
    [33] = "speargun",
    [34] = "speargun_ammo",
    [35] = "pistol",
    [36] = "pistol_ammo",
    [37] = "smg",
    [38] = "smg_ammo",
    [39] = "rifle",
    [40] = "rifle_ammo",
    [41] = "grenade",
    [72] = "glowstick",
    [73] = "dog_whistle",
    [81] = "fishing_rod",
    -- Ammo boxes, shells, and fish/crustaceans deliberately excluded.
}

-- Keyed by the name with underscores turned into spaces, so both "?tool fire_extinguisher"
-- and "?tool fire extinguisher" work.
local EQUIPMENT_BY_NAME = {}
for id, nm in pairs(EQUIPMENT_NAMES) do
    EQUIPMENT_BY_NAME[(nm:gsub("_", " "))] = id
end
EQUIPMENT_BY_NAME["coal"] = 28
EQUIPMENT_BY_NAME["ore"] = 28
EQUIPMENT_BY_NAME["ingot"] = 28

-- Built once at load; announced in chunks since a single server.announce with ~150 lines truncates.
local EQUIPMENT_LIST_LINES = {}
do
    local ids = {}
    for id in pairs(EQUIPMENT_NAMES) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        EQUIPMENT_LIST_LINES[#EQUIPMENT_LIST_LINES + 1] = id .. " = " .. EQUIPMENT_NAMES[id]
    end
end

local function sendToolList(peer_id)
    local perMsg, buf = 30, {}
    server.announce("[Tools]", "?tool | Usage: ?tool <id|name>. Available equipment:", peer_id)
    for i = 1, #EQUIPMENT_LIST_LINES do
        buf[#buf + 1] = EQUIPMENT_LIST_LINES[i]
        if #buf >= perMsg or i == #EQUIPMENT_LIST_LINES then
            server.announce("[Tools]", table.concat(buf, "\n"), peer_id)
            buf = {}
        end
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REPAIR / FLIP / VTP
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function repairGroup(group_id)
    local g = groups[group_id]
    if not g then return 0 end
    local n = 0
    for vehicle_id in pairs(g.vehicles) do
        server.resetVehicleState(vehicle_id)
        pendingApply[vehicle_id] = true
        n = n + 1
    end
    return n
end

local function flipGroup(group_id)
    local g = groups[group_id]
    if not g then return 0 end
    local n = 0
    for vehicle_id in pairs(g.vehicles) do
        local m, ok = server.getVehiclePos(vehicle_id)
        if ok and m then
            local x, y, z = matrix.position(m)
            local yaw = math.atan(m[9] or 0, m[11] or 1)
            local flat = matrix.multiply(
                matrix.translation(x, y + CONFIG.FLIP_Y_OFFSET, z),
                matrix.rotationY(yaw))
            if safeServer("setVehiclePos", vehicle_id, flat) then
                pendingApply[vehicle_id] = true
                n = n + 1
            end
        end
    end
    return n
end

-- Uses setVehiclePos (exact placement) instead of setGroupPosSafe, whose collision-avoidance
-- nudged groups off the exact target. Verification is deferred -- see onTick's VTP block.
local function requestVtpTeleport(group_id, peer_id)
    local g = groups[group_id]
    if not g then
        say(peer_id, "That vehicle is gone.")
        return
    end
    local repVid = next(g.vehicles)
    if not repVid then
        say(peer_id, "That vehicle has nothing to move.")
        return
    end
    local pm, ok = server.getPlayerPos(peer_id)
    if not ok or not pm then
        say(peer_id, "Couldn't find you, try again in a moment.")
        return
    end
    local repM, repOk = server.getVehiclePos(repVid)
    if not repOk or not repM then
        say(peer_id, "Couldn't find your vehicle, try again in a moment.")
        return
    end

    local px, py, pz = matrix.position(pm)
    local ty = py + CONFIG.VTP_HEIGHT
    local rx, ry, rz = matrix.position(repM)
    local dx, dy, dz = px - rx, ty - ry, pz - rz

    local moved = 0
    for vid in pairs(g.vehicles) do
        local vm, vok = server.getVehiclePos(vid)
        if vok and vm then
            local nm = {}
            for i = 1, 16 do nm[i] = vm[i] end
            nm[13], nm[14], nm[15] = vm[13] + dx, vm[14] + dy, vm[15] + dz
            if safeServer("setVehiclePos", vid, nm) then
                pendingApply[vid] = true
                moved = moved + 1
            end
        end
    end

    if moved == 0 then
        say(peer_id, "That didn't work, try again in a moment.")
        dbgLog(1, "VTP", "group " .. group_id .. " teleport moved 0 bodies")
        return
    end

    pendingVtpVerify[group_id] = {
        peer_id = peer_id,
        target = { px, ty, pz },
        beforePos = { rx, ry, rz },
        repVid = repVid,
        verify_ms = server.getTimeMillisec() + CONFIG.VTP_VERIFY_DELAY_MS,
    }
    dbgLog(4, "VTP", "group " .. group_id .. " teleport issued for peer " .. peer_id .. " (" .. moved .. " bodies)")
end

local function resolveOwnedGroups(peer_id, arg)
    local p = getP(peer_id)
    if not p then return nil, "Player state missing." end
    if arg == nil then
        local list = groupsOwnedBy(p.steam_id)
        if #list == 0 then return nil, "You have no vehicles spawned." end
        return list
    end
    local group_id = tonumber(arg)
    if not group_id then return nil, "Invalid group ID: " .. tostring(arg) end
    local g = groups[group_id]
    if not g then return nil, "No such group: " .. group_id end
    if g.owner_steam ~= p.steam_id then return nil, "You don't own group " .. group_id .. "." end
    return { group_id }
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HEAL / REVIVE MODULE
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function reviveIfPvpOff(peer_id)
    local p = getP(peer_id)
    if not p or p.pvp then return end
    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then return end
    local data = server.getObjectData(charId)
    if not data then return end
    if data.dead or data.incapacitated then
        server.reviveCharacter(charId)
        dbgLog(5, "HEAL", p.name .. " revived (PvP off)")
    end
    if data.hp and data.hp < 100 then
        server.setCharacterData(charId, 100, true, false)
        dbgLog(5, "HEAL", p.name .. " healed to full (PvP off)")
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NUKE MODULE
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function queueBlast(x, y, z, mag)
    nukeQueue[#nukeQueue + 1] = { m = matrix.translation(x, y, z), mag = mag }
end

local function queueGrid(cx, cy, cz, n, spacing, mag)
    local half = (n - 1) / 2
    for ix = -half, half do
        for iy = -half, half do
            for iz = -half, half do
                queueBlast(cx + ix * spacing, cy + iy * spacing, cz + iz * spacing, mag)
            end
        end
    end
end

local function queueNuke(tier, targetMatrix)
    local x, y, z = matrix.position(targetMatrix)
    local mag = CONFIG.NUKE_MAGNITUDE
    if tier == "nuke" then
        queueBlast(x, y, z, mag)
    elseif tier == "hypernuke" then
        queueGrid(x, y, z, CONFIG.HYPER_GRID, CONFIG.GRID_SPACING, mag)
    elseif tier == "meganuke" then
        queueGrid(x, y, z, CONFIG.MEGA_GRID, CONFIG.GRID_SPACING, mag)
    end
end

local function resolveNukeTarget(kind, idArg)
    kind = (kind or ""):lower()
    if kind == "p" then
        local peer = resolveTarget(idArg)
        if not peer then return nil, "No such player: " .. tostring(idArg) end
        local m, ok = server.getPlayerPos(peer)
        if not ok then return nil, "Couldn't locate that player." end
        return m
    elseif kind == "v" then
        local gid = tonumber(idArg)
        if not gid or not groups[gid] then return nil, "No such group: " .. tostring(idArg) end
        local firstVid = next(groups[gid].vehicles)
        if not firstVid then return nil, "Group " .. gid .. " has no vehicles." end
        local m, ok = server.getVehiclePos(firstVid)
        if not ok then return nil, "Couldn't locate that vehicle." end
        return m
    end
    return nil, "First argument must be 'v' (vehicle) or 'p' (player)."
end

local function loadTeleports()
    if teleportCache then return end
    teleportCache = {}
    local zones = server.getZones("teleport")
    if not zones then return end
    for _, z in pairs(zones) do
        local x, y, zPos = matrix.position(z.transform)
        teleportCache[z.name] = { x, y, zPos }
    end
end

local function loadCargoZones()
    if cargoZoneCache then return end
    cargoZoneCache = {}
    local zones = server.getZones("cargo")
    if not zones then return end
    for _, z in pairs(zones) do
        local x, y, zPos = matrix.position(z.transform)
        cargoZoneCache[z.name] = { x, y, zPos }
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ECONOMY: CARGO & FUEL STATION
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ?cargo/?deliver and ?refuel are built on the same 16 zones ?tp already uses.
local FUEL_TYPE_DIESEL, FUEL_TYPE_JETFUEL = 1, 2

-- Returns the numeric zone id (1-16), matching TELEPORT_NAMES' indices.
local function findNearestZone(pos, radius)
    loadTeleports()
    local names = CONFIG.TELEPORT_ARID_DLC and TELEPORT_NAMES_DLC or TELEPORT_NAMES
    local bestId, bestDist = nil, math.huge
    for i = 1, #names do
        local z = teleportCache[tostring(i)]
        if z then
            local d = dist3(pos, z)
            if d < bestDist then bestId, bestDist = i, d end
        end
    end
    if bestId and bestDist <= radius then return bestId end
    return nil
end

-- ANY group counts, not just the ?deliver caller's, so players can combine loads.
local function totalMassNearZone(zonePos, radius)
    local total = 0
    for _, g in pairs(groups) do
        local repVid = next(g.vehicles)
        if repVid then
            local posQueried, vm, posOk = safeServerQuery("getVehiclePos", repVid)
            if posQueried and posOk and vm then
                local vx, vy, vz = matrix.position(vm)
                if dist3({ vx, vy, vz }, zonePos) <= radius then
                    for vid in pairs(g.vehicles) do
                        local cQueried, d, cOk = safeServerQuery("getVehicleComponents", vid)
                        if cQueried and cOk and d then total = total + (d.mass or 0) end
                    end
                end
            end
        end
    end
    return total
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- UI
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Dedup key includes position, not just text -- otherwise a panel move with unchanged text
-- would silently be skipped.
local function sendPopup(peer_id, ui_id, name, show, text, x, y)
    popupCache[peer_id] = popupCache[peer_id] or {}
    local key = show and (text .. "\0" .. tostring(x) .. "," .. tostring(y)) or "__HIDDEN__"
    if popupCache[peer_id][ui_id] == key then return end
    popupCache[peer_id][ui_id] = key
    server.setPopupScreen(peer_id, ui_id, name, show, text, x, y)
end

local UI_SEP_1 = "________________"
local UI_SEP_2 = "________________"
local UI_SEP_3 = "________________"

local function buildMain(peer_id, playerCount)
    local p = getP(peer_id)
    if not p then return "" end
    local uptime = (server.getTimeMillisec() - startMs) / 1000
    local playtime = g_savedata.playtime[p.steam_id] or 0

    local myGroups = groupsOwnedBy(p.steam_id)
    local vehText
    if #myGroups == 0 then
        vehText = "none"
    else
        local parts = {}
        for _, gid in ipairs(myGroups) do parts[#parts + 1] = "#" .. gid end
        vehText = table.concat(parts, ", ")
    end

    return
        "" .. CONFIG.SERVER_NAME .. "\n" ..
        "No workshop\n" ..
        UI_SEP_1 .. "\n" ..
        fmtHMSShort(uptime) .. "\n" ..
        "TPS: " .. string.format("%.0f", tpsNow) .. "\n" ..
        "Players: " .. playerCount .. "\n" ..
        UI_SEP_2 .. "\n" ..
        fmtHMSShort(playtime) .. "\n" ..
        "Vehicles: " .. vehText .. "\n" ..
        "Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. "\n" ..
        UI_SEP_3 .. "\n" ..
        "Antisteal: " .. onOff(p.antisteal) .. "\n" ..
        "PvP: " .. onOff(p.pvp) .. "\n" ..
        "Hidden: " .. onOff(p.hidden)
end

local function buildCenter(peer_id)
    local p = getP(peer_id)
    if not p or p.authed then return "" end
    return
        "" .. CONFIG.SERVER_NAME .. "\n" ..
        "NO-WORKSHOP SERVER, self-built vehicles only.\n" ..
        (p.revoked and "Type ?auth to unlock." or "Type ?noworkshop to unlock.") .. "\n" ..
        "Read ?rules first."
end

local function refreshUI(peer_id, playerCount)
    local p = getP(peer_id)
    if not p then return end
    sendPopup(peer_id, UI_CENTER, "Auth", not p.authed, buildCenter(peer_id), UI_X_CENTER, UI_Y_CENTER)
    sendPopup(peer_id, UI_MAIN, "Stats", p.ui, p.ui and buildMain(peer_id, playerCount) or "", UI_X_MAIN, UI_Y_MAIN)
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HELP
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Read by ?help, ?help <command>, and a command's own bad-argument reply.
local COMMAND_HELP = {
    ["?help"] = {
        tier = "everyone",
        usage = "?help [command]",
        detail = "Shows the full command list, or the same short detail for just one command if given.",
    },
    ["?man"] = {
        tier = "everyone",
        usage = "?man [command]",
        detail = "Shows the full manpage-style documentation for a command.",
    },
    ["?noworkshop"] = {
        tier = "everyone",
        usage = "?noworkshop",
        detail = "First-time auth that unlocks the workbench.",
    },
    ["?auth"] = {
        tier = "everyone",
        usage = "?auth",
        detail = "Re-authorizes you after a revoke.",
    },
    ["?ui"] = {
        tier = "everyone",
        usage = "?ui",
        detail = "Toggles your on-screen stats panel on or off.",
    },
    ["?die"] = {
        tier = "everyone",
        usage = "?die",
        detail = "Kills your own character.",
    },
    ["?admins"] = {
        tier = "everyone",
        usage = "?admins",
        detail = "Lists every admin currently online with their rank.",
    },
    ["?rules"] = {
        tier = "everyone",
        usage = "?rules",
        detail = "Shows the server rules.",
    },
    ["?tp"] = {
        tier = "everyone",
        usage = "?tp [location id]",
        detail = "Teleports you to one of the named map locations.",
    },
    ["?c"] = {
        tier = "authed",
        usage = "?c [group id]",
        detail = "Despawns one of your vehicles, or all of them if no group id is given.",
    },
    ["?r"] = {
        tier = "authed",
        usage = "?r [group id]",
        detail = "Repairs one of your vehicles (and refills its fuel for free), or all of them if no id is given.",
    },
    ["?f"] = {
        tier = "authed",
        usage = "?f [group id]",
        detail = "Flips one of your vehicles upright, or all of them if no id is given.",
    },
    ["?vtp"] = {
        tier = "authed",
        usage = "?vtp [group id]",
        detail = "Teleports one of your vehicles to you.",
    },
    ["?as"] = {
        tier = "authed",
        usage = "?as",
        detail = "Toggles antisteal on all your vehicles, blocking other players from editing or deleting them.",
    },
    ["?pvp"] = {
        tier = "authed",
        usage = "?pvp",
        detail = "Toggles whether your vehicles and you personally can take damage.",
    },
    ["?hide"] = {
        tier = "authed",
        usage = "?hide",
        detail = "Toggles hiding you and your vehicles from the map for everyone else.",
    },
    ["?tool"] = {
        tier = "authed",
        usage = "?tool [id|name]",
        detail = "Buys and gives you one piece of equipment.",
    },
    ["?balance"] = {
        tier = "authed",
        usage = "?balance",
        detail = "Shows your current money balance.",
    },
    ["?pay"] = {
        tier = "authed",
        usage = "?pay [peer_id|name] [amount]",
        detail =
        "Pays another player money directly; admins instead inject (or with a negative amount, deduct) money without spending their own.",
    },
    ["?requestpay"] = {
        tier = "authed",
        usage = "?requestpay [peer_id|name] [amount]",
        detail = "Asks another player to pay you, which they must accept via ?accept or ?decline.",
    },
    ["?accept"] = {
        tier = "authed",
        usage = "?accept",
        detail = "Pays whatever pending ?requestpay request is currently aimed at you.",
    },
    ["?decline"] = {
        tier = "authed",
        usage = "?decline",
        detail = "Refuses whatever pending ?requestpay request is currently aimed at you.",
    },
    ["?cargo"] = {
        tier = "authed",
        usage = "?cargo",
        detail = "Requests a cargo hauling job from your current map location to a random destination.",
    },
    ["?deliver"] = {
        tier = "authed",
        usage = "?deliver",
        detail = "Completes your active ?cargo job and pays out if enough vehicle mass is parked at the destination.",
    },
    ["?refuel"] = {
        tier = "authed",
        usage = "?refuel",
        detail = "Pays to top up diesel/jetfuel on a vehicle of yours parked near a map location.",
    },
    ["?warn"] = {
        tier = "moderator",
        usage = "?warn [peer_id|name] [reason]",
        detail =
        "Warns a player, de-auths them, and despawns all their vehicles; repeated warnings escalate to a kick or ban.",
    },
    ["?kill"] = {
        tier = "moderator",
        usage = "?kill [peer_id|name]",
        detail = "Kills a player's character.",
    },
    ["?msg"] = {
        tier = "moderator",
        usage = "?msg [peer_id|name] [message]",
        detail = "Sends a private message that only that one player sees.",
    },
    ["?tpp"] = {
        tier = "admin",
        usage = "?tpp [peer_id|name]",
        detail = "Teleports you to another player.",
    },
    ["?bring"] = {
        tier = "admin",
        usage = "?bring [peer_id|name]",
        detail = "Teleports another player to you.",
    },
    ["?freeze"] = {
        tier = "admin",
        usage = "?freeze [peer_id|name]",
        detail = "Locks a player in their exact current position until ?unfreeze is run on them.",
    },
    ["?unfreeze"] = {
        tier = "admin",
        usage = "?unfreeze [peer_id|name]",
        detail = "Releases a player who is currently frozen (?freeze) or held (?hold).",
    },
    ["?hold"] = {
        tier = "admin",
        usage = "?hold [peer_id|name]",
        detail = "Holds a player in front of you until ?unfreeze is run on them.",
    },
    ["?crash"] = {
        tier = "admin",
        usage = "?crash [peer_id|name]",
        detail = "Ejects a player from the world entirely by teleporting them to invalid coordinates.",
    },
    ["?revoke"] = {
        tier = "admin",
        usage = "?revoke [peer_id|name]",
        detail = "Revokes a player's auth and despawns every vehicle they own.",
    },
    ["?dsp"] = {
        tier = "admin",
        usage = "?dsp [peer_id|name]",
        detail = "Despawns every vehicle a player owns, without touching their auth.",
    },
    ["?setlimit"] = {
        tier = "admin",
        usage = "?setlimit [1-" .. CONFIG.MAX_LIMIT .. "] | ?setlimit [peer_id|name] [1-" .. CONFIG.MAX_LIMIT .. "]",
        detail = "Sets the global vehicle limit, or one player's limit if a player is given.",
    },
    ["?nuke"] = {
        tier = "admin",
        usage = "?nuke [v|p] [id]",
        detail = "Triggers a single explosion at a vehicle or player, requiring the Search and Destroy DLC.",
    },
    ["?hypernuke"] = {
        tier = "admin",
        usage = "?hypernuke [v|p] [id]",
        detail =
        "Triggers 125 explosions in a 5x5x5 grid centered on a vehicle or player, requiring the Search and Destroy DLC.",
    },
    ["?meganuke"] = {
        tier = "admin",
        usage = "?meganuke [v|p] [id]",
        detail =
        "Triggers 729 explosions in a 9x9x9 grid centered on a vehicle or player, requiring the Search and Destroy DLC.",
    },
    ["?flares"] = {
        tier = "admin",
        usage = "?flares",
        detail = "Despawns loose dropped equipment that this script has tracked being dropped this session.",
    },
    ["?announce"] = {
        tier = "admin",
        usage = "?announce [message]",
        detail = "Broadcasts a message to everyone as a chat line and a toast popup.",
    },
    ["?dbg"] = {
        tier = "admin",
        usage = "?dbg [0-5|off]",
        detail = "Streams live debug logs to your screen only, at the verbosity level you pick.",
    },
    ["?perf"] = {
        tier = "admin",
        usage = "?perf",
        detail = "Shows a one-shot performance snapshot of TPS, queue sizes, and antilag state.",
    },
    ["?antilag"] = {
        tier = "admin",
        usage = "?antilag [10-50]",
        detail = "Forces an immediate antilag check, or sets the normal-tier TPS threshold if given a number.",
    },
}
COMMAND_HELP["?cleanup"] = COMMAND_HELP["?c"]
COMMAND_HELP["?repair"] = COMMAND_HELP["?r"]
COMMAND_HELP["?flip"] = COMMAND_HELP["?f"]
COMMAND_HELP["?antisteal"] = COMMAND_HELP["?as"]

-- Explicit display order per tier (COMMAND_HELP itself has no order -- it's a hash
-- table). Aliases are deliberately left out of these lists so the compact ?help
-- view doesn't show both "?c" and "?cleanup" as if they were different commands.
local HELP_ORDER_EVERYONE = { "?help", "?man", "?noworkshop", "?auth", "?ui", "?die", "?admins", "?rules", "?tp" }
local HELP_ORDER_AUTHED = {
    "?c", "?r", "?f", "?vtp", "?as", "?pvp", "?hide", "?tool",
    "?balance", "?pay", "?requestpay", "?accept", "?decline", "?cargo", "?deliver", "?refuel",
}
local HELP_ORDER_MODERATION = { "?warn", "?kill", "?msg" }
local HELP_ORDER_ADMIN = {
    "?tpp", "?bring", "?freeze", "?unfreeze", "?hold", "?crash", "?revoke", "?dsp", "?setlimit",
    "?nuke", "?hypernuke", "?meganuke", "?flares", "?announce", "?dbg", "?perf", "?antilag",
}

-- Deliberately does NOT repeat usage/tier -- showManPage() pulls those from COMMAND_HELP.
local MAN_HELP = {
    ["?help"] = {
        description = "Prints either the full command list (grouped by tier, filtered to what you can " ..
            "actually run) or, with an argument, the one-line usage + short-detail entry for a single command.",
        whenToUse = "Use this for a quick reminder of a command's syntax. When you want the full story, " ..
            "edge cases, and worked examples, reach for ?man instead.",
        variants = "No argument lists every command you have permission to see. With an argument it shows " ..
            "just that one command's short entry, same text as that command's own bad-argument error.",
        examples = { "?help", "?help tpp", "?help ?pay" },
    },
    ["?man"] = {
        description = "The exhaustive reference for a single command: description, when to use it, its " ..
            "different forms, and worked examples, everything ?help's one-liner leaves out.",
        whenToUse = "Use this when ?help's short summary isn't enough to know exactly how a command behaves, " ..
            "or before running something unfamiliar or irreversible (nukes, ?revoke, ?crash, etc).",
        examples = { "?man tpp", "?man ?pay", "?man setlimit" },
    },
    ["?noworkshop"] = {
        description = "One-time first-auth command. Unlocks the workbench for a player who has never had " ..
            "auth revoked before.",
        whenToUse = "Run this the very first time you join and want workbench access. If you were ever " ..
            "warned or revoked in the past, this will refuse, use ?auth instead.",
        variants = "Mutually exclusive with ?auth: ?noworkshop only works if you've NEVER been revoked. " ..
            "Once you've been revoked even once, ?noworkshop permanently refuses and tells you to use ?auth " ..
            "instead; ?auth in turn refuses for a player who has never been revoked and tells them to use " ..
            "?noworkshop instead. Pick whichever one your current state actually calls for.",
        examples = { "?noworkshop" },
    },
    ["?auth"] = {
        description = "Re-auth command for a player who previously had access revoked (via ?revoke or an " ..
            "auto de-auth from ?warn).",
        whenToUse = "Run this to regain workbench access after being warned or revoked. Your vehicles from " ..
            "before the revoke are not restored, they were despawned for good when it happened.",
        variants = "Mutually exclusive with ?noworkshop: ?auth only works if you've been revoked at least " ..
            "once. If you've never been revoked, ?auth refuses and tells you to use ?noworkshop instead; " ..
            "?noworkshop in turn refuses once you HAVE been revoked and tells you to use ?auth instead. Pick " ..
            "whichever one your current state actually calls for.",
        examples = { "?auth" },
    },
    ["?ui"] = {
        description = "Toggles your on-screen stats panel showing uptime, TPS, player count, your playtime, " ..
            "vehicle count, money balance, and your current antisteal/PvP/hidden toggle states.",
        whenToUse = "Turn it on when you want a persistent glance at your stats and toggle states without " ..
            "running ?balance/?pvp/?hide/?as separately; turn it off if it's cluttering your screen.",
        examples = { "?ui" },
    },
    ["?die"] = {
        description = "Kills your own character outright.",
        whenToUse = "Stuck somewhere with no way out, or just want a clean respawn.",
        variants = "Only affects you. To kill someone ELSE, a moderator or admin needs to run ?kill on them.",
        examples = { "?die" },
    },
    ["?admins"] = {
        description = "Lists every admin currently online along with their rank (OWNER/ADMIN/MODERATOR).",
        whenToUse = "Use this to find out who's online and able to help, or to get a peer id/name for someone " ..
            "you need to contact.",
        examples = { "?admins" },
    },
    ["?rules"] = {
        description = "Prints the server rules, one line per rule.",
        whenToUse = "Read this before you build or interact with anyone, especially right after joining, " ..
            "the auth screen points you at it.",
        examples = { "?rules" },
    },
    ["?tp"] = {
        description = "Teleports you to one of the 16 named map locations, and best-effort re-seats you in " ..
            "your vehicle on arrival if you own one.",
        whenToUse = "Use this to quickly travel to a named location on the map, a base, an airport, a " ..
            "delivery zone, etc, instead of flying or driving there yourself.",
        variants = "With no argument, prints the full numbered list of the 16 locations instead of " ..
            "teleporting. Not the same as ?tpp, which is admin-only and teleports you to a PLAYER instead of " ..
            "a fixed location.",
        examples = { "?tp", "?tp 3" },
    },
    ["?c"] = {
        description = "Despawns one of your vehicles by group id, or every vehicle you own if no id is given.",
        whenToUse = "Use this to clear out a vehicle you're done with, or to wipe your whole fleet and start " ..
            "fresh, without waiting for it to be destroyed some other way.",
        variants = "With a group id, despawns just that one vehicle. With no argument, despawns ALL of your " ..
            "vehicles at once. Alias: ?cleanup (identical behavior, just the long-form name).",
        examples = { "?c", "?c 12", "?cleanup" },
    },
    ["?r"] = {
        description = "Repairs one of your vehicles by group id (or all of them with no id given), and also " ..
            "refills fuel/tanks for free as part of the repair.",
        whenToUse = "Use this after a crash or combat damage to get a vehicle flyable/drivable again without " ..
            "paying for ?refuel separately.",
        variants = "With a group id, repairs just that one vehicle. With no argument, repairs ALL of your " ..
            "vehicles at once. Alias: ?repair (identical behavior, just the long-form name).",
        examples = { "?r", "?r 12", "?repair" },
    },
    ["?f"] = {
        description = "Flips one of your vehicles right-side-up by group id, or all of them with no id given.",
        whenToUse = "Use this when a vehicle has rolled or landed upside down but isn't actually damaged, so " ..
            "you don't need a full ?r repair.",
        variants = "With a group id, flips just that one vehicle. With no argument, flips ALL of your " ..
            "vehicles at once. Does NOT repair damage, pair it with ?r if the vehicle is also broken. " ..
            "Alias: ?flip (identical behavior, just the long-form name).",
        examples = { "?f", "?f 12", "?flip" },
    },
    ["?vtp"] = {
        description = "Teleports one of your vehicles to your current location.",
        whenToUse = "Use this to bring a vehicle you left somewhere back to you, instead of walking or " ..
            "flying back to fetch it.",
        variants = "The group id is REQUIRED if you own more than one vehicle; it's optional (and inferred) " ..
            "if you only own exactly one.",
        examples = { "?vtp", "?vtp 12" },
    },
    ["?as"] = {
        description = "Toggles antisteal on ALL your vehicles at once, blocking other players from editing " ..
            "or deleting them.",
        whenToUse = "Turn this on when you want to protect your vehicles from griefing or accidental edits " ..
            "by others; turn it off if you want to let someone else work on them.",
        variants = "Applies to every vehicle you own simultaneously, there's no per-vehicle toggle. Alias: " ..
            "?antisteal (identical behavior, just the long-form name).",
        examples = { "?as", "?antisteal" },
    },
    ["?pvp"] = {
        description = "Toggles whether your vehicles can take damage and whether you personally can be hurt.",
        whenToUse = "Turn this on if you want to fight or be shot at; leave it off for a purely peaceful, " ..
            "no-damage session.",
        variants = "Saved between sessions, it survives a reload or reconnect, unlike ?hide.",
        examples = { "?pvp" },
    },
    ["?hide"] = {
        description = "Toggles hiding you and your vehicles from the map for everyone except you.",
        whenToUse = "Use this if you want to operate without other players seeing your position or vehicles " ..
            "on the map.",
        variants = "Session-only, NOT saved, so it always resets back to visible when you rejoin. Unlike " ..
            "?pvp, this does not persist.",
        examples = { "?hide" },
    },
    ["?tool"] = {
        description = "Buys and gives you one piece of equipment: outfits, weapons/ammo, or general items.",
        whenToUse = "Use this to gear up without needing to find and interact with a physical vendor.",
        variants = "With no argument, lists every available id/name and its price instead of buying anything. " ..
            "Name lookup is case-insensitive and forgiving of underscore-vs-space (\"fire_extinguisher\", " ..
            "\"Fire_Extinguisher\", and \"fire extinguisher\" all resolve the same). Outfits cost $" ..
            CONFIG.TOOL_PRICE_OUTFIT .. ", weapons/ammo cost $" .. CONFIG.TOOL_PRICE_WEAPON ..
            ", everything else costs $" .. CONFIG.TOOL_PRICE_ITEM ..
            ". You're only charged if the item is confirmed to have actually been given, a failed attempt " ..
            "(e.g. every slot full) never costs anything.",
        examples = { "?tool", "?tool fire_extinguisher", "?tool 4" },
    },
    ["?balance"] = {
        description = "Shows your current money balance.",
        whenToUse = "Use this for a quick check of your funds before an expensive command like ?tool or " ..
            "?refuel. The same number is also shown on the ?ui stats panel if it's open.",
        examples = { "?balance" },
    },
    ["?pay"] = {
        description = "Pays another player money directly and immediately, no confirmation needed from " ..
            "them.",
        whenToUse = "Use this to send money to another player right away. If you instead want to ASK someone " ..
            "to pay YOU (with them able to accept/decline), use ?requestpay.",
        variants = "For a normal player, ?pay deducts the amount from your own balance and adds it to the " ..
            "target's, failing with no charge if you can't afford it. For an admin, ?pay behaves differently: " ..
            "it injects money into the target's balance instead of deducting from the admin's own (this " ..
            "replaced the old separate ?givemoney command), and a negative amount deducts from the target " ..
            "instead of adding.",
        examples = { "?pay Sam 100", "?pay 3 50" },
    },
    ["?requestpay"] = {
        description = "Asks another player to pay YOU a given amount.",
        whenToUse = "Use this when you want someone else to send you money but want them to explicitly " ..
            "confirm it rather than having it taken automatically, the reverse of ?pay.",
        variants = "If the target can currently afford the amount, they get notified and must run ?accept " ..
            "or ?decline themselves, nothing is taken automatically. If they CAN'T currently afford it, the " ..
            "request is never even sent, you're told immediately that it failed and why. An unanswered " ..
            "request expires after " .. math.floor(CONFIG.PAYREQUEST_TTL_SEC / 60) .. " minutes.",
        examples = { "?requestpay Sam 100" },
    },
    ["?accept"] = {
        description = "Pays whatever pending ?requestpay request is currently aimed at you.",
        whenToUse = "Use this once someone has sent you a ?requestpay and you're willing to pay it.",
        variants = "Fails with no charge if you don't have enough money, or if there's no pending request at " ..
            "all. To refuse instead, use ?decline.",
        examples = { "?accept" },
    },
    ["?decline"] = {
        description = "Refuses whatever pending ?requestpay request is currently aimed at you.",
        whenToUse = "Use this to turn down a payment request without paying it. The requester is notified " ..
            "that you declined.",
        examples = { "?decline" },
    },
    ["?cargo"] = {
        description = "Requests a cargo hauling job: an origin (wherever you're standing) and a randomly " ..
            "picked destination among the other 15 map locations.",
        whenToUse = "Use this to start earning money by hauling vehicle mass between map locations. Run " ..
            "?deliver once you've parked enough mass at the destination.",
        variants = "You must be standing at one of the 16 map locations (within " ..
            CONFIG.CARGO_PICKUP_RADIUS .. "m) for that to become the origin. Only one job can be active at a " ..
            "time, and there's a " .. CONFIG.CARGO_COOLDOWN_SEC ..
            "s cooldown between REQUESTS (not deliveries). ANY vehicle's mass near the destination counts " ..
            "toward a job, not just your own, so this can be done as a team. If the server has a container " ..
            "prop configured, one spawns at the origin as a visual marker, delivery itself is still checked " ..
            "by mass at the destination either way.",
        examples = { "?cargo" },
    },
    ["?deliver"] = {
        description = "Completes your active ?cargo job and pays out immediately if enough vehicle mass is " ..
            "currently parked at the destination.",
        whenToUse = "Run this once you (or teammates) have moved enough mass near the destination zone from " ..
            "an active ?cargo job.",
        variants = "Enough mass parked within " .. CONFIG.CARGO_DELIVERY_RADIUS ..
            "m of the destination, yours or another player's, combining loads is allowed, triggers " ..
            "payout. Fails with no payout if there's no active job, or not enough mass there yet.",
        examples = { "?deliver" },
    },
    ["?refuel"] = {
        description = "Pays to top up diesel/jetfuel tanks (never water/oil/other fluids) on a vehicle of " ..
            "yours parked near one of the 16 map locations.",
        whenToUse = "Use this when a vehicle is low on fuel and you don't want to do a full ?r repair (which " ..
            "is free but also fixes damage), or when ?r isn't needed but fuel still is.",
        variants = "You and the vehicle both need to be within " .. CONFIG.FUEL_STATION_RADIUS ..
            "m of the same map location. Costs $" .. CONFIG.FUEL_PRICE_PER_UNIT ..
            "/unit, if you can't afford a full top-up, it fills as much as you CAN afford rather than " ..
            "refusing outright. Separate from ?r, which stays free and unaffected by this.",
        examples = { "?refuel" },
    },
    ["?warn"] = {
        description = "Warns a player: notifies them with the reason, de-auths them, and despawns all their " ..
            "vehicles.",
        whenToUse = "Use this as the standard moderation escalation step for rule-breaking that doesn't " ..
            "warrant an immediate kick or ban.",
        variants = CONFIG.WARNS_BEFORE_KICK .. " warnings auto-kicks the player (and resets their warning " ..
            "count back to zero), and " .. CONFIG.KICKS_BEFORE_BAN ..
            " auto-kicks auto-bans them instead of kicking. The reason is limited to about 2 words, the " ..
            "game's own command system only ever passes 3 arguments total, so there's no \"rest of the " ..
            "message\" to use for a longer reason.",
        examples = { "?warn Sam griefing", "?warn 3 spam" },
    },
    ["?kill"] = {
        description = "Kills another player's character outright.",
        whenToUse = "Enforcing a rule in the moment (combat where PvP was off, ignoring a warning to stop) " ..
            "without the lasting consequences ?warn carries (de-auth, vehicle despawn).",
        variants = "Moderator-tier, same as ?warn. To kill YOURSELF instead, use ?die.",
        examples = { "?kill Sam", "?kill 3" },
    },
    ["?msg"] = {
        description = "Sends a private message that ONLY the targeted player sees.",
        whenToUse = "Use this to talk to one player without broadcasting to the whole server, e.g. warning " ..
            "them privately or coordinating a moderation action.",
        variants = "Not a broadcast filtered client-side, other players never receive it at all. Logged at " ..
            "debug level 3, so only admins actively streaming ?dbg 3 or higher can see it happened.",
        examples = { "?msg Sam stop that", "?msg 3 come here" },
    },
    ["?tpp"] = {
        description = "Teleports YOU to another player.",
        whenToUse = "Use this to quickly reach a player, to help them, spectate, or investigate something.",
        variants = "Not the same as ?tp, which teleports you to a fixed map location instead of a player. " ..
            "To bring the player TO you instead, use ?bring.",
        examples = { "?tpp Sam", "?tpp 3" },
    },
    ["?bring"] = {
        description = "Teleports another player TO you.",
        whenToUse = "Use this when you want a player brought to your location instead of traveling to them " ..
            "yourself, the reverse of ?tpp.",
        examples = { "?bring Sam", "?bring 3" },
    },
    ["?freeze"] = {
        description = "Locks a player in their exact current position, unable to move.",
        whenToUse = "Use this to hold a player in place, e.g. during an investigation or to stop them " ..
            "fleeing, without ejecting them from the world.",
        variants = "Release a frozen player with ?unfreeze, the same command used to release someone held " ..
            "with ?hold.",
        examples = { "?freeze Sam", "?freeze 3" },
    },
    ["?unfreeze"] = {
        description = "Releases a player who is currently frozen (?freeze) or held (?hold).",
        whenToUse = "Use this once you're done holding a player with ?freeze or ?hold.",
        examples = { "?unfreeze Sam", "?unfreeze 3" },
    },
    ["?hold"] = {
        description = "Holds a player in front of you, following your position and facing.",
        whenToUse = "Use this to keep a player right next to you, e.g. to escort or observe them without " ..
            "letting them wander off.",
        variants = "Release a held player with ?unfreeze, the same command used to release someone frozen " ..
            "with ?freeze.",
        examples = { "?hold Sam", "?hold 3" },
    },
    ["?crash"] = {
        description = "Teleports a player to NaN coordinates, ejecting them from the world entirely.",
        whenToUse = "A blunt, drastic tool, there's no confirmation step, so only reach for this when you " ..
            "genuinely need a player forcibly removed from the world right now.",
        variants = "Use with care, unlike other teleport commands there is no safe fallback behavior if " ..
            "used by mistake.",
        examples = { "?crash Sam", "?crash 3" },
    },
    ["?revoke"] = {
        description = "Revokes a player's auth and despawns every vehicle they own.",
        whenToUse = "Use this as a stronger moderation action than ?warn when a player shouldn't keep " ..
            "workbench access, or as a manual reset of someone's fleet and permissions.",
        variants = "The player can run ?auth again afterward to re-unlock the workbench, but their vehicles " ..
            "are gone for good, ?revoke does not come back automatically the way a timed punishment would.",
        examples = { "?revoke Sam", "?revoke 3" },
    },
    ["?dsp"] = {
        description = "Despawns every vehicle a player owns, without revoking their auth or affecting their permissions.",
        whenToUse = "Use this when you just want someone's creations gone (lag, clutter, a build that broke " ..
            "rules) without treating it as a moderation strike, unlike ?revoke this doesn't touch their access.",
        examples = { "?dsp Sam", "?dsp 3" },
    },
    ["?setlimit"] = {
        description = "Sets the maximum number of vehicles a player (or everyone) is allowed to own at once.",
        whenToUse = "Use the global form to tune the server-wide vehicle cap, or the per-player form to give " ..
            "one specific player a different limit (e.g. a trusted builder who needs more).",
        variants = "One argument (?setlimit <n>) sets the GLOBAL vehicle limit for everyone. Two arguments " ..
            "(?setlimit <peer_id|name> <n>) sets that ONE player's limit instead, overriding the global limit " ..
            "just for them. Capped at " .. CONFIG.MAX_LIMIT .. " either way.",
        examples = { "?setlimit 5", "?setlimit Sam 10" },
    },
    ["?nuke"] = {
        description = "A single explosion at a vehicle group id or a player's location.",
        whenToUse = "Use this for a single, targeted destructive hit, e.g. testing damage, clearing a " ..
            "specific vehicle, or a punitive strike on a player's position.",
        variants = "Target a vehicle with ?nuke v <group id>, or a player with ?nuke p <peer_id>. Requires " ..
            "the Search and Destroy DLC to be enabled on this server. For bigger effects, see ?hypernuke (125 " ..
            "explosions) and ?meganuke (729 explosions).",
        examples = { "?nuke v 12", "?nuke p 3" },
    },
    ["?hypernuke"] = {
        description = "125 explosions in a 5x5x5 grid centered on a vehicle group id or a player's location.",
        whenToUse = "Use this when a single ?nuke isn't enough destructive coverage but you don't need the " ..
            "full scale of ?meganuke.",
        variants = "Target a vehicle with ?hypernuke v <group id>, or a player with ?hypernuke p <peer_id>. " ..
            "Requires the Search and Destroy DLC.",
        examples = { "?hypernuke v 12", "?hypernuke p 3" },
    },
    ["?meganuke"] = {
        description = "729 explosions in a 9x9x9 grid centered on a vehicle group id or a player's location.",
        whenToUse = "Use this for maximum-scale destruction, the biggest of the three nuke tiers " ..
            "(?nuke, ?hypernuke, ?meganuke).",
        variants = "Target a vehicle with ?meganuke v <group id>, or a player with ?meganuke p <peer_id>. " ..
            "Requires the Search and Destroy DLC.",
        examples = { "?meganuke v 12", "?meganuke p 3" },
    },
    ["?flares"] = {
        description = "Despawns loose equipment (flares, coal, dropped weapons, anything not on a vehicle or " ..
            "held by a character) that this script has personally tracked being dropped this session.",
        whenToUse = "Use this to manually clean up clutter left on the ground when the game's own auto-" ..
            "despawn didn't catch it.",
        variants = "Dropped items already auto-despawn on their own, this is a manual retry for anything " ..
            "that failed to. There's no API to scan the whole map for objects, so this can never reach items " ..
            "that were on the ground before the script last loaded.",
        examples = { "?flares" },
    },
    ["?announce"] = {
        description = "Broadcasts a message to everyone as both a plain chat line and a green toast popup.",
        whenToUse = "Use this for server-wide announcements, event start, restart warning, rule reminder, " ..
            "that everyone should see prominently.",
        variants = "Limited to about 3 words per call, the game's command system only ever passes 3 " ..
            "arguments total, so a longer message needs multiple ?announce calls in a row.",
        examples = { "?announce Restarting in 5 minutes" },
    },
    ["?dbg"] = {
        description = "Streams live debug logs to YOUR screen only, at the verbosity level you pick.",
        whenToUse = "Use this to watch what the script is doing in real time, diagnosing a problem, " ..
            "monitoring moderation activity, or checking performance-sensitive events as they happen.",
        variants = "Cumulative: level N shows everything from level 1 up to N. 1 = crash risk/conflicts " ..
            "only, 2 = + moderation/structural events, 3 = + every admin command run plus join/leave, 4 = + " ..
            "per-vehicle detail, 5 = + everything else (apply-queue writes, HTTP calls, heal actions, nuke " ..
            "blasts, marker placements, a full state heartbeat once/sec). ?dbg off or ?dbg 0 turns it off.",
        examples = { "?dbg 3", "?dbg 5", "?dbg off" },
    },
    ["?perf"] = {
        description = "A one-shot performance snapshot: current/average TPS, apply-queue and nuke-queue " ..
            "sizes, and antilag's current state.",
        whenToUse = "Use this for a quick health check of the server without leaving a live stream running, " ..
            "unlike ?dbg, this is a single reply, not continuous.",
        examples = { "?perf" },
    },
    ["?antilag"] = {
        description = "Checks or sets the TPS threshold that triggers the antilag system's normal tier.",
        whenToUse = "Use the no-argument form to force an immediate check when you suspect lag right now, or " ..
            "the numeric form to retune how sensitive antilag is for this session.",
        variants = "No argument: forces an immediate antilag check at the current TPS. With a number: sets " ..
            "the normal-tier TPS threshold (clamped 10-50). Critical tier stays fixed at 10 TPS / 5s sustained " ..
            "and can't be changed with this command.",
        examples = { "?antilag", "?antilag 25" },
    },
}
MAN_HELP["?cleanup"] = MAN_HELP["?c"]
MAN_HELP["?repair"] = MAN_HELP["?r"]
MAN_HELP["?flip"] = MAN_HELP["?f"]
MAN_HELP["?antisteal"] = MAN_HELP["?as"]

-- Gates ?help/?man so a command reads as "unknown" to anyone who couldn't run it.
local function canSeeCommand(p, tier)
    if tier == "everyone" then return true end
    if tier == "authed" then return p ~= nil and (p.authed or p.is_admin) end
    if tier == "moderator" then return p ~= nil and (p.is_admin or isModerator(p)) end
    if tier == "admin" then return p ~= nil and p.is_admin == true end
    return false
end

-- A command the caller can't run reads as nonexistent, so nobody learns a higher-tier
-- command exists by probing ?help.
local function showCommandHelp(peer_id, cmd)
    cmd = tostring(cmd):lower()
    if cmd:sub(1, 1) ~= "?" then cmd = "?" .. cmd end
    local info = COMMAND_HELP[cmd]
    if not info or not canSeeCommand(getP(peer_id), info.tier) then
        say(peer_id, "No help entry for \"" .. cmd .. "\". Run ?help with no argument for the full command list.")
        return
    end
    server.announce("[Help]", cmd .. " | Usage: " .. info.usage .. ", " .. info.detail, peer_id)
end

local function showManPage(peer_id, cmd)
    cmd = tostring(cmd):lower()
    if cmd:sub(1, 1) ~= "?" then cmd = "?" .. cmd end
    local info = COMMAND_HELP[cmd]
    local man = MAN_HELP[cmd]
    if not info or not man or not canSeeCommand(getP(peer_id), info.tier) then
        say(peer_id, "No man entry for \"" .. cmd .. "\". Run ?help with no argument for the full command list.")
        return
    end
    local lines = {
        cmd .. " | Usage: " .. info.usage .. " | tier: " .. info.tier,
        "",
        "DESCRIPTION",
        "  " .. man.description,
        "",
        "WHEN TO USE",
        "  " .. man.whenToUse,
    }
    if man.variants then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "VARIANTS"
        lines[#lines + 1] = "  " .. man.variants
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "EXAMPLES"
    for _, ex in ipairs(man.examples) do
        lines[#lines + 1] = "  " .. ex
    end
    server.announce("[Man]", table.concat(lines, "\n"), peer_id)
end

local function sendHelp(peer_id)
    local p         = getP(peer_id)
    local authed    = p and p.authed
    local admin     = p and p.is_admin
    local moderator = p and isModerator(p)
    local lines     = { "Commands (run \"?help <command>\" for full detail on any of these):" }
    for _, cmd in ipairs(HELP_ORDER_EVERYONE) do
        lines[#lines + 1] = cmd .. " | " .. COMMAND_HELP[cmd].usage
    end
    if authed then
        for _, cmd in ipairs(HELP_ORDER_AUTHED) do
            lines[#lines + 1] = cmd .. " | " .. COMMAND_HELP[cmd].usage
        end
    else
        lines[#lines + 1] = (p and p.revoked)
            and "(type ?auth to unlock the rest of the commands)"
            or "(type ?noworkshop to unlock the rest of the commands)"
    end
    if admin or moderator then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Moderation:"
        for _, cmd in ipairs(HELP_ORDER_MODERATION) do
            lines[#lines + 1] = cmd .. " | " .. COMMAND_HELP[cmd].usage
        end
    end
    if admin then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Admin:"
        for _, cmd in ipairs(HELP_ORDER_ADMIN) do
            lines[#lines + 1] = cmd .. " | " .. COMMAND_HELP[cmd].usage
        end
    end
    server.announce("[Help]", table.concat(lines, "\n"), peer_id)
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMMAND SETS (for permission + unknown-command detection)
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local ADMIN_CMDS = {
    ["?tpp"] = true,
    ["?bring"] = true,
    ["?freeze"] = true,
    ["?unfreeze"] = true,
    ["?hold"] = true,
    ["?crash"] = true,
    ["?revoke"] = true,
    ["?dsp"] = true,
    ["?setlimit"] = true,
    ["?nuke"] = true,
    ["?hypernuke"] = true,
    ["?meganuke"] = true,
    ["?flares"] = true,
    ["?announce"] = true,
    ["?dbg"] = true,
    ["?perf"] = true,
    ["?antilag"] = true,
}
local KNOWN_CMDS = {
    ["?help"] = true,
    ["?man"] = true,
    ["?noworkshop"] = true,
    ["?auth"] = true,
    ["?ui"] = true,
    ["?die"] = true,
    ["?c"] = true,
    ["?cleanup"] = true,
    ["?r"] = true,
    ["?repair"] = true,
    ["?f"] = true,
    ["?flip"] = true,
    ["?vtp"] = true,
    ["?as"] = true,
    ["?antisteal"] = true,
    ["?pvp"] = true,
    ["?hide"] = true,
    ["?tpp"] = true,
    ["?bring"] = true,
    ["?freeze"] = true,
    ["?unfreeze"] = true,
    ["?hold"] = true,
    ["?crash"] = true,
    ["?revoke"] = true,
    ["?dsp"] = true,
    ["?setlimit"] = true,
    ["?nuke"] = true,
    ["?hypernuke"] = true,
    ["?meganuke"] = true,
    ["?tool"] = true,
    ["?flares"] = true,
    ["?announce"] = true,
    ["?dbg"] = true,
    ["?perf"] = true,
    ["?antilag"] = true,
    -- ?warn/?kill/?msg: admin OR moderator, own inline permission check, not gated by ADMIN_CMDS.
    ["?warn"] = true,
    ["?kill"] = true,
    ["?admins"] = true,
    ["?rules"] = true,
    ["?tp"] = true,
    ["?msg"] = true,
    ["?balance"] = true,
    ["?pay"] = true,
    ["?requestpay"] = true,
    ["?accept"] = true,
    ["?decline"] = true,
    ["?cargo"] = true,
    ["?deliver"] = true,
    ["?refuel"] = true,
}

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CALLBACKS
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- `authed` is passed in rather than hardcoded: a real join starts UNauthed, but the reload
-- rebuild restores whatever auth the engine already had so a reload doesn't de-auth everyone.
local function makePlayerRecord(steam_id, name, is_admin, authed)
    local savedPvp = g_savedata.pvp[steam_id]
    if savedPvp == nil then savedPvp = CONFIG.DEFAULT_PVP end
    return {
        steam_id    = steam_id,
        name        = name,
        is_admin    = (is_admin == true),
        authed      = (authed == true),
        -- revoked: true once this player has EVER been de-authed. Distinguishes "never
        -- authed yet" (?noworkshop) from "was authed, lost it" (?auth).
        revoked     = false,
        ui          = CONFIG.DEFAULT_UI_ON,
        pvp         = savedPvp,
        antisteal   = CONFIG.DEFAULT_ANTISTEAL,
        limit       = nil,
        speed       = 0,
        alt         = 0,
        last_pos    = nil,
        dbgLevel    = 0,
        hidden      = false,
        -- cargoJob: { origin_zone_id, dest_zone_id, dest_name, mass_required, payout }, session-only.
        cargoJob    = nil,
        lastCargoMs = 0,
        -- payRequest: { from_peer_id, from_name, amount, ts_ms }.
        payRequest  = nil,
    }
end

-- Fires on world load AND on "?reload_scripts" -- the rebuild loop re-seeds
-- players/steamToPeer since onPlayerJoin doesn't re-fire for already-connected players.
function onCreate(is_world_create)
    startMs = server.getTimeMillisec()
    tpsLastMs = startMs

    -- math.random is deterministic until seeded.
    if type(math.randomseed) == "function" then
        math.randomseed(startMs)
    end

    tickCount = 0
    uiTimer, healTimer, tpsTimer, freezeTimer, dbgHeartbeatTimer = 0, 0, 0, 0, 0
    tpsNow, tpsAvg = 60, 60
    lastPlayerCount = 0
    criticalWasHealthy = true
    criticalSinceMs = startMs
    antilagNormalUiShown = false
    antilagCriticalUiShown = false

    if CONFIG.CLEAN_VEHICLES_ON_LOAD then
        server.cleanVehicles()
    end

    -- Re-seed player state for everyone already connected (the reload case); a no-op on a
    -- genuine fresh world create.
    local list = server.getPlayers()
    if list then
        for _, pl in pairs(list) do
            local sid = tostring(pl.steam_id)
            players[pl.id] = makePlayerRecord(sid, pl.name, pl.admin, pl.auth)
            steamToPeer[sid] = pl.id
            g_savedata.playtime[sid] = g_savedata.playtime[sid] or 0
            getBalance(sid)
            popupCache[pl.id] = {}
            -- A reload wipes in-memory state but not what's already client-rendered.
            -- 9004/9002 are the removed Nearby/admin panels' old ids.
            server.removePopup(pl.id, UI_MAIN)
            server.removePopup(pl.id, UI_CENTER)
            server.removePopup(pl.id, 9004)
            server.removePopup(pl.id, UI_COUNTDOWN)
            server.removePopup(pl.id, UI_ANTILAG_NORMAL)
            server.removePopup(pl.id, UI_ANTILAG_CRITICAL)
            server.removePopup(pl.id, 9002)
        end
    end

    queueHttpLists()

    server.announce("[" .. CONFIG.SCRIPT_NAME .. "]",
        CONFIG.SCRIPT_NAME .. " v" .. CONFIG.SCRIPT_VERSION .. " initialized and loaded.", -1)
end

function onPlayerJoin(steam_id, name, peer_id, is_admin, is_auth)
    steam_id = tostring(steam_id)
    players[peer_id] = makePlayerRecord(steam_id, name, is_admin, false)
    steamToPeer[steam_id] = peer_id
    g_savedata.playtime[steam_id] = g_savedata.playtime[steam_id] or 0
    getBalance(steam_id)
    popupCache[peer_id] = {}

    -- Always de-auth on join first, THEN grant back only if the HTTP lists say so, so
    -- nobody keeps a stale engine-side auth from a previous session.
    server.removeAuth(peer_id)
    applyAccess(peer_id)

    local p = players[peer_id]
    if p and p.authed then
        notify(peer_id, rankOf(p) .. " access",
            "You're recognized here, so you're already in. Welcome to " .. CONFIG.SERVER_NAME ..
            ". Type ?rules to see how things run here.", "GREEN")
    else
        notify(peer_id, "Welcome to " .. CONFIG.SERVER_NAME,
            "Self-built vehicles only, no workshop. Type ?noworkshop to start building, and ?rules " ..
            "to see how things run here.", "YELLOW")
    end
    queueApplyAllOf(steam_id)
    dbgLog(3, "JOIN", name .. " (" .. steam_id .. ") joined as peer " .. peer_id .. " rank " .. rankOf(players[peer_id]))
end

function onPlayerLeave(steam_id, name, peer_id, is_admin, is_auth)
    steam_id = tostring(steam_id)
    dbgLog(3, "LEAVE", name .. " (" .. steam_id .. ") left, peer " .. peer_id)
    if CONFIG.DESPAWN_VEHICLES_ON_LEAVE then destroyAllGroupsOf(steam_id) end

    frozen[peer_id] = nil
    for held, f in pairs(frozen) do
        if f.anchor == peer_id then
            frozen[held] = nil
            notify(held, "Released", "Your admin left, you're free.", "YELLOW")
        end
    end

    server.removePopup(peer_id, UI_MAIN)
    server.removePopup(peer_id, UI_CENTER)
    server.removePopup(peer_id, 9004)
    server.removePopup(peer_id, UI_COUNTDOWN)
    removePlayerMarker(peer_id)
    players[peer_id] = nil
    popupCache[peer_id] = nil
    if steamToPeer[steam_id] == peer_id then steamToPeer[steam_id] = nil end
end

function onPlayerDie(steam_id, name, peer_id, is_admin, is_auth)
    reviveIfPvpOff(peer_id)
end

-- looseEquipment tracks anything this fails to despawn, so ?flares can retry it later.
function onEquipmentDrop(character_object_id, equipment_object_id, equipment_id)
    if not CONFIG.AUTO_DESPAWN_DROPPED_EQUIPMENT then return end
    looseEquipment[equipment_object_id] = true
    if safeServer("despawnObject", equipment_object_id, true) then
        looseEquipment[equipment_object_id] = nil
        dbgLog(4, "EQUIPMENT", "despawned dropped equipment id " .. tostring(equipment_id) ..
            " (object " .. equipment_object_id .. ")")
    end
end

-- Ignores replies that parsed to zero ids so a connection failure never revokes everyone's access.
function httpReply(port, request, reply)
    if port ~= CONFIG.HTTP_PORT then return end
    local ids = parseSteamIds(reply)
    if not next(ids) then
        dbgLog(1, "HTTP", "empty/failed reply for " .. tostring(request) .. ", keeping previous list")
        return
    end
    if request == CONFIG.HTTP_PATH_VERIFIED then
        verifiedSet = ids
        dbgLog(2, "HTTP", "verified list updated (" .. tostring(next(ids) and "ok" or "empty") .. ")")
    elseif request == CONFIG.HTTP_PATH_ADMINS then
        adminSet = ids
        dbgLog(2, "HTTP", "admin list updated")
    else
        return
    end
    applyAccessToAll()
end

function onTick(game_ticks)
    tickCount = tickCount + game_ticks

    tpsTimer = tpsTimer + game_ticks
    if tpsTimer >= CONFIG.TPS_WINDOW_TICKS then
        local now = server.getTimeMillisec()
        local elapsed = (now - tpsLastMs) / 1000
        if elapsed > 0 then
            -- tpsAvg is smoothed, display only, never used for antilag decisions.
            tpsNow = tpsTimer / elapsed
            tpsAvg = (tpsAvg * 0.9) +
                (tpsNow * 0.1)
        end
        tpsTimer = 0
        tpsLastMs = now
    end

    -- Drains at most ONE queued request per tick (SW hard-limits httpGet to 1/tick).
    if CONFIG.HTTP_ENABLED then
        httpPollTimer = httpPollTimer + game_ticks
        if httpPollTimer >= CONFIG.HTTP_POLL_SEC * 60 then
            httpPollTimer = 0
            queueHttpLists()
        end
        if #httpQueue > 0 then
            local path = table.remove(httpQueue, 1)
            server.httpGet(CONFIG.HTTP_PORT, path)
            dbgLog(5, "HTTP", "sent request to " .. path)
        end
    end

    -- Wall-clock based -- once the server is under load, ticks aren't a reliable stand-in for seconds.
    if next(pendingDestroy) then
        local nowMs = server.getTimeMillisec()
        for group_id, pd in pairs(pendingDestroy) do
            if not groups[group_id] then
                pendingDestroy[group_id] = nil
                dbgLog(3, "ANTILAG", "countdown abandoned, group " .. group_id .. " already gone")
            elseif pd.cancelIfHealthy and tpsNow >= normalTpsThreshold() then
                pendingDestroy[group_id] = nil
                dbgLog(2, "ANTILAG", "countdown cancelled, group " .. group_id .. " spared (TPS recovered)")
            else
                if nowMs >= pd.deadline_ms then
                    local nm = ownerName(groups[group_id])
                    pendingDestroy[group_id] = nil
                    -- Silent: broadcastNotify below is this removal's toast.
                    destroyGroup(group_id, true)
                    broadcastNotify("Antilag",
                        nm .. "'s creation (group " .. group_id .. ") was removed.", "ORANGE")
                    dbgLog(2, "ANTILAG",
                        "countdown finished, group " .. group_id .. " removed (" .. pd.publicReason .. ")")
                end
            end
        end
    end

    -- GLOBAL ANTILAG UI: normal-tier panel, shown to every player only while a TPS-cull
    -- countdown is running. Critical fully suppresses normal so the two can never both show.
    do
        local activeText = nil
        if tpsNow >= CONFIG.ANTILAG_CRITICAL_TPS then
            for group_id, pd in pairs(pendingDestroy) do
                if pd.cancelIfHealthy then
                    local secLeft = math.max(0, math.ceil((pd.deadline_ms - server.getTimeMillisec()) / 1000))
                    local nm = groups[group_id] and ownerName(groups[group_id]) or "a player"
                    activeText = "ANTILAG" ..
                        "\nTPS: " .. string.format("%.0f", tpsNow) ..
                        "\nOwner " .. nm ..
                        "\nID: " .. group_id ..
                        "\nTime: " .. secLeft .. "s"
                    break
                end
            end
        end
        if activeText or antilagNormalUiShown then
            local show = activeText ~= nil
            for peer_id in pairs(players) do
                sendPopup(peer_id, UI_ANTILAG_NORMAL, "Antilag", show, activeText or "",
                    UI_X_ANTILAG_NORMAL, UI_Y_ANTILAG_NORMAL)
            end
            antilagNormalUiShown = show
        end
    end

    -- Read-back delayed until VTP_VERIFY_DELAY_MS after the teleport, see requestVtpTeleport().
    if next(pendingVtpVerify) then
        local nowMs = server.getTimeMillisec()
        for group_id, v in pairs(pendingVtpVerify) do
            if nowMs >= v.verify_ms then
                pendingVtpVerify[group_id] = nil
                local g = groups[group_id]
                if not g then
                    say(v.peer_id, "That vehicle is gone.")
                else
                    local posQueried, vm, posOk = safeServerQuery("getVehiclePos", v.repVid)
                    local success = true
                    if posQueried and posOk and vm then
                        local afterPos = { matrix.position(vm) }
                        local nearTarget = dist3(afterPos, v.target) <= CONFIG.VTP_VERIFY_TOLERANCE
                        local movedFar = v.beforePos and dist3(afterPos, v.beforePos) >= CONFIG.VTP_MOVED_MIN
                        success = nearTarget or movedFar
                    end
                    if success then
                        for vid in pairs(g.vehicles) do pendingApply[vid] = true end
                        say(v.peer_id, "Your vehicle is here.")
                        dbgLog(3, "VTP", "group " .. group_id .. " teleported to peer " .. v.peer_id)
                    else
                        say(v.peer_id, "That didn't work, try again in a moment.")
                        dbgLog(1, "VTP", "group " .. group_id .. " didn't verifiably move (no-op)")
                    end
                end
            end
        end
    end

    local processed = 0
    local vid = next(pendingApply)
    while vid and processed < CONFIG.APPLY_PER_TICK do
        applyVehicleSettings(vid)
        pendingApply[vid] = nil
        processed = processed + 1
        vid = next(pendingApply)
    end

    local blasts = 0
    while #nukeQueue > 0 and blasts < CONFIG.NUKE_PER_TICK do
        local b = table.remove(nukeQueue)
        server.spawnExplosion(b.m, b.mag)
        blasts = blasts + 1
        dbgLog(5, "NUKE", "blast fired, magnitude " .. tostring(b.mag) .. " (" .. #nukeQueue .. " left queued)")
    end

    -- Throttled to CONFIG.FREEZE_UPDATE_TICKS, doesn't need 60Hz precision.
    freezeTimer = freezeTimer + game_ticks
    if freezeTimer >= CONFIG.FREEZE_UPDATE_TICKS then
        freezeTimer = 0
        for held, f in pairs(frozen) do
            if f.mode == "spot" then
                server.setPlayerPos(held, f.pos)
            elseif f.mode == "front" then
                local am, ok = server.getPlayerPos(f.anchor)
                if ok and am then
                    local ax, ay, az = matrix.position(am)
                    local yaw = math.atan(am[9] or 0, am[11] or 1)
                    local fx = ax + math.sin(yaw) * CONFIG.HOLD_RADIUS
                    local fz = az + math.cos(yaw) * CONFIG.HOLD_RADIUS
                    server.setPlayerPos(held, matrix.translation(fx, ay + CONFIG.HOLD_HEIGHT, fz))
                end
            end
        end
    end

    healTimer = healTimer + game_ticks
    if healTimer >= CONFIG.HEAL_CHECK_TICKS then
        healTimer = 0
        for peer_id in pairs(players) do reviveIfPvpOff(peer_id) end
    end

    -- ANTILAG: fixed-rate TPS-triggered cull -------------------------------------
    -- Driven by current tps, not the smoothed display average, which lags a real spike.
    -- Two tiers, mutually exclusive -- critical fully suppresses normal.
    if CONFIG.ANTILAG_ENABLED then
        local normalTps = normalTpsThreshold()
        local inCritical = tpsNow < CONFIG.ANTILAG_CRITICAL_TPS

        -- NORMAL TIER ------------------------------------------------------------
        if tpsNow < normalTps and not inCritical then
            local alreadyCounting = false
            for _, pd in pairs(pendingDestroy) do
                if pd.cancelIfHealthy then
                    alreadyCounting = true
                    break
                end
            end

            if not alreadyCounting then
                local nowMs = server.getTimeMillisec()
                local worst, worstCost = nil, 0
                for group_id, g in pairs(groups) do
                    local ageSec = (nowMs - (g.spawn_ms or 0)) / 1000
                    if (g.cost or 0) > 0 and ageSec >= CONFIG.LAG_SPAWN_GRACE_SEC then
                        local ec = effectiveCost(group_id)
                        if ec > worstCost then worst, worstCost = group_id, ec end
                    end
                end

                if worst then
                    local worstGroup = groups[worst]
                    local worstOwnerPeer = steamToPeer[worstGroup.owner_steam]
                    dbgLog(2, "ANTILAG",
                        "TPS-cull: group " .. worst .. " (" .. ownerName(worstGroup) .. ") cost " ..
                        fmtCost(worstCost) .. " at TPS " .. string.format("%.1f", tpsNow))
                    scheduleGroupDestroy(worst, worstOwnerPeer,
                        "most expensive group, TPS " .. string.format("%.1f", tpsNow),
                        "TPS cull", true)
                end
            end
        end

        -- CRITICAL TIER ------------------------------------------------------------
        if inCritical then
            local nowMs = server.getTimeMillisec()
            if criticalWasHealthy then
                criticalSinceMs = nowMs
                criticalWasHealthy = false
                for group_id, pd in pairs(pendingDestroy) do
                    if pd.cancelIfHealthy then pendingDestroy[group_id] = nil end
                end
                dbgLog(2, "ANTILAG", "critical sustain window started, TPS " .. string.format("%.1f", tpsNow))
            end
            local sustainedSec = (nowMs - criticalSinceMs) / 1000
            if sustainedSec >= CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC then
                local count = 0
                for group_id in pairs(groups) do
                    pendingDestroy[group_id] = nil
                    destroyGroup(group_id, true)
                    count = count + 1
                end
                if count > 0 then
                    broadcastNotify("Antilag", "All " .. count .. " creation(s) were removed.", "ORANGE")
                    dbgLog(1, "ANTILAG", "critical cull: " .. count .. " groups removed, TPS " ..
                        string.format("%.1f", tpsNow))
                end
                criticalWasHealthy = true
            end
        else
            criticalWasHealthy = true
        end

        -- GLOBAL ANTILAG UI: critical-tier panel, shown while the sustain window is counting.
        local criticalActive = (not criticalWasHealthy) and inCritical
        local criticalText = nil
        if criticalActive then
            local secLeft = math.max(0,
                CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC - (server.getTimeMillisec() - criticalSinceMs) / 1000)
            criticalText = "CRITICAL TPS" ..
                "\nTPS: " .. string.format("%.0f", tpsNow) ..
                "\nTime: " .. math.ceil(secLeft) .. "s"
        end
        if criticalActive or antilagCriticalUiShown then
            for peer_id in pairs(players) do
                sendPopup(peer_id, UI_ANTILAG_CRITICAL, "Antilag", criticalActive, criticalText or "",
                    UI_X_ANTILAG_CRITICAL, UI_Y_ANTILAG_CRITICAL)
            end
            antilagCriticalUiShown = criticalActive
        end
    end

    uiTimer = uiTimer + game_ticks
    if uiTimer >= CONFIG.UI_REFRESH_TICKS then
        local dt = uiTimer / 60
        uiTimer = 0
        local list = server.getPlayers()
        local playerCount = 0
        for _ in pairs(list) do playerCount = playerCount + 1 end
        lastPlayerCount = playerCount
        for _, pl in pairs(list) do
            local p = players[pl.id]
            if p then
                p.is_admin = (pl.admin == true)
                g_savedata.playtime[p.steam_id] = (g_savedata.playtime[p.steam_id] or 0) + dt
                local m, ok = server.getPlayerPos(pl.id)
                if ok and m then
                    local x, y, z = matrix.position(m)
                    if p.last_pos then
                        local dx = x - p.last_pos.x
                        local dy = y - p.last_pos.y
                        local dz = z - p.last_pos.z
                        p.speed = (math.sqrt(dx * dx + dy * dy + dz * dz) / dt) * 3.6
                    else
                        p.speed = 0
                    end
                    p.alt = y
                    p.last_pos = { x = x, y = y, z = z }
                else
                    p.speed = 0
                end
                refreshUI(pl.id, playerCount)
                updatePlayerMarker(pl.id)
            end
        end
    end

    -- Full state dump ~once/sec; skips the table scans entirely unless someone has level 5 active.
    dbgHeartbeatTimer = dbgHeartbeatTimer + game_ticks
    if dbgHeartbeatTimer >= 60 then
        dbgHeartbeatTimer = 0
        local anyLvl5 = false
        for _, pl in pairs(players) do
            if pl.is_admin and (pl.dbgLevel or 0) >= 5 then
                anyLvl5 = true
                break
            end
        end
        if anyLvl5 then
            local applyQ = 0
            for _ in pairs(pendingApply) do applyQ = applyQ + 1 end
            local totalGroups, totalVehicles = 0, 0
            for _, g in pairs(groups) do
                totalGroups = totalGroups + 1
                totalVehicles = totalVehicles + (g.bodyCount or 0)
            end
            local frozenCount = 0
            for _ in pairs(frozen) do frozenCount = frozenCount + 1 end
            dbgLog(5, "TICK",
                "tick " .. tickCount .. " | TPS " .. string.format("%.1f", tpsNow) ..
                " | players " .. lastPlayerCount .. " | groups " .. totalGroups ..
                " | vehicles " .. totalVehicles .. " | frozen " .. frozenCount ..
                " | applyQ " .. applyQ .. " | nukeQ " .. #nukeQueue)
        end
    end
end

function onGroupSpawn(group_id, peer_id, x, y, z, group_cost)
    if peer_id == nil or peer_id == -1 then return end
    local p = getP(peer_id)
    if not p then return end
    local g = getOrCreateGroup(group_id, p.steam_id)
    g.owner_steam = p.steam_id
    g.spawn_tick = tickCount
    dbgLog(2, "GROUP", "group " .. group_id .. " spawned by " .. p.name)
    enforceLimit(p.steam_id)
end

function onVehicleSpawn(vehicle_id, peer_id, x, y, z, group_cost, group_id)
    if peer_id == nil or peer_id == -1 then return end
    local p = getP(peer_id)
    if not p then return end

    -- A straggler body arriving after its group was already destroyed would otherwise
    -- rebuild a fresh group and survive -- blockedGroups keeps every later body blocked too.
    if blockedGroups[group_id] then
        dbgLog(1, "CONFLICT", "vehicle " .. vehicle_id .. " tried to join already-blocked group " .. group_id)
        server.despawnVehicleGroup(group_id, true)
        return
    end

    local g = getOrCreateGroup(group_id, p.steam_id)

    if not g.vehicles[vehicle_id] then
        g.vehicles[vehicle_id] = true
        g.bodyCount = g.bodyCount + 1
    end
    vehicleToGroup[vehicle_id] = group_id
    pendingApply[vehicle_id] = true
    dbgLog(4, "VEHICLE", "vehicle " .. vehicle_id .. " spawned in group " .. group_id .. " (owner " .. p.name .. ")")

    if CONFIG.ANTILAG_ENABLED and g.bodyCount > CONFIG.MAX_SUBBODIES_PER_GROUP then
        smiteHardLimit(group_id,
            g.bodyCount .. " physics bodies over the limit of " .. CONFIG.MAX_SUBBODIES_PER_GROUP)
    end
end

function onVehicleDespawn(vehicle_id, peer_id)
    local group_id = vehicleToGroup[vehicle_id]
    if not group_id then return end
    dbgLog(4, "VEHICLE", "vehicle " .. vehicle_id .. " despawned (group " .. group_id .. ")")
    vehicleToGroup[vehicle_id] = nil
    pendingApply[vehicle_id] = nil
    local g = groups[group_id]
    if g and g.vehicles[vehicle_id] then
        g.cost = math.max(0, (g.cost or 0) - (vehicleCost[vehicle_id] or 0))
        g.voxels = math.max(0, (g.voxels or 0) - (vehicleVoxels[vehicle_id] or 0))
        g.vehicles[vehicle_id] = nil
        g.bodyCount = math.max(0, g.bodyCount - 1)
        if g.bodyCount == 0 then
            groups[group_id] = nil
            blockedGroups[group_id] = nil
            removeGroupMarker(group_id)
        else
            updateGroupMarker(group_id)
        end
    end
    vehicleCost[vehicle_id] = nil
    vehicleVoxels[vehicle_id] = nil
end

function onVehicleLoad(vehicle_id)
    local gid = vehicleToGroup[vehicle_id]
    if not gid then return end

    -- Same sticky-block check as onVehicleSpawn.
    if blockedGroups[gid] then
        dbgLog(1, "CONFLICT", "vehicle " .. vehicle_id .. " loaded into already-blocked group " .. gid)
        server.despawnVehicleGroup(gid, true)
        return
    end

    pendingApply[vehicle_id] = true

    local g = groups[gid]
    if not g then return end

    local ownerPeer = steamToPeer[g.owner_steam]
    local ownerP = ownerPeer and players[ownerPeer]

    local c, v, maker = analyzeVehicle(vehicle_id)

    if maker and not MADE_BY_EXCEPTIONS[maker] and ownerP and maker ~= normalizeName(ownerP.name) then
        blockedGroups[gid] = true
        notify(ownerPeer, "Not Your Creation",
            "Component tagged \"MADE BY " ..
            maker .. "\", spawning someone else's build isn't allowed here, so the group was removed.", "YELLOW")
        server.announce("[MODERATION]",
            ownerP.name .. " spawned a creation tagged MADE BY " .. maker .. " and it was removed.", -1)
        dbgLog(2, "MODERATION", ownerP.name .. " made-by violation (tag: " .. maker .. "), group " .. gid .. " removed")
        destroyGroup(gid)
        return
    end

    updateGroupMarker(gid)

    -- Replaces this vehicle's cost/voxel contribution rather than adding, so a reload
    -- doesn't double-count a vehicle that was already loaded before.
    g.cost = (g.cost or 0) - (vehicleCost[vehicle_id] or 0) + c
    vehicleCost[vehicle_id] = c
    g.voxels = (g.voxels or 0) - (vehicleVoxels[vehicle_id] or 0) + v
    vehicleVoxels[vehicle_id] = v
    dbgLog(4, "VEHICLE", "vehicle " .. vehicle_id .. " loaded, cost " .. fmtCost(c) .. " voxels " .. v)

    local ec = effectiveCost(gid)

    if CONFIG.SPAWN_POPUP and not g.announced then
        g.announced = true
        broadcastNotify("Vehicle Spawned",
            "Owner: " .. ownerName(g) ..
            "\nLag cost: " .. fmtCost(ec) ..
            "\nVehicle ID: " .. gid, "GREEN")
    end

    -- Hard limits only apply within the initial spawn window -- onVehicleLoad also fires
    -- for ?r/?f/?vtp on an already-settled group, which must not get smited.
    local spawnAgeSec = (server.getTimeMillisec() - (g.spawn_ms or 0)) / 1000
    if CONFIG.ANTILAG_ENABLED and spawnAgeSec <= CONFIG.LAG_SPAWN_GRACE_SEC then
        if g.voxels > CONFIG.MAX_BLOCKS_PER_GROUP then
            smiteHardLimit(gid, fmtCost(g.voxels) .. " blocks over the limit of " .. CONFIG.MAX_BLOCKS_PER_GROUP)
            return
        end
        if ec > CONFIG.LAG_MAX_COST then
            smiteHardLimit(gid, "lag cost " .. fmtCost(ec) .. " over the limit of " .. CONFIG.LAG_MAX_COST)
            return
        end
        if spawnAgeSec > CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC then
            smiteHardLimit(gid, "took " .. string.format("%.1f", spawnAgeSec) .. "s to load, over the " ..
                CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC .. "s limit")
            return
        end
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CHAT (profanity ban only -- no rank prefix)
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- onChatMessage can't cancel/edit a message, so a rank prefix isn't possible here.
function onChatMessage(peer_id, sender_name, message)
    if CONFIG.PROFANITY_BAN and containsSlur(message) then
        server.announce("[MODERATION]", sender_name .. " was auto-banned for prohibited language.", -1)
        dbgLog(2, "MODERATION", sender_name .. " auto-banned for prohibited language: " .. message)
        local p = players[peer_id]
        if p then destroyAllGroupsOf(p.steam_id) end
        server.banPlayer(peer_id)
        return
    end
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ROOT ACCESS SYSTEM
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- A third tier above admin, hardcoded OWNERS only. Guardrail-free by design. All state is
-- in-memory only; a reload is the only undo, nothing persists to g_savedata.
local rootSessions        = {}
-- pendingVerification: [steam_id] = { code = "NNNNNN", expires_ms }.
local pendingVerification = {}
local usedRootCodes       = {}
local ROOT_CODE_TTL_MS    = 30000

local function rootSay(peer_id, msg)
    server.announce("[ROOT]", msg, peer_id)
end

-- Recovers argument tokens past the engine's 3-argument ceiling (settank, explode need more)
-- by re-parsing full_message. Never used for the subcommand or verify code, only arg1/arg2.
local function rootExtraArgs(full_message, arg3)
    local extra = {}
    if type(full_message) == "string" and arg3 ~= nil then
        local tokens = {}
        for tok in full_message:gmatch("%S+") do tokens[#tokens + 1] = tok end
        for i = 4, #tokens do
            if tokens[i] == tostring(arg3) then
                for j = i + 1, #tokens do extra[#extra + 1] = tokens[j] end
                break
            end
        end
    end
    return extra
end

-- Fresh 6-digit code, guaranteed unused this run.
local function generateRootCode()
    local code
    repeat
        code = tostring(math.random(100000, 999999))
    until not usedRootCodes[code]
    usedRootCodes[code] = true
    return code
end

local function handleRootEnable(peer_id, steam_id)
    local code = generateRootCode()
    pendingVerification[steam_id] = { code = code, expires_ms = server.getTimeMillisec() + ROOT_CODE_TTL_MS }
    rootSay(peer_id,
        "Root gives you full control with no safety checks, and only a script reload can undo a mistake. " ..
        "To continue, type ?root verify " .. code .. "\n" ..
        "The code lasts 30 seconds and works once.")
end

local function handleRootVerify(peer_id, steam_id, submitted)
    local pending = pendingVerification[steam_id]
    if not pending then
        rootSay(peer_id, "No code to verify. Type ?root enable first.")
        return
    end
    if server.getTimeMillisec() > pending.expires_ms then
        pendingVerification[steam_id] = nil
        rootSay(peer_id, "That code expired. Type ?root enable for a new one.")
        return
    end
    if submitted ~= pending.code then
        rootSay(peer_id, "Wrong code.")
        return
    end
    pendingVerification[steam_id] = nil
    rootSessions[steam_id] = true
    rootSay(peer_id, "You are in root. Type ?root help for the command list, ?root disable to leave.")
end

local function handleRootDisable(peer_id, steam_id)
    rootSessions[steam_id] = nil
    rootSay(peer_id, "You left root.")
end

-- ---- Root command registry ------------------------------------------------------------
-- Every handler is (caller_peer_id, args) and calls server.* directly with raw,
-- unvalidated values on purpose -- no bounds/target/nil guards.

-- Fail-loud: reports a clear error to the caller instead of an unguarded nil index
-- silently aborting the command (this sandbox has no pcall).
local function rootPlayer(caller, rawId)
    local id = tonumber(rawId)
    local tp = id and players[id]
    if not tp then
        rootSay(caller, "No such peer: " .. tostring(rawId))
        return nil
    end
    return tp, id
end

local function rootGroup(caller, rawId)
    local id = tonumber(rawId)
    local g = id and groups[id]
    if not g then
        rootSay(caller, "No such tracked group: " .. tostring(rawId))
        return nil
    end
    return g, id
end

local rootCommands = {
    ["tphere"] = function(caller, a)
        local m = server.getPlayerPos(caller)
        server.setPlayerPos(tonumber(a[1]), m)
        rootSay(caller, "tphere -> peer " .. tostring(a[1]))
    end,
    ["goto"] = function(caller, a)
        local m = server.getPlayerPos(tonumber(a[1]))
        server.setPlayerPos(caller, m)
        rootSay(caller, "goto -> peer " .. tostring(a[1]))
    end,
    ["kill"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.killCharacter(charId)
        rootSay(caller, "killed peer " .. tostring(a[1]))
    end,
    ["heal"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.reviveCharacter(charId)
        server.setCharacterData(charId, 100, true, false)
        rootSay(caller, "healed peer " .. tostring(a[1]))
    end,
    ["god"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.setCharacterData(charId, 999999, true, false)
        rootSay(caller, "god (hp 999999) -> peer " .. tostring(a[1]))
    end,
    ["sethp"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.setCharacterData(charId, tonumber(a[2]), true, false)
        rootSay(caller, "sethp " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    -- Bypasses every rule ?noworkshop/?auth enforce.
    ["forceauth"] = function(caller, a)
        local tp, target = rootPlayer(caller, a[1])
        if not tp then return end
        local on = a[2] == "1"
        tp.authed = on
        if on then server.addAuth(target) else server.removeAuth(target) end
        rootSay(caller, "forceauth " .. tostring(on) .. " -> peer " .. tostring(target))
    end,
    ["forceadmin"] = function(caller, a)
        local tp, target = rootPlayer(caller, a[1])
        if not tp then return end
        tp.is_admin = a[2] == "1"
        safeServer("addAdmin", target)
        rootSay(caller, "forceadmin " .. tostring(tp.is_admin) .. " -> peer " .. tostring(target))
    end,
    ["forcerevoked"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        tp.revoked = a[2] == "1"
        rootSay(caller, "forcerevoked " .. tostring(tp.revoked) .. " -> peer " .. tostring(a[1]))
    end,
    -- Does NOT persist to g_savedata.pvp, unlike ?pvp's own toggle.
    ["setpvp"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        tp.pvp = a[2] == "1"
        queueApplyAllOf(tp.steam_id)
        rootSay(caller, "setpvp " .. tostring(tp.pvp) .. " -> peer " .. tostring(a[1]))
    end,
    ["sethidden"] = function(caller, a)
        local tp, target = rootPlayer(caller, a[1])
        if not tp then return end
        tp.hidden = a[2] == "1"
        updatePlayerMarker(target)
        local owned = groupsOwnedBy(tp.steam_id)
        for i = 1, #owned do updateGroupMarker(owned[i]) end
        rootSay(caller, "sethidden " .. tostring(tp.hidden) .. " -> peer " .. tostring(target))
    end,
    ["setdbg"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        tp.dbgLevel = tonumber(a[2])
        rootSay(caller, "setdbg " .. tostring(tp.dbgLevel) .. " -> peer " .. tostring(a[1]))
    end,
    -- NO clamp-at-zero (unlike setBalance()) -- can go negative.
    ["setbalance"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        g_savedata.wallet = g_savedata.wallet or {}
        g_savedata.wallet[tp.steam_id] = tonumber(a[2])
        rootSay(caller, "setbalance " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    ["addbalance"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        g_savedata.wallet = g_savedata.wallet or {}
        g_savedata.wallet[tp.steam_id] = (g_savedata.wallet[tp.steam_id] or 0) + tonumber(a[2])
        rootSay(caller, "addbalance " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]) ..
            " (new: " .. tostring(g_savedata.wallet[tp.steam_id]) .. ")")
    end,
    ["dumpplayer"] = function(caller, a)
        local tp = rootPlayer(caller, a[1])
        if not tp then return end
        rootSay(caller, "peer " .. tostring(a[1]) .. " dump:\n" ..
            "steam_id=" .. tostring(tp.steam_id) .. " name=" .. tostring(tp.name) ..
            " is_admin=" .. tostring(tp.is_admin) .. " authed=" .. tostring(tp.authed) ..
            " revoked=" .. tostring(tp.revoked) .. "\n" ..
            "ui=" .. tostring(tp.ui) .. " pvp=" .. tostring(tp.pvp) ..
            " antisteal=" .. tostring(tp.antisteal) .. " hidden=" .. tostring(tp.hidden) ..
            " limit=" .. tostring(tp.limit) .. "\n" ..
            "dbgLevel=" .. tostring(tp.dbgLevel) .. " speed=" .. tostring(tp.speed) ..
            " alt=" .. tostring(tp.alt) .. " lastCargoMs=" .. tostring(tp.lastCargoMs))
    end,

    ["vtphere"] = function(caller, a)
        local m = server.getPlayerPos(caller)
        server.setGroupPosSafe(tonumber(a[1]), m)
        rootSay(caller, "vtphere -> group " .. tostring(a[1]))
    end,
    ["vteleport"] = function(caller, a)
        server.setGroupPosSafe(tonumber(a[1]), matrix.translation(tonumber(a[2]), tonumber(a[3]), tonumber(a[4])))
        rootSay(caller, "vteleport group " .. tostring(a[1]) .. " -> " .. tostring(a[2]) .. "," ..
            tostring(a[3]) .. "," .. tostring(a[4]))
    end,
    ["vdespawn"] = function(caller, a)
        server.despawnVehicleGroup(tonumber(a[1]), true)
        rootSay(caller, "despawned group " .. tostring(a[1]))
    end,
    ["vinv"] = function(caller, a)
        server.setVehicleInvulnerable(tonumber(a[1]), a[2] == "1")
        rootSay(caller, "vehicle " .. tostring(a[1]) .. " invulnerable=" .. tostring(a[2] == "1"))
    end,
    ["settank"] = function(caller, a)
        server.setVehicleTank(tonumber(a[1]), a[2], tonumber(a[3]), tonumber(a[4]))
        rootSay(caller, "settank v" .. tostring(a[1]) .. " " .. tostring(a[2]) .. "=" .. tostring(a[3]) ..
            " fluid " .. tostring(a[4]))
    end,
    -- The number antilag's ceiling check reads.
    ["vcost"] = function(caller, a)
        local g = rootGroup(caller, a[1])
        if not g then return end
        g.cost = tonumber(a[2])
        rootSay(caller, "vcost group " .. tostring(a[1]) .. " = " .. tostring(g.cost))
    end,
    -- Same mark a hard limit sets.
    ["vblock"] = function(caller, a)
        local gid = tonumber(a[1])
        if a[2] == "1" then blockedGroups[gid] = true else blockedGroups[gid] = nil end
        rootSay(caller, "vblock group " .. tostring(gid) .. " = " .. tostring(a[2] == "1"))
    end,
    ["chown"] = function(caller, a)
        local g = rootGroup(caller, a[1])
        if not g then return end
        local tp = rootPlayer(caller, a[2])
        if not tp then return end
        g.owner_steam = tp.steam_id
        rootSay(caller, "chown group " .. tostring(a[1]) .. " -> peer " .. tostring(a[2]) .. " (" .. tp.name .. ")")
    end,
    -- Does NOT persist -- the next queueApplyAllOf for the real owner overwrites it back.
    ["chmod"] = function(caller, a)
        local g = rootGroup(caller, a[1])
        if not g then return end
        local antisteal, invuln = a[2] == "1", a[3] == "1"
        for vehicle_id in pairs(g.vehicles) do
            server.setVehicleEditable(vehicle_id, not antisteal)
            server.setVehicleInvulnerable(vehicle_id, invuln)
        end
        rootSay(caller, "chmod group " .. tostring(a[1]) .. " antisteal=" .. tostring(antisteal) ..
            " invulnerable=" .. tostring(invuln))
    end,
    ["forcecull"] = function(caller, a)
        local gid = tonumber(a[1])
        pendingDestroy[gid] = nil
        destroyGroup(gid)
        rootSay(caller, "forcecull group " .. tostring(gid))
    end,
    ["dumpgroup"] = function(caller, a)
        local g = rootGroup(caller, a[1])
        if not g then return end
        local n = 0
        for _ in pairs(g.vehicles) do n = n + 1 end
        rootSay(caller, "group " .. tostring(a[1]) .. " dump:\n" ..
            "owner_steam=" .. tostring(g.owner_steam) .. " bodyCount=" .. tostring(g.bodyCount) ..
            " (counted " .. n .. ")\n" ..
            "cost=" .. tostring(g.cost) .. " voxels=" .. tostring(g.voxels) ..
            " announced=" .. tostring(g.announced) .. " spawn_tick=" .. tostring(g.spawn_tick) ..
            " spawn_ms=" .. tostring(g.spawn_ms) .. "\n" ..
            "blocked=" .. tostring(blockedGroups[tonumber(a[1])] == true) ..
            " pendingDestroy=" .. tostring(pendingDestroy[tonumber(a[1])] ~= nil))
    end,

    -- Reverts on the next real TPS recompute (every CONFIG.TPS_WINDOW_TICKS ticks).
    ["forcetps"] = function(caller, a)
        tpsNow = tonumber(a[1])
        rootSay(caller, "tpsNow forced to " .. tostring(tpsNow) .. " (reverts on the next real TPS sample)")
    end,
    -- No 10-50 clamp, unlike ?antilag <n>.
    ["antinormaltps"] = function(caller, a)
        antilagNormalTps = tonumber(a[1])
        rootSay(caller, "antilagNormalTps = " .. tostring(antilagNormalTps) .. " (unclamped)")
    end,
    ["anticrittps"] = function(caller, a)
        CONFIG.ANTILAG_CRITICAL_TPS = tonumber(a[1])
        rootSay(caller, "CONFIG.ANTILAG_CRITICAL_TPS = " .. tostring(CONFIG.ANTILAG_CRITICAL_TPS))
    end,
    ["maxlagcost"] = function(caller, a)
        CONFIG.LAG_MAX_COST = tonumber(a[1])
        rootSay(caller, "CONFIG.LAG_MAX_COST = " .. tostring(CONFIG.LAG_MAX_COST))
    end,
    ["maxspawntime"] = function(caller, a)
        CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC = tonumber(a[1])
        rootSay(caller, "CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC = " .. tostring(CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC))
    end,
    ["anticritsustain"] = function(caller, a)
        CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC = tonumber(a[1])
        rootSay(caller, "CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC = " .. tostring(CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC))
    end,
    ["resetantilag"] = function(caller, a)
        for gid in pairs(pendingDestroy) do pendingDestroy[gid] = nil end
        for gid in pairs(blockedGroups) do blockedGroups[gid] = nil end
        criticalWasHealthy = true
        antilagNormalUiShown = false
        antilagCriticalUiShown = false
        for peer_id in pairs(players) do
            server.removePopup(peer_id, UI_ANTILAG_NORMAL)
            server.removePopup(peer_id, UI_ANTILAG_CRITICAL)
        end
        rootSay(caller, "antilag runtime state fully reset (pendingDestroy, blockedGroups, both global panels)")
    end,

    -- Antilag panels only refresh while shown -- trigger one via forcetps to see the move.
    ["uimove"] = function(caller, a)
        local panel, x, y = a[1], tonumber(a[2]), tonumber(a[3])
        if panel == "main" then
            UI_X_MAIN, UI_Y_MAIN = x, y
        elseif panel == "center" then
            UI_X_CENTER, UI_Y_CENTER = x, y
        elseif panel == "antilagnormal" then
            UI_X_ANTILAG_NORMAL, UI_Y_ANTILAG_NORMAL = x, y
        elseif panel == "antilagcritical" then
            UI_X_ANTILAG_CRITICAL, UI_Y_ANTILAG_CRITICAL = x, y
        else
            rootSay(caller, "Unknown panel \"" .. tostring(panel) ..
                "\". Valid: main, center, antilagnormal, antilagcritical.")
            return
        end
        rootSay(caller, "uimove " .. panel .. " -> " .. tostring(x) .. "," .. tostring(y))
    end,
    -- Bypasses sendPopup's cache; use a scratch id (9999+) since a built-in id gets overwritten.
    ["uishow"] = function(caller, a)
        local target, ui_id, x, y = tonumber(a[1]), tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
        local text = ""
        for i = 5, #a do text = text .. (i > 5 and " " or "") .. tostring(a[i]) end
        server.setPopupScreen(target, ui_id, "Root", true, text, x, y)
        rootSay(caller, "uishow ui_id " .. tostring(ui_id) .. " -> peer " .. tostring(target) ..
            " @ " .. tostring(x) .. "," .. tostring(y))
    end,
    ["uihide"] = function(caller, a)
        server.removePopup(tonumber(a[1]), tonumber(a[2]))
        rootSay(caller, "uihide ui_id " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    ["uidump"] = function(caller, a)
        rootSay(caller,
            "main=" .. UI_MAIN .. " @ " .. UI_X_MAIN .. "," .. UI_Y_MAIN .. "\n" ..
            "center=" .. UI_CENTER .. " @ " .. UI_X_CENTER .. "," .. UI_Y_CENTER .. "\n" ..
            "antilagnormal=" ..
            UI_ANTILAG_NORMAL .. " @ " .. UI_X_ANTILAG_NORMAL .. "," .. UI_Y_ANTILAG_NORMAL .. "\n" ..
            "antilagcritical=" .. UI_ANTILAG_CRITICAL .. " @ " .. UI_X_ANTILAG_CRITICAL .. "," .. UI_Y_ANTILAG_CRITICAL)
    end,

    -- No key-existence check -- a typo'd key silently creates a new field.
    ["cfgset"] = function(caller, a)
        local key, raw = a[1], a[2]
        local val
        if raw == "true" then
            val = true
        elseif raw == "false" then
            val = false
        elseif tonumber(raw) then
            val = tonumber(raw)
        else
            val = raw
        end
        CONFIG[key] = val
        rootSay(caller, "CONFIG." .. tostring(key) .. " = " .. tostring(val))
    end,
    ["cfgget"] = function(caller, a)
        rootSay(caller, "CONFIG." .. tostring(a[1]) .. " = " .. tostring(CONFIG[a[1]]))
    end,

    ["explode"] = function(caller, a)
        server.spawnExplosion(matrix.translation(tonumber(a[1]), tonumber(a[2]), tonumber(a[3])), tonumber(a[4]))
        rootSay(caller, "explode @ " .. tostring(a[1]) .. "," .. tostring(a[2]) .. "," .. tostring(a[3]) ..
            " mag " .. tostring(a[4]))
    end,
    ["clean"] = function(caller, a)
        server.cleanVehicles()
        rootSay(caller, "cleanVehicles(), every vehicle server-wide despawned")
    end,
    -- No MAX_LIMIT clamp, unlike ?setlimit.
    ["setlimit"] = function(caller, a)
        globalLimit = tonumber(a[1])
        rootSay(caller, "globalLimit = " .. tostring(globalLimit) .. " (unclamped)")
    end,
    ["announce"] = function(caller, a)
        server.announce("[ROOT]", table.concat(a, " "), -1)
    end,
    ["reseed"] = function(caller, a)
        math.randomseed(server.getTimeMillisec())
        rootSay(caller, "RNG re-seeded")
    end,
    ["dump"] = function(caller, a)
        local playerCount, groupCount, vehicleCount, pendingCount, blockedCount = 0, 0, 0, 0, 0
        for _ in pairs(players) do playerCount = playerCount + 1 end
        for _, g in pairs(groups) do
            groupCount = groupCount + 1
            vehicleCount = vehicleCount + (g.bodyCount or 0)
        end
        for _ in pairs(pendingDestroy) do pendingCount = pendingCount + 1 end
        for _ in pairs(blockedGroups) do blockedCount = blockedCount + 1 end
        rootSay(caller,
            "players=" .. playerCount .. " groups=" .. groupCount .. " vehicles=" .. vehicleCount .. "\n" ..
            "pendingDestroy=" .. pendingCount .. " blockedGroups=" .. blockedCount .. "\n" ..
            "tpsNow=" .. string.format("%.1f", tpsNow) .. " tpsAvg=" .. string.format("%.1f", tpsAvg) ..
            " globalLimit=" .. tostring(globalLimit) .. "\n" ..
            "uptime=" .. fmtHMSShort((server.getTimeMillisec() - startMs) / 1000) ..
            " rootSessions=" .. (function()
                local n = 0
                for _ in pairs(rootSessions) do n = n + 1 end
                return n
            end)())
    end,

    -- ACCESS (runtime OWNERS/ADMINS list edits, in-memory only, do NOT persist) ------------
    ["addowner"] = function(caller, a)
        CONFIG.OWNERS[tostring(a[1])] = true
        rootSay(caller, "OWNERS += " .. tostring(a[1]))
    end,
    ["removeowner"] = function(caller, a)
        CONFIG.OWNERS[tostring(a[1])] = nil
        rootSay(caller, "OWNERS -= " .. tostring(a[1]))
    end,
    ["addadmin"] = function(caller, a)
        CONFIG.ADMINS[tostring(a[1])] = true
        rootSay(caller, "ADMINS += " .. tostring(a[1]))
    end,
    ["removeadmin"] = function(caller, a)
        CONFIG.ADMINS[tostring(a[1])] = nil
        rootSay(caller, "ADMINS -= " .. tostring(a[1]))
    end,
}

-- Display order (rootCommands is a hash table, has none). Every name here needs a matching
-- ROOT_MAN entry.
local ROOT_COMMAND_ORDER = {
    "tphere", "goto", "kill", "heal", "god", "sethp", "forceauth", "forceadmin", "forcerevoked",
    "setpvp", "sethidden", "setdbg", "setbalance", "addbalance", "dumpplayer",
    "vtphere", "vteleport", "vdespawn", "vinv", "settank", "vcost", "vblock", "chown", "chmod",
    "forcecull", "dumpgroup",
    "forcetps", "antinormaltps", "maxlagcost", "maxspawntime", "anticrittps", "anticritsustain", "resetantilag",
    "uimove", "uishow", "uihide", "uidump",
    "cfgset", "cfgget",
    "explode", "clean", "setlimit", "announce", "reseed", "dump",
    "addowner", "removeowner", "addadmin", "removeadmin",
}

-- Minimum trailing args each root command needs (0 if none), checked before dispatch.
local ROOT_MIN_ARGS = {
    tphere = 1,
    ["goto"] = 1,
    kill = 1,
    heal = 1,
    god = 1,
    sethp = 2,
    forceauth = 2,
    forceadmin = 2,
    forcerevoked = 2,
    setpvp = 2,
    sethidden = 2,
    setdbg = 2,
    setbalance = 2,
    addbalance = 2,
    dumpplayer = 1,
    vtphere = 1,
    vteleport = 4,
    vdespawn = 1,
    vinv = 2,
    settank = 4,
    vcost = 2,
    vblock = 2,
    chown = 2,
    chmod = 3,
    forcecull = 1,
    dumpgroup = 1,
    forcetps = 1,
    antinormaltps = 1,
    maxlagcost = 1,
    maxspawntime = 1,
    anticrittps = 1,
    anticritsustain = 1,
    resetantilag = 0,
    uimove = 3,
    uishow = 4,
    uihide = 2,
    uidump = 0,
    cfgset = 2,
    cfgget = 1,
    explode = 4,
    clean = 0,
    setlimit = 1,
    announce = 1,
    reseed = 0,
    dump = 0,
    addowner = 1,
    removeowner = 1,
    addadmin = 1,
    removeadmin = 1,
}

local ROOT_MAN = {
    ["tphere"] = {
        syntax = "?root tphere <peer_id>",
        description = "Teleports the named player to YOUR current position.",
        whenToUse = "Pulling a test account to you quickly, or recovering a player stuck somewhere.",
        examples = { "?root tphere 3" },
    },
    ["goto"] = {
        syntax = "?root goto <peer_id>",
        description = "Teleports YOU to the named player's current position. Reverse of tphere.",
        whenToUse = "Jumping to wherever a player/bug report is happening without asking them to move.",
        examples = { "?root goto 3" },
    },
    ["kill"] = {
        syntax = "?root kill <peer_id>",
        description = "Kills the named player's character outright. No confirmation, no PvP-off protection.",
        whenToUse = "Testing death/revive flows, or resetting a stuck character state.",
        examples = { "?root kill 3" },
    },
    ["heal"] = {
        syntax = "?root heal <peer_id>",
        description = "Revives (if dead/incapacitated) and fully heals the named player to 100 HP.",
        whenToUse = "Undoing a root kill/sethp test, or helping a stuck player without touching their PvP setting.",
        examples = { "?root heal 3" },
    },
    ["god"] = {
        syntax = "?root god <peer_id>",
        description = "Sets HP to 999999, effectively unkillable by any normal damage source.",
        whenToUse = "Testing damage-heavy scenarios (nukes, falls, combat) without dying mid-test.",
        variants = "For a specific HP value instead of the god-mode default, use sethp.",
        examples = { "?root god 3" },
    },
    ["sethp"] = {
        syntax = "?root sethp <peer_id> <hp>",
        description = "Sets HP to any raw value, no 0-100 clamp. Negative or huge values are passed straight through.",
        whenToUse =
        "Precisely testing low-HP UI/behavior (e.g. sethp 3 5 to see the near-death state) without relying on combat.",
        examples = { "?root sethp 3 1", "?root sethp 3 100000" },
    },
    ["forceauth"] = {
        syntax = "?root forceauth <peer_id> <0|1>",
        description =
        "Directly sets p.authed and calls the matching engine addAuth/removeAuth, bypasses every ?noworkshop/?auth rule (revoked state, already-authed guard).",
        whenToUse =
        "Testing authed-tier commands on a throwaway account without running the real entry flow, or force-fixing a desynced auth state.",
        variants =
        "Does NOT touch p.revoked, pair with forcerevoked if you also need to flip which of ?noworkshop/?auth would normally apply.",
        examples = { "?root forceauth 3 1", "?root forceauth 3 0" },
    },
    ["forceadmin"] = {
        syntax = "?root forceadmin <peer_id> <0|1>",
        description =
        "Directly sets p.is_admin and calls the engine addAdmin, bypasses the OWNERS/ADMINS/HTTP adminSet checks entirely.",
        whenToUse = "Testing admin-tier commands on an account not on any hardcoded/HTTP list.",
        examples = { "?root forceadmin 3 1" },
    },
    ["forcerevoked"] = {
        syntax = "?root forcerevoked <peer_id> <0|1>",
        description =
        "Directly sets p.revoked, which decides whether that player needs ?noworkshop (0) or ?auth (1) to re-enter.",
        whenToUse =
        "Testing the ?noworkshop/?auth mutual-exclusion error paths without actually running ?revoke or warning the player.",
        examples = { "?root forcerevoked 3 1" },
    },
    ["setpvp"] = {
        syntax = "?root setpvp <peer_id> <0|1>",
        description =
        "Directly sets p.pvp and re-queues vehicle settings. Unlike the real ?pvp command, this does NOT write to g_savedata, it does not persist across reload/reconnect.",
        whenToUse =
        "Quickly testing PvP-on/off behavior on someone else's account, or a temporary override you don't want saved.",
        examples = { "?root setpvp 3 1" },
    },
    ["sethidden"] = {
        syntax = "?root sethidden <peer_id> <0|1>",
        description = "Directly sets p.hidden and refreshes that player's and their vehicles' map markers.",
        whenToUse = "Testing the ?hide map-visibility behavior on another account.",
        examples = { "?root sethidden 3 1" },
    },
    ["setdbg"] = {
        syntax = "?root setdbg <peer_id> <0-5>",
        description =
        "Sets ANY peer's debug-stream level, not just an admin's own (the real ?dbg only ever affects the caller).",
        whenToUse =
        "Turning on a live debug stream for a non-admin test account, or forcing an admin's stream on/off remotely.",
        examples = { "?root setdbg 3 5" },
    },
    ["setbalance"] = {
        syntax = "?root setbalance <peer_id> <amount>",
        description = "Directly overwrites g_savedata.wallet for that player's steam_id. No clamp, can be set negative.",
        whenToUse =
        "Setting up a specific economy test state (e.g. exactly enough for one ?tool purchase, or a negative balance to see how the rest of the economy reacts).",
        examples = { "?root setbalance 3 1000", "?root setbalance 3 -50" },
    },
    ["addbalance"] = {
        syntax = "?root addbalance <peer_id> <amount>",
        description =
        "Adds a raw delta to that player's wallet. No clamp, a negative amount can push the balance below zero.",
        whenToUse = "Nudging a balance up/down mid-test without recalculating the absolute target for setbalance.",
        examples = { "?root addbalance 3 500", "?root addbalance 3 -500" },
    },
    ["dumpplayer"] = {
        syntax = "?root dumpplayer <peer_id>",
        description =
        "Prints that peer's entire in-memory player record: steam_id, name, is_admin, authed, revoked, ui, pvp, antisteal, hidden, limit, dbgLevel, speed, alt, lastCargoMs.",
        whenToUse =
        "First command to run when a player's behavior doesn't match what you expect, see the exact state the script thinks they're in.",
        examples = { "?root dumpplayer 3" },
    },
    ["vtphere"] = {
        syntax = "?root vtphere <group_id>",
        description =
        "Teleports a vehicle group to YOUR current position. Works on ANY raw group id, tracked by this script or not.",
        whenToUse =
        "Recovering a vehicle stuck out of reach, or the same job the real ?vtp does but for a group you don't own.",
        variants = "vteleport does the same move but to explicit x/y/z instead of \"to you\".",
        examples = { "?root vtphere 42" },
    },
    ["vteleport"] = {
        syntax = "?root vteleport <group_id> <x> <y> <z>",
        description = "Teleports a vehicle group to explicit raw coordinates.",
        whenToUse =
        "Placing a test vehicle at an exact, repeatable position (e.g. lining it up on a cargo zone to test ?deliver's radius check).",
        examples = { "?root vteleport 42 100 50 -200" },
    },
    ["vdespawn"] = {
        syntax = "?root vdespawn <group_id>",
        description = "Despawns a vehicle group immediately by raw group id.",
        whenToUse = "Cleaning up a test vehicle, including ones this script never tracked.",
        examples = { "?root vdespawn 42" },
    },
    ["vinv"] = {
        syntax = "?root vinv <vehicle_id> <0|1>",
        description =
        "Sets one vehicle's invulnerability directly. Note: this is a VEHICLE id, not a group id, a multi-body group needs one call per body.",
        whenToUse =
        "Testing damage on a specific body inside a group without changing the whole group's PvP-driven invulnerability.",
        examples = { "?root vinv 7 1" },
    },
    ["settank"] = {
        syntax = "?root settank <vehicle_id> <tank_name> <amount> <fluid_type>",
        description =
        "Fills one tank on one vehicle to any raw amount/fluid type, no capacity or fluid-type check (unlike the real ?refuel).",
        whenToUse = "Setting up an exact fuel-state test (overfilled, wrong fluid, empty) instantly.",
        variants =
        "Fluid type ids: 0=freshwater, 1=diesel, 2=jetfuel, 3=air, 4=exhaust, 5=oil, 6=seawater, 7=steam, 8=slurry, 9=saturated slurry, 10=oxygen, 11=nitrogen, 12=hydrogen.",
        examples = { "?root settank 7 fuel_tank_1 500 1" },
    },
    ["vcost"] = {
        syntax = "?root vcost <group_id> <cost>",
        description =
        "Overwrites this script's TRACKED lag-cost number for a group, the exact value antilag's cost-ceiling check reads. Does not touch the real vehicle at all.",
        whenToUse =
        "Testing the antilag cost-ceiling trigger (now an instant smite, no countdown) without building an actually expensive vehicle.",
        examples = { "?root vcost 42 999999" },
    },
    ["vblock"] = {
        syntax = "?root vblock <group_id> <0|1>",
        description =
        "Sets or clears blockedGroups for a raw group id, the same permanent mark a hard antilag limit leaves, without tripping one for real.",
        whenToUse =
        "Testing what happens when a straggler body tries to join an already-blocked group (onVehicleSpawn's CONFLICT path).",
        examples = { "?root vblock 42 1" },
    },
    ["chown"] = {
        syntax = "?root chown <group_id> <peer_id>",
        description =
        "Reassigns a group's tracked owner to another player, by peer id, the same target format every other root player command uses.",
        whenToUse =
        "Testing ownership-dependent behavior (limits, ?c, ?vtp permission checks) without actually re-spawning the vehicle under a different account.",
        variants =
        "The target must be online, so their steam_id can be resolved. Use forceauth/forceadmin on that same peer if you also need to test their auth/admin state.",
        examples = { "?root chown 42 3" },
    },
    ["chmod"] = {
        syntax = "?root chmod <group_id> <antisteal 0|1> <invuln 0|1>",
        description =
        "Sets a group's antisteal (editable by others) and invulnerable flags directly on every body in the group, bypassing the owner's own ?as/?pvp preference.",
        whenToUse =
        "Testing antisteal/damage behavior on a group you don't own, or forcing a specific permission state for a test build regardless of who owns it.",
        variants =
        "This does not persist. The next queueApplyAllOf for the real owner (their own ?as/?pvp toggle, or a fresh spawn) overwrites it back to their actual preference.",
        examples = { "?root chmod 42 1 1", "?root chmod 42 0 0" },
    },
    ["forcecull"] = {
        syntax = "?root forcecull <group_id>",
        description =
        "Destroys a group immediately, skipping the countdown/warning popup and the public removal broadcast entirely.",
        whenToUse = "Instant cleanup during testing when you don't want antilag's normal 3s countdown UI in the way.",
        examples = { "?root forcecull 42" },
    },
    ["dumpgroup"] = {
        syntax = "?root dumpgroup <group_id>",
        description =
        "Prints a tracked group's full record: owner_steam, bodyCount (and a live recount), cost, voxels, announced, spawn_tick/spawn_ms, and its blocked/pendingDestroy status.",
        whenToUse =
        "Same idea as dumpplayer, first command to run when a vehicle's antilag/ownership behavior looks wrong.",
        examples = { "?root dumpgroup 42" },
    },
    ["forcetps"] = {
        syntax = "?root forcetps <n>",
        description =
        "Overrides the live tpsNow value directly. Reverts automatically on the next real TPS sample (every CONFIG.TPS_WINDOW_TICKS ticks, ~1s).",
        whenToUse =
        "THE command for testing antilag without actually lagging the server, set forcetps 5 to trigger the normal tier, or hold it below ANTILAG_CRITICAL_TPS for ANTILAG_CRITICAL_SUSTAIN_SEC seconds (shrink that with anticritsustain first) to trigger the mass cull.",
        variants =
        "Since it reverts within ~1s, you may need to re-run it repeatedly (or script multiple calls) to hold a fake TPS long enough to cross the critical sustain window.",
        examples = { "?root forcetps 5", "?root forcetps 60" },
    },
    ["antinormaltps"] = {
        syntax = "?root antinormaltps <n>",
        description =
        "Raw override of the live normal-tier TPS threshold. Unlike the real ?antilag <n>, this has NO 10-50 clamp.",
        whenToUse =
        "Testing extreme or invalid thresholds (0, negative, 1000) to see how the rest of antilag reacts, beyond what the clamped admin command allows.",
        examples = { "?root antinormaltps 0", "?root antinormaltps 55" },
    },
    ["maxlagcost"] = {
        syntax = "?root maxlagcost <n>",
        description =
        "Live override of CONFIG.LAG_MAX_COST, the serverwide lag-cost ceiling. Equivalent to cfgset LAG_MAX_COST <n>, provided as a named shortcut since it's the hard-limit number you'll retune most.",
        whenToUse =
        "Lowering it temporarily to make the cost-ceiling smite easy to trigger for testing, or raising it if real builds are getting caught unfairly.",
        examples = { "?root maxlagcost 500000", "?root maxlagcost 1000" },
    },
    ["maxspawntime"] = {
        syntax = "?root maxspawntime <seconds>",
        description =
        "Live override of CONFIG.ANTILAG_MAX_SPAWN_TIME_SEC, how long a group may take to finish loading before it's smited.",
        whenToUse =
        "Testing the spawn-time smite without building something that's actually slow to load, lower it to something a normal build will exceed.",
        examples = { "?root maxspawntime 0.1", "?root maxspawntime 5" },
    },
    ["anticrittps"] = {
        syntax = "?root anticrittps <n>",
        description =
        "Live override of CONFIG.ANTILAG_CRITICAL_TPS. Equivalent to cfgset ANTILAG_CRITICAL_TPS <n>, provided as a named shortcut.",
        whenToUse =
        "Raising the critical threshold close to the normal one to make it easy to cross both tiers while testing.",
        examples = { "?root anticrittps 35" },
    },
    ["anticritsustain"] = {
        syntax = "?root anticritsustain <sec>",
        description =
        "Live override of CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC, how long TPS must stay under the critical threshold before the mass cull fires.",
        whenToUse =
        "Shrinking this to 1-2s while testing so you don't have to hold forcetps for the full default 5 seconds each time.",
        examples = { "?root anticritsustain 1" },
    },
    ["resetantilag"] = {
        syntax = "?root resetantilag",
        description =
        "Clears every pending antilag countdown and hard-limit block, and force-hides both global antilag panels for everyone online.",
        whenToUse =
        "Cleaning up after a round of antilag testing (forcetps, vcost, etc) so leftover fake state doesn't affect real players next.",
        examples = { "?root resetantilag" },
    },
    ["uimove"] = {
        syntax = "?root uimove <main|center|antilagnormal|antilagcritical> <x> <y>",
        description =
        "Live-repositions one of the script's built-in UI panels. Takes effect on that panel's next refresh.",
        whenToUse =
        "THE command for testing where UIs should go, iterate on x/y live without editing and reloading the script for every tweak.",
        variants =
        "main refreshes every UI_REFRESH_TICKS (visible almost immediately). The antilag panels only refresh while actively shown, trigger one with forcetps/anticritsustain first to see the move happen live.",
        examples = { "?root uimove main -0.5 0.3", "?root uimove antilagnormal -0.89 -0.1" },
    },
    ["uishow"] = {
        syntax = "?root uishow <peer_id> <ui_id> <x> <y> <text...>",
        description =
        "Raw server.setPopupScreen call, shows ANY text at ANY ui_id/position to ANY peer, completely bypassing every built-in panel's own logic and sendPopup's dedup cache.",
        whenToUse =
        "Prototyping a brand-new panel layout that doesn't exist in the script yet. Use a scratch ui_id (9999 or higher) so the real refresh loops don't fight you for it.",
        variants =
        "Reusing a built-in id (9001-9007) works too, but the owning system's normal refresh loop will overwrite your test on its own next cycle, it has no idea root touched that id.",
        examples = { "?root uishow 3 9999 0 0.5 Test panel line one" },
    },
    ["uihide"] = {
        syntax = "?root uihide <peer_id> <ui_id>",
        description = "Raw server.removePopup call for any peer/ui_id.",
        whenToUse =
        "Clearing a uishow test panel, or force-clearing a built-in panel that's stuck on-screen without waiting for its normal hide logic.",
        examples = { "?root uihide 3 9999" },
    },
    ["uidump"] = {
        syntax = "?root uidump",
        description = "Lists every built-in panel's ui_id and its CURRENT live x/y position.",
        whenToUse =
        "Always run this before uimove so you know your starting point and aren't guessing at current coordinates.",
        examples = { "?root uidump" },
    },
    ["cfgset"] = {
        syntax = "?root cfgset <key> <value>",
        description =
        "Generic live setter for any top-level CONFIG.* field. \"true\"/\"false\" become booleans, anything tonumber()-parseable becomes a number, everything else stays a raw string.",
        whenToUse =
        "Changing any config knob on the fly without a reload, fuel prices, lag weights, cooldowns, DLC flags, anything in CONFIG. The general-purpose escape hatch beyond the named shortcuts (anticrittps etc).",
        variants =
        "No key-existence check, a typo'd key silently creates a new, inert CONFIG field rather than erroring. Use cfgget first if unsure of the exact name.",
        examples = { "?root cfgset FUEL_PRICE_PER_UNIT 0", "?root cfgset ANTILAG_ENABLED false", "?root cfgset LAG_MAX_COST 50000" },
    },
    ["cfgget"] = {
        syntax = "?root cfgget <key>",
        description = "Reads back any CONFIG.* field's current live value.",
        whenToUse = "Checking a config value before changing it with cfgset, or confirming a change actually took.",
        examples = { "?root cfgget FUEL_PRICE_PER_UNIT" },
    },
    ["explode"] = {
        syntax = "?root explode <x> <y> <z> <magnitude>",
        description = "A single explosion at any raw coordinates and any magnitude.",
        whenToUse = "Testing damage/PvP/vehicle-destruction behavior at an exact location.",
        examples = { "?root explode 0 50 0 10" },
    },
    ["clean"] = {
        syntax = "?root clean",
        description =
        "Despawns EVERY vehicle on the server at once (server.cleanVehicles()), not just this script's tracked ones.",
        whenToUse = "Hard reset of the vehicle world state mid-session, without a full script reload.",
        examples = { "?root clean" },
    },
    ["setlimit"] = {
        syntax = "?root setlimit <n>",
        description =
        "Sets the global vehicle limit directly. Unlike the real ?setlimit, there is NO CONFIG.MAX_LIMIT clamp.",
        whenToUse = "Testing an out-of-range limit (0, negative, huge) beyond what the clamped admin command allows.",
        examples = { "?root setlimit 0", "?root setlimit 999" },
    },
    ["announce"] = {
        syntax = "?root announce <text...>",
        description = "Broadcasts a raw chat line to everyone via the [ROOT] tag. No toast, no color, plain chat only.",
        whenToUse = "A quick server-wide message during testing that's visibly tagged as root output.",
        examples = { "?root announce Server restarting for maintenance" },
    },
    ["reseed"] = {
        syntax = "?root reseed",
        description = "Re-seeds math.random with the current wall-clock time.",
        whenToUse =
        "Forcing a fresh random sequence mid-session, e.g. to verify ?cargo's destination roll isn't stuck repeating the same result.",
        examples = { "?root reseed" },
    },
    ["dump"] = {
        syntax = "?root dump",
        description =
        "Server-wide live counters: players online, tracked groups/vehicles, pending antilag countdowns, blocked groups, current TPS/avg TPS, global vehicle limit, uptime, and active root session count.",
        whenToUse = "The \"is anything stuck\" command, run this first when something server-wide seems off.",
        examples = { "?root dump" },
    },
    ["addowner"] = {
        syntax = "?root addowner <steam_id>",
        description =
        "Adds a steam_id to CONFIG.OWNERS in memory, live, that player is OWNER rank immediately (no rejoin needed, applyAccess re-checks aren't required since rankOf() reads CONFIG.OWNERS directly on every call).",
        whenToUse = "Granting a co-tester OWNER rank for a session without editing the file and reloading.",
        variants =
        "IN-MEMORY ONLY, same as every other root effect, a script reload reverts this to whatever's hardcoded in the file. Edit CONFIG.OWNERS in the source directly for a permanent grant.",
        examples = { "?root addowner 76561198000000000" },
    },
    ["removeowner"] = {
        syntax = "?root removeowner <steam_id>",
        description = "Removes a steam_id from CONFIG.OWNERS in memory, live.",
        whenToUse = "Revoking a temporary OWNER grant made with addowner during the same session.",
        variants =
        "IN-MEMORY ONLY, see addowner's note. Also note this does NOT end that player's root session if one is already active (rootSessions is separate), pair with ?root disable run by them, or a reload, to fully revoke.",
        examples = { "?root removeowner 76561198000000000" },
    },
    ["addadmin"] = {
        syntax = "?root addadmin <steam_id>",
        description = "Adds a steam_id to CONFIG.ADMINS in memory, live, that player is ADMIN rank immediately.",
        whenToUse = "Granting a co-tester ADMIN rank for a session without editing the file and reloading.",
        variants = "IN-MEMORY ONLY, see addowner's note.",
        examples = { "?root addadmin 76561198000000000" },
    },
    ["removeadmin"] = {
        syntax = "?root removeadmin <steam_id>",
        description = "Removes a steam_id from CONFIG.ADMINS in memory, live.",
        whenToUse = "Revoking a temporary ADMIN grant made with addadmin during the same session.",
        variants = "IN-MEMORY ONLY, see addowner's note.",
        examples = { "?root removeadmin 76561198000000000" },
    },
}

-- Kept separate from COMMAND_HELP/MAN_HELP so ?root never leaks into the normal ?help listing.
local function rootHelp(peer_id, sub)
    if not sub then
        local lines = { "Root commands (?root help <command> for full detail):" }
        for _, name in ipairs(ROOT_COMMAND_ORDER) do
            lines[#lines + 1] = name .. ", " .. ROOT_MAN[name].syntax
        end
        rootSay(peer_id, table.concat(lines, "\n"))
        return
    end
    local man = ROOT_MAN[sub:lower()]
    if not man then
        rootSay(peer_id, "No root help entry for \"" .. sub .. "\". Run ?root help with no argument for the full list.")
        return
    end
    local lines = {
        man.syntax,
        "",
        "DESCRIPTION",
        "  " .. man.description,
        "",
        "WHEN TO USE",
        "  " .. man.whenToUse,
    }
    if man.variants then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "VARIANTS"
        lines[#lines + 1] = "  " .. man.variants
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "EXAMPLES"
    for _, ex in ipairs(man.examples) do
        lines[#lines + 1] = "  " .. ex
    end
    rootSay(peer_id, table.concat(lines, "\n"))
end

--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMMANDS
--━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
function onCustomCommand(full_message, peer_id, is_admin, is_auth, command, arg1, arg2, arg3)
    command = (command or ""):lower()
    local p = getP(peer_id)
    if not p then
        dbgLog(2, "CMD", "command " .. command .. " from peer " .. tostring(peer_id) ..
            " ignored, no player record yet")
        return
    end
    p.is_admin = (is_admin == true)

    -- Skips ?root entirely -- root leaves nothing in the debug stream, including verify codes.
    if command ~= "?root" then
        local argStr = ""
        if arg1 ~= nil then argStr = argStr .. " " .. tostring(arg1) end
        if arg2 ~= nil then argStr = argStr .. " " .. tostring(arg2) end
        if arg3 ~= nil then argStr = argStr .. " " .. tostring(arg3) end
        dbgLog(3, "CMD", p.name .. " [" .. rankOf(p) .. "] ran " .. command .. argStr)
    end

    -- Handled at the top so it's never blocked by a lower-tier gate. For a non-owner this
    -- falls through to the normal flow -- ?root is absent from every command table, so it
    -- lands on the same "Unknown Command" reply a typo would.
    if command == "?root" then
        if isOwner(p) then
            local steam_id = p.steam_id
            local sub = arg1 and tostring(arg1):lower() or nil

            if sub == "enable" then
                handleRootEnable(peer_id, steam_id)
            elseif sub == "verify" then
                handleRootVerify(peer_id, steam_id, arg2 and tostring(arg2) or nil)
            elseif sub == "disable" then
                handleRootDisable(peer_id, steam_id)
            elseif not sub then
                rootSay(peer_id, rootSessions[steam_id]
                    and "You are in root. Type ?root help for commands, ?root disable to leave."
                    or "Type ?root enable to begin.")
            elseif rootSessions[steam_id] then
                if sub == "help" then
                    rootHelp(peer_id, arg2 and tostring(arg2) or nil)
                else
                    local handler = rootCommands[sub]
                    if handler then
                        local rargs = {}
                        if arg2 ~= nil then rargs[#rargs + 1] = tostring(arg2) end
                        if arg3 ~= nil then rargs[#rargs + 1] = tostring(arg3) end
                        local extra = rootExtraArgs(full_message, arg3)
                        for i = 1, #extra do rargs[#rargs + 1] = extra[i] end
                        local minArgs = ROOT_MIN_ARGS[sub] or 0
                        if #rargs < minArgs then
                            rootSay(peer_id, "?root " .. sub .. " needs " .. minArgs ..
                                " argument(s). Type ?root help " .. sub .. " for the exact syntax.")
                        else
                            handler(peer_id, rargs)
                        end
                    else
                        rootSay(peer_id, "That is not a root command. Type ?root help for the list.")
                    end
                end
            else
                rootSay(peer_id, "You are not in root. Type ?root enable first.")
            end
            return
        end
    end

    if command == "?help" then
        if arg1 then
            showCommandHelp(peer_id, arg1)
        else
            sendHelp(peer_id)
        end
        return
    end

    if command == "?man" then
        if arg1 then
            showManPage(peer_id, arg1)
        else
            say(peer_id, "Usage: ?man <command>. Run ?help for the short list, ?man <command> for full detail.")
        end
        return
    end

    -- ?noworkshop (first-time auth) and ?auth (re-auth after a revoke) are deliberately
    -- separate and non-interchangeable.
    if command == "?noworkshop" then
        if p.authed then
            say(peer_id, "You are already authorized.")
            return
        end
        if p.revoked then
            say(peer_id, "Your access was revoked. Type ?auth to get it back.")
            dbgLog(3, "AUTH", p.name .. " tried ?noworkshop after being revoked")
            return
        end
        p.authed = true
        server.addAuth(peer_id)
        say(peer_id, "You're in. Build your own vehicles and go.")
        refreshUI(peer_id, lastPlayerCount)
        dbgLog(2, "AUTH", p.name .. " authorized via ?noworkshop")
        return
    end

    if command == "?auth" then
        if p.authed then
            say(peer_id, "You are already authorized.")
            return
        end
        if not p.revoked then
            say(peer_id, "First time here? Type ?noworkshop instead.")
            dbgLog(3, "AUTH", p.name .. " tried ?auth without ever being revoked")
            return
        end
        p.authed = true
        p.revoked = false
        server.addAuth(peer_id)
        say(peer_id, "You're back in.")
        -- Instant refresh, don't make them wait for the next UI_REFRESH_TICKS tick.
        refreshUI(peer_id, lastPlayerCount)
        dbgLog(2, "AUTH", p.name .. " re-authorized via ?auth")
        return
    end

    if command == "?ui" then
        p.ui = not p.ui
        say(peer_id, "Stats UI: " .. onOff(p.ui))
        refreshUI(peer_id, lastPlayerCount)
        dbgLog(3, "PLAYER", p.name .. " toggled stats UI -> " .. onOff(p.ui))
        return
    end

    -- Not gated behind auth, same reasoning as ?tp: only affects the player themselves.
    if command == "?die" then
        local charId, ok = server.getPlayerCharacterID(peer_id)
        if not ok or not charId then
            say(peer_id, "Couldn't find your character, try again in a moment.")
            return
        end
        if not safeServer("killCharacter", charId) then
            say(peer_id, "That didn't work, try again in a moment.")
            return
        end
        dbgLog(3, "PLAYER", p.name .. " ran ?die")
        return
    end

    if command == "?admins" then
        local lines = {}
        for pid, pl in pairs(players) do
            if pl.is_admin then
                lines[#lines + 1] = pl.name .. " [" .. rankOf(pl) .. "]"
            end
        end
        if #lines == 0 then
            say(peer_id, "No admins currently online.")
        else
            server.announce("[Admins]", table.concat(lines, "\n"), peer_id)
        end
        return
    end

    if command == "?rules" then
        server.announce("[Rules]", CONFIG.SERVER_NAME .. " rules:", peer_id)
        server.announce("1", "Leave anyone with PvP off alone, don't shoot, ram, or otherwise hurt them.", peer_id)
        server.announce("2", "Keep fights away from spawn points, take it elsewhere.", peer_id)
        server.announce("3", "EMP and radiation weapons are banned outright, no exceptions.", peer_id)
        server.announce("4", "Builds that lag the server can be removed on sight, by antilag or by staff.", peer_id)
        server.announce("5", "Keep mic volume reasonable, no blasting music or screaming into voice chat.", peer_id)
        server.announce("6", "Don't harass, stalk, or repeatedly wind other people up.", peer_id)
        server.announce("7", "Staff calls are final, take disputes to them, not to chat.", peer_id)
        server.announce("8", "Politics, religion, and culture-war arguments stay out of this server.", peer_id)
        server.announce("9", "Don't spam chat, don't flood the server with repeated messages.", peer_id)
        server.announce("10", "Don't exploit bugs or use cheats, mods, or external tools to gain an advantage.", peer_id)
        server.announce("11", "Don't impersonate staff or other players, and don't lie about your own rank.", peer_id)
        server.announce("12",
            "Don't build anything that is offensive, NSFW, or otherwise inappropriate for a public server.", peer_id)
        server.announce("13", "Workshop is not allowed for this server, no exceptions.", peer_id)
        return
    end

    if command == "?tp" then
        local names = CONFIG.TELEPORT_ARID_DLC and TELEPORT_NAMES_DLC or TELEPORT_NAMES
        if not arg1 then
            showCommandHelp(peer_id, "?tp")
            say(peer_id, "Available locations:")
            for i, nm in ipairs(names) do
                say(peer_id, i .. " - " .. nm)
            end
            return
        end
        local id = tonumber(arg1)
        if not id or id < 1 or id > #names then
            say(peer_id, "\"" .. tostring(arg1) .. "\" isn't a valid location id, must be 1-" .. #names .. ".")
            showCommandHelp(peer_id, "?tp")
            return
        end
        loadTeleports()
        local pos = teleportCache[tostring(id)]
        if not pos then
            say(peer_id,
                "\"" .. names[id] .. "\" isn't available on this map, no teleport zone named \"" .. id .. "\" here.")
            return
        end
        if not safeServer("setPlayerPos", peer_id, matrix.translation(pos[1], pos[2], pos[3])) then
            say(peer_id, "Teleport failed, server.setPlayerPos unavailable.")
            return
        end
        local verifyM, verifyOk = server.getPlayerPos(peer_id)
        if not verifyOk or not verifyM then
            say(peer_id, "Teleport failed, couldn't verify your new position. Try again.")
            dbgLog(1, "TELEPORT", p.name .. " ?tp to " .. names[id] .. " could not be verified")
            return
        end
        local vx, vy, vz = matrix.position(verifyM)
        if dist3({ vx, vy, vz }, pos) > CONFIG.VTP_VERIFY_TOLERANCE then
            say(peer_id, "Teleport failed, didn't verifiably move. Try again.")
            dbgLog(1, "TELEPORT", p.name .. " ?tp to " .. names[id] .. " didn't verifiably move")
            return
        end
        notify(peer_id, "Teleported", "You've been teleported to " .. names[id] .. ".", "GREEN")
        dbgLog(3, "TELEPORT", p.name .. " went to " .. names[id])

        -- Best-effort: seat the player in their own vehicle if it's parked at this destination.
        local owned = groupsOwnedBy(p.steam_id)
        local firstVid, seatName = nil, nil
        for i = 1, #owned do
            local g = groups[owned[i]]
            local vid = g and next(g.vehicles)
            if vid then
                local vpQueried, vpm, vpOk = safeServerQuery("getVehiclePos", vid)
                if vpQueried and vpOk and vpm then
                    local vx, vy, vz = matrix.position(vpm)
                    if dist3({ vx, vy, vz }, pos) <= CONFIG.FUEL_STATION_RADIUS then
                        local dQueried, d, dok = safeServerQuery("getVehicleComponents", vid)
                        if dQueried and dok and d and d.components and d.components.seats then
                            for _, seat in pairs(d.components.seats) do
                                if seat.name then
                                    firstVid, seatName = vid, seat.name
                                    break
                                end
                            end
                        end
                    end
                end
            end
            if seatName then break end
        end
        if firstVid and seatName then
            local charId, cok = server.getPlayerCharacterID(peer_id)
            if cok and charId then
                safeServer("setSeated", charId, firstVid, seatName)
                dbgLog(4, "TELEPORT", p.name .. " seated in vehicle " .. firstVid .. " on arrival at " .. names[id])
            end
        end
        return
    end

    local authedCmds = {
        ["?c"] = true,
        ["?cleanup"] = true,
        ["?r"] = true,
        ["?repair"] = true,
        ["?f"] = true,
        ["?flip"] = true,
        ["?vtp"] = true,
        ["?as"] = true,
        ["?antisteal"] = true,
        ["?pvp"] = true,
        ["?hide"] = true,
        ["?tool"] = true,
        ["?balance"] = true,
        ["?pay"] = true,
        ["?requestpay"] = true,
        ["?accept"] = true,
        ["?decline"] = true,
        ["?cargo"] = true,
        ["?deliver"] = true,
        ["?refuel"] = true,
    }
    if authedCmds[command] and not p.authed then
        say(peer_id, p.revoked and "Run ?auth first." or "Run ?noworkshop first.")
        dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied " .. command .. ", not authed")
        return
    end

    if command == "?c" or command == "?cleanup" then
        local n = destroyAllGroupsOf(p.steam_id)
        say(peer_id, "Despawned " .. n .. " creation(s).")
        dbgLog(2, "GROUP", p.name .. " ran ?c, despawned " .. n .. " of their own creation(s)")
        return
    end

    if command == "?r" or command == "?repair" then
        local list, err = resolveOwnedGroups(peer_id, arg1)
        if not list then
            say(peer_id, err)
            return
        end
        local total = 0
        for i = 1, #list do total = total + repairGroup(list[i]) end
        say(peer_id, "Repaired " .. total .. " vehicle(s). (Fuel/tanks refilled too.)")
        dbgLog(3, "VEHICLE", p.name .. " ran ?r, repaired " .. total .. " vehicle(s)")
        return
    end

    if command == "?f" or command == "?flip" then
        local list, err = resolveOwnedGroups(peer_id, arg1)
        if not list then
            say(peer_id, err)
            return
        end
        local total = 0
        for i = 1, #list do total = total + flipGroup(list[i]) end
        say(peer_id, "Flipped " .. total .. " vehicle(s). Damage untouched, use ?r to repair.")
        dbgLog(3, "VEHICLE", p.name .. " ran ?f, flipped " .. total .. " vehicle(s)")
        return
    end

    if command == "?vtp" then
        local owned = groupsOwnedBy(p.steam_id)
        if #owned == 0 then
            say(peer_id, "You have no vehicles spawned.")
            return
        end
        local target
        if arg1 then
            local gid = tonumber(arg1)
            if not gid or not groups[gid] or groups[gid].owner_steam ~= p.steam_id then
                say(peer_id, "You don't own group " .. tostring(arg1) .. ".")
                return
            end
            target = gid
        elseif #owned == 1 then
            target = owned[1]
        else
            say(peer_id, "You have multiple creations. Use ?vtp <id>. Groups: " .. table.concat(owned, ", "))
            return
        end
        -- Result arrives asynchronously once onTick's verification block confirms the move.
        requestVtpTeleport(target, peer_id)
        return
    end

    if command == "?as" or command == "?antisteal" then
        p.antisteal = not p.antisteal
        queueApplyAllOf(p.steam_id)
        if p.antisteal then
            notify(peer_id, "AntiSteal ON", "Your vehicles can't be returned to workbench or deleted by others.",
                "GREEN")
        else
            notify(peer_id, "AntiSteal Off", "Anyone can now return/delete your vehicles.", "RED")
        end
        dbgLog(3, "PLAYER", p.name .. " toggled antisteal -> " .. onOff(p.antisteal))
        return
    end

    if command == "?pvp" then
        p.pvp = not p.pvp
        g_savedata.pvp[p.steam_id] = p.pvp
        queueApplyAllOf(p.steam_id)
        if p.pvp then
            notify(peer_id, "PvP On", "Your vehicles can be damaged and you can be hurt. [saved]", "RED")
        else
            notify(peer_id, "PvP Off", "Your vehicles are invulnerable and you auto-revive. [saved]", "GREEN")
        end
        dbgLog(3, "PLAYER", p.name .. " toggled pvp -> " .. onOff(p.pvp))
        return
    end

    -- Not saved, resets on rejoin.
    if command == "?hide" then
        p.hidden = not p.hidden
        updatePlayerMarker(peer_id)
        local owned = groupsOwnedBy(p.steam_id)
        for i = 1, #owned do updateGroupMarker(owned[i]) end
        if p.hidden then
            notify(peer_id, "Hidden ON",
                "You and your vehicles are hidden from the map (still visible to you).", "GREEN")
        else
            notify(peer_id, "Hidden Off", "You and your vehicles are visible on the map again.", "RED")
        end
        dbgLog(3, "PLAYER", p.name .. " toggled hidden -> " .. onOff(p.hidden))
        return
    end

    if command == "?balance" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        say(peer_id, "Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ".")
        return
    end

    -- Admin: injects money into the target (negative amount deducts). Player: normal
    -- peer-to-peer payment, positive amount only.
    if command == "?pay" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local target = resolveTarget(arg1)
        local amount = tonumber(arg2)
        if arg1 ~= nil and not target then
            say(peer_id, "That player isn't in the server, try someone else.")
            return
        end
        if not target or not amount or (amount == 0) or (not p.is_admin and amount < 0) then
            showCommandHelp(peer_id, "?pay")
            return
        end
        if target == peer_id then
            say(peer_id, "You can't pay yourself.")
            return
        end
        local targetSteam = players[target].steam_id

        if p.is_admin then
            local newBal = addBalance(targetSteam, amount)
            say(peer_id, (amount >= 0 and "Gave " or "Deducted ") .. players[target].name .. " $" ..
                fmtMoney(math.abs(amount)) .. ". New balance: $" .. fmtMoney(newBal) .. ".")
            say(target, "An admin adjusted your balance by $" .. fmtMoney(amount) ..
                ". New balance: $" .. fmtMoney(newBal) .. ".")
            dbgLog(3, "ADMIN", p.name .. " ran ?pay -> " .. players[target].name .. " (" .. fmtMoney(amount) .. ")")
            return
        end

        if not deductBalance(p.steam_id, amount) then
            say(peer_id, "Not enough money, you have $" .. fmtMoney(getBalance(p.steam_id)) ..
                ", tried to pay $" .. fmtMoney(amount) .. ".")
            return
        end
        addBalance(targetSteam, amount)
        say(peer_id, "Paid " .. players[target].name .. " $" .. fmtMoney(amount) ..
            ". Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ".")
        notify(target, "Payment Received",
            p.name .. " paid you $" .. fmtMoney(amount) .. ". Balance: $" .. fmtMoney(getBalance(targetSteam)) .. ".",
            "GREEN")
        dbgLog(4, "ECONOMY", p.name .. " paid " .. players[target].name .. " $" .. fmtMoney(amount))
        return
    end

    if command == "?requestpay" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local target = resolveTarget(arg1)
        local amount = tonumber(arg2)
        if arg1 ~= nil and not target then
            say(peer_id, "That player isn't in the server, try someone else.")
            return
        end
        if not target or not amount or amount <= 0 then
            showCommandHelp(peer_id, "?requestpay")
            return
        end
        if target == peer_id then
            say(peer_id, "You can't request a payment from yourself.")
            return
        end
        -- Checked before the request is even created, so an unaffordable request never sends.
        if not hasBalance(players[target].steam_id, amount) then
            say(peer_id, players[target].name .. " doesn't have enough balance ($" ..
                fmtMoney(getBalance(players[target].steam_id)) .. ", needed $" .. fmtMoney(amount) ..
                "), request not sent.")
            return
        end
        players[target].payRequest = {
            from_peer_id = peer_id,
            from_name = p.name,
            amount = amount,
            ts_ms = server.getTimeMillisec(),
        }
        say(peer_id, "Requested $" .. fmtMoney(amount) .. " from " .. players[target].name .. ".")
        notify(target, "Payment Requested",
            p.name .. " is requesting $" .. fmtMoney(amount) .. " from you. Run ?accept to pay it, or " ..
            "?decline to refuse. Expires in " .. math.floor(CONFIG.PAYREQUEST_TTL_SEC / 60) .. " minutes.", "YELLOW")
        dbgLog(4, "ECONOMY", p.name .. " requested $" .. fmtMoney(amount) .. " from " .. players[target].name)
        return
    end

    if command == "?accept" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local req = p.payRequest
        if not req then
            say(peer_id, "No pending payment request, someone needs to run ?requestpay on you first.")
            return
        end
        if server.getTimeMillisec() - req.ts_ms > CONFIG.PAYREQUEST_TTL_SEC * 1000 then
            p.payRequest = nil
            say(peer_id, "That payment request expired. Ask " .. req.from_name .. " to ?requestpay again.")
            return
        end
        local fromP = players[req.from_peer_id]
        if not fromP or fromP.name ~= req.from_name then
            p.payRequest = nil
            say(peer_id, req.from_name .. " is no longer online, the request was cancelled.")
            return
        end
        if not deductBalance(p.steam_id, req.amount) then
            say(peer_id, "Not enough money to pay this, you have $" .. fmtMoney(getBalance(p.steam_id)) ..
                ", need $" .. fmtMoney(req.amount) .. ".")
            return
        end
        addBalance(fromP.steam_id, req.amount)
        p.payRequest = nil
        say(peer_id, "Paid " .. req.from_name .. " $" .. fmtMoney(req.amount) ..
            ". Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ".")
        notify(req.from_peer_id, "Payment Received",
            p.name .. " paid your request of $" .. fmtMoney(req.amount) .. ".", "GREEN")
        dbgLog(4, "ECONOMY", p.name .. " accepted a $" .. fmtMoney(req.amount) .. " request from " .. req.from_name)
        return
    end

    if command == "?decline" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local req = p.payRequest
        if not req then
            say(peer_id, "No pending payment request to decline.")
            return
        end
        p.payRequest = nil
        say(peer_id, "Declined the $" .. fmtMoney(req.amount) .. " request from " .. req.from_name .. ".")
        if players[req.from_peer_id] and players[req.from_peer_id].name == req.from_name then
            notify(req.from_peer_id, "Payment Declined",
                p.name .. " declined your request for $" .. fmtMoney(req.amount) .. ".", "YELLOW")
        end
        dbgLog(3, "ECONOMY", p.name .. " declined a $" .. fmtMoney(req.amount) .. " request from " .. req.from_name)
        return
    end

    if command == "?cargo" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local names = CONFIG.TELEPORT_ARID_DLC and TELEPORT_NAMES_DLC or TELEPORT_NAMES

        if p.cargoJob then
            say(peer_id, "Active job: haul at least " .. fmtCost(p.cargoJob.mass_required) .. "kg to " ..
                p.cargoJob.dest_name .. " (zone " .. p.cargoJob.dest_zone_id .. ") for $" ..
                fmtMoney(p.cargoJob.payout) .. ". Run ?deliver once enough mass is there.")
            return
        end

        local nowMs = server.getTimeMillisec()
        local waitMs = CONFIG.CARGO_COOLDOWN_SEC * 1000 - (nowMs - (p.lastCargoMs or 0))
        if waitMs > 0 then
            say(peer_id, "Wait " .. math.ceil(waitMs / 1000) .. "s before requesting another cargo job.")
            return
        end

        local pos, posOk = server.getPlayerPos(peer_id)
        if not posOk or not pos then
            say(peer_id, "Couldn't get your position, you may be dead or still loading. Try again in a moment.")
            return
        end
        local px, py, pz = matrix.position(pos)
        local originZoneId = findNearestZone({ px, py, pz }, CONFIG.CARGO_PICKUP_RADIUS)
        if not originZoneId then
            say(peer_id, "You need to be at one of the 16 zones to request a cargo job (within " ..
                CONFIG.CARGO_PICKUP_RADIUS .. "m). Run ?tp with no argument to see the list.")
            return
        end

        local destId
        repeat destId = math.random(1, #names) until destId ~= originZoneId
        loadTeleports()
        local originPos, destPos = teleportCache[tostring(originZoneId)], teleportCache[tostring(destId)]
        local distKm = dist3(originPos, destPos) / 1000
        local payout = math.min(CONFIG.CARGO_PAYOUT_CAP,
            math.floor(CONFIG.CARGO_PAYOUT_BASE + distKm * CONFIG.CARGO_PAYOUT_PER_KM))
        local massReq = math.floor(CONFIG.CARGO_MASS_REQUIRED_BASE + distKm * CONFIG.CARGO_MASS_REQUIRED_PER_KM)

        p.cargoJob = {
            origin_zone_id = originZoneId,
            dest_zone_id = destId,
            dest_name = names[destId],
            mass_required = massReq,
            payout = payout,
            container_object_id = nil,
        }
        p.lastCargoMs = nowMs

        -- Best-effort visible container prop -- the job is already accepted either way.
        if CONFIG.CARGO_CONTAINER_COMPONENT_ID > 0 then
            loadCargoZones()
            local spawnPos = cargoZoneCache[tostring(originZoneId)]
            if spawnPos then
                local aQueried, addonIndex, aOk = safeServerQuery("getAddonIndex")
                if aQueried and aOk and addonIndex then
                    local sQueried, objId, sOk = safeServerQuery("spawnAddonComponent",
                        matrix.translation(spawnPos[1], spawnPos[2], spawnPos[3]),
                        addonIndex, CONFIG.CARGO_CONTAINER_COMPONENT_ID)
                    if sQueried and sOk and objId then
                        p.cargoJob.container_object_id = objId
                        dbgLog(4, "ECONOMY",
                            p.name .. "'s cargo container spawned (object " .. tostring(objId) ..
                            ") at zone " .. originZoneId)
                    else
                        dbgLog(1, "ERROR", "?cargo: container spawn failed for " .. p.name ..
                            " at zone " .. originZoneId)
                    end
                end
            else
                dbgLog(2, "ECONOMY",
                    "?cargo: no \"cargo\" zone named \"" .. originZoneId .. "\" configured, container not spawned")
            end
        end

        notify(peer_id, "Cargo Job",
            "Haul at least " .. fmtCost(massReq) .. "kg to " .. names[destId] .. " (zone " .. destId ..
            ") for $" .. fmtMoney(payout) .. ". Any vehicles near the zone count, team up if you want. " ..
            "Run ?deliver once there.", "GREEN")
        dbgLog(4, "ECONOMY", p.name .. " took a cargo job to " .. names[destId] .. " for $" .. fmtMoney(payout))
        return
    end

    if command == "?deliver" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        if not p.cargoJob then
            say(peer_id, "No active cargo job. Run ?cargo at one of the 16 zones to request one.")
            return
        end
        loadTeleports()
        local destPos = teleportCache[tostring(p.cargoJob.dest_zone_id)]
        local mass = totalMassNearZone(destPos, CONFIG.CARGO_DELIVERY_RADIUS)
        if mass < p.cargoJob.mass_required then
            say(peer_id, "Not enough mass at " .. p.cargoJob.dest_name .. " yet, " .. fmtCost(mass) ..
                "kg there, need " .. fmtCost(p.cargoJob.mass_required) ..
                "kg within " .. CONFIG.CARGO_DELIVERY_RADIUS .. "m of the zone.")
            return
        end
        local payout = p.cargoJob.payout
        addBalance(p.steam_id, payout)
        if p.cargoJob.container_object_id then
            safeServer("despawnObject", p.cargoJob.container_object_id, true)
        end
        notify(peer_id, "Delivered",
            "Delivered to " .. p.cargoJob.dest_name .. " (" .. fmtCost(mass) .. "kg on site). Paid $" ..
            fmtMoney(payout) .. ". Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ".", "GREEN")
        dbgLog(4, "ECONOMY", p.name .. " delivered cargo to " .. p.cargoJob.dest_name .. " for $" .. fmtMoney(payout))
        p.cargoJob = nil
        return
    end

    -- Tops up ONLY diesel/jetfuel tanks. Separate from ?r, which stays free and untouched.
    if command == "?refuel" then
        if not CONFIG.ECONOMY_ENABLED then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            return
        end
        local pos, posOk = server.getPlayerPos(peer_id)
        if not posOk or not pos then
            say(peer_id, "Can't find you right now. Try again in a moment.")
            return
        end
        local px, py, pz = matrix.position(pos)
        local zoneId = findNearestZone({ px, py, pz }, CONFIG.FUEL_STATION_RADIUS)
        if not zoneId then
            say(peer_id, "Not near a fuel station. Run ?tp to see the 16 locations.")
            return
        end
        loadTeleports()
        local zonePos = teleportCache[tostring(zoneId)]

        local pending, totalMissing = {}, 0
        for _, gid in ipairs(groupsOwnedBy(p.steam_id)) do
            local g = groups[gid]
            for vid in pairs(g.vehicles) do
                local vqQueried, vm, vqOk = safeServerQuery("getVehiclePos", vid)
                if vqQueried and vqOk and vm then
                    local vx, vy, vz = matrix.position(vm)
                    if dist3({ vx, vy, vz }, zonePos) <= CONFIG.FUEL_STATION_RADIUS then
                        local cqQueried, d, cqOk = safeServerQuery("getVehicleComponents", vid)
                        if cqQueried and cqOk and d and d.components and d.components.tanks then
                            for _, tank in pairs(d.components.tanks) do
                                if tank.fluid_type == FUEL_TYPE_DIESEL or tank.fluid_type == FUEL_TYPE_JETFUEL then
                                    local missing = (tank.capacity or 0) - (tank.value or 0)
                                    if missing > 0 then
                                        pending[#pending + 1] = { vid = vid, tank = tank, missing = missing }
                                        totalMissing = totalMissing + missing
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if #pending == 0 then
            if totalMissing == 0 then
                say(peer_id, "Nothing to refuel here, tanks are full, or none of yours are nearby.")
            else
                say(peer_id, "No vehicle of yours is close enough. Park within " ..
                    CONFIG.FUEL_STATION_RADIUS .. "m.")
            end
            return
        end

        local balance = getBalance(p.steam_id)
        local affordableUnits = math.min(totalMissing, math.floor(balance / CONFIG.FUEL_PRICE_PER_UNIT))
        if affordableUnits <= 0 then
            say(peer_id, "Not enough money, fuel is $" .. CONFIG.FUEL_PRICE_PER_UNIT ..
                "/unit. Balance: $" .. fmtMoney(balance) .. ".")
            return
        end

        -- Fills each tank then verifies via getVehicleTank, only charging for what's
        -- CONFIRMED -- server.setVehicleTank has no documented return value.
        local remaining, filledUnits = affordableUnits, 0
        for i = 1, #pending do
            if remaining <= 0 then break end
            local item = pending[i]
            local before = item.tank.value or 0
            local add = math.min(remaining, item.missing)
            safeServer("setVehicleTank", item.vid, item.tank.name, before + add, item.tank.fluid_type)
            local vqQueried, after, afterOk = safeServerQuery("getVehicleTank", item.vid, item.tank.name)
            local confirmed = (vqQueried and afterOk and after and after.value) or before
            local actualAdd = math.max(0, confirmed - before)
            remaining = remaining - actualAdd
            filledUnits = filledUnits + actualAdd
        end

        if filledUnits <= 0 then
            say(peer_id, "Refueling didn't work, no charge made.")
            dbgLog(1, "ERROR", "?refuel: setVehicleTank had no verified effect for " .. p.name)
            return
        end

        local cost = math.floor(filledUnits * CONFIG.FUEL_PRICE_PER_UNIT)
        deductBalance(p.steam_id, cost)
        if filledUnits < totalMissing then
            notify(peer_id, "Partial Refuel",
                "Filled " .. math.floor(filledUnits) .. "/" .. math.ceil(totalMissing) .. " units for $" .. cost ..
                ".", "YELLOW")
        else
            notify(peer_id, "Refueled", "Filled " .. math.floor(filledUnits) .. " units for $" .. cost .. ".",
                "GREEN")
        end
        dbgLog(4, "ECONOMY", p.name .. " refueled " .. math.floor(filledUnits) .. " units for $" .. cost)
        return
    end

    if command == "?tool" then
        if not arg1 then
            sendToolList(peer_id)
            return
        end
        local eqId = (arg2 == nil) and tonumber(arg1) or nil
        if not eqId then
            local parts = { tostring(arg1) }
            if arg2 then parts[#parts + 1] = tostring(arg2) end
            if arg3 then parts[#parts + 1] = tostring(arg3) end
            local query = table.concat(parts, " "):lower():gsub("_", " ")
            eqId = EQUIPMENT_BY_NAME[query]
        end
        if not eqId or not EQUIPMENT_NAMES[eqId] then
            say(peer_id, "Unknown tool: " .. tostring(arg1) .. ". Type ?tool (no argument) for the full list.")
            return
        end

        local price = CONFIG.ECONOMY_ENABLED and toolPrice(eqId) or 0
        if price > 0 and not hasBalance(p.steam_id, price) then
            say(peer_id, "Not enough money for " .. EQUIPMENT_NAMES[eqId] .. " ($" .. price ..
                "). Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ". Run ?cargo to earn more.")
            return
        end

        local charId, ok = server.getPlayerCharacterID(peer_id)
        if not ok or not charId then
            say(peer_id, "Couldn't find your character, try again in a moment.")
            return
        end

        -- No documented rule for which ids need which slot, so this attempts each empty
        -- slot in turn and checks setCharacterItem's real success flag.
        local slot, ok2
        if OUTFIT_IDS[eqId] then
            local queried, success = safeServerQuery("setCharacterItem", charId, 10, eqId, true, 100, 100)
            if queried and success then slot, ok2 = 10, true end
        else
            for candidate = 1, 9 do
                local queried, current = safeServerQuery("getCharacterItem", charId, candidate)
                -- id 0/nil means the slot is empty.
                if (not queried) or current == 0 or current == nil then
                    local setQueried, success = safeServerQuery("setCharacterItem", charId, candidate, eqId,
                        true, 100, 100)
                    if setQueried and success then
                        slot, ok2 = candidate, true
                        break
                    end
                end
            end
        end

        if ok2 then
            if price > 0 then deductBalance(p.steam_id, price) end
            say(peer_id, "Gave you " .. EQUIPMENT_NAMES[eqId] .. " (id " .. eqId .. ", slot " .. slot ..
                (price > 0 and (") for $" .. price .. ". Balance: $" .. fmtMoney(getBalance(p.steam_id))) or ")") .. ".")
            dbgLog(4, "ECONOMY",
                p.name .. " got " .. EQUIPMENT_NAMES[eqId] .. " (" .. eqId .. ") in slot " .. slot ..
                (price > 0 and (" for $" .. price) or " (free)"))
        else
            say(peer_id, "Could not give you " .. EQUIPMENT_NAMES[eqId] .. ", every slot was full or rejected it. " ..
                "No charge made. Check ?dbg 1 for the specific failure.")
        end
        return
    end

    -- Own inline permission check, not the ADMIN_CMDS gate, since moderators need this too.
    if command == "?warn" then
        if not (p.is_admin or isModerator(p)) then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied ?warn, not admin/moderator")
            return
        end
        local target = resolveTarget(arg1)
        if not target then
            showCommandHelp(peer_id, "?warn")
            return
        end
        -- onCustomCommand only ever gives 3 args total, so a reason is capped at arg2+arg3.
        local reasonParts = {}
        if arg2 then reasonParts[#reasonParts + 1] = tostring(arg2) end
        if arg3 then reasonParts[#reasonParts + 1] = tostring(arg3) end
        local reason = #reasonParts > 0 and table.concat(reasonParts, " ") or nil
        warnPlayer(target, reason, p.name)
        return
    end

    if command == "?kill" then
        if not (p.is_admin or isModerator(p)) then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied ?kill, not admin/moderator")
            return
        end
        local target = resolveTarget(arg1)
        if not target then
            showCommandHelp(peer_id, "?kill")
            return
        end
        local charId, ok = server.getPlayerCharacterID(target)
        if not ok or not charId then
            say(peer_id, "Couldn't find their character, try again in a moment.")
            return
        end
        if not safeServer("killCharacter", charId) then
            say(peer_id, "That didn't work, try again in a moment.")
            return
        end
        say(peer_id, "Killed " .. players[target].name .. ".")
        notify(target, "Killed", "A moderator killed you.", "RED")
        dbgLog(3, "MODERATION", p.name .. " ran ?kill -> " .. players[target].name)
        return
    end

    if command == "?msg" then
        if not (p.is_admin or isModerator(p)) then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied ?msg, not admin/moderator")
            return
        end
        local target = resolveTarget(arg1)
        local textParts = {}
        if arg2 then textParts[#textParts + 1] = tostring(arg2) end
        if arg3 then textParts[#textParts + 1] = tostring(arg3) end
        if not target or #textParts == 0 then
            showCommandHelp(peer_id, "?msg")
            return
        end
        local text = table.concat(textParts, " ")
        server.announce("[PM from " .. p.name .. "]", "> " .. text, target)
        say(peer_id, "Sent to " .. players[target].name .. ": " .. text)
        dbgLog(3, "ADMIN", p.name .. " privately messaged " .. players[target].name .. ": " .. text)
        return
    end

    if not p.is_admin then
        if ADMIN_CMDS[command] then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied " .. command .. ", not admin")
            return
        end
    end

    if p.is_admin then
        if command == "?tpp" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?tpp")
                return
            end
            local m, ok = server.getPlayerPos(target)
            if not ok then
                say(peer_id, "Couldn't get their position, try again in a moment.")
                return
            end
            local tx, ty, tz = matrix.position(m)
            if not safeServer("setPlayerPos", peer_id, m) then
                say(peer_id, "Teleport failed, server.setPlayerPos unavailable.")
                return
            end
            local vm, vok = server.getPlayerPos(peer_id)
            if not vok or not vm or dist3({ matrix.position(vm) }, { tx, ty, tz }) > CONFIG.VTP_VERIFY_TOLERANCE then
                say(peer_id, "Teleport failed, didn't verifiably move. Try again.")
                dbgLog(1, "ADMIN", p.name .. " ?tpp -> " .. players[target].name .. " didn't verifiably move")
                return
            end
            say(peer_id, "Teleported to " .. players[target].name .. ".")
            dbgLog(3, "ADMIN", p.name .. " ran ?tpp -> " .. players[target].name)
            return
        end

        if command == "?bring" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?bring")
                return
            end
            local m, ok = server.getPlayerPos(peer_id)
            if not ok then
                say(peer_id, "Couldn't get your own position, try again in a moment.")
                return
            end
            local tx, ty, tz = matrix.position(m)
            if not safeServer("setPlayerPos", target, m) then
                say(peer_id, "Bring failed, server.setPlayerPos unavailable.")
                return
            end
            local vm, vok = server.getPlayerPos(target)
            if not vok or not vm or dist3({ matrix.position(vm) }, { tx, ty, tz }) > CONFIG.VTP_VERIFY_TOLERANCE then
                say(peer_id, "Bring failed, they didn't verifiably move. Try again.")
                dbgLog(1, "ADMIN", p.name .. " ?bring -> " .. players[target].name .. " didn't verifiably move")
                return
            end
            say(peer_id, "Brought " .. players[target].name .. " to you.")
            notify(target, "Summoned", "You were teleported to an admin.", "YELLOW")
            dbgLog(3, "ADMIN", p.name .. " ran ?bring -> " .. players[target].name)
            return
        end

        if command == "?freeze" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?freeze")
                return
            end
            local m, ok = server.getPlayerPos(target)
            if not ok then
                say(peer_id, "Couldn't get their position, try again in a moment.")
                return
            end
            frozen[target] = { mode = "spot", pos = m }
            say(peer_id, "Froze " .. players[target].name .. ".")
            notify(target, "Frozen", "An admin has frozen you in place.", "RED")
            dbgLog(3, "ADMIN", p.name .. " ran ?freeze -> " .. players[target].name)
            return
        end

        if command == "?hold" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?hold")
                return
            end
            frozen[target] = { mode = "front", anchor = peer_id }
            say(peer_id, "Now holding " .. players[target].name .. " in front of you.")
            notify(target, "On A Leash", "An admin is holding you in front of them.", "RED")
            dbgLog(3, "ADMIN", p.name .. " ran ?hold -> " .. players[target].name)
            return
        end

        if command == "?unfreeze" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?unfreeze")
                return
            end
            if frozen[target] then
                frozen[target] = nil
                say(peer_id, "Released " .. players[target].name .. ".")
                notify(target, "Released", "You're free.", "YELLOW")
                dbgLog(3, "ADMIN", p.name .. " ran ?unfreeze -> " .. players[target].name)
            else
                say(peer_id, "They're not currently frozen or held, so there's nothing to release.")
            end
            return
        end

        if command == "?crash" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?crash")
                return
            end
            -- No verify-then-act here (unlike ?tpp/?bring): a NaN position IS the goal.
            local nan = 0 / 0
            if not safeServer("setPlayerPos", target, matrix.translation(nan, nan, nan)) then
                say(peer_id, "Crash failed, server.setPlayerPos unavailable.")
                return
            end
            server.announce("[Server]", players[target].name .. " has been ejected from reality.", -1)
            dbgLog(3, "ADMIN", p.name .. " ran ?crash -> " .. players[target].name)
            return
        end

        if command == "?revoke" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?revoke")
                return
            end
            local tp = players[target]
            tp.authed = false
            tp.revoked = true
            server.removeAuth(target)
            local removed = destroyAllGroupsOf(tp.steam_id)
            say(peer_id, "Revoked auth from " .. tp.name .. " and removed " .. removed .. " of their creation(s).")
            notify(target, "Auth Revoked",
                "An admin revoked your auth.\nYour vehicles have been removed.\nType ?auth to re-request access.",
                "RED")
            refreshUI(target, lastPlayerCount)
            dbgLog(3, "ADMIN", p.name .. " ran ?revoke -> " .. tp.name .. " (removed " .. removed .. ")")
            return
        end

        if command == "?dsp" then
            local target = resolveTarget(arg1)
            if not target then
                showCommandHelp(peer_id, "?dsp")
                return
            end
            local tp = players[target]
            local removed = destroyAllGroupsOf(tp.steam_id)
            say(peer_id, "Despawned " .. removed .. " of " .. tp.name .. "'s creation(s).")
            if removed > 0 then
                notify(target, "Vehicles Despawned", "An admin despawned your creations.", "YELLOW")
            end
            dbgLog(3, "ADMIN", p.name .. " ran ?dsp -> " .. tp.name .. " (removed " .. removed .. ")")
            return
        end

        -- One arg = global limit; two args = that player's limit.
        if command == "?setlimit" then
            if arg2 == nil then
                local n = tonumber(arg1)
                if not n or n < 1 then
                    showCommandHelp(peer_id, "?setlimit")
                    return
                end
                if n > CONFIG.MAX_LIMIT then
                    say(peer_id, "Limit is capped at " .. CONFIG.MAX_LIMIT .. ", using " .. CONFIG.MAX_LIMIT .. ".")
                    n = CONFIG.MAX_LIMIT
                end
                globalLimit = math.floor(n)
                say(-1, "Global vehicle limit is now " .. globalLimit .. ".")
                dbgLog(3, "ADMIN", p.name .. " ran ?setlimit -> global " .. globalLimit)
                for _, pl in pairs(players) do enforceLimit(pl.steam_id) end
                return
            end

            local target = resolveTarget(arg1)
            local n = tonumber(arg2)
            if not target or not n then
                showCommandHelp(peer_id, "?setlimit")
                return
            end
            if n < 1 then
                say(peer_id, "Limit must be at least 1.")
                return
            end
            if n > CONFIG.MAX_LIMIT then
                say(peer_id, "Limit is capped at " .. CONFIG.MAX_LIMIT .. ", using " .. CONFIG.MAX_LIMIT .. ".")
                n = CONFIG.MAX_LIMIT
            end
            players[target].limit = math.floor(n)
            say(peer_id, "Set " .. players[target].name .. "'s limit to " .. players[target].limit .. ".")
            say(target, "An admin set your vehicle limit to " .. players[target].limit .. ".")
            dbgLog(3, "ADMIN", p.name .. " ran ?setlimit -> " .. players[target].name .. " = " .. players[target].limit)
            enforceLimit(players[target].steam_id)
            return
        end

        if command == "?nuke" or command == "?hypernuke" or command == "?meganuke" then
            if not server.dlcWeapons() then
                say(peer_id, "Nukes require the Search and Destroy DLC, which isn't enabled here.")
                return
            end
            local m, err = resolveNukeTarget(arg1, arg2)
            if not m then
                say(peer_id, err)
                showCommandHelp(peer_id, command)
                return
            end
            local tier = command:sub(2)
            queueNuke(tier, m)
            server.announce("[Server]", "Incoming " .. tier .. "! (" .. #nukeQueue .. " blasts queued)", -1)
            dbgLog(3, "ADMIN", p.name .. " ran ?" .. tier .. " at " .. tostring(arg1) .. " " .. tostring(arg2))
            return
        end

        -- Can't reach items already on the ground before the script loaded.
        if command == "?flares" then
            local count = 0
            for object_id in pairs(looseEquipment) do
                if safeServer("despawnObject", object_id, true) then
                    looseEquipment[object_id] = nil
                    count = count + 1
                end
            end
            say(peer_id, "Despawned " .. count .. " tracked loose item(s).")
            dbgLog(3, "ADMIN", p.name .. " ran ?flares, despawned " .. count)
            return
        end

        -- Limited to ~3 words since onCustomCommand only gives 3 args.
        if command == "?announce" then
            local parts = {}
            if arg1 then parts[#parts + 1] = tostring(arg1) end
            if arg2 then parts[#parts + 1] = tostring(arg2) end
            if arg3 then parts[#parts + 1] = tostring(arg3) end
            if #parts == 0 then
                showCommandHelp(peer_id, "?announce")
                return
            end
            local msg = table.concat(parts, " ")
            server.announce("[" .. CONFIG.SERVER_NAME .. "]", msg, -1)
            for pid in pairs(players) do
                notify(pid, "Announcement", msg, "GREEN")
            end
            dbgLog(3, "ADMIN", p.name .. " ran ?announce -> " .. msg)
            return
        end

        if command == "?dbg" then
            local raw = arg1 and tostring(arg1):lower() or "0"
            local n = (raw == "off") and 0 or tonumber(raw)
            if not n or n < 0 or n > 5 then
                showCommandHelp(peer_id, "?dbg")
                return
            end
            p.dbgLevel = math.floor(n)
            if p.dbgLevel == 0 then
                say(peer_id, "Debug stream off.")
            else
                say(peer_id, "Debug stream set to level " .. p.dbgLevel .. " (1=critical .. 5=everything).")
            end
            dbgLog(3, "ADMIN", p.name .. " ran ?dbg -> level " .. p.dbgLevel)
            return
        end

        if command == "?perf" then
            local applyQ = 0
            for _ in pairs(pendingApply) do applyQ = applyQ + 1 end
            local curveText
            if tpsNow < CONFIG.ANTILAG_CRITICAL_TPS then
                local sustainedSec = criticalWasHealthy and 0 or (server.getTimeMillisec() - criticalSinceMs) / 1000
                curveText = "antilag CRITICAL | sustained " .. string.format("%.1f", sustainedSec) .. "/" ..
                    CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC .. "s"
            elseif tpsNow < normalTpsThreshold() then
                curveText = "antilag NORMAL | culling worst group (threshold " .. normalTpsThreshold() .. ")"
            else
                curveText = "antilag idle (tps healthy, threshold " .. normalTpsThreshold() .. ")"
            end
            server.announce("[PERF]",
                "TPS " .. string.format("%.1f", tpsNow) .. " (avg " .. string.format("%.1f", tpsAvg) .. ") | " ..
                "applyQueue " ..
                applyQ .. " | nukeQueue " .. #nukeQueue .. " | players " .. lastPlayerCount .. " | " .. curveText,
                peer_id)
            return
        end

        -- No argument manually triggers a cull check; ?antilag <n> sets the threshold (10-50).
        if command == "?antilag" then
            if arg1 == nil then
                local nowMs = server.getTimeMillisec()
                local worst, worstCost = nil, 0
                for group_id, g in pairs(groups) do
                    local ageSec = (nowMs - (g.spawn_ms or 0)) / 1000
                    if (g.cost or 0) > 0 and ageSec >= CONFIG.LAG_SPAWN_GRACE_SEC then
                        local ec = effectiveCost(group_id)
                        if ec > worstCost then worst, worstCost = group_id, ec end
                    end
                end
                if not worst then
                    say(peer_id, "Nothing to cull, no eligible groups running right now.")
                    return
                end
                if pendingDestroy[worst] then
                    say(peer_id, ownerName(groups[worst]) .. "'s creation is already counting down.")
                    return
                end
                local worstOwnerPeer = steamToPeer[groups[worst].owner_steam]
                say(peer_id, "Triggered: culling " .. ownerName(groups[worst]) .. "'s creation (cost " ..
                    fmtCost(worstCost) .. ").")
                if worstOwnerPeer then
                    notify(worstOwnerPeer, "Vehicle Removed",
                        "An admin manually triggered antilag. Your creation is the most expensive one running " ..
                        "and will be removed in " .. CONFIG.ANTILAG_COUNTDOWN_SEC .. "s.", "ORANGE")
                end
                -- cancelIfHealthy = false: a manual trigger is unconditional.
                scheduleGroupDestroy(worst, worstOwnerPeer, "manually triggered by admin",
                    "manual trigger", false)
                dbgLog(3, "ADMIN", p.name .. " manually triggered antilag on group " .. worst ..
                    " (" .. ownerName(groups[worst]) .. ", cost " .. fmtCost(worstCost) .. ")")
                return
            end

            local n = tonumber(arg1)
            if not n then
                showCommandHelp(peer_id, "?antilag")
                return
            end
            n = math.floor(math.max(10, math.min(50, n)))
            antilagNormalTps = n
            say(peer_id, "Normal antilag TPS threshold set to " .. n .. ".")
            dbgLog(3, "ADMIN", p.name .. " set antilag normal threshold to " .. n)
            return
        end
    end

    if not KNOWN_CMDS[command] then
        notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
        dbgLog(3, "CMD", p.name .. " [" .. rankOf(p) .. "] used unknown command " .. command)
    end
end
