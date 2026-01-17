g_savedata = g_savedata or {}

function ensure_savedata()
    if type(g_savedata) ~= "table" then
        g_savedata = {}
    end
    g_savedata.players = g_savedata.players or {}
    g_savedata.admins = g_savedata.admins or {}
    g_savedata.config = g_savedata.config or {
        antisteal = false,
        relay_url = "http://127.0.0.1:8371/v1/emit",
    }
end

function is_admin(steam_id)
    return g_savedata.admins[tostring(steam_id)] == true
end

function add_admin(steam_id)
    g_savedata.admins[tostring(steam_id)] = true
end

function remove_admin(steam_id)
    g_savedata.admins[tostring(steam_id)] = nil
end

function relay_event(kind, payload)
    message = string.format(
        '{"source":"polarscript","kind":"%s","payload":%s}',
        kind,
        payload
    )
    if server.httpPost then
        pcall(server.httpPost, g_savedata.config.relay_url, message)
    elseif server.httpRequest then
        pcall(server.httpRequest, g_savedata.config.relay_url, message)
    end
end

function json_escape(value)
    text = tostring(value)
    text = text:gsub("\\", "\\\\")
    text = text:gsub("\"", "\\\"")
    return text
end

function onCreate(is_world_create)
    ensure_savedata()
end

function onSave()
    return g_savedata
end

function onTick(game_ticks)
    if game_ticks % 3600 == 0 then
        relay_event("polarscript.heartbeat", string.format('{"tick":%d}', game_ticks))
    end
end

function onPlayerJoin(steam_id, name, peer_id, admin, auth)
    ensure_savedata()
    g_savedata.players[tostring(steam_id)] = {
        name = name,
        peer_id = peer_id,
        admin = admin or false,
        auth = auth or false,
        joined = os.time(),
    }
    if admin or auth then
        add_admin(steam_id)
    end
    server.announce("[Server]", name .. " joined the game")
    relay_event(
        "polarscript.join",
        string.format('{"name":"%s","steam_id":"%s"}', json_escape(name), json_escape(steam_id))
    )
end

function onPlayerLeave(steam_id, name, peer_id, admin, auth)
    ensure_savedata()
    g_savedata.players[tostring(steam_id)] = nil
    server.announce("[Server]", name .. " left the game")
    relay_event(
        "polarscript.leave",
        string.format('{"name":"%s","steam_id":"%s"}', json_escape(name), json_escape(steam_id))
    )
end

function onPlayerDie(steam_id, name, peer_id, is_admin, is_auth)
    server.announce("[Server]", name .. " died")
    relay_event(
        "polarscript.death",
        string.format('{"name":"%s","steam_id":"%s"}', json_escape(name), json_escape(steam_id))
    )
end

function onVehicleSpawn(vehicle_id, peer_id, x, y, z, cost)
    relay_event("polarscript.vehicle_spawn", string.format('{"vehicle_id":%d,"peer_id":%d}', vehicle_id, peer_id))
    setVehicleEditable(vehicle_id, false)
end

function onCustomCommand(full_message, user_peer_id, is_admin, is_auth, command, one, two, three, four, five)
    ensure_savedata()
    steam_id = server.getPlayerSteamID and server.getPlayerSteamID(user_peer_id) or user_peer_id
    if command == "?help" then
        server.announce("[PolarScript]", "Commands: ?ping ?players ?admin ?antisteal ?relay")
    elseif command == "?ping" then
        server.announce("[PolarScript]", "Pong!")
    elseif command == "?players" then
        count = 0
        for _ in pairs(g_savedata.players) do
            count = count + 1
        end
        server.announce("[PolarScript]", "Online players: " .. tostring(count))
    elseif command == "?admin" and (is_admin or is_auth) then
        if one == "add" and two then
            add_admin(two)
            server.announce("[PolarScript]", "Added admin " .. tostring(two))
        elseif one == "remove" and two then
            remove_admin(two)
            server.announce("[PolarScript]", "Removed admin " .. tostring(two))
        else
            server.announce("[PolarScript]", "Usage: ?admin add/remove <steam_id>")
        end
    elseif command == "?antisteal" and (is_admin or is_auth) then
        if one == "on" then
            g_savedata.config.antisteal = true
            server.announce("[PolarScript]", "Anti-steal enabled")
        elseif one == "off" then
            g_savedata.config.antisteal = false
            server.announce("[PolarScript]", "Anti-steal disabled")
        else
            server.announce("[PolarScript]", "Usage: ?antisteal on/off")
        end
    elseif command == "?relay" and (is_admin or is_auth) then
        if one then
            g_savedata.config.relay_url = one
            server.announce("[PolarScript]", "Relay URL updated")
        else
            server.announce("[PolarScript]", "Usage: ?relay <url>")
        end
    end
end
