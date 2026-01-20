g_savedata = g_savedata or {}
g_savedata.playerdata = g_savedata.playerdata or {}
g_savedata.usercreations = g_savedata.usercreations or {}

local pendingApply = {}
local healTimer = 0
local groups = g_savedata.usercreations
local UI_ID = 9001
local UI_MAIN = 9001
local UI_ADMIN = 9002
local uiTimer = 0
local SERVER_NAME = "My Server"
local tpsNow = 60
local tpsAvg = 60
local UI_X = -0.9
local UI_Y_MAIN = 0.7
local UI_Y_ADMIN = 0
local lastXYZ = {}
local lastSpeedKmh = {}
local SPEED_TICKS = 1
local speedTimer = 0
local DBG_ON = true
local DBG_COOLDOWN_TICKS = 60
local dbgLast = {}
local UI_CENTER = 9003
local UI_X_CENTER = 0
local UI_Y_CENTER = 0

local function dbg(peer_id, tag, text)
    if not DBG_ON then return end
    local t = server.getTimeMillisec() or 0
    dbgLast[peer_id] = dbgLast[peer_id] or {}
    local last = dbgLast[peer_id][tag] or -999999
    if (t - last) < (DBG_COOLDOWN_TICKS * 1000 / 60) then return end
    dbgLast[peer_id][tag] = t
    server.announce("[DBG]", text, peer_id)
end

local function getPD(peer_id)
    local key = tostring(peer_id)
    g_savedata.playerdata[key] = g_savedata.playerdata[key] or {}
    local pd = g_savedata.playerdata[key]
    if pd.authed == nil then pd.authed = false end
    if pd.ui == nil then pd.ui = true end
    if pd.is_admin == nil then pd.is_admin = false end
    return pd
end

local function getRankText(pd)
    if pd.is_admin then return "ADMIN" end
    if pd.authed then return "AUTHED" end
    return "GUEST"
end

local function getPlaytimeText(pd)
    local s = pd.playtime_s or 0
    local m = math.floor(s / 60)
    local h = math.floor(m / 60)
    m = m % 60
    return tostring(h) .. "h " .. tostring(m) .. "m"
end

local function countMyGroups(peer_id)
    local n = 0
    for _, data in pairs(groups) do
        if data.owner == peer_id then n = n + 1 end
    end
    return n
end


local function buildCenter(peer_id)
    local pd = getPD(peer_id)
    if pd.authed then return "" end

    return
        "==<" .. SERVER_NAME .. ">==\n" ..
        "You are NOT authed\n" ..
        "Type ?auth to enable commands\n" ..
        "Tip: ?help"
end

local function updateCenter(peer_id)
    local pd = getPD(peer_id)

    if pd.authed then
        server.setPopupScreen(peer_id, UI_CENTER, "Auth", false, "", UI_X_CENTER, UI_Y_CENTER)
        return
    end

    server.setPopupScreen(peer_id, UI_CENTER, "Auth", true, buildCenter(peer_id), UI_X_CENTER, UI_Y_CENTER)
end

local function onOff(v) return v and "ON" or "OFF" end

local function buildUiAdmin(peer_id)
    local pd = getPD(peer_id)

    local trackedGroups = 0
    for _ in pairs(groups) do trackedGroups = trackedGroups + 1 end

    local pending = 0
    for _ in pairs(pendingApply) do pending = pending + 1 end

    return
        "ADMIN\n" ..
        "Auth: " .. onOff(pd.authed) .. "\n" ..
        "AS: " .. onOff(pd.as ~= false) .. "  PVP: " .. onOff(pd.pvp) .. "\n" ..
        "Groups: " .. trackedGroups .. "\n" ..
        "Pending: " .. pending
end

local function getMatrixPos(m)
    if not m then return 0, 0, 0 end

    if matrix and matrix.position then
        local a, b, c = matrix.position(m)
        if type(a) == "number" then return a, b, c end
        if type(a) == "table" then
            return a.x or a[1] or 0, a.y or a[2] or 0, a.z or a[3] or 0
        end
    end

    return m[13] or 0, m[14] or 0, m[15] or 0
end

local function getPlayerXYZ(peer_id)
    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then return 0, 0, 0, false end
    local m = server.getObjectPos(charId)
    local x, y, z = getMatrixPos(m)
    return x, y, z, true
end

local function countTrackedVehicles()
    local n = 0
    for _, data in pairs(groups) do
        local v = data.vehicles or {}
        for _ in pairs(v) do n = n + 1 end
    end
    return n
end

local function buildUiMain(peer_id)
    local pd = getPD(peer_id)
    local xyz = lastXYZ[peer_id] or { x = 0, y = 0, z = 0 }
    local speedKmh = lastSpeedKmh[peer_id] or 0
    local myGroups = countMyGroups(peer_id)

    return
        "==<" .. SERVER_NAME .. ">==\n" ..
        "TPS:\n" ..
        "Average TPS:\n" ..
        "============\n" ..
        "Vehicles: " .. tostring(myGroups) .. "\n" ..
        "Speed: " .. string.format("%.1f", speedKmh) .. " km/h\n" ..
        "Altitude: " .. string.format("%.1f", xyz.y) .. "\n" ..
        "============\n" ..
        "Rank: " .. getRankText(pd) .. "\n" ..
        "Playtime: " .. getPlaytimeText(pd)
end

local function updateUiFor(peer_id, is_show)
    if not is_show then
        server.setPopupScreen(peer_id, UI_MAIN, "Main", false, "", UI_X, UI_Y_MAIN)
        server.setPopupScreen(peer_id, UI_ADMIN, "Admin", false, "", UI_X, UI_Y_ADMIN)
        return
    end

    server.setPopupScreen(
        peer_id,
        UI_MAIN,
        "Main",
        true,
        buildUiMain(peer_id),
        UI_X,
        UI_Y_MAIN
    )

    local pd = g_savedata.playerdata[tostring(peer_id)] or {}
    if pd.is_admin then
        server.setPopupScreen(
            peer_id,
            UI_ADMIN,
            "Admin",
            true,
            buildUiAdmin(peer_id),
            UI_X,
            UI_Y_ADMIN
        )
    else
        server.setPopupScreen(peer_id, UI_ADMIN, "Admin", false, "", UI_X, UI_Y_ADMIN)
    end
end

local function buildTooltip(vehicle_id, ownerPeer, group_id)
    local pd = g_savedata.playerdata[tostring(ownerPeer)] or {}
    local as = pd.as
    if as == nil then as = true end
    local pvp = pd.pvp
    if pvp == nil then pvp = false end

    return
        "Owner: " .. tostring(ownerPeer) ..
        "\nVehicle ID: " .. tostring(vehicle_id) ..
        "\nGroup ID: " .. tostring(group_id) ..
        "\nAntiSteal: " .. tostring(as) ..
        "\nPvP: " .. tostring(pvp)
end

local function applyVehicleSettings(vehicle_id, ownerPeer, group_id)
    local pd = g_savedata.playerdata[tostring(ownerPeer)] or {}
    local as = pd.as
    if as == nil then as = true end
    local pvp = pd.pvp
    if pvp == nil then pvp = false end

    server.setVehicleEditable(vehicle_id, not as)

    server.setVehicleInvulnerable(vehicle_id, not pvp)

    server.setVehicleTooltip(vehicle_id, buildTooltip(vehicle_id, ownerPeer, group_id))
end

local function getOwnerAndGroupFromVehicle(vehicle_id)
    local vehicleIdStr = tostring(vehicle_id)
    for groupIdStr, data in pairs(groups) do
        local v = data.vehicles or {}
        if v[vehicleIdStr] then
            return data.owner, groupIdStr
        end
    end
    return nil, nil
end

local function healIfPvpOff(peer_id)
    local pd = g_savedata.playerdata[tostring(peer_id)] or {}
    local pvp = pd.pvp
    if pvp == nil then pvp = false end
    if pvp then return end

    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then return end

    local data = server.getObjectData(charId)
    if not data then return end

    if data.dead or data.incapacitated then
        server.reviveCharacter(charId)
    end

    if data.hp and data.hp < 100 then
        server.setCharacterData(charId, 100, true, false)
    end
end

local function sendHelp(peer_id, is_admin, is_auth)
    local msg = ""
    msg = msg .. "Commands:\n"
    msg = msg .. "?help\n"
    msg = msg .. "?auth\n"
    msg = msg .. "?noworkshop\n"

    if is_auth then
        msg = msg .. "?as / ?antisteal\n"
        msg = msg .. "?pvp\n"
        msg = msg .. "?c / ?cleanup\n"
    else
        msg = msg .. "(auth needed) ?as, ?pvp, ?c\n"
    end

    if is_admin then
        msg = msg .. "\nAdmin:\n"
        msg = msg .. "?dbg\n"
    end

    server.announce("[Help]", msg, peer_id)
end

function onTick(game_ticks)
    speedTimer = speedTimer + game_ticks
    if speedTimer >= SPEED_TICKS then
        speedTimer = 0

        for _, pl in pairs(server.getPlayers()) do
            local x, y, z, ok = getPlayerXYZ(pl.id)
            if ok then
                local prev = lastXYZ[pl.id]
                if prev then
                    local dx = x - prev.x
                    local dy = y - prev.y
                    local dz = z - prev.z
                    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                    local dt = SPEED_TICKS / 60
                    lastSpeedKmh[pl.id] = (dist / dt) * 3.6
                else
                    lastSpeedKmh[pl.id] = 0
                end
                lastXYZ[pl.id] = { x = x, y = y, z = z }
            else
                lastSpeedKmh[pl.id] = 0
            end
        end
    end
    local perf = 60 / math.max(game_ticks, 1)
    if perf > 60 then perf = 60 end
    tpsNow = perf
    tpsAvg = (tpsAvg * 0.9) + (tpsNow * 0.1)

    for vehicle_id, data in pairs(pendingApply) do
        applyVehicleSettings(vehicle_id, data.owner, data.group)
        pendingApply[vehicle_id] = nil
    end

    healTimer = healTimer + game_ticks
    if healTimer >= 0 then
        healTimer = 0
        for _, pl in pairs(server.getPlayers()) do
            healIfPvpOff(pl.id)
        end
    end

    uiTimer = uiTimer + game_ticks
    if uiTimer >= 0 then
        uiTimer = 0
        for _, pl in pairs(server.getPlayers()) do
            local key = tostring(pl.id)
            g_savedata.playerdata[key] = g_savedata.playerdata[key] or {}
            local pd = getPD(pl.id)
            pd.playtime_s = (pd.playtime_s or 0) + (game_ticks / 60)

            pd.is_admin = (pl.admin == true or pl.admin == 1)

            local show = pd.ui
            if show == nil then show = true end
            updateUiFor(pl.id, show)
            updateCenter(pl.id)
        end
    end
end

function onPlayerJoin(steam_id, name, peer_id, admin, auth)
    server.announce("[Server]", name .. " joined the game")

    local key = tostring(peer_id)
    g_savedata.playerdata[key] = g_savedata.playerdata[key] or {}
    local pd = g_savedata.playerdata[key]

    pd.is_admin = (admin == true)

    pd.authed = false
    pd.as = true
    pd.pvp = false
    pd.ui = true

    server.removeAuth(peer_id)
    server.announce("[Server]", "Type ?auth to get auth!", peer_id)

    updateUiFor(peer_id, true)
    updateCenter(peer_id)
end

function onPlayerLeave(steam_id, name, peer_id, admin, auth)
    server.removePopup(peer_id, UI_CENTER)
    server.removePopup(peer_id, UI_MAIN)
    server.removePopup(peer_id, UI_ADMIN)
    server.announce("[Server]", name .. " left the game")

    local toRemove = {}
    for groupIdStr, data in pairs(groups) do
        if data.owner == peer_id then
            toRemove[#toRemove + 1] = groupIdStr
        end
    end

    for i = 1, #toRemove do
        local gid = toRemove[i]
        server.despawnVehicleGroup(tonumber(gid) or gid, true)
        groups[gid] = nil
    end
    server.removePopup(peer_id, UI_ID)
end

function onCustomCommand(full_message, user_peer_id, is_admin, is_auth, command, one, two, three, four, five)
    command = (command or ""):lower()

    local key = tostring(user_peer_id)
    g_savedata.playerdata[key] = g_savedata.playerdata[key] or {}
    g_savedata.playerdata[key].is_admin = (is_admin == true or is_admin == 1)

    if command == "?help" then
        sendHelp(user_peer_id, is_admin, is_auth)
        return
    end

    if command == "?ui" then
        local key = tostring(user_peer_id)
        local pd = g_savedata.playerdata[key] or {}
        local cur = pd.ui
        if cur == nil then cur = true end
        pd.ui = not cur
        g_savedata.playerdata[key] = pd

        updateUiFor(user_peer_id, pd.ui)
        server.announce("[Server]", "ui = " .. tostring(pd.ui), user_peer_id)
        return
    end

    if (command == "?c" or command == "?cleanup" or command == "?as" or command == "?antisteal") and not is_auth then
        server.announce("[Server]", "Run ?auth first", user_peer_id)
        return
    end

    if command == "?pvp" then
        local pd = g_savedata.playerdata[tostring(user_peer_id)] or {}
        local cur = pd.pvp
        if cur == nil then cur = false end
        pd.pvp = not cur
        g_savedata.playerdata[tostring(user_peer_id)] = pd

        server.announce("[Server]", "PvP = " .. tostring(pd.pvp), user_peer_id)

        for groupIdStr, data in pairs(groups) do
            if data.owner == user_peer_id then
                local v = data.vehicles or {}
                for vehicleIdStr, _ in pairs(v) do
                    pendingApply[tonumber(vehicleIdStr) or vehicleIdStr] = { owner = user_peer_id, group = groupIdStr }
                end
            end
        end
    end

    if command == "?auth" then
        local pd = getPD(user_peer_id)
        pd.authed = true
        server.addAuth(user_peer_id)
        updateCenter(user_peer_id)
        server.announce("[Server]", "You are authed", user_peer_id)
        return
    end

    if command == "?noworkshop" then
        local pd = getPD(user_peer_id)
        pd.authed = false
        server.removeAuth(user_peer_id)
        updateCenter(user_peer_id)
        server.announce("[Server]", "Workshop disabled", user_peer_id)
        return
    end

    if command == "?as" or command == "?antisteal" then
        local pd = g_savedata.playerdata[tostring(user_peer_id)] or {}
        local current = pd.as
        if current == nil then current = true end
        pd.as = not current
        g_savedata.playerdata[tostring(user_peer_id)] = pd

        server.announce("[Server]", "Antisteal = " .. tostring(pd.as), user_peer_id)

        for groupIdStr, data in pairs(groups) do
            if data.owner == user_peer_id then
                local v = data.vehicles or {}
                for vehicleIdStr, _ in pairs(v) do
                    applyVehicleSettings(tonumber(vehicleIdStr) or vehicleIdStr, user_peer_id, groupIdStr)
                end
            end
        end
    end

    if command == "?c" or command == "?cleanup" then
        local me = user_peer_id
        local despawned = 0
        local toRemove = {}

        for groupIdStr, data in pairs(groups) do
            if data.owner == me then
                toRemove[#toRemove + 1] = groupIdStr
            end
        end

        for i = 1, #toRemove do
            local groupIdStr = toRemove[i]
            server.despawnVehicleGroup(tonumber(groupIdStr) or groupIdStr, true)
            groups[groupIdStr] = nil
            despawned = despawned + 1
        end



        server.announce("[Server]", "Despawned " .. tostring(despawned) .. " groups", me)
    end

    if command == "?dbg" then
        local countGroups = 0
        for _ in pairs(groups) do countGroups = countGroups + 1 end

        server.announce("[DBG]", "groups tracked: " .. tostring(countGroups), user_peer_id)

        for gid, data in pairs(groups) do
            local countVehicles = 0
            local v = data.vehicles or {}
            for _ in pairs(v) do countVehicles = countVehicles + 1 end

            server.announce("[DBG]",
                "group " .. gid .. " owner " .. tostring(data.owner) .. " vehicles " .. tostring(countVehicles),
                user_peer_id)
        end
    end
end

function onVehicleSpawn(vehicle_id, peer_id, x, y, z, group_cost, group_id)
    if peer_id == -1 or peer_id == nil then
        return
    end

    local groupIdStr = tostring(group_id)
    local vehicleIdStr = tostring(vehicle_id)

    if groups[groupIdStr] == nil then
        groups[groupIdStr] = { owner = peer_id, vehicles = {} }
        server.announce("[DBG]", "group auto-created from vehicle spawn " .. groupIdStr)
    end

    groups[groupIdStr].vehicles[vehicleIdStr] = true
    pendingApply[vehicle_id] = { owner = peer_id, group = groupIdStr }
    server.announce("[DBG]", "vehicle " .. vehicleIdStr .. " added to group " .. groupIdStr)
end

function onGroupSpawn(group_id, peer_id, x, y, z, group_cost)
    if peer_id == -1 or peer_id == nil then
        return
    end

    local groupIdStr = tostring(group_id)

    local key = tostring(peer_id)
    g_savedata.playerdata[key] = g_savedata.playerdata[key] or {}
    local pd = g_savedata.playerdata[key]

    local old = pd.last_group
    if old and groups[tostring(old)] then
        server.despawnVehicleGroup(tonumber(old) or old, true)
        groups[tostring(old)] = nil
    end

    groups[groupIdStr] = groups[groupIdStr] or { owner = peer_id, vehicles = {} }
    groups[groupIdStr].owner = peer_id
    pd.last_group = group_id

    server.announce("[DBG]", "group set " .. groupIdStr .. " owner " .. tostring(peer_id))
end

function onVehicleDespawn(vehicle_id, peer_id)
    local vehicleIdStr = tostring(vehicle_id)

    for groupIdStr, data in pairs(groups) do
        local v = data.vehicles or {}
        if v[vehicleIdStr] then
            v[vehicleIdStr] = nil
            server.announce("[DBG]", "vehicle " .. vehicleIdStr .. " removed from group " .. groupIdStr)

            local anyLeft = false
            for _ in pairs(v) do
                anyLeft = true
                break
            end

            if not anyLeft then
                groups[groupIdStr] = nil
                server.announce("[DBG]", "group cleaned " .. groupIdStr)
            end

            break
        end
    end
end

function onVehicleLoad(vehicle_id)
    local ownerPeer, groupIdStr = getOwnerAndGroupFromVehicle(vehicle_id)
    if not ownerPeer then return end
    applyVehicleSettings(vehicle_id, ownerPeer, groupIdStr)
end
