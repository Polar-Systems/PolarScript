g_savedata = g_savedata or { playerdata = {}, usercreations = {} }
local groups = g_savedata.usercreations

function onTick(game_ticks)

end

function onPlayerJoin(steam_id, name, peer_id, admin, auth)
    server.announce("[Server]", name .. " joined the game")
end

function onPlayerLeave(steam_id, name, peer_id, admin, auth)
    server.announce("[Server]", name .. " left the game")
end

function onVehicleSpawn(vehicle_id, peer_id, x, y, z, group_cost, group_id)
    local groupIdStr = tostring(group_id)
    local vehicleIdStr = tostring(vehicle_id)

    groups[groupIdStr].vehicles[vehicleIdStr] = true
end

function onGroupSpawn(group_id, peer_id, x, y, z, group_cost)
    if peer_id == -1 or peer_id == nil then
        return
    end

    local groupIdStr = tostring(group_id)

    if groups[groupIdStr] == nil then
        groups[groupIdStr] = { owner = peer_id, vehicles = {} }
    else
        groups[groupIdStr].owner = peer_id
    end
end
