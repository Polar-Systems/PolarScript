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

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local CONFIG                 = {
    SERVER_NAME                    = "(server name)",   -- shown at the top of the main UI panel and in chat prefixes
    SCRIPT_NAME                    = "PolarScript", -- fixed addon branding, used ONLY in the load announcement
    DEFAULT_VEHICLE_LIMIT          = 1,
    UI_REFRESH_TICKS               = 30,            -- was 60 (1s) -- halved so the stats panel/nearby list/auth
    -- screen feel snappier. State-changing commands (auth, revoke) also force an
    -- immediate refresh instead of waiting for this timer at all -- see refreshUI() callers.
    HEAL_CHECK_TICKS               = 30,
    TPS_WINDOW_TICKS               = 60,
    DESPAWN_VEHICLES_ON_LEAVE      = true,
    APPLY_PER_TICK                 = 4,
    FLIP_Y_OFFSET                  = 2.0,
    VTP_HEIGHT                     = 5.0,
    VTP_VERIFY_TOLERANCE           = 15.0, -- metres -- a ?vtp'd body this close to the target counts as arrived
    VTP_MOVED_MIN                  = 5.0,  -- metres -- OR a body that moved at least this far from where it
    -- started counts as moved (covers large builds whose sampled body lands far from the
    -- exact target purely due to build size). Failure = neither of the two. See vtpGroupToPlayer().
    DEFAULT_UI_ON                  = true,
    DEFAULT_ANTISTEAL              = true,
    DEFAULT_PVP                    = false,

    -- ANTILAG -----------------------------------------------------------------
    ANTILAG_ENABLED                = true, -- master switch for auto-despawn (all triggers below)
    SPAWN_POPUP                    = true, -- global "vehicle spawned" popup with lag cost

    -- Cost formula weights. Voxels and mass were the only inputs before; now every
    -- expensive dimension server.getVehicleComponents() exposes is counted, plus
    -- sub-body count at the group level (joint/constraint solving scales badly with
    -- body count, not just linearly -- see LAG_W_SUBBODY below).
    LAG_W_VOXELS                   = 1.0,  -- cost weight per voxel
    LAG_W_MASS                     = 2.0,  -- cost weight per unit mass
    LAG_W_COMPONENTS               = 15.0, -- cost weight per LOGIC/electronic component (seats, buttons, dials,
    -- tanks, batteries, hoppers, guns, rope_hooks, signs). Weighted far
    -- higher per-unit than voxels/mass because each one is simulated AND
    -- network-synced individually -- 50 buttons costs far more than 50
    -- plain hull voxels, even though voxel/mass math alone treats them the same.
    LAG_W_SUBBODY                  = 400.0, -- cost weight per sub-body (vehicle) IN THE GROUP, applied at group level.
    -- Joint/constraint solving between bodies scales worse than linearly,
    -- so a 20-body creation isn't just "20x one body" -- it's disproportionately
    -- worse, and this weight is what makes MAX_SUBBODIES_PER_GROUP (below)
    -- and the cost ceiling agree with each other instead of contradicting.

    LAG_PLAYER_FACTOR              = 0.15, -- each connected player inflates effective cost by this fraction
    LAG_AGE_WEIGHT                 = 0.5,  -- freshly spawned vehicles cost up to +50% (they're the spike)
    LAG_AGE_DECAY                  = 600,  -- ticks (10s) over which the recency bonus fades to 0

    -- LAG_MAX_COST is a blind-guess starting point, same caveat as before. Doubled
    -- again per request -- still worth retuning from real ?dbg readings once you
    -- have telemetry from your actual builds.
    LAG_MAX_COST                   = 120000, -- effective cost above which a group is auto-despawned on load
    -- (this ceiling has NO grace period -- a genuinely oversized build
    -- gets caught immediately, on purpose)

    -- HARD STRUCTURAL LIMITS -- independent of the weighted cost formula entirely.
    -- These fire even if a group's weighted cost happens to be low (e.g. lots of cheap
    -- small bodies, or lots of blocks with low individual mass) -- they catch shapes of
    -- abuse the cost formula alone might underweight.
    MAX_SUBBODIES_PER_GROUP        = 25,    -- more than this many physics bodies (sub-vehicles) in one
    -- group -> instant despawn, checked the moment a new body joins.
    MAX_BLOCKS_PER_GROUP           = 20000, -- more than this many total voxels/blocks across the whole
    -- group -> instant despawn, checked on load. Also a guess --
    -- retune from ?dbg once you see real numbers.

    ANTILAG_COUNTDOWN_SEC          = 3, -- seconds a doomed group sits with a countdown popup
    -- before it's actually removed, giving the owner a moment to see it coming.
    -- Applies to all four antilag triggers (sub-body limit, block limit, cost
    -- ceiling, TPS cull). The MADE-BY moderation check is separate and stays instant.

    LAG_SPAWN_GRACE_SEC            = 5.0, -- a group younger than this is IMMUNE to the TPS-triggered cull
    -- (below). Spawning always causes a brief, expected, legitimate TPS
    -- dip while the vehicle loads -- without this grace period, antilag
    -- sees that normal dip as "sustained lag" and kills the thing that
    -- just spawned, every single time, because it's the only group there.
    -- This does NOT exempt it from LAG_MAX_COST, MAX_SUBBODIES_PER_GROUP,
    -- or MAX_BLOCKS_PER_GROUP above -- those three are hard ceilings on
    -- purpose and stay instant regardless of age.

    -- FIXED-RATE TPS CULL. Same behavior no matter how bad the TPS is -- no
    -- gentle/aggressive scaling. Two tiers:
    --   tps < ANTILAG_NORMAL_TPS			   -> despawn ONE (the worst) group, with an
    --											  ANTILAG_COUNTDOWN_SEC warning popup first.
    --   tps < ANTILAG_CRITICAL_TPS sustained for
    --   ANTILAG_CRITICAL_SUSTAIN_SEC seconds	 -> despawn EVERYTHING, all groups at once.
    -- ANTILAG_NORMAL_TPS is live-adjustable in-game via ?antilag <10-50>.
    ANTILAG_NORMAL_TPS             = 40, -- below this, cull the single worst group
    ANTILAG_CRITICAL_TPS           = 10, -- below this, continuously, triggers the mass cull
    ANTILAG_CRITICAL_SUSTAIN_SEC   = 5,  -- how long TPS must stay under ANTILAG_CRITICAL_TPS before the mass cull fires

    -- The three HARD limits (sub-body count, block count, weighted cost) don't destroy
    -- the group the instant they're tripped - the owner gets this many seconds of
    -- warning with a countdown popup first. New sub-bodies still stop joining
    -- immediately (blockedGroups is set the moment the violation is detected), so this
    -- delay only affects when the actual removal happens, not whether the creation can
    -- keep growing during it. The normal-tier TPS cull reuses this same delay.

    -- NUKES (require Search & Destroy DLC) ------------------------------------
    NUKE_MAGNITUDE                 = 10.0, -- per-blast strength. Undocumented scale -- tune in-game.
    GRID_SPACING                   = 12.0, -- metres between blasts in a grid (big spread)
    HYPER_GRID                     = 5,    -- 5x5x5 = 125 blasts
    MEGA_GRID                      = 9,    -- 9x9x9 = 729 blasts
    NUKE_PER_TICK                  = 15,   -- blasts spawned per tick (729 -> ~49 ticks to drain)

    -- MODERATION --------------------------------------------------------------
    PROFANITY_BAN                  = true, -- auto-ban on a whole-word slur match
    -- NOTE: there is no [ADMIN]/[PLAYER] chat prefix. Confirmed in the API docs:
    -- onChatMessage is purely informational, has no return value, and there is NO
    -- function to cancel/suppress/edit a chat message before it reaches other clients.
    -- The only way to add a tag would be to ALSO broadcast a second, separate line
    -- (the original vanilla line still shows no matter what) -- removed per request
    -- rather than ship that half-measure.
    MAX_LIMIT                      = 10,   -- hard ceiling on any ?setlimit (global or per-player)
    CLEAN_VEHICLES_ON_LOAD         = true, -- server.cleanVehicles() on every script (re)load

    -- DROPPED EQUIPMENT ---------------------------------------------------------
    -- Anything a character drops (flares, coal, weapons, whatever) despawns the
    -- instant it hits the ground, via onEquipmentDrop -> server.despawnObject. There is
    -- no API to list every object already in the world, so this can only catch drops
    -- that happen while the script is running - ?flares below is a manual sweep over
    -- what this script has personally seen, not a scan of the whole map.
    AUTO_DESPAWN_DROPPED_EQUIPMENT = true,

    -- WARN / KICK / BAN ---------------------------------------------------------
    WARNS_BEFORE_KICK              = 3, -- Nth warning auto-kicks (and resets the warn counter to 0)
    KICKS_BEFORE_BAN               = 3, -- Nth auto-kick (from warnings) auto-bans instead

    -- ACCESS LISTS (pulled over HTTP) -----------------------------------------
    -- CRITICAL LIMITATION: Stormworks server.httpGet can ONLY reach localhost (127.0.0.1)
    -- on the machine running the game/dedicated server -- it CANNOT fetch a public URL
    -- directly, and it's limited to 1 request/tick. To use this (including the Discord
    -- warn webhook below) you MUST run a small local webserver on HTTP_PORT (same box)
    -- that answers these paths -- that local server is what actually reaches the
    -- internet/Discord. For the two LIST paths, any 17+ digit number in the reply body is
    -- treated as a steam_id (plain text, one-per-line, CSV, or a JSON array all parse
    -- fine). If no local server is listening the request is just dropped -- no-op, safe.
    HTTP_ENABLED                   = false,       -- master switch for the verified/admin lists AND the Discord warn webhook
    HTTP_PORT                      = 8080,
    HTTP_PATH_VERIFIED             = "/verified", -- returns steam_ids that auto-get auth
    HTTP_PATH_ADMINS               = "/admins",   -- returns steam_ids that auto-get admin + auth
    HTTP_PATH_WARN                 = "/warn",     -- GET ?steam_id=X&reason=Y -- your relay forwards this to the Discord bot
    HTTP_POLL_SEC                  = 60,          -- how often to re-pull the verified/admin lists

    -- steam_ids that always rank as OWNER (highest, above admin). Hardcoded, not from
    -- HTTP. MUST be a quoted STRING key, e.g. ["76561198000000000"] = true -- NOT a bare
    -- number. p.steam_id is always a string (tostring()'d on join in onPlayerJoin/
    -- makePlayerRecord), so CONFIG.OWNERS[p.steam_id] does a STRING-keyed lookup. A bare
    -- numeric key like [76561198305443102] is a completely different table key from the
    -- string "76561198305443102" -- Lua never treats them as equal, so the lookup always
    -- misses and isOwner()/rankOf()/applyAccess() silently never grant OWNER, no error, no
    -- warning. This also sidesteps a second, environment-dependent risk: some constrained
    -- Lua sandboxes store all numbers as doubles, which can't represent a 17-digit steam64
    -- id exactly -- a quoted string has no such precision ceiling either way.
    OWNERS                         = { ["76561198305443102"] = true },
    -- steam_ids that always rank as ADMIN. Hardcoded, not from HTTP -- separate from the
    -- HTTP-sourced adminSet (CONFIG.HTTP_PATH_ADMINS above). Same quoted-STRING-key rule
    -- as OWNERS applies here, for the exact same reason. Both OWNERS and ADMINS auto-auth
    -- AND auto-admin on join (see applyAccess()) -- neither tier needs to run ?noworkshop.
    ADMINS                         = {},
    -- steam_ids that rank as MODERATOR (between admin and player). Hardcoded, not from
    -- HTTP. Moderators get ONLY ?warn -- none of the other admin commands.
    MODERATORS                     = {},

    -- TELEPORT ------------------------------------------------------------------
    -- ?tp teleports a player to one of the vanilla map's named "teleport"-tagged
    -- zones (Multiplayer Hangar, ONeill, etc). These are built into the base game map
    -- itself, not this mission -- server.getZones("teleport") reads whatever zones
    -- exist in the world the server is actually running, so this only finds anything
    -- if that world has them. Set to false if the Arid/Industrial DLC is disabled on
    -- this server, which drops the location list from 16 down to 9.
    TELEPORT_ARID_DLC              = true,

    -- Freeze/hold -------------------------------------------------------------
    HOLD_RADIUS                    = 3.0,
    HOLD_HEIGHT                    = 1.0,
    HOLD_SPEED                     = 0.06, -- radians advanced PER UPDATE (not per tick -- see FREEZE_UPDATE_TICKS)
    FREEZE_UPDATE_TICKS            = 3,    -- how often frozen/held players get repositioned (3 = ~20Hz).
    -- Repositioning doesn't need 60Hz precision, and this is throttled
    -- the same way heal/UI already are -- only run it as often as it matters.

    -- ECONOMY ---------------------------------------------------------------
    ECONOMY_ENABLED                = true, -- master switch. When false, ?balance/?pay/?requestpay/
    -- ?accept/?decline/?cargo/?deliver/?refuel all fall through to "unknown command",
    -- and ?tool skips the balance check entirely (still gated by ?auth as before,
    -- just free again).
    ECONOMY_STARTING_BALANCE       = 500, -- new players start with this much

    -- Player-to-player payments.
    PAYREQUEST_TTL_SEC             = 300, -- a ?requestpay expires if not ?accept/?decline'd within this long

    -- Cargo hauling. There's no way for an addon script to detect whether a vehicle
    -- is actually built to the SIBTaT hitch standard -- that's a community BUILD
    -- CONVENTION about component geometry, invisible to the Lua API entirely. What
    -- IS readable is a vehicle's total mass (server.getVehicleComponents' d.mass,
    -- already used by analyzeVehicle for the antilag cost formula), so cargo jobs
    -- are built around that instead: delivery requires enough mass parked near the
    -- destination zone, not a specific trailer design. A real SIBTaT trailer is a
    -- natural, efficient way to hit that mass requirement, but it's never checked
    -- for directly -- any sufficiently heavy vehicle satisfies a job.
    -- Payout/mass requirement both scale with straight-line zone-to-zone distance,
    -- so farther jobs need bigger rigs and pay more. Not tuned against real map
    -- distances yet -- same "retune once you've seen real numbers" caveat as
    -- LAG_MAX_COST.
    CARGO_PAYOUT_BASE              = 50,   -- flat $ regardless of distance
    CARGO_PAYOUT_PER_KM            = 8,    -- extra $ per km of straight-line zone-to-zone distance
    CARGO_PAYOUT_CAP               = 600,  -- hard ceiling on any single job's payout
    CARGO_MASS_REQUIRED_BASE       = 500,  -- kg required at the destination regardless of distance
    CARGO_MASS_REQUIRED_PER_KM     = 20,   -- extra kg required per km of job distance
    CARGO_PICKUP_RADIUS            = 40.0, -- metres from a zone required to run ?cargo there
    CARGO_DELIVERY_RADIUS          = 40.0, -- metres from the destination zone a vehicle's mass must be
    -- within to count toward a job -- ANY vehicle's mass counts, not just the job
    -- holder's own, so players can combine loads to finish a job together.
    CARGO_COOLDOWN_SEC             = 60, -- wait between ?cargo REQUESTS (not deliveries). No time
    -- limit on an accepted job on purpose -- the only real abuse vector (spamming
    -- ?cargo to reroll for an easy job) is already closed by this cooldown plus
    -- "one active job at a time", so a forfeiture timer would add bookkeeping
    -- without closing any additional hole.

    -- Fuel station (?refuel). Separate from ?r's free repair-side fuel top-up --
    -- this ONLY fills diesel/jetfuel tanks, and only for money.
    FUEL_PRICE_PER_UNIT            = 2,    -- $ per unit of diesel/jetfuel restored
    FUEL_STATION_RADIUS            = 40.0, -- metres: both you AND the vehicle being refueled must be
    -- within this of the same zone

    -- ?tool equipment pricing tiers -- see WEAPON_IDS/OUTFIT_IDS for which ids fall
    -- into which tier. Anything in neither table is TOOL_PRICE_ITEM.
    TOOL_PRICE_OUTFIT              = 150,
    TOOL_PRICE_WEAPON              = 100,
    TOOL_PRICE_ITEM                = 40,
}

-- Slurs that trigger an auto-ban. Stored NORMALIZED (lowercase a-z only, after
-- leet substitution). Whole-word match only, so "trigger"/"bigger"/"night" are
-- safe. Edit freely. Kept to unambiguous, no-excuse terms per your spec.
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

-- Only server.notify() toast popups can be colored (via NOTIFICATION_TYPE below).
-- server.announce(), used for chat lines, takes no color argument at all - a chat
-- message is always plain text no matter what. Three tiers:
--   GREEN  - something good happened, or you succeeded at something.
--   YELLOW - routine info, or something failed but nothing serious.
--   RED	- pay attention. Bans, kicks, warnings, vehicles removed, being frozen.
-- The exact numeric IDs aren't documented anywhere - complete_mission looks green,
-- failed_mission_critical looks red, in testing. Adjust if any of these read wrong.
local NOTIFY                 = {
    GREEN  = 4, -- complete_mission
    YELLOW = 2, -- failed_mission
    RED    = 3, -- failed_mission_critical
}

-- Component-name tags that are EXEMPT from the "made by someone else" check.
-- TAJIN is a common image-to-vehicle converter tool; its output vehicles are tagged
-- "MADE BY TAJIN" by the tool itself, not by whoever spawned them -- that's expected
-- and not a stolen/downloaded creation, so it's whitelisted here.
local MADE_BY_EXCEPTIONS     = {
    ["TAJIN"] = true,
}

-- ?tp location list. Index in this array is the id a player types (?tp 4 ->
-- ONeill). Zone names in the world are expected to be these same numbers as strings
-- ("1", "2", ...) -- that's how the base game's own teleport zones are named.
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

--------------------------------------------------------------------------------
-- UI IDs / positions
--------------------------------------------------------------------------------
local UI_MAIN                = 9001
local UI_CENTER              = 9003
-- "Nearby" panel -- see updateNearbyUI()'s comment for why this is a fixed on-screen
-- list rather than a floating tag that actually hovers over each player's head.
local UI_NEARBY              = 9004
local UI_COUNTDOWN           = 9005 -- LEGACY id, no longer shown (superseded by UI_ANTILAG_NORMAL/CRITICAL
-- below). Kept only so a removePopup() on join/leave can clear a stale
-- popup for anyone reconnecting after the update -- safe to delete once
-- every client has reconnected at least once post-update.
local UI_ANTILAG_NORMAL      = 9006  -- GLOBAL normal-tier TPS-cull popup, shown to every player, see the antilag block in onTick
local UI_ANTILAG_CRITICAL    = 9007  -- GLOBAL critical-tier (mass despawn) popup, shown to every player

local UI_X_MAIN              = -0.89 -- main stats panel
local UI_Y_MAIN              = 0.60  -- main stats panel vertical position (nudged down again to fit the new Balance line)
local UI_X_CENTER            = 0.0
local UI_Y_CENTER            = 0.0
local UI_X_NEARBY            = 0.0
local UI_Y_NEARBY            = -0.35 -- lower-center, out of the way of the main panel/hotbar
local NEARBY_RADIUS          = 10.0  -- metres
local UI_X_COUNTDOWN         = 0.0
local UI_Y_COUNTDOWN         = 0.15  -- upper-center, hard to miss

-- Global antilag panels: same X as the main stats panel, stacked below it (smaller
-- Y = lower on screen in this UI system), normal above critical.
local UI_X_ANTILAG_NORMAL    = UI_X_MAIN
local UI_Y_ANTILAG_NORMAL    = UI_Y_MAIN - 0.60
local UI_X_ANTILAG_CRITICAL  = UI_X_MAIN
local UI_Y_ANTILAG_CRITICAL  = UI_Y_MAIN - 0.50

--------------------------------------------------------------------------------
-- STATE (in-memory)
--------------------------------------------------------------------------------
local players                = {} -- [peer_id]	 = { steam_id, name, is_admin, authed, ui, pvp, antisteal, limit, speed, alt, last_pos }
local steamToPeer            = {} -- [steam_id]	= peer_id
local groups                 = {} -- [group_id]	= { owner_steam, vehicles={[vid]=true}, bodyCount, spawn_tick, cost, voxels, announced }
-- bodyCount is a LIVE counter (incremented/decremented on spawn/despawn) --
-- never recompute it by looping g.vehicles, that's the whole point of it existing.
local vehicleToGroup         = {} -- [vehicle_id]  = group_id
local vehicleCost            = {} -- [vehicle_id]  = last computed cost (so reloads don't double-count)
local vehicleVoxels          = {} -- [vehicle_id]  = last computed voxel count (same reload-safety reasoning)
local pendingApply           = {} -- [vehicle_id]  = true
local popupCache             = {} -- [peer_id]	 = {[ui_id]=last_text}
local frozen                 = {} -- [peer_id]	 = { mode, pos, anchor, angle }
local nukeQueue              = {} -- array of { m, mag }
local blockedGroups          = {} -- [group_id]	= true, group failed a hard limit and stays blocked
-- for every sub-body that finishes spawning afterward, not just the first one caught.
local looseEquipment         = {} -- [object_id]   = true, dropped equipment this script has seen and
-- tried to despawn. Used by ?flares as a fallback sweep - see that command's comment.
local pendingDestroy         = {} -- [group_id]	= { deadline_ms, ownerPeer, ownerName, publicReason, ownerReason }
-- groups that failed a hard antilag limit and are counting down to actual removal.

local verifiedSet            = {}  -- [steam_id]	= true  (auto-auth list, from HTTP)
local adminSet               = {}  -- [steam_id]	= true  (auto-admin+auth list, from HTTP)
local httpQueue              = {}  -- array of pending request path strings (drained 1/tick -- SW allows 1 httpGet/tick)
local teleportCache          = nil -- [zone_name_string] = {x,y,z}, built once on first ?tp use, nil until then

local globalLimit            = CONFIG.DEFAULT_VEHICLE_LIMIT
local lastPlayerCount        = 0 -- refreshed each UI tick; used by the lag-cost math

--------------------------------------------------------------------------------
-- COUNTERS / TIMERS
--------------------------------------------------------------------------------
local tickCount              = 0
local uiTimer                = 0
local healTimer              = 0
local tpsTimer               = 0
local freezeTimer            = 0 -- throttles frozen/held repositioning to CONFIG.FREEZE_UPDATE_TICKS instead of every tick
local dbgHeartbeatTimer      = 0 -- drives the ~1/sec level-5 debug heartbeat
local httpPollTimer          = 0 -- drives periodic re-pull of the verified/admin HTTP lists
local tpsLastMs              = 0
local tpsNow                 = 60
local tpsAvg                 = 60
local startMs                = 0
local antilagNormalTps       = nil   -- runtime override for CONFIG.ANTILAG_NORMAL_TPS, set via ?antilag <n>; nil = use config default
local criticalWasHealthy     = true  -- tracks whether tps was >= ANTILAG_CRITICAL_TPS as of last tick
local criticalSinceMs        = 0     -- wall-clock ms when tps first dropped below ANTILAG_CRITICAL_TPS (start of the sustain window)
local antilagNormalUiShown   = false -- whether the global normal-tier antilag popup is currently visible to players
local antilagCriticalUiShown = false -- whether the global critical-tier antilag popup is currently visible to players

--------------------------------------------------------------------------------
-- PERSISTENT STATE
--------------------------------------------------------------------------------
g_savedata                   = g_savedata or {}
g_savedata.playtime          = g_savedata.playtime or {} -- [steam_id] = seconds
g_savedata.pvp               = g_savedata.pvp or {}      -- [steam_id] = bool
g_savedata.warns             = g_savedata.warns or {}    -- [steam_id] = current warning count (resets to 0 on auto-kick)
g_savedata.kicks             = g_savedata.kicks or {}    -- [steam_id] = lifetime auto-kick count (never reset)
g_savedata.wallet            = g_savedata.wallet or {}   -- [steam_id] = money balance (integer, never negative)

--------------------------------------------------------------------------------
-- UTILITIES
--------------------------------------------------------------------------------

local function say(peer_id, msg)
    server.announce("[" .. CONFIG.SERVER_NAME .. "]", msg, peer_id)
end

-- Colored toast popup. kind is "GREEN", "YELLOW", or "RED" (see NOTIFY above). Use this
-- instead of say() whenever something actually happened to the player - a status
-- change, an action taken against them, a real result. Use say() for plain replies.
local function notify(peer_id, title, msg, kind)
    server.notify(peer_id, title, msg, NOTIFY[kind] or NOTIFY.YELLOW)
end

-- Same colored toast, sent to every currently connected player at once -- used for
-- server-wide events (antilag smites) where a plain chat announce can't carry color.
local function broadcastNotify(title, msg, kind)
    for peer_id in pairs(players) do
        notify(peer_id, title, msg, kind)
    end
end

-- Leveled debug log stream, set per-admin via "?dbg <0-5>". Cumulative: picking level N
-- streams every event tagged level <= N to that admin, live, until they set it back to 0.
--   1 = crash risk / conflicts -- a server.* call that doesn't exist or failed, or a
--								 blockedGroups conflict (a straggler body arriving
--								 from a creation that already got destroyed). Nothing
--								 here means the script actually crashed - this sandbox
--								 has no pcall, so an uncaught error can't be caught or
--								 logged from inside the script at all. It means
--								 something didn't behave as expected and is worth
--								 checking.
--   2 = + moderation / structural -- despawns, bans, kicks, warns, made-by violations,
--									group/vehicle create/destroy, limit enforcement
--   3 = + admin actions	   -- every admin command run, join/leave
--   4 = + per-vehicle detail  -- individual spawn/load/cost events
--   5 = + everything else	 -- apply-queue writes, HTTP requests and replies,
--								heal/revive actions, nuke blasts, map marker
--								placements, and a full state heartbeat once/sec.
--								Frozen/held repositioning is the one thing skipped
--								even here - it runs up to 20 times a second, and
--								logging every tick of it would flood chat for
--								nothing. The freeze/hold STATE CHANGE is still
--								logged, at level 3, as the admin action that caused it.
local function dbgLog(level, tag, msg)
    for peer_id, p in pairs(players) do
        if p.is_admin and (p.dbgLevel or 0) >= level then
            server.announce("[DBG" .. level .. "/" .. tag .. "]", msg, peer_id)
        end
    end
end

-- Calls server[fnName](...) ONLY if that function actually exists in this build's API.
-- The Stormworks addon Lua sandbox does NOT provide pcall/error (confirmed at runtime --
-- calling pcall itself errors "attempt to call a nil value"), so we CANNOT catch runtime
-- errors from inside an API call. What we CAN do -- and the failure that actually bit us
-- with the guessed map/equipment APIs -- is guard against calling a function that isn't
-- there at all, which is a plain "attempt to call a nil value" crash. Checking the type
-- first turns that specific crash into a logged no-op. A wrong-signature call to a real
-- function is still unprotected (nothing in this sandbox can protect it), but that's a
-- one-time authoring bug to fix, not a name that varies by DLC/version.
local function safeServer(fnName, ...)
    local fn = server[fnName]
    if type(fn) ~= "function" then
        dbgLog(1, "ERROR", "server." .. fnName .. " is unavailable in this build, skipped")
        -- This is the closest thing to a "script crash" notice this sandbox can send -
        -- an actual uncaught Lua error can't be caught or reported at all (no pcall
        -- here), so a missing/failed API call is the one failure mode we CAN surface.
        -- Every online admin gets a red toast regardless of their ?dbg level, since
        -- this is worth seeing even if nobody's actively streaming the debug log.
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

-- Same missing-function guard as safeServer, for calls whose return value the caller
-- actually needs (safeServer above throws its away, which is fine for the fire-and-
-- forget writes it's normally used for but not for a read like getCharacterItem).
-- Returns (true, ...results) on success, or just false if the API doesn't exist.
local function safeServerQuery(fnName, ...)
    local fn = server[fnName]
    if type(fn) ~= "function" then
        dbgLog(1, "ERROR", "server." .. fnName .. " is unavailable in this build, skipped")
        return false
    end
    return true, fn(...)
end

local function onOff(v) return v and "on" or "off" end

-- Compact "1h 2m 3s" form, no zero-padding. Used in the main UI where the label
-- itself was dropped (Uptime/Playtime) -- the format is distinctive enough on its
-- own that a "HH:MM:SS" number without a label reads ambiguous in a way this doesn't.
local function fmtHMSShort(seconds)
    local s   = math.floor(seconds or 0)
    local h   = math.floor(s / 3600)
    local m   = math.floor((s % 3600) / 60)
    local sec = s % 60
    return h .. "h " .. m .. "m " .. sec .. "s"
end

-- Cost -> short integer string.
local function fmtCost(c) return string.format("%.0f", c or 0) end

-- Straight-line distance (metres) between two {x,y,z} arrays. Defined here in
-- UTILITIES rather than down in the ECONOMY section where it was originally, because
-- vtpGroupToPlayer() (REPAIR/FLIP/VTP, well above ECONOMY) reads it back to verify a
-- teleport actually moved the vehicle. A `local function` is only visible to code
-- AFTER its definition -- with dist3 defined later, that call resolved to a nil global
-- and crashed ?vtp every time the verify path ran. Defining it up here keeps it in
-- scope for every caller.
local function dist3(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function getP(peer_id) return players[peer_id] end

--------------------------------------------------------------------------------
-- WALLET
--------------------------------------------------------------------------------
local function fmtMoney(n) return string.format("%.0f", n or 0) end

-- Lazily seeds a new steam_id at CONFIG.ECONOMY_STARTING_BALANCE on first read --
-- this is the single source of truth for "does this player have a balance yet",
-- so every other wallet function routes through this rather than touching
-- g_savedata.wallet directly.
local function getBalance(steam_id)
    -- Belt and suspenders on top of the top-of-file g_savedata init: if an older
    -- save from before wallet existed gets loaded, this table might not be here yet.
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

-- Clamped at 0 either direction -- never lets a balance go negative, same
-- "clamp, don't corrupt state" reasoning ?setlimit already uses for MAX_LIMIT.
local function addBalance(steam_id, amount)
    return setBalance(steam_id, getBalance(steam_id) + (amount or 0))
end

-- Deducts ONLY if funds are sufficient, and charges nothing at all otherwise --
-- callers MUST check the return value before granting whatever was paid for, the
-- same verify-then-act discipline ?tool's is_success check already follows.
local function deductBalance(steam_id, amount)
    if not hasBalance(steam_id, amount) then return false end
    g_savedata.wallet[steam_id] = getBalance(steam_id) - amount
    return true
end

-- True if p is on the hardcoded MODERATORS list (not HTTP-sourced, unlike admin/verified).
local function isModerator(p)
    return p ~= nil and CONFIG.MODERATORS[p.steam_id] == true
end

-- True if p is on the hardcoded OWNERS list -- the highest tier, and the ONLY tier that
-- can touch the root-access system (see the ROOT ACCESS section near onCustomCommand).
-- Same hardcoded, not-HTTP-sourced basis as isModerator, and the same check rankOf() uses.
local function isOwner(p)
    return p ~= nil and CONFIG.OWNERS[p.steam_id] == true
end

-- Rank string, used on the map marker and the nearby-players panel.
-- OWNER (hardcoded) > ADMIN > MODERATOR (hardcoded) > PLAYER (authed) > GUEST.
local function rankOf(p)
    if not p then return "GUEST" end
    if CONFIG.OWNERS[p.steam_id] then return "OWNER" end
    if p.is_admin then return "ADMIN" end
    if isModerator(p) then return "MODERATOR" end
    if p.authed then return "PLAYER" end
    return "GUEST"
end

-- Apply the HTTP-derived access lists (and the hardcoded OWNERS/ADMINS lists) to one
-- online player: admins/owners get engine admin + auth, verified get auth. Called on join
-- and again whenever a fresh list arrives over HTTP. It only ever GRANTS from these lists --
-- it never revokes, so a manual ?revoke or in-game de-admin isn't fought by a stale list.
-- OWNERS and CONFIG.ADMINS (both hardcoded) grant the SAME instant auth+admin here as the
-- HTTP adminSet always has -- neither tier ever needs to type ?noworkshop.
local function applyAccess(peer_id)
    local p = players[peer_id]
    if not p then return end
    local isAdmin = adminSet[p.steam_id] or CONFIG.OWNERS[p.steam_id] or CONFIG.ADMINS[p.steam_id]
    if isAdmin then
        if not p.is_admin then
            p.is_admin = true
            safeServer("addAdmin", peer_id) -- guarded: don't let an unexpected-missing API kill the script
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

-- Re-apply access to everyone currently online (after a fresh list lands).
local function applyAccessToAll()
    for peer_id in pairs(players) do applyAccess(peer_id) end
end

-- Pull every 17+ digit run out of an HTTP reply body as a steam_id. Deliberately
-- format-agnostic: plain text, one-per-line, CSV, or a JSON array of ids all work,
-- because a steam64 id is always a 17-digit number and nothing else in a sane reply is.
local function parseSteamIds(reply)
    local set = {}
    if type(reply) == "string" then
        for id in reply:gmatch("%d+") do
            if #id >= 17 then set[id] = true end
        end
    end
    return set
end

-- Queue both list requests (drained one-per-tick in onTick -- SW allows 1 httpGet/tick).
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

-- Percent-encode a string for safe use inside an HTTP GET query string (?reason=...).
local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Queue a one-off request (e.g. the Discord warn webhook) -- no dedup, unlike
-- queueHttpLists, since each warn has distinct steam_id/reason and should always fire.
local function queueHttpRequest(path)
    if not CONFIG.HTTP_ENABLED then return end
    httpQueue[#httpQueue + 1] = path
end

-- Owner display name for a group (or "offline").
local function ownerName(g)
    local op = steamToPeer[g.owner_steam]
    return (op and players[op] and players[op].name) or "offline"
end

-- Resolve a command arg to a peer_id (numeric peer_id OR case-insensitive name).
-- Exact name matches are checked FIRST, in their own full pass, before falling back
-- to substring matching -- pairs() iteration order isn't guaranteed, so without this
-- an exact match like "?tp Sam" could non-deterministically resolve to "Samantha"
-- instead of "Sam" depending on table iteration order that session.
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

--------------------------------------------------------------------------------
-- PROFANITY
--------------------------------------------------------------------------------

-- Common leet substitutions applied before stripping to letters.
local LEET = { ["0"] = "o", ["1"] = "i", ["3"] = "e", ["4"] = "a", ["5"] = "s", ["7"] = "t", ["@"] = "a", ["$"] = "s" }

-- Normalize a single word: lowercase -> leet-map -> keep only a-z.
local function normalizeWord(w)
    w = w:lower()
    w = w:gsub(".", function(ch) return LEET[ch] or ch end) -- map leet chars
    w = w:gsub("[^a-z]", "")                                -- strip everything but letters
    return w
end

-- True if any WHOLE word in the message normalizes to a listed slur, OR if a run of
-- consecutive SHORT tokens (each <=2 letters once normalized) glues together into one.
-- The second check exists purely to catch "n i g g e r" / "ni gg er" style spacing
-- evasion -- dotted/punctuated evasion ("n.i.g.g.e.r") is already caught by the first
-- loop since normalizeWord strips all non a-z characters from within a single token.
--
-- The run only ever accumulates tokens of length <=2, and resets the moment it hits
-- a longer one -- so a normal sentence like "not bigger" can never trigger it: "not"
-- is 3 letters, so it never even starts a run, and "bigger" is 6 letters, so it can't
-- join one either. Only a string of genuinely short tokens (typically single letters,
-- the classic spell-it-out evasion) can ever accumulate into a slur-length string.
local function containsSlur(message)
    local run = ""
    for word in message:gmatch("%S+") do               -- split on whitespace
        local nw = normalizeWord(word)                 -- normalize the token
        if nw ~= "" and SLURS[nw] then return true end -- exact whole-word hit

        if nw ~= "" and #nw <= 2 then
            run = run .. nw
            if SLURS[run] then return true end -- spaced-out evasion hit
        else
            run = ""                           -- any longer/empty token breaks the run
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- OWNERSHIP / GROUPS
--------------------------------------------------------------------------------

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

-- Get (or create) the tracking record for a group. Centralizes group-record
-- creation so onGroupSpawn and onVehicleSpawn don't each maintain their own
-- copy of the same table literal -- one shape, one place it's defined.
local function getOrCreateGroup(group_id, steam_id)
    local g = groups[group_id]
    if not g then
        g = {
            owner_steam = steam_id,
            vehicles    = {},
            bodyCount   = 0, -- LIVE counter -- see the `groups` state comment
            spawn_tick  = tickCount,
            spawn_ms    = server.getTimeMillisec(),
            cost        = 0,
            voxels      = 0,
        }
        groups[group_id] = g
    end
    return g
end

-- Forward-declared: defined in the MAP MARKERS section below, but destroyGroup (right
-- here) needs to call removeGroupMarker, so the local has to exist before this point.
local updateGroupMarker, removeGroupMarker, updatePlayerMarker, removePlayerMarker

local function destroyGroup(group_id)
    local g = groups[group_id]
    if not g then return false end
    server.despawnVehicleGroup(group_id, true)
    for vehicle_id in pairs(g.vehicles) do
        vehicleToGroup[vehicle_id] = nil
        vehicleCost[vehicle_id] = nil
        vehicleVoxels[vehicle_id] = nil
        pendingApply[vehicle_id] = nil
    end
    groups[group_id] = nil
    removeGroupMarker(group_id)
    return true
end

local function destroyAllGroupsOf(steam_id)
    local ids = groupsOwnedBy(steam_id)
    for i = 1, #ids do destroyGroup(ids[i]) end
    return #ids
end

-- Antilag doesn't destroy a group the instant it fails a hard limit. It schedules the
-- actual removal CONFIG.ANTILAG_COUNTDOWN_SEC seconds out and shows the owner a live
-- countdown popup in the meantime (processed in onTick's ANTILAG COUNTDOWN block).
--
-- cancelIfHealthy marks this as a TPS-cull entry: if server TPS recovers to the healthy
-- zone before the timer runs out, the countdown block cancels it and the group
-- survives. A brief spawn-time dip that recovers in a few ticks (completely normal --
-- see the comment on LAG_SPAWN_GRACE_SEC) shouldn't cost someone their creation just
-- because it happened to be the most expensive thing running at that instant. This
-- does NOT apply to the hard-limit triggers (sub-body/block/cost) -- those are
-- unconditional violations, not "server is currently struggling," so they're never
-- cancelled and their callers mark blockedGroups immediately instead.
local function scheduleGroupDestroy(group_id, ownerPeer, ownerReason, publicReason, cancelIfHealthy)
    pendingDestroy[group_id] = {
        deadline_ms = server.getTimeMillisec() + CONFIG.ANTILAG_COUNTDOWN_SEC * 1000,
        ownerPeer = ownerPeer,
        ownerReason = ownerReason,
        publicReason = publicReason,
        cancelIfHealthy = cancelIfHealthy or false,
    }
end

--------------------------------------------------------------------------------
-- WARN / KICK / BAN
--------------------------------------------------------------------------------
-- A warning: notifies the target with the reason, de-auths them, deletes their
-- vehicle(s), fires the Discord webhook (via the local relay -- see CONFIG's HTTP
-- comment), and escalates: every CONFIG.WARNS_BEFORE_KICK-th warning auto-kicks (and
-- resets the warn counter), and every CONFIG.KICKS_BEFORE_BAN-th such kick auto-bans
-- instead of kicking. Warn counts persist in g_savedata (survive reloads/restarts).
local function warnPlayer(target_peer, reason, byName)
    local tp = players[target_peer]
    if not tp then return false end
    local steam_id = tp.steam_id
    reason = (reason and reason ~= "") and reason or "No reason given"

    -- Belt and suspenders on top of the top-of-file g_savedata init: if an OLDER save
    -- from before warns/kicks existed gets loaded, these tables might not be here yet.
    g_savedata.warns = g_savedata.warns or {}
    g_savedata.kicks = g_savedata.kicks or {}

    g_savedata.warns[steam_id] = (g_savedata.warns[steam_id] or 0) + 1
    local warnCount = g_savedata.warns[steam_id]

    notify(target_peer, "Warned",
        "Reason: " .. reason ..
        "\nWarnings: " .. warnCount .. "/" .. CONFIG.WARNS_BEFORE_KICK, "RED")
    tp.authed = false
    tp.revoked = true -- they now need ?auth to get back in, not ?noworkshop -- see ?auth's handler
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

--------------------------------------------------------------------------------
-- LAG COST
--------------------------------------------------------------------------------

-- Uppercase + trim, for case-insensitive name comparisons. "Sergeant Polar Bear"
-- and "SERGEANT POLAR BEAR " compare equal after this.
local function normalizeName(s)
    return (s or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
end

-- Reads a loaded vehicle's components ONCE and returns everything both the cost
-- formula and the MADE-BY check need from it: cost, raw voxel count, and any
-- "MADE BY <x>" maker tag found on a component name. This used to be two separate
-- functions that each called server.getVehicleComponents on their own, back to back,
-- for every single vehicle load -- that call has to enumerate every voxel and
-- component on the vehicle, so doing it twice was real, avoidable work sitting right
-- at the moment a vehicle spawns, which is exactly when TPS is already under the
-- most pressure. One call now.
--
-- CONFIRMED LIMITATION on the MADE-BY part, not a bug to fix: the native in-world
-- prompt ("VEHICLE (MADE BY X)") the game shows when you click a vehicle is
-- generated from that vehicle's SAVED TITLE. server.getVehicleName, which used to
-- expose that title, was removed from the addon API in the Space DLC update and
-- there's still no replacement -- getVehicleSign only returns {name, pos}, never
-- the displayed text either. So the most common case -- the game's own default
-- attribution on someone else's build -- can't be read from Lua at all. What this
-- DOES catch is a maker tag someone typed directly into a component's name field
-- (a seat, a sign, whatever), which is a real convention some tools use (TAJIN's
-- image converter, for one) precisely because getVehicleName is gone.
local function analyzeVehicle(vehicle_id)
    local d, ok = server.getVehicleComponents(vehicle_id) -- LOADED vehicles only
    if not ok or not d then return 0, 0, nil end
    local voxels = d.voxels or 0
    local mass = d.mass or 0

    local componentCount = 0
    local maker = nil
    if d.components then
        for _, category in pairs(d.components) do -- signs, seats, buttons, dials, tanks, batteries, hoppers, guns, rope_hooks
            for _, comp in pairs(category) do
                componentCount = componentCount + 1
                if not maker and comp.name then
                    -- Letters/spaces only after "MADE BY " -- stops at the first punctuation,
                    -- so "MADE BY AKYJLA)" or "MADE BY TAJIN - v2" correctly captures just
                    -- "AKYJLA" / "TAJIN" instead of dragging trailing junk along.
                    local m = comp.name:upper():match("MADE BY%s+([%w][%w%s]*)")
                    if m then maker = normalizeName(m) end
                end
            end
        end
    end
    if d.characters then
        for _ in pairs(d.characters) do componentCount = componentCount + 1 end -- NPCs/seated characters count too
    end

    local cost = voxels * CONFIG.LAG_W_VOXELS + mass * CONFIG.LAG_W_MASS + componentCount * CONFIG.LAG_W_COMPONENTS
    return cost, voxels, maker
end

-- Returns the currently-active normal-tier TPS threshold: the ?antilag runtime
-- override if one has been set, otherwise the CONFIG default.
local function normalTpsThreshold()
    return antilagNormalTps or CONFIG.ANTILAG_NORMAL_TPS
end

-- Effective cost of a GROUP: (per-vehicle cost sum + sub-body count cost) scaled by
-- player count and spawn recency. Reads g.bodyCount directly (O(1), maintained
-- incrementally on spawn/despawn) rather than counting g.vehicles every call --
-- this function runs multiple times per tick via the apply queue, so that loop
-- used to run multiple times per tick too.
local function effectiveCost(group_id)
    local g = groups[group_id]
    if not g then return 0 end
    local raw = (g.cost or 0) + (g.bodyCount or 0) * CONFIG.LAG_W_SUBBODY
    local age = tickCount - (g.spawn_tick or tickCount)                                  -- ticks since spawn
    local ageBonus = math.max(0, 1 - age / CONFIG.LAG_AGE_DECAY) * CONFIG.LAG_AGE_WEIGHT -- fresh = costlier
    return raw * (1 + lastPlayerCount * CONFIG.LAG_PLAYER_FACTOR) * (1 + ageBonus)
end

--------------------------------------------------------------------------------
-- VEHICLE SETTINGS (antisteal / pvp / tooltip)
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- MAP MARKERS (?hide) -- green for vehicle groups, orange for players
--------------------------------------------------------------------------------
-- Markers are PARENTED (position_type VEHICLE/OBJECT below) to a vehicle_id/character
-- object_id rather than given a raw x/z -- the engine then follows that vehicle/player
-- around on its own, so these only need to be (re)placed on the events below, never
-- repositioned every tick.
--
-- CONFIRMED CONSTANTS (position_type / marker_type/icon) -- car=12, survivor=1.
--
-- CONFIRMED LIMITATION: there's no addon API to read a vehicle's actual saved title
-- (see analyzeVehicle()'s comment above -- server.getVehicleName was removed from the
-- API). So the vehicle marker's label shows OWNER + GROUP/VEHICLE ID, not a real name --
-- that's genuinely all this script can see, same limitation as the MADE-BY check.
--
-- Every server.addMapObject/removeMapObject call below goes through safeServer(), not
-- server.X directly -- if this API turns out to not exist, or take different args than
-- expected, that's now a logged no-op instead of a script-killing error (see safeServer's
-- comment near the top of the file for why that distinction matters here specifically).
local MAP_POS_VEHICLE    = 1     -- follows vehicle_parent_id automatically
local MAP_POS_OBJECT     = 2     -- follows object_parent_id (character) automatically
local MAP_ICON_VEHICLE   = 12    -- "car"
local MAP_ICON_PLAYER    = 1     -- "survivor"
local MAP_ID_PLAYER_BASE = 20000 -- ui_id = base + peer_id
local MAP_ID_GROUP_BASE  = 30000 -- ui_id = base + group_id

-- Removes a marker for everyone AND for one specific peer (belt-and-suspenders --
-- covers both the broadcast case (-1) and the narrowcast case (?hide targeted only
-- the owner), regardless of which one was actually last sent).
local function clearMapObject(id, alsoPeer)
    safeServer("removeMapObject", -1, id)
    if alsoPeer then safeServer("removeMapObject", alsoPeer, id) end
end

-- (Re)places a group's marker according to its owner's current ?hide state. If the
-- owner is hidden, the marker is sent ONLY to the owner's own peer_id (visible to
-- them, invisible to everyone else, per spec) -- if the owner is offline while
-- hidden, there's nobody to target, so it's simply not sent to anyone.
-- IDEMPOTENT for the same reasons as updatePlayerMarker: this is called on EVERY vehicle
-- load in the group, so a 20-body creation would otherwise re-place its one marker 20
-- times during a single spawn burst. The marker is parented to a vehicle_id and follows
-- it automatically, so we only re-place when the thing it's parented to (g.mapVid) is gone
-- or when the hidden target changes. g.mapVid/g.mapTarget remember what's currently placed.
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

    -- Nothing to show: no loaded vehicle to parent to, or hidden-and-owner-offline.
    local haveVid = g.mapVid and g.vehicles[g.mapVid]
    local firstVid = haveVid and g.mapVid or next(g.vehicles)
    if not firstVid or (hidden and not ownerPeer) then
        if g.mapVid then
            clearMapObject(id, nil)
            g.mapVid, g.mapTarget = nil, nil
        end
        return
    end

    -- Already correctly placed (same vehicle, same audience) -> no-op.
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

-- (Re)places a player's own marker according to their current ?hide state.
--
-- IDEMPOTENT: this is called every UI refresh (once/sec/player) from the tick loop, but
-- the marker is PARENTED to the character object_id -- the engine moves it on its own, so
-- there is nothing to update per second. We therefore only touch the map API when
-- something that actually changes the marker changes: the character id (respawn gives a
-- new one) or the hidden flag (?hide toggles who it's sent to). Otherwise this is a couple
-- of cheap comparisons and an early return -- no removeMapObject/addMapObject churn, no
-- per-second marker flicker. p.mapCharId/p.mapHidden remember what's currently placed.
function updatePlayerMarker(peer_id)
    local p = getP(peer_id)
    if not p then return end
    local id = MAP_ID_PLAYER_BASE + peer_id

    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then
        if p.mapCharId then -- had a marker, character's gone now -> drop it
            clearMapObject(id, peer_id)
            p.mapCharId, p.mapHidden, p.mapRank = nil, nil, nil
        end
        return
    end

    local rank = rankOf(p)
    -- Also re-places when RANK changes (auth granted, promoted to admin, etc.) --
    -- otherwise the marker's rank text would go stale even though it's still correct
    -- about character/hidden-state.
    if p.mapCharId == charId and p.mapHidden == p.hidden and p.mapRank == rank then return end -- already correct

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

--------------------------------------------------------------------------------
-- EQUIPMENT (?tool)
--------------------------------------------------------------------------------
-- Character equipment slots (confirmed from the API docs' SWSlotNumberEnum alias):
-- slot 1 = large item slot, slots 2-9 = the eight small item slots, slot 10 =
-- the single outfit slot. There is no slot 11+ -- it doesn't exist in-game.
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

-- Weapon/ammo ids -- used only to pick a ?tool price tier (CONFIG.TOOL_PRICE_WEAPON),
-- not for slot logic (that's handled generically above regardless of category).
local WEAPON_IDS = {
    [13] = true,
    [14] = true, -- flaregun, flaregun_ammo
    [31] = true,
    [32] = true, -- c4, c4_detonator
    [33] = true,
    [34] = true, -- speargun, speargun_ammo
    [35] = true,
    [36] = true, -- pistol, pistol_ammo
    [37] = true,
    [38] = true, -- smg, smg_ammo
    [39] = true,
    [40] = true, -- rifle, rifle_ammo
    [41] = true, -- grenade
}

-- ?tool's price for a given equipment id: outfit tier, weapon tier, or the
-- catch-all item tier for everything else (binoculars, compass, first_aid, rope,
-- radio, tools, etc).
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
    -- Ammo boxes (42-61, 150-154), naval/artillery shells (62-71), and fish/
    -- crustaceans (82-146) are deliberately left out of this list. None of them are
    -- something a player actually wants handed to them directly -- the ammo boxes and
    -- shells only make sense loaded into a turret or gun, and the fish/crabs/lobsters
    -- are animals, not tools. Add an id back here if you want it available again.
}

-- Reverse lookup, keyed by the name with underscores turned into spaces (matching
-- ?tool's own "byt ut _ mot mellanslag" normalization) so lookups are forgiving of
-- both "?tool fire_extinguisher" and "?tool fire extinguisher".
local EQUIPMENT_BY_NAME = {}
for id, nm in pairs(EQUIPMENT_NAMES) do
    EQUIPMENT_BY_NAME[(nm:gsub("_", " "))] = id
end
-- id 28 covers three distinct visuals (coal/ore/ingot) -- register each as its own alias too.
EQUIPMENT_BY_NAME["coal"] = 28
EQUIPMENT_BY_NAME["ore"] = 28
EQUIPMENT_BY_NAME["ingot"] = 28

-- Sorted "id = name" lines for the no-arg "?tool" listing. Built once at load, not per
-- call. Announced in a few chunks because a single server.announce with ~150 lines gets
-- truncated in the chat box.
local EQUIPMENT_LIST_LINES = {}
do
    local ids = {}
    for id in pairs(EQUIPMENT_NAMES) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        EQUIPMENT_LIST_LINES[#EQUIPMENT_LIST_LINES + 1] = id .. " = " .. EQUIPMENT_NAMES[id]
    end
end

-- Send the whole equipment list to one player, ~30 entries per announce so nothing is
-- truncated. Used by "?tool" with no argument.
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

--------------------------------------------------------------------------------
-- REPAIR / FLIP / VTP
--------------------------------------------------------------------------------

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

-- Verify-then-act, same pattern as ?refuel: check every precondition BEFORE calling
-- the API, then read back a representative vehicle's real position to confirm the move
-- actually took effect, rather than trusting a call with no documented success return.
--
-- The read-back sample is `next(g.vehicles)` -- an ARBITRARY body of the group, which
-- for a large multi-body creation can sit tens of metres from the group origin the
-- teleport targets. So "did it work?" can't be "is that body within a few metres of the
-- player" (that false-fails big builds that DID move). Instead we accept success if
-- EITHER of two things is true:
--   (a) the body ended up near the target -- catches small builds precisely, and the
--       no-op case where the vehicle was already at the player (nothing to do), and
--   (b) the body moved a long way from where it started -- catches big builds summoned
--       from across the map, whose sampled body lands far from the exact target purely
--       because of the build's size, yet clearly DID move.
-- Only when NEITHER holds -- the body neither reached the target nor moved at all -- do
-- we conclude setGroupPosSafe silently did nothing and report failure. Reads that come
-- back unavailable fall through and trust the call (nothing left to check against).
local function vtpGroupToPlayer(group_id, peer_id)
    local g = groups[group_id]
    if not g then
        dbgLog(1, "VTP", "vtpGroupToPlayer: group " .. group_id .. " no longer exists")
        return false
    end
    local repVid = next(g.vehicles)
    if not repVid then
        dbgLog(1, "VTP", "vtpGroupToPlayer: group " .. group_id .. " has no vehicles to move")
        return false
    end
    local pm, ok = server.getPlayerPos(peer_id)
    if not ok or not pm then
        dbgLog(2, "VTP", "vtpGroupToPlayer: couldn't get peer " .. peer_id .. "'s position")
        return false
    end

    -- Where the sample body sits BEFORE the move, so we can tell "moved" from "no-op".
    local beforePos = nil
    local bQueried, bm, bOk = safeServerQuery("getVehiclePos", repVid)
    if bQueried and bOk and bm then beforePos = { matrix.position(bm) } end

    local x, y, z = matrix.position(pm)
    local ty = y + CONFIG.VTP_HEIGHT
    if not safeServer("setGroupPosSafe", group_id, matrix.translation(x, ty, z)) then
        return false -- safeServer already logged the missing-API case
    end

    local posQueried, vm, posOk = safeServerQuery("getVehiclePos", repVid)
    if posQueried and posOk and vm then
        local afterPos = { matrix.position(vm) }
        local nearTarget = dist3(afterPos, { x, ty, z }) <= CONFIG.VTP_VERIFY_TOLERANCE
        local movedFar = beforePos and dist3(afterPos, beforePos) >= CONFIG.VTP_MOVED_MIN
        if not nearTarget and not movedFar then
            dbgLog(1, "VTP",
                "vtpGroupToPlayer: group " .. group_id .. " didn't verifiably move (no-op)")
            return false
        end
    end
    -- If the read-back itself wasn't available (posQueried/posOk false), fall through and
    -- trust the call -- there's nothing left to verify against.

    for vid in pairs(g.vehicles) do pendingApply[vid] = true end
    dbgLog(3, "VTP", "group " .. group_id .. " teleported to peer " .. peer_id)
    return true
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

--------------------------------------------------------------------------------
-- HEAL / REVIVE MODULE
--------------------------------------------------------------------------------

-- Revive + full-heal a player if their PvP is off. Used by the periodic loop AND onPlayerDie.
local function reviveIfPvpOff(peer_id)
    local p = getP(peer_id)
    if not p or p.pvp then return end -- PvP on -> leave them mortal
    local charId, ok = server.getPlayerCharacterID(peer_id)
    if not ok or not charId then return end
    local data = server.getObjectData(charId)
    if not data then return end
    if data.dead or data.incapacitated then
        server.reviveCharacter(charId) -- bring them back up
        dbgLog(5, "HEAL", p.name .. " revived (PvP off)")
    end
    if data.hp and data.hp < 100 then
        server.setCharacterData(charId, 100, true, false) -- top up to full
        dbgLog(5, "HEAL", p.name .. " healed to full (PvP off)")
    end
end

--------------------------------------------------------------------------------
-- NUKE MODULE
--------------------------------------------------------------------------------

local function queueBlast(x, y, z, mag)
    nukeQueue[#nukeQueue + 1] = { m = matrix.translation(x, y, z), mag = mag }
end

-- Queue an NxNxN cube of blasts centred on (cx,cy,cz).
local function queueGrid(cx, cy, cz, n, spacing, mag)
    local half = (n - 1) / 2 -- offset so the grid is centred
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
        queueBlast(x, y, z, mag)                                        -- single
    elseif tier == "hypernuke" then
        queueGrid(x, y, z, CONFIG.HYPER_GRID, CONFIG.GRID_SPACING, mag) -- 5x5x5 = 125
    elseif tier == "meganuke" then
        queueGrid(x, y, z, CONFIG.MEGA_GRID, CONFIG.GRID_SPACING, mag)  -- 9x9x9 = 729
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

-- Builds teleportCache from the world's "teleport"-tagged zones, once, on first use
-- (there's no reason to query this before anyone actually runs ?tp). Zones are keyed
-- by their in-world name, which the base game's own teleport zones set to plain
-- numbers ("1", "2", ...) matching TELEPORT_NAMES/TELEPORT_NAMES_DLC's order.
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

--------------------------------------------------------------------------------
-- ECONOMY: CARGO & FUEL STATION
--------------------------------------------------------------------------------
-- Both ?cargo/?deliver and ?refuel are built on the same 16 zones ?tp already uses
-- (loadTeleports()/teleportCache above), so pickup, delivery, and fuel stations are
-- all just "one of the 16 named locations", not a separate zone system.
local FUEL_TYPE_DIESEL, FUEL_TYPE_JETFUEL = 1, 2

-- dist3() (straight-line distance between two {x,y,z} arrays) lives up in UTILITIES
-- now -- it's used by vtpGroupToPlayer() far above this section, and a later-defined
-- local wasn't in scope there. See its definition for the full reasoning.

-- Nearest of the 16 zones to `pos` ({x,y,z} array), or nil if none is within
-- `radius` metres. Returns the numeric zone id (1-16), matching TELEPORT_NAMES'
-- indices, not the zone's string name.
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

-- Total mass (kg) of every vehicle GROUP whose representative body (the same
-- next(g.vehicles) anchor the map-marker code already uses) is within `radius` of
-- `zonePos`. ANY group counts, not just ones owned by whoever is running ?deliver --
-- that's deliberate, so multiple players' vehicles can combine to satisfy one
-- cargo job together instead of it having to be a single player's single vehicle.
local function totalMassNearZone(zonePos, radius)
    local total = 0
    for _, g in pairs(groups) do
        local repVid = next(g.vehicles)
        if repVid then
            -- Both getVehiclePos and getVehicleComponents return (value, is_success) --
            -- safeServerQuery prepends its own "did the call happen at all" flag, so
            -- there are three values to check here, not two: did we even call it, AND
            -- did the game itself report success, before trusting the data.
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

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

-- BUG FIX: the dedup key used to be JUST the text, so if a panel's position moved but its
-- text happened to be unchanged (UI_CENTER's auth screen is static text, for one), the
-- redundant-call skip below would suppress the position update entirely -- the popup would
-- silently stay at its OLD coordinates until the text next changed for an unrelated reason.
-- Position is now part of the key, so any (x,y) change always re-sends. This matters
-- especially for the root "uimove" command (see the ROOT ACCESS section) -- live-testing a
-- panel's position needs every move to actually take visible effect, not just the ones that
-- happen to coincide with a text change.
local function sendPopup(peer_id, ui_id, name, show, text, x, y)
    popupCache[peer_id] = popupCache[peer_id] or {}
    local key = show and (text .. "\0" .. tostring(x) .. "," .. tostring(y)) or "__HIDDEN__"
    if popupCache[peer_id][ui_id] == key then return end
    popupCache[peer_id][ui_id] = key
    server.setPopupScreen(peer_id, ui_id, name, show, text, x, y)
end

local UI_SEP_1 = "________________" -- separator under the title
local UI_SEP_2 = "________________" -- separator under the TPS block (one longer, as specified)
local UI_SEP_3 = "________________" -- separator under the TPS block (one longer, as specified)

local function buildMain(peer_id, playerCount)
    local p = getP(peer_id)
    if not p then return "" end
    local uptime = (server.getTimeMillisec() - startMs) / 1000
    local playtime = g_savedata.playtime[p.steam_id] or 0

    -- Show the actual group ID(s) this player owns (same IDs shown in the spawn
    -- popup and the vehicle hover tooltip), not just a count. "none" when the
    -- player has nothing currently spawned.
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
        (p.revoked and "Type ?auth to unlock." or "Type ?noworkshop to unlock.")
end

local function refreshUI(peer_id, playerCount)
    local p = getP(peer_id)
    if not p then return end
    sendPopup(peer_id, UI_CENTER, "Auth", not p.authed, buildCenter(peer_id), UI_X_CENTER, UI_Y_CENTER)
    sendPopup(peer_id, UI_MAIN, "Stats", p.ui, p.ui and buildMain(peer_id, playerCount) or "", UI_X_MAIN, UI_Y_MAIN)
end

-- BEST-ACHIEVABLE VERSION OF "a UI over a player's head within N metres": there is NO
-- addon API for a floating world-space tag that actually hovers over another entity.
-- server.setCharacterTooltip looks like the obvious candidate but its own docs say it
-- explicitly does "Doesn't support setting a player's tooltip" (NPCs/objects only, not
-- real players) -- confirmed, not a guess. Popups (server.setPopupScreen) are flat
-- SCREEN-space overlays positioned by a fixed x/y fraction, with no way to bind them to
-- another entity's projected position -- addon Lua has no camera/view-matrix access to
-- do that projection ourselves either. So instead: a small fixed on-screen panel listing
-- everyone within NEARBY_RADIUS metres of YOU, by name + rank. It updates once per UI
-- refresh (same ~1/sec cadence as the main panel), not truly real-time, and it's not
-- physically anchored over anyone's head -- but it's the closest thing to "who's near me
-- and what are they" that the documented API actually supports.
local function updateNearbyUI(peer_id)
    local p = getP(peer_id)
    if not p or not p.last_pos then return end
    local lines = {}
    for other_id, op in pairs(players) do
        if other_id ~= peer_id and op.last_pos then
            local dx = p.last_pos.x - op.last_pos.x
            local dy = p.last_pos.y - op.last_pos.y
            local dz = p.last_pos.z - op.last_pos.z
            if math.sqrt(dx * dx + dy * dy + dz * dz) <= NEARBY_RADIUS then
                lines[#lines + 1] = op.name .. " [" .. rankOf(op) .. "]"
            end
        end
    end
    local show = p.ui and #lines > 0
    sendPopup(peer_id, UI_NEARBY, "Nearby", show, show and table.concat(lines, "\n") or "", UI_X_NEARBY, UI_Y_NEARBY)
end

--------------------------------------------------------------------------------
-- HELP
--------------------------------------------------------------------------------
-- ONE entry per command here -- usage string, permission tier, and a full detail
-- paragraph. Three different things read from this SAME table instead of keeping
-- three separate copies of the same information that could drift apart:
--   1. ?help			  -- compact one-line-per-command list (usage string only)
--   2. ?help <command>	-- the full detail paragraph for just that one command
--   3. running a command with missing/invalid arguments -- shows that SAME full
--	  detail paragraph, not a shorter, different "Usage:" message
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
    ["?admins"] = {
        tier = "everyone",
        usage = "?admins",
        detail = "Lists every admin currently online with their rank.",
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
        detail = "Makes a player orbit around YOU at a fixed radius until ?unfreeze is run on them.",
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
-- Aliases point at the same entry as their canonical command, so ?help cleanup /
-- ?help repair / ?help flip / ?help antisteal all work too.
COMMAND_HELP["?cleanup"] = COMMAND_HELP["?c"]
COMMAND_HELP["?repair"] = COMMAND_HELP["?r"]
COMMAND_HELP["?flip"] = COMMAND_HELP["?f"]
COMMAND_HELP["?antisteal"] = COMMAND_HELP["?as"]

-- Explicit display order per tier (COMMAND_HELP itself has no order -- it's a hash
-- table). Aliases are deliberately left out of these lists so the compact ?help
-- view doesn't show both "?c" and "?cleanup" as if they were different commands.
local HELP_ORDER_EVERYONE = { "?help", "?man", "?noworkshop", "?auth", "?ui", "?admins", "?tp" }
local HELP_ORDER_AUTHED = {
    "?c", "?r", "?f", "?vtp", "?as", "?pvp", "?hide", "?tool",
    "?balance", "?pay", "?requestpay", "?accept", "?decline", "?cargo", "?deliver", "?refuel",
}
local HELP_ORDER_MODERATION = { "?warn", "?msg" }
local HELP_ORDER_ADMIN = {
    "?tpp", "?bring", "?freeze", "?unfreeze", "?hold", "?crash", "?revoke", "?setlimit",
    "?nuke", "?hypernuke", "?meganuke", "?flares", "?announce", "?dbg", "?perf", "?antilag",
}

-- Exhaustive manpage-style reference, one entry per CANONICAL command (aliases point at
-- their canonical entry, same pattern as COMMAND_HELP). Deliberately does NOT repeat
-- `usage`/`tier` -- showManPage() pulls those straight from COMMAND_HELP[cmd] so there's
-- only ever one place that can go stale. `variants` is optional (nil) for commands with
-- just one straightforward form.
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
    ["?admins"] = {
        description = "Lists every admin currently online along with their rank (OWNER/ADMIN/MODERATOR).",
        whenToUse = "Use this to find out who's online and able to help, or to get a peer id/name for someone " ..
            "you need to contact.",
        examples = { "?admins" },
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
            "toward a job, not just your own, so this can be done as a team.",
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
        whenToUse = "Use this once you're done holding a player in place with ?freeze or orbiting them with " ..
            "?hold.",
        examples = { "?unfreeze Sam", "?unfreeze 3" },
    },
    ["?hold"] = {
        description = "Makes a player orbit around YOU at a fixed radius.",
        whenToUse = "Use this to keep a player nearby and immobilized-but-orbiting, e.g. to escort or " ..
            "observe them without letting them wander off.",
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

-- Full detail for ONE command -- used by both "?help <command>" and by that
-- command's own no-argument/bad-argument branch, so the exact same text shows up
-- Can player p SEE a command of this tier? Used to gate ?help <cmd> and ?man <cmd> so a
-- player can never read the docs for a command they cannot run: an admin command is
-- "unknown" to a guest in the help/man lookup exactly as it is at the dispatcher. Higher
-- tiers can always see lower ones (an admin sees authed/everyone docs). Owners are
-- auto-admin (see applyAccess), so admin-tier docs are visible to them too.
local function canSeeCommand(p, tier)
    if tier == "everyone" then return true end
    if tier == "authed" then return p ~= nil and (p.authed or p.is_admin) end
    if tier == "moderator" then return p ~= nil and (p.is_admin or isModerator(p)) end
    if tier == "admin" then return p ~= nil and p.is_admin == true end
    return false
end

-- whichever way a player asks. Accepts the command with or without a leading "?".
local function showCommandHelp(peer_id, cmd)
    cmd = tostring(cmd):lower()
    if cmd:sub(1, 1) ~= "?" then cmd = "?" .. cmd end
    local info = COMMAND_HELP[cmd]
    -- A command the caller can't run reads as nonexistent here, same wording as a real
    -- unknown command, so no one learns a higher-tier command exists by probing ?help.
    if not info or not canSeeCommand(getP(peer_id), info.tier) then
        say(peer_id, "No help entry for \"" .. cmd .. "\". Run ?help with no argument for the full command list.")
        return
    end
    server.announce("[Help]", cmd .. " | Usage: " .. info.usage .. ", " .. info.detail, peer_id)
end

-- Exhaustive manpage-style reference for ONE command -- used by "?man <command>". Pulls
-- usage/tier from COMMAND_HELP so there's only one source of truth for those, and the
-- description/whenToUse/variants/examples from MAN_HELP. Tier-gated the same way
-- showCommandHelp is: you can only read the man page for a command you could actually run.
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
        -- Point them at the RIGHT unlock command for their state: a first-timer needs
        -- ?noworkshop, someone who was revoked needs ?auth (see the ?noworkshop/?auth split).
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

--------------------------------------------------------------------------------
-- COMMAND SETS (for permission + unknown-command detection)
--------------------------------------------------------------------------------
local ADMIN_CMDS = {
    ["?tpp"] = true,
    ["?bring"] = true,
    ["?freeze"] = true,
    ["?unfreeze"] = true,
    ["?hold"] = true,
    ["?crash"] = true,
    ["?revoke"] = true,
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
    ["?warn"] = true,   -- admin OR moderator -- own inline permission check, not gated by ADMIN_CMDS
    ["?admins"] = true, -- public, everyone
    ["?tp"] = true,     -- public, everyone -- location teleport (was ?goto), not the admin ?tpp
    ["?msg"] = true,    -- admin OR moderator -- own inline permission check, not gated by ADMIN_CMDS
    ["?balance"] = true,
    ["?pay"] = true,
    ["?requestpay"] = true,
    ["?accept"] = true,
    ["?decline"] = true,
    ["?cargo"] = true,
    ["?deliver"] = true,
    ["?refuel"] = true,
}

--------------------------------------------------------------------------------
-- CALLBACKS
--------------------------------------------------------------------------------

-- Builds a fresh in-memory player record. `authed` is passed in rather than hardcoded
-- because the two callers disagree: a real join starts UNauthed (false), but the reload
-- rebuild below restores whatever auth the engine already had for that player so a
-- ?reload_scripts doesn't silently de-authorize everyone mid-session.
local function makePlayerRecord(steam_id, name, is_admin, authed)
    local savedPvp = g_savedata.pvp[steam_id]
    if savedPvp == nil then savedPvp = CONFIG.DEFAULT_PVP end
    return {
        steam_id    = steam_id,
        name        = name,
        is_admin    = (is_admin == true),
        authed      = (authed == true),
        revoked     = false, -- true once this player has EVER been de-authed after having auth (?revoke or auto
        -- de-auth on warn). Distinguishes "never authed yet" (must use ?noworkshop) from
        -- "was authed, lost it" (must use ?auth) -- see the ?auth/?noworkshop handlers.
        ui          = CONFIG.DEFAULT_UI_ON,
        pvp         = savedPvp,
        antisteal   = CONFIG.DEFAULT_ANTISTEAL,
        limit       = nil,
        speed       = 0,
        alt         = 0,
        last_pos    = nil,
        dbgLevel    = 0,     -- debug stream verbosity, set via ?dbg <0-5>
        hidden      = false, -- map visibility, set via ?hide (session-only, not saved)
        cargoJob    = nil,   -- { origin_zone_id, dest_zone_id, dest_name, mass_required, payout } -- session-only
        lastCargoMs = 0,     -- server.getTimeMillisec() of the last ?cargo REQUEST, for CARGO_COOLDOWN_SEC
        payRequest  = nil,   -- { from_peer_id, from_name, amount, ts_ms } -- a pending ?requestpay aimed at this player
    }
end

-- Fires on a genuine world load AND on "?reload_scripts" (the vanilla server console
-- command that hot-reloads addon Lua without restarting the mission). Either way, the
-- whole file is re-executed as a fresh chunk, so every `local` table/counter declared
-- above (players, groups, vehicleToGroup, frozen, queues, timers, ...) is ALREADY back
-- to its literal initial value by the time this runs. g_savedata is untouched by design
-- (it's the persistent store), so playtime/pvp survive a reload.
--
-- THE BUG THIS FIXES: onPlayerJoin does NOT re-fire for already-connected players after
-- a ?reload_scripts (only genuine new joins trigger it). So without the rebuild loop
-- below, the `players` table stays EMPTY for everyone currently on the server -- and then
-- every command hits `getP() == nil -> return`, the UI loop skips everyone, and nothing
-- responds. The only thing that keeps "working" is map markers placed before the reload,
-- because those are engine-side and parented, so they keep following on their own. That
-- is exactly the "everything dead except the icons still move" symptom. Re-seeding
-- `players`/`steamToPeer` from server.getPlayers() here is what actually restores the
-- script after a reload.
--
-- CONFIRMED LIMITATION: vehicles/groups that were ALREADY spawned before the reload are
-- NOT re-tracked -- there is no addon API to enumerate existing vehicles, so antisteal/
-- pvp/cost/antilag stop applying to pre-existing creations until they're respawned.
-- Their pre-reload map markers also linger as orphans (the group records that owned them
-- are gone). New spawns after the reload work normally.
function onCreate(is_world_create)
    startMs = server.getTimeMillisec()
    tpsLastMs = startMs

    -- Seed the RNG once per script run. Lua's math.random is deterministic UNTIL seeded --
    -- without this, every reload produces the exact same sequence, which matters both for
    -- ?cargo destination rolls and (more importantly) the root-access confirmation code.
    -- getTimeMillisec() is the only entropy-ish source this sandbox exposes; it varies with
    -- real load timing across runs, which is enough to prevent a fixed, predictable sequence.
    -- Guarded so a sandbox without math.randomseed degrades to a no-op instead of crashing.
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

    -- Wipe every player-spawned vehicle on (re)load, per spec -- gives a guaranteed clean
    -- world and, as a bonus, means the "pre-reload vehicles are now untracked orphans"
    -- limitation above simply can't happen: there are no leftover vehicles to be orphaned.
    if CONFIG.CLEAN_VEHICLES_ON_LOAD then
        server.cleanVehicles()
    end

    -- Re-seed player state for everyone already connected (the reload case). On a genuine
    -- fresh world create this list is normally empty, so the loop is a harmless no-op.
    local list = server.getPlayers()
    if list then
        for _, pl in pairs(list) do
            local sid = tostring(pl.steam_id)
            players[pl.id] = makePlayerRecord(sid, pl.name, pl.admin, pl.auth)
            steamToPeer[sid] = pl.id
            g_savedata.playtime[sid] = g_savedata.playtime[sid] or 0
            getBalance(sid) -- seeds a starting wallet balance if this steam_id has never had one
            popupCache[pl.id] = {}
            -- BUG FIX: a reload wipes every in-memory Lua table (players, pendingDestroy,
            -- antilagNormalUiShown, etc. -- see the comment above onCreate) but does NOT
            -- touch anything already rendered client-side. If antilag's global panel was
            -- showing when the reload happened, the internal "is it shown" flag resets to
            -- false, and since nothing THINKS it needs to hide the popup, the hide call
            -- never gets sent -- the stale popup sits on screen forever. Explicitly clear
            -- every popup id this script ever uses for every currently connected player,
            -- so init always starts from a genuinely blank slate instead of trusting
            -- in-memory state that has no relationship to what the client last saw.
            server.removePopup(pl.id, UI_MAIN)
            server.removePopup(pl.id, UI_CENTER)
            server.removePopup(pl.id, UI_NEARBY)
            server.removePopup(pl.id, UI_COUNTDOWN)
            server.removePopup(pl.id, UI_ANTILAG_NORMAL)
            server.removePopup(pl.id, UI_ANTILAG_CRITICAL)
            -- The old admin panel popup used ui_id 9002 and no longer exists in this
            -- script. A client that already had it open keeps showing it until told
            -- to hide that id, so clear it once for anyone reconnecting after the update.
            server.removePopup(pl.id, 9002)
        end
    end

    -- Kick off the first HTTP list pull (applied once the replies land). Access is then
    -- re-applied on every join and on every subsequent poll.
    queueHttpLists()

    server.announce("[" .. "Server" .. "]",
        CONFIG.SERVER_NAME .. " loaded - Powered by " .. CONFIG.SCRIPT_NAME, -1)
end

function onPlayerJoin(steam_id, name, peer_id, is_admin, is_auth)
    steam_id = tostring(steam_id)
    players[peer_id] = makePlayerRecord(steam_id, name, is_admin, false)
    steamToPeer[steam_id] = peer_id
    g_savedata.playtime[steam_id] = g_savedata.playtime[steam_id] or 0
    getBalance(steam_id) -- seeds a starting wallet balance if this steam_id has never had one
    popupCache[peer_id] = {}

    -- Always de-auth on join first, THEN grant back only if the HTTP lists say so. This
    -- way nobody keeps a stale engine-side auth from a previous session, and verified/admin
    -- players get their access without touching chat.
    server.removeAuth(peer_id)
    applyAccess(peer_id)

    local p = players[peer_id]
    if p and p.authed then
        notify(peer_id, rankOf(p) .. " access",
            "You're recognized here, so you're already in. Welcome to " .. CONFIG.SERVER_NAME .. ".", "GREEN")
    else
        notify(peer_id, "Welcome to " .. CONFIG.SERVER_NAME,
            "Self-built vehicles only, no workshop. Type ?noworkshop to start building.", "YELLOW")
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
    server.removePopup(peer_id, UI_NEARBY)
    server.removePopup(peer_id, UI_COUNTDOWN)
    removePlayerMarker(peer_id)
    players[peer_id] = nil
    popupCache[peer_id] = nil
    if steamToPeer[steam_id] == peer_id then steamToPeer[steam_id] = nil end
end

function onPlayerDie(steam_id, name, peer_id, is_admin, is_auth)
    reviveIfPvpOff(peer_id) -- immediate revive attempt; the periodic loop is the backup
end

-- Fires when any character (players included) drops a held item. Despawns it right
-- away so dropped gear doesn't pile up on the ground. looseEquipment tracks anything
-- this fails to despawn, so ?flares can retry it later.
function onEquipmentDrop(character_object_id, equipment_object_id, equipment_id)
    if not CONFIG.AUTO_DESPAWN_DROPPED_EQUIPMENT then return end
    looseEquipment[equipment_object_id] = true
    if safeServer("despawnObject", equipment_object_id, true) then
        looseEquipment[equipment_object_id] = nil
        dbgLog(4, "EQUIPMENT", "despawned dropped equipment id " .. tostring(equipment_id) ..
            " (object " .. equipment_object_id .. ")")
    end
end

-- Reply from our local relay webserver (see the HTTP config comment for the localhost-only
-- constraint). We match on the request path to know which list came back, rebuild that
-- set, and re-apply access to everyone online. A "Connection refused" body (no local
-- server listening) contains no 17-digit ids, so it just parses to an empty set -- which
-- would REVOKE everyone. To avoid that we ignore replies that yielded zero ids.
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

    -- TPS ---------------------------------------------------------------------
    tpsTimer = tpsTimer + game_ticks
    if tpsTimer >= CONFIG.TPS_WINDOW_TICKS then
        local now = server.getTimeMillisec()
        local elapsed = (now - tpsLastMs) / 1000
        if elapsed > 0 then
            tpsNow = tpsTimer / elapsed -- NO CLAMP: uncapped, so catch-up bursts above 60
            -- (the engine processing several queued ticks in
            -- quick succession while recovering) are visible
            -- rather than hidden at a fake ceiling.
            tpsAvg = (tpsAvg * 0.9) +
                (tpsNow * 0.1) -- heavily smoothed -- DISPLAY ONLY, never used for antilag decisions
        end
        tpsTimer = 0
        tpsLastMs = now
    end

    -- HTTP ACCESS LISTS -------------------------------------------------------
    -- Re-pull on a timer, and drain at most ONE queued request per tick (SW hard-limits
    -- httpGet to 1/tick). Entirely skipped unless HTTP_ENABLED, so it costs nothing off.
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

    -- ANTILAG COUNTDOWN --------------------------------------------------------
    -- Wall-clock based, same reasoning as the TPS cull below: once the server is under
    -- enough load for antilag to be relevant, ticks stop being a reliable stand-in for
    -- real seconds.
    if next(pendingDestroy) then
        local nowMs = server.getTimeMillisec()
        for group_id, pd in pairs(pendingDestroy) do
            if not groups[group_id] then
                -- Already gone through another path (?c, ?revoke, the owner leaving) --
                -- stop counting down for something that isn't there anymore. No popup to
                -- clear -- the per-owner UI_COUNTDOWN popup was removed when the global
                -- normal-tier panel replaced it (see below).
                pendingDestroy[group_id] = nil
                dbgLog(3, "ANTILAG", "countdown abandoned, group " .. group_id .. " already gone")
            elseif pd.cancelIfHealthy and tpsNow >= normalTpsThreshold() then
                -- TPS recovered before the timer ran out -- this was a temporary dip
                -- (spawning something normally does this for a few ticks, see the spawn
                -- popup's own comment on LAG_SPAWN_GRACE_SEC), not sustained lag. Spare
                -- the creation instead of removing it. No toast here -- the global panel
                -- disappearing IS the "you're safe" signal, no separate announce needed.
                pendingDestroy[group_id] = nil
                dbgLog(2, "ANTILAG", "countdown cancelled, group " .. group_id .. " spared (TPS recovered)")
            else
                if nowMs >= pd.deadline_ms then
                    local nm = ownerName(groups[group_id])
                    pendingDestroy[group_id] = nil
                    destroyGroup(group_id)
                    -- Antilag announces ONLY at the moment a creation is ACTUALLY removed --
                    -- never at trigger time, never on a spare. This is the single "it
                    -- happened" signal for EVERY countdown-based trigger (TPS cull, the
                    -- sub-body/block/cost hard limits, and manual ?antilag alike), one
                    -- yellow broadcast toast (server.announce can't carry colour, see
                    -- notify()'s comment). The per-owner toast at schedule time is UI, not
                    -- an announcement.
                    broadcastNotify("Antilag",
                        nm .. "'s creation (group " .. group_id .. ") was removed.", "YELLOW")
                    dbgLog(2, "ANTILAG",
                        "countdown finished, group " .. group_id .. " removed (" .. pd.publicReason .. ")")
                end
            end
        end
    end

    -- GLOBAL ANTILAG UI: normal-tier panel, visible to every player, shown only while a
    -- TPS-cull countdown is actively running. "same X as main UI, different Y" per spec.
    -- Trimmed to exactly three lines: TPS, owner & group ID, time left -- nothing else.
    do
        local activeText = nil
        -- Critical fully suppresses normal: the moment TPS is in the critical band, the
        -- normal panel is force-hidden so the two panels can NEVER both be visible, not
        -- even for the single transition tick before the critical block clears the
        -- pending normal-tier countdowns further down.
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
                    break -- only one normal-tier countdown is ever active at a time (see the self-throttle below)
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

    -- APPLY QUEUE (batched) ---------------------------------------------------
    local processed = 0
    local vid = next(pendingApply)
    while vid and processed < CONFIG.APPLY_PER_TICK do
        applyVehicleSettings(vid)
        pendingApply[vid] = nil
        processed = processed + 1
        vid = next(pendingApply)
    end

    -- NUKE QUEUE --------------------------------------------------------------
    local blasts = 0
    while #nukeQueue > 0 and blasts < CONFIG.NUKE_PER_TICK do
        local b = table.remove(nukeQueue)
        server.spawnExplosion(b.m, b.mag)
        blasts = blasts + 1
        dbgLog(5, "NUKE", "blast fired, magnitude " .. tostring(b.mag) .. " (" .. #nukeQueue .. " left queued)")
    end

    -- FROZEN / HELD -----------------------------------------------------------
    -- Throttled to CONFIG.FREEZE_UPDATE_TICKS instead of every tick -- repositioning
    -- a player doesn't need 60Hz precision, and this loop is almost always empty
    -- anyway (nobody frozen), so the throttle mainly matters on the rare occasions
    -- it isn't. HOLD_SPEED is multiplied by the tick gap so orbit speed stays the
    -- same real-time speed regardless of update rate.
    freezeTimer = freezeTimer + game_ticks
    if freezeTimer >= CONFIG.FREEZE_UPDATE_TICKS then
        local elapsedTicks = freezeTimer -- may be slightly more than the config value; use the real gap
        freezeTimer = 0
        for held, f in pairs(frozen) do
            if f.mode == "spot" then
                server.setPlayerPos(held, f.pos)
            elseif f.mode == "orbit" then
                local am, ok = server.getPlayerPos(f.anchor)
                if ok and am then
                    local ax, ay, az = matrix.position(am)
                    f.angle = f.angle + CONFIG.HOLD_SPEED * elapsedTicks
                    local ox = ax + math.cos(f.angle) * CONFIG.HOLD_RADIUS
                    local oz = az + math.sin(f.angle) * CONFIG.HOLD_RADIUS
                    server.setPlayerPos(held, matrix.translation(ox, ay + CONFIG.HOLD_HEIGHT, oz))
                end
            end
        end
    end

    -- HEAL LOOP ---------------------------------------------------------------
    healTimer = healTimer + game_ticks
    if healTimer >= CONFIG.HEAL_CHECK_TICKS then
        healTimer = 0
        for peer_id in pairs(players) do reviveIfPvpOff(peer_id) end
    end

    -- ANTILAG: fixed-rate TPS-triggered cull -------------------------------------
    -- Driven by CURRENT tps (tpsNow), not the smoothed display average (tpsAvg) --
    -- tpsAvg has a ~10-sample time constant, so it lags a real spike by many seconds,
    -- which was making antilag look "slow" when it was actually just looking at stale data.
    --
    -- Two tiers, MUTUALLY EXCLUSIVE -- critical fully suppresses normal. Since
    -- ANTILAG_CRITICAL_TPS < ANTILAG_NORMAL_TPS, TPS below critical is ALSO below
    -- normal, so without this guard both would try to act on the same tick. Only one
    -- of the two global panels is ever shown at a time as a result.
    --   normal:   tps < ANTILAG_NORMAL_TPS, but tps >= ANTILAG_CRITICAL_TPS -> single
    --			 worst group, ANTILAG_COUNTDOWN_SEC warning (can be spared -- see the
    --			 countdown block above).
    --   critical: tps < ANTILAG_CRITICAL_TPS, continuously, for ANTILAG_CRITICAL_SUSTAIN_SEC
    --			 seconds -> every group despawned at once, no warning, no reprieve.
    if CONFIG.ANTILAG_ENABLED then
        local normalTps = normalTpsThreshold()
        local inCritical = tpsNow < CONFIG.ANTILAG_CRITICAL_TPS

        -- NORMAL TIER ------------------------------------------------------------
        if tpsNow < normalTps and not inCritical then
            -- If a group is already counting down from a previous pass, leave it alone --
            -- don't re-schedule the same group every tick while its timer is still running.
            local alreadyCounting = false
            for _, pd in pairs(pendingDestroy) do
                if pd.cancelIfHealthy then
                    alreadyCounting = true
                    break
                end
            end

            if not alreadyCounting then
                local nowMs = server.getTimeMillisec()
                -- Find the single worst group. Groups younger than LAG_SPAWN_GRACE_SEC are
                -- SKIPPED here -- see the config comment for why.
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
                    -- NOT marked in blockedGroups -- a TPS-cull target can be cancelled if
                    -- TPS recovers before the timer runs out (see the countdown block
                    -- above), and blockedGroups is a PERMANENT mark. The hard-limit
                    -- triggers (sub-body/block/cost) still mark it, because those never
                    -- get cancelled -- see scheduleGroupDestroy's callers.
                    -- No notify/announce here on purpose -- the global panel below is the
                    -- "this is happening" signal; antilag only ever toasts once something
                    -- ACTUALLY gets removed (handled in the countdown block above).
                    scheduleGroupDestroy(worst, worstOwnerPeer,
                        "most expensive group, TPS " .. string.format("%.1f", tpsNow),
                        "TPS cull", true)
                end
            end
        end

        -- CRITICAL TIER ------------------------------------------------------------
        -- Tracks how long TPS has stayed CONTINUOUSLY below ANTILAG_CRITICAL_TPS. Any
        -- tick where TPS recovers above the threshold resets the sustain window.
        if inCritical then
            local nowMs = server.getTimeMillisec()
            if criticalWasHealthy then
                criticalSinceMs = nowMs
                criticalWasHealthy = false
                -- Critical fully supersedes normal -- drop any in-flight normal-tier
                -- countdown so the two panels can never both be showing at once. Not a
                -- smite (nothing was removed here), so no toast for this specifically --
                -- if critical goes on to actually despawn everything, THAT group is
                -- included in that broadcast; if TPS recovers first, it's simply gone.
                for group_id, pd in pairs(pendingDestroy) do
                    if pd.cancelIfHealthy then pendingDestroy[group_id] = nil end
                end
                dbgLog(2, "ANTILAG", "critical sustain window started, TPS " .. string.format("%.1f", tpsNow))
            end
            local sustainedSec = (nowMs - criticalSinceMs) / 1000
            if sustainedSec >= CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC then
                local count = 0
                for group_id in pairs(groups) do
                    pendingDestroy[group_id] = nil -- skip the normal countdown entirely, this is instant
                    destroyGroup(group_id)
                    count = count + 1
                end
                if count > 0 then
                    -- Antilag ONLY announces/toasts once it actually removes something --
                    -- broadcast as a yellow toast to everyone, same style as a vehicle-spawned
                    -- popup (server.announce can't carry color, see notify()'s comment).
                    broadcastNotify("Antilag", "All " .. count .. " creation(s) were removed.", "YELLOW")
                    dbgLog(1, "ANTILAG", "critical cull: " .. count .. " groups removed, TPS " ..
                        string.format("%.1f", tpsNow))
                end
                criticalWasHealthy = true -- reset the sustain window regardless -- the slate is now clean
            end
        else
            criticalWasHealthy = true
        end

        -- GLOBAL ANTILAG UI: critical-tier panel, visible to every player, shown only
        -- while the sustained-TPS window toward a mass despawn is actively counting.
        -- Trimmed to exactly two lines: TPS, time left.
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

    -- UI + STATS --------------------------------------------------------------
    uiTimer = uiTimer + game_ticks
    if uiTimer >= CONFIG.UI_REFRESH_TICKS then
        local dt = uiTimer / 60
        uiTimer = 0
        local list = server.getPlayers()
        local playerCount = 0
        for _ in pairs(list) do playerCount = playerCount + 1 end
        lastPlayerCount = playerCount -- feed the lag-cost math
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
                updatePlayerMarker(pl.id) -- retries here until the character exists post-join, then keeps it in sync
            end
        end
        -- Separate pass, AFTER every player's position above is fresh -- computing
        -- "nearby" during the loop above could compare against a not-yet-updated
        -- position for players later in iteration order.
        for _, pl in pairs(list) do
            if players[pl.id] then updateNearbyUI(pl.id) end
        end
    end

    -- DEBUG HEARTBEAT (level 5) ------------------------------------------------
    -- A full state dump pushed roughly once a second to anyone streaming level 5 --
    -- "everything that happens". Skips the work entirely (no table scans) unless
    -- someone actually has level 5 active, so it costs nothing on a normal server.
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

    -- Check FIRST, before tracking anything. A large creation spawns its sub-bodies one
    -- at a time - onVehicleSpawn fires once per body over several events, not all at
    -- once. If the very first destroyGroup() call below happens while later bodies of
    -- the SAME creation are still on the way in, those stragglers used to slip through:
    -- they'd arrive after the group record was gone, getOrCreateGroup would build a
    -- fresh one for them, and they'd survive since the new group hadn't hit the limit
    -- yet either. blockedGroups keeps the block in force for every body that shows up
    -- after the first one got caught, so nothing from that creation is left standing.
    if blockedGroups[group_id] then
        dbgLog(1, "CONFLICT", "vehicle " .. vehicle_id .. " tried to join already-blocked group " .. group_id)
        server.despawnVehicleGroup(group_id, true)
        return
    end

    local g = getOrCreateGroup(group_id, p.steam_id)

    if not g.vehicles[vehicle_id] then -- guard: only count a vehicle once even if this fires twice for it
        g.vehicles[vehicle_id] = true
        g.bodyCount = g.bodyCount + 1
    end
    vehicleToGroup[vehicle_id] = group_id
    pendingApply[vehicle_id] = true
    dbgLog(4, "VEHICLE", "vehicle " .. vehicle_id .. " spawned in group " .. group_id .. " (owner " .. p.name .. ")")

    -- Too many physics bodies in one group. Checked the moment a new body joins rather
    -- than waiting for onVehicleLoad, so the creation is stopped before it finishes
    -- loading in at all.
    if CONFIG.ANTILAG_ENABLED and g.bodyCount > CONFIG.MAX_SUBBODIES_PER_GROUP then
        blockedGroups[group_id] = true
        -- No public announce here -- antilag only ever announces on ACTUAL removal (the
        -- countdown block does that for every trigger). The owner gets the personal
        -- countdown toast below; the public "removed" broadcast fires 3s later.
        dbgLog(2, "ANTILAG",
            "sub-body limit: group " .. group_id .. " (" .. p.name .. "), " .. g.bodyCount ..
            " / " .. CONFIG.MAX_SUBBODIES_PER_GROUP)
        notify(peer_id, "Creation Removed",
            g.bodyCount .. " physics bodies is over this server's limit of " ..
            CONFIG.MAX_SUBBODIES_PER_GROUP .. ". Removing in " .. CONFIG.ANTILAG_COUNTDOWN_SEC ..
            "s, split large builds into separate rope/winch-connected vehicles instead.", "YELLOW")
        scheduleGroupDestroy(group_id, peer_id,
            g.bodyCount .. " physics bodies (limit " .. CONFIG.MAX_SUBBODIES_PER_GROUP .. ")",
            "sub-body limit")
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
        g.cost = math.max(0, (g.cost or 0) - (vehicleCost[vehicle_id] or 0))       -- subtract its cost contribution
        g.voxels = math.max(0, (g.voxels or 0) - (vehicleVoxels[vehicle_id] or 0)) -- and its voxel contribution
        g.vehicles[vehicle_id] = nil
        g.bodyCount = math.max(0, g.bodyCount - 1)
        if g.bodyCount == 0 then
            groups[group_id] = nil -- O(1) emptiness check, no loop
            removeGroupMarker(group_id)
        else
            updateGroupMarker(group_id) -- re-parent the marker if it was riding this vehicle
        end
    end
    vehicleCost[vehicle_id] = nil
    vehicleVoxels[vehicle_id] = nil
end

function onVehicleLoad(vehicle_id)
    local gid = vehicleToGroup[vehicle_id]
    if not gid then return end

    -- Same sticky-block check as onVehicleSpawn, and for the same reason: a body can
    -- finish loading after its group already got destroyed for a hard-limit violation.
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

    -- ONE component read for both the cost numbers and the MADE-BY check below --
    -- see analyzeVehicle()'s comment for why that used to be two separate calls.
    local c, v, maker = analyzeVehicle(vehicle_id)

    -- If a component's name field on this vehicle reads "MADE BY <someone else>" and
    -- that someone isn't an exempted tool like TAJIN, the whole group gets removed.
    -- This can only check component NAME fields, not the vehicle's actual saved title -
    -- server.getVehicleName was removed from the addon API in the Space DLC update and
    -- there's still no replacement for it as of this writing, so a vehicle's real title
    -- (the one shown in the game's own "(MADE BY X)" prompt) can't be read from Lua at
    -- all. This check only catches tags someone typed directly into a component's name.
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

    updateGroupMarker(gid) -- now that a vehicle is confirmed loaded, place/update its map marker

    -- Replace this vehicle's cost and voxel contribution rather than adding to it, so a
    -- reload doesn't double-count a vehicle that was already loaded before.
    g.cost = (g.cost or 0) - (vehicleCost[vehicle_id] or 0) + c
    vehicleCost[vehicle_id] = c
    g.voxels = (g.voxels or 0) - (vehicleVoxels[vehicle_id] or 0) + v
    vehicleVoxels[vehicle_id] = v
    dbgLog(4, "VEHICLE", "vehicle " .. vehicle_id .. " loaded, cost " .. fmtCost(c) .. " voxels " .. v)

    local ec = effectiveCost(gid) -- computed once, used below by both the popup and the ceiling check

    -- Spawn popup, once per group, local to the owner only.
    if CONFIG.SPAWN_POPUP and not g.announced then
        g.announced = true
        notify(ownerPeer, "Vehicle Spawned",
            "Owner: " .. ownerName(g) ..
            "\nLag cost: " .. fmtCost(ec) ..
            "\nVehicle ID: " .. gid, "GREEN")
    end

    if CONFIG.ANTILAG_ENABLED then
        -- Total blocks across the whole group, independent of the weighted cost formula.
        -- Catches builds made of lots of cheap, low-mass blocks that the cost formula
        -- underweights on its own.
        if g.voxels > CONFIG.MAX_BLOCKS_PER_GROUP then
            blockedGroups[gid] = true
            local nm = ownerName(g)
            -- No public announce at trigger time -- see the sub-body limit in
            -- onVehicleSpawn for why. Owner toast now, public "removed" broadcast on
            -- actual removal via the countdown block.
            dbgLog(2, "ANTILAG",
                "block limit: group " .. gid .. " (" .. nm .. "), " .. fmtCost(g.voxels) ..
                " / " .. CONFIG.MAX_BLOCKS_PER_GROUP)
            notify(ownerPeer, "Creation Removed",
                fmtCost(g.voxels) .. " blocks is over this server's limit of " ..
                CONFIG.MAX_BLOCKS_PER_GROUP .. ". Removing in " .. CONFIG.ANTILAG_COUNTDOWN_SEC ..
                "s, break large builds into smaller connected pieces.", "YELLOW")
            scheduleGroupDestroy(gid, ownerPeer,
                fmtCost(g.voxels) .. " blocks (limit " .. CONFIG.MAX_BLOCKS_PER_GROUP .. ")",
                "block limit")
            return
        end

        -- Weighted cost: voxels + mass + components + sub-body count, scaled by player
        -- count and how recently the group spawned.
        if ec > CONFIG.LAG_MAX_COST then
            blockedGroups[gid] = true
            local nm = ownerName(g)
            -- No public announce at trigger time -- see the sub-body limit in
            -- onVehicleSpawn for why. Owner toast now, public "removed" broadcast on
            -- actual removal via the countdown block.
            dbgLog(2, "ANTILAG",
                "cost ceiling: group " .. gid .. " (" .. nm .. "), " .. fmtCost(ec) ..
                " / " .. CONFIG.LAG_MAX_COST)
            notify(ownerPeer, "Creation Removed",
                "Lag cost " .. fmtCost(ec) .. " is over this server's limit of " ..
                CONFIG.LAG_MAX_COST .. ". Removing in " .. CONFIG.ANTILAG_COUNTDOWN_SEC ..
                "s, fewer components and lighter materials both lower this number.", "YELLOW")
            scheduleGroupDestroy(gid, ownerPeer,
                "lag cost " .. fmtCost(ec) .. " (limit " .. CONFIG.LAG_MAX_COST .. ")",
                "cost ceiling")
        end
    end
end

--------------------------------------------------------------------------------
-- CHAT (profanity ban only -- no rank prefix, see note below)
--------------------------------------------------------------------------------
-- CONFIRMED ENGINE LIMITATION: onChatMessage is purely informational. It has NO return
-- value the engine honors, and there is no function to delete/cancel/suppress a chat
-- message -- so a [ADMIN]/[PLAYER] tag can only ever be an ADDED second line, never a
-- replacement of the original. Removed per request rather than ship that half-measure.
-- (rankOf() is still used elsewhere -- the map marker label and the ?admins command.)
function onChatMessage(peer_id, sender_name, message)
    -- Profanity auto-ban, so a slur never lingers.
    if CONFIG.PROFANITY_BAN and containsSlur(message) then
        server.announce("[MODERATION]", sender_name .. " was auto-banned for prohibited language.", -1)
        dbgLog(2, "MODERATION", sender_name .. " auto-banned for prohibited language: " .. message)
        local p = players[peer_id]
        if p then destroyAllGroupsOf(p.steam_id) end -- don't leave a banned player's vehicles cluttering the world
        server.banPlayer(peer_id)                    -- NOTE: vanilla SW bans can't be undone in-game
        return
    end
end

--------------------------------------------------------------------------------
-- ROOT ACCESS SYSTEM
--------------------------------------------------------------------------------
-- A third tier ABOVE admin, for hardcoded OWNERS only (CONFIG.OWNERS). It is NOT
-- "admin with more" -- it is a temporary, opt-in, GUARDRAIL-FREE mode. Its whole danger
-- is that root commands pass values straight to the game API with no bounds-checking, no
-- null/target validation, and no supported-vs-unsupported distinction. That is the point,
-- and it is exactly why entry is a deliberate challenge/response (?root enable -> a coded
-- warning -> ?root verify <code>) rather than an always-on flag: it must never be entered
-- by accident.
--
-- ALL root state below is in-memory only. A script reload wipes every session, pending
-- code, and used-code record back to zero -- reload IS the undo button, and the only one.
-- There is deliberately NO persistent log (per spec): nothing about root touches g_savedata.
--
-- SECURITY MODEL: the ENTRY/DISPATCH layer (enable/verify/disable, code gen, owner check)
-- is written defensively so it can't be crashed by normal use -- that's the gate and it
-- has to hold. The individual rootCommands handlers are the opposite: they call server.*
-- DIRECTLY (never through safeServer), with raw values, on purpose. A bad root command can
-- error out and take the whole addon down -- that is the accepted, documented behavior.
local rootSessions        = {}   -- [steam_id] = true while that owner's root session is active
local pendingVerification = {}   -- [steam_id] = { code = "NNNNNN", expires_ms = <getTimeMillisec deadline> }
local usedRootCodes       = {}   -- [code] = true -- every code ever issued this run, so none repeats
local ROOT_CODE_TTL_MS    = 30000 -- a freshly issued code is valid for exactly 30 seconds

-- One-line owner-only reply channel, distinct "[ROOT]" prefix so root output never looks
-- like a normal server message.
local function rootSay(peer_id, msg)
    server.announce("[ROOT]", msg, peer_id)
end

-- Builds the argument list AFTER the root subcommand (e.g. for "?root settank 12 tank1
-- 500 1", this returns {"12", "tank1", "500", "1"} given sub-relevant arg2/arg3).
--
-- DELIBERATE DESIGN: arg2/arg3 -- the engine's own reliable positional split, the exact
-- same one every other command in this file (?pay, ?setlimit, ?msg, ...) already trusts
-- without question -- are ALWAYS used for the first two argument slots. full_message (the
-- raw typed line) is used ONLY to recover a 4th token, and only as best-effort: some root
-- commands (settank, explode) need more than the engine's 3-argument ceiling gives us
-- (arg1=subcommand, arg2, arg3), and full_message is the one way to see past that.
--
-- This function is NEVER used for the subcommand itself or the verify code -- those come
-- straight from arg1/arg2 in the dispatcher below. An earlier version of this file parsed
-- full_message from scratch for everything, including the security-critical verify code --
-- that meant a single unverified assumption about the engine's exact full_message format
-- could silently break ?root verify. Since arg1/arg2/arg3 are already proven reliable
-- everywhere else in this file, the security path now depends on nothing else.
local function rootExtraArgs(full_message, arg3)
    local extra = {}
    if type(full_message) == "string" and arg3 ~= nil then
        local tokens = {}
        for tok in full_message:gmatch("%S+") do tokens[#tokens + 1] = tok end
        -- Find arg3 in the tokenised line and take everything AFTER it -- whatever the
        -- engine truncated past its 3-argument ceiling. If arg3's text happens to repeat
        -- earlier in the line, this can only find it at the position >= where it was
        -- expected (token 4, since "?root <sub> <arg2> <arg3>" is 4 tokens), so we start
        -- the search there rather than from token 1.
        for i = 4, #tokens do
            if tokens[i] == tostring(arg3) then
                for j = i + 1, #tokens do extra[#extra + 1] = tokens[j] end
                break
            end
        end
    end
    return extra
end

-- Fresh 6-digit numeric code, guaranteed unused for this script run. Range starts at
-- 100000 so it's always exactly 6 digits (no leading-zero ambiguity). Burned into
-- usedRootCodes the instant it's generated, whether or not it's ever verified.
local function generateRootCode()
    local code
    repeat
        code = tostring(math.random(100000, 999999))
    until not usedRootCodes[code]
    usedRootCodes[code] = true
    return code
end

-- ?root enable -- issue a code + the blunt warning, privately, to the requesting owner.
-- The warning is sent BEFORE the code is usable (it IS the message carrying the code), so
-- nobody reaches verify without having seen exactly what they're opting into.
local function handleRootEnable(peer_id, steam_id)
    local code = generateRootCode()
    pendingVerification[steam_id] = { code = code, expires_ms = server.getTimeMillisec() + ROOT_CODE_TTL_MS }
    rootSay(peer_id,
        "Root gives you full control with no safety checks, and only a script reload can undo a mistake. " ..
        "To continue, type ?root verify " .. code .. "\n" ..
        "The code lasts 30 seconds and works once.")
end

-- ?root verify <code> -- activate the session if the code is exact and still inside its
-- 30s window. Wrong code leaves the pending code open (they can retry until it expires);
-- an expired code is cleared and they're told to re-run ?root enable.
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

-- ?root disable -- end the session immediately.
local function handleRootDisable(peer_id, steam_id)
    rootSessions[steam_id] = nil
    rootSay(peer_id, "You left root.")
end

-- ---- Root command registry ------------------------------------------------------------
-- Extend freely. Every handler is (caller_peer_id, args) where args is the array of tokens
-- AFTER the subcommand. Handlers call server.* DIRECTLY with raw, unclamped, unvalidated
-- values ON PURPOSE -- do NOT add the bounds/target/nil guards a normal admin command
-- would have. tonumber() here is parsing, not guarding: a non-numeric arg becomes nil and
-- is passed straight through, and whatever the API then does (including erroring out and
-- taking the addon down until a reload) is the accepted behavior.
--
-- Root commands reach into this script's own internal state too, not just the game API --
-- CONFIG fields, the live UI_X_*/UI_Y_* panel positions, tpsNow, antilagNormalTps, globalLimit,
-- players[]/groups[] records -- because they're all plain `local`s in this same file/chunk,
-- any function defined later (which every root handler is) shares them as upvalues BY
-- REFERENCE. Reassigning one here changes what every other part of the script sees,
-- immediately, on the next read -- that's what makes root able to move UI panels, force
-- antilag thresholds, or edit a player's auth state live, without a reload.
local rootCommands = {
    -- PLAYER ----------------------------------------------------------------------------
    -- teleport the named peer to the caller's current position
    ["tphere"] = function(caller, a)
        local m = server.getPlayerPos(caller)
        server.setPlayerPos(tonumber(a[1]), m)
        rootSay(caller, "tphere -> peer " .. tostring(a[1]))
    end,
    -- teleport the caller to the named peer
    ["goto"] = function(caller, a)
        local m = server.getPlayerPos(tonumber(a[1]))
        server.setPlayerPos(caller, m)
        rootSay(caller, "goto -> peer " .. tostring(a[1]))
    end,
    -- kill the named peer's character outright
    ["kill"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.killCharacter(charId)
        rootSay(caller, "killed peer " .. tostring(a[1]))
    end,
    -- revive + full-heal the named peer
    ["heal"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.reviveCharacter(charId)
        server.setCharacterData(charId, 100, true, false)
        rootSay(caller, "healed peer " .. tostring(a[1]))
    end,
    -- absurd-HP "god mode": HP set far past any normal bound (root: no clamp)
    ["god"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.setCharacterData(charId, 999999, true, false)
        rootSay(caller, "god (hp 999999) -> peer " .. tostring(a[1]))
    end,
    -- set the named peer's HP to any raw value, no range check
    ["sethp"] = function(caller, a)
        local charId = server.getPlayerCharacterID(tonumber(a[1]))
        server.setCharacterData(charId, tonumber(a[2]), true, false)
        rootSay(caller, "sethp " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    -- force this script's OWN auth flag for a peer (does NOT touch is_admin/rank -- just
    -- p.authed and the matching engine-side addAuth/removeAuth call), bypassing every rule
    -- ?noworkshop/?auth normally enforce (revoked state, already-authed guard, etc).
    ["forceauth"] = function(caller, a)
        local target = tonumber(a[1])
        local tp = players[target]
        local on = a[2] == "1"
        tp.authed = on
        if on then server.addAuth(target) else server.removeAuth(target) end
        rootSay(caller, "forceauth " .. tostring(on) .. " -> peer " .. tostring(target))
    end,
    -- force this script's is_admin flag AND the engine-side addAdmin call for a peer.
    ["forceadmin"] = function(caller, a)
        local target = tonumber(a[1])
        local tp = players[target]
        tp.is_admin = a[2] == "1"
        safeServer("addAdmin", target)
        rootSay(caller, "forceadmin " .. tostring(tp.is_admin) .. " -> peer " .. tostring(target))
    end,
    -- force p.revoked directly -- flips which of ?noworkshop/?auth will work for that
    -- player without actually running ?revoke or a warn on them.
    ["forcerevoked"] = function(caller, a)
        local tp = players[tonumber(a[1])]
        tp.revoked = a[2] == "1"
        rootSay(caller, "forcerevoked " .. tostring(tp.revoked) .. " -> peer " .. tostring(a[1]))
    end,
    -- force p.pvp for a peer, bypassing ?pvp's own toggle (and its g_savedata write --
    -- this does NOT persist, unlike the real ?pvp command).
    ["setpvp"] = function(caller, a)
        local tp = players[tonumber(a[1])]
        tp.pvp = a[2] == "1"
        queueApplyAllOf(tp.steam_id)
        rootSay(caller, "setpvp " .. tostring(tp.pvp) .. " -> peer " .. tostring(a[1]))
    end,
    -- force p.hidden for a peer, bypassing ?hide's own toggle.
    ["sethidden"] = function(caller, a)
        local target = tonumber(a[1])
        local tp = players[target]
        tp.hidden = a[2] == "1"
        updatePlayerMarker(target)
        local owned = groupsOwnedBy(tp.steam_id)
        for i = 1, #owned do updateGroupMarker(owned[i]) end
        rootSay(caller, "sethidden " .. tostring(tp.hidden) .. " -> peer " .. tostring(target))
    end,
    -- force ANY peer's debug-stream level, not just an admin's own via ?dbg.
    ["setdbg"] = function(caller, a)
        local tp = players[tonumber(a[1])]
        tp.dbgLevel = tonumber(a[2])
        rootSay(caller, "setdbg " .. tostring(tp.dbgLevel) .. " -> peer " .. tostring(a[1]))
    end,
    -- raw wallet write, NO clamp-at-zero (unlike setBalance()) -- can go negative.
    ["setbalance"] = function(caller, a)
        local tp = players[tonumber(a[1])]
        g_savedata.wallet = g_savedata.wallet or {}
        g_savedata.wallet[tp.steam_id] = tonumber(a[2])
        rootSay(caller, "setbalance " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    -- raw wallet delta, NO clamp -- can push a balance negative.
    ["addbalance"] = function(caller, a)
        local tp = players[tonumber(a[1])]
        g_savedata.wallet = g_savedata.wallet or {}
        g_savedata.wallet[tp.steam_id] = (g_savedata.wallet[tp.steam_id] or 0) + tonumber(a[2])
        rootSay(caller, "addbalance " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]) ..
            " (new: " .. tostring(g_savedata.wallet[tp.steam_id]) .. ")")
    end,
    -- dump a peer's full in-memory player record -- every field, raw. The single most
    -- useful command for tracing "why is this player's state wrong".
    ["dumpplayer"] = function(caller, a)
        local tp = players[tonumber(a[1])]
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

    -- VEHICLE / GROUP ---------------------------------------------------------------------
    -- teleport a group (by raw group id, tracked or not) to the caller
    ["vtphere"] = function(caller, a)
        local m = server.getPlayerPos(caller)
        server.setGroupPosSafe(tonumber(a[1]), m)
        rootSay(caller, "vtphere -> group " .. tostring(a[1]))
    end,
    -- teleport a group to EXPLICIT raw coordinates (not "to the caller")
    ["vteleport"] = function(caller, a)
        server.setGroupPosSafe(tonumber(a[1]), matrix.translation(tonumber(a[2]), tonumber(a[3]), tonumber(a[4])))
        rootSay(caller, "vteleport group " .. tostring(a[1]) .. " -> " .. tostring(a[2]) .. "," ..
            tostring(a[3]) .. "," .. tostring(a[4]))
    end,
    -- despawn a group by raw group id
    ["vdespawn"] = function(caller, a)
        server.despawnVehicleGroup(tonumber(a[1]), true)
        rootSay(caller, "despawned group " .. tostring(a[1]))
    end,
    -- toggle a single vehicle's invulnerability (arg2 "1" = invulnerable)
    ["vinv"] = function(caller, a)
        server.setVehicleInvulnerable(tonumber(a[1]), a[2] == "1")
        rootSay(caller, "vehicle " .. tostring(a[1]) .. " invulnerable=" .. tostring(a[2] == "1"))
    end,
    -- fill a tank to any raw amount / fluid type (overfill, wrong fluid, whatever)
    ["settank"] = function(caller, a)
        server.setVehicleTank(tonumber(a[1]), a[2], tonumber(a[3]), tonumber(a[4]))
        rootSay(caller, "settank v" .. tostring(a[1]) .. " " .. tostring(a[2]) .. "=" .. tostring(a[3]) ..
            " fluid " .. tostring(a[4]))
    end,
    -- overwrite this script's TRACKED cost for a group (the number antilag's cost-ceiling
    -- check reads) -- lets you force a group to look expensive/cheap without actually
    -- changing anything about the real vehicle, purely for testing the cost-ceiling trigger.
    ["vcost"] = function(caller, a)
        local g = groups[tonumber(a[1])]
        g.cost = tonumber(a[2])
        rootSay(caller, "vcost group " .. tostring(a[1]) .. " = " .. tostring(g.cost))
    end,
    -- force (or clear) blockedGroups for a raw group id -- the same permanent mark the
    -- hard antilag limits set, without actually tripping one. "1" blocks, anything else clears.
    ["vblock"] = function(caller, a)
        local gid = tonumber(a[1])
        if a[2] == "1" then blockedGroups[gid] = true else blockedGroups[gid] = nil end
        rootSay(caller, "vblock group " .. tostring(gid) .. " = " .. tostring(a[2] == "1"))
    end,
    -- reassign a group's tracked owner_steam to any raw steam_id, online or not.
    ["vowner"] = function(caller, a)
        local g = groups[tonumber(a[1])]
        g.owner_steam = tostring(a[2])
        rootSay(caller, "vowner group " .. tostring(a[1]) .. " -> " .. tostring(a[2]))
    end,
    -- immediately destroy a group, skipping the countdown/warning entirely.
    ["forcecull"] = function(caller, a)
        local gid = tonumber(a[1])
        pendingDestroy[gid] = nil
        destroyGroup(gid)
        rootSay(caller, "forcecull group " .. tostring(gid))
    end,
    -- dump a tracked group's full in-memory record.
    ["dumpgroup"] = function(caller, a)
        local g = groups[tonumber(a[1])]
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

    -- ANTILAG -----------------------------------------------------------------------------
    -- override the LIVE tpsNow reading directly -- lets you trigger normal/critical antilag
    -- on demand for testing, with no need to actually lag the real server. The very next
    -- onTick reads this value, so effects (or the lack of them) are visible within 1 tick.
    -- NOTE: tpsNow is recomputed from real wall-clock timing every CONFIG.TPS_WINDOW_TICKS
    -- ticks (see onTick's TPS block), so a forced value here is temporary -- it holds until
    -- that recompute next fires, then reverts to whatever the real server is actually doing.
    ["forcetps"] = function(caller, a)
        tpsNow = tonumber(a[1])
        rootSay(caller, "tpsNow forced to " .. tostring(tpsNow) .. " (reverts on the next real TPS sample)")
    end,
    -- raw override of the live normal-tier threshold, NO 10-50 clamp (?antilag <n> clamps;
    -- this doesn't).
    ["antinormaltps"] = function(caller, a)
        antilagNormalTps = tonumber(a[1])
        rootSay(caller, "antilagNormalTps = " .. tostring(antilagNormalTps) .. " (unclamped)")
    end,
    -- live override of CONFIG.ANTILAG_CRITICAL_TPS -- equivalent to "cfgset
    -- ANTILAG_CRITICAL_TPS <n>", provided as a named shortcut since it's the one CONFIG
    -- field you'll reach for constantly while testing the critical tier.
    ["anticrittps"] = function(caller, a)
        CONFIG.ANTILAG_CRITICAL_TPS = tonumber(a[1])
        rootSay(caller, "CONFIG.ANTILAG_CRITICAL_TPS = " .. tostring(CONFIG.ANTILAG_CRITICAL_TPS))
    end,
    -- live override of CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC -- shrink this to 1-2s while
    -- testing so you don't have to hold forcetps below critical for the full 5s each time.
    ["anticritsustain"] = function(caller, a)
        CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC = tonumber(a[1])
        rootSay(caller, "CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC = " .. tostring(CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC))
    end,
    -- full antilag runtime reset: clears every pending countdown and hard-limit block, and
    -- force-hides both global panels for every currently connected player (resetting the
    -- antilagNormalUiShown/antilagCriticalUiShown FLAGS alone isn't enough -- see the same
    -- class of bug fixed in onCreate's popup-reset comment; this command applies that same
    -- fix on demand instead of only at reload).
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

    -- UI --------------------------------------------------------------------------------
    -- live-reposition one of the script's built-in panels by name: main, center, nearby,
    -- antilagnormal, antilagcritical. Takes effect on that panel's NEXT refresh (immediate
    -- for main/nearby -- refreshed every UI_REFRESH_TICKS; antilag panels only refresh
    -- while actively shown, so trigger one via forcetps/anticrittps to see it move live).
    ["uimove"] = function(caller, a)
        local panel, x, y = a[1], tonumber(a[2]), tonumber(a[3])
        if panel == "main" then
            UI_X_MAIN, UI_Y_MAIN = x, y
        elseif panel == "center" then
            UI_X_CENTER, UI_Y_CENTER = x, y
        elseif panel == "nearby" then
            UI_X_NEARBY, UI_Y_NEARBY = x, y
        elseif panel == "antilagnormal" then
            UI_X_ANTILAG_NORMAL, UI_Y_ANTILAG_NORMAL = x, y
        elseif panel == "antilagcritical" then
            UI_X_ANTILAG_CRITICAL, UI_Y_ANTILAG_CRITICAL = x, y
        else
            rootSay(caller, "Unknown panel \"" .. tostring(panel) ..
                "\". Valid: main, center, nearby, antilagnormal, antilagcritical.")
            return
        end
        rootSay(caller, "uimove " .. panel .. " -> " .. tostring(x) .. "," .. tostring(y))
    end,
    -- raw server.setPopupScreen call for ANY ui_id/x/y/text, to ANY peer -- bypasses
    -- sendPopup's cache AND every built-in panel's own logic entirely. Use a scratch id
    -- (9999+) to prototype a brand-new panel layout without fighting the panels that
    -- already own ids 9001-9007; reusing a built-in id works too but the normal refresh
    -- loop will overwrite it on its own next cycle, since that loop doesn't know root
    -- touched it.
    ["uishow"] = function(caller, a)
        local target, ui_id, x, y = tonumber(a[1]), tonumber(a[2]), tonumber(a[3]), tonumber(a[4])
        local text = ""
        for i = 5, #a do text = text .. (i > 5 and " " or "") .. tostring(a[i]) end
        server.setPopupScreen(target, ui_id, "Root", true, text, x, y)
        rootSay(caller, "uishow ui_id " .. tostring(ui_id) .. " -> peer " .. tostring(target) ..
            " @ " .. tostring(x) .. "," .. tostring(y))
    end,
    -- raw server.removePopup for any ui_id/peer -- clears a uishow test panel, or force-
    -- clears a stuck built-in one without waiting for the normal hide logic to catch up.
    ["uihide"] = function(caller, a)
        server.removePopup(tonumber(a[1]), tonumber(a[2]))
        rootSay(caller, "uihide ui_id " .. tostring(a[2]) .. " -> peer " .. tostring(a[1]))
    end,
    -- lists every built-in panel's ui_id and CURRENT live x/y -- read this before uimove
    -- to see exactly what you're about to change.
    ["uidump"] = function(caller, a)
        rootSay(caller,
            "main=" .. UI_MAIN .. " @ " .. UI_X_MAIN .. "," .. UI_Y_MAIN .. "\n" ..
            "center=" .. UI_CENTER .. " @ " .. UI_X_CENTER .. "," .. UI_Y_CENTER .. "\n" ..
            "nearby=" .. UI_NEARBY .. " @ " .. UI_X_NEARBY .. "," .. UI_Y_NEARBY .. "\n" ..
            "antilagnormal=" .. UI_ANTILAG_NORMAL .. " @ " .. UI_X_ANTILAG_NORMAL .. "," .. UI_Y_ANTILAG_NORMAL .. "\n" ..
            "antilagcritical=" .. UI_ANTILAG_CRITICAL .. " @ " .. UI_X_ANTILAG_CRITICAL .. "," .. UI_Y_ANTILAG_CRITICAL)
    end,

    -- CONFIG ------------------------------------------------------------------------------
    -- generic live setter for ANY top-level CONFIG.* field -- the general-purpose escape
    -- hatch for "change stuff on the go" beyond the named shortcuts above. Auto-detects
    -- type: "true"/"false" -> boolean, anything tonumber() accepts -> number, else raw
    -- string. No key-existence check -- a typo'd key just silently creates a new,
    -- unused CONFIG field (matches root's no-guards ethos; use cfgget to check first).
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
    -- read back any CONFIG.* field's current live value.
    ["cfgget"] = function(caller, a)
        rootSay(caller, "CONFIG." .. tostring(a[1]) .. " = " .. tostring(CONFIG[a[1]]))
    end,

    -- WORLD / SERVER ------------------------------------------------------------------
    -- an explosion of any magnitude at any raw x/y/z
    ["explode"] = function(caller, a)
        server.spawnExplosion(matrix.translation(tonumber(a[1]), tonumber(a[2]), tonumber(a[3])), tonumber(a[4]))
        rootSay(caller, "explode @ " .. tostring(a[1]) .. "," .. tostring(a[2]) .. "," .. tostring(a[3]) ..
            " mag " .. tostring(a[4]))
    end,
    -- despawn EVERY vehicle on the server at once
    ["clean"] = function(caller, a)
        server.cleanVehicles()
        rootSay(caller, "cleanVehicles(), every vehicle server-wide despawned")
    end,
    -- override the global vehicle limit with NO MAX_LIMIT clamp
    ["setlimit"] = function(caller, a)
        globalLimit = tonumber(a[1])
        rootSay(caller, "globalLimit = " .. tostring(globalLimit) .. " (unclamped)")
    end,
    -- broadcast a raw line to everyone
    ["announce"] = function(caller, a)
        server.announce("[ROOT]", table.concat(a, " "), -1)
    end,
    -- re-seed the RNG with the current wall clock -- forces a fresh, unpredictable
    -- sequence for anything that calls math.random (?cargo's destination roll, root's own
    -- code generator), useful when testing "did the seed actually change the outcome".
    ["reseed"] = function(caller, a)
        math.randomseed(server.getTimeMillisec())
        rootSay(caller, "RNG re-seeded")
    end,
    -- server-wide live counters snapshot -- players online, tracked groups/vehicles,
    -- pending antilag countdowns, blocked groups, current TPS/uptime. The "is anything
    -- stuck" command.
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
            " rootSessions=" .. (function() local n = 0
                for _ in pairs(rootSessions) do n = n + 1 end
                return n
            end)())
    end,

    -- ACCESS (runtime OWNERS/ADMINS list edits, in-memory only -- see the reload caveat
    -- in the man page: these do NOT persist, they edit CONFIG in memory the same way
    -- everything else about root does) --------------------------------------------------
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

-- ---- Root command ORDER + full man pages ------------------------------------------------
-- Display order (rootCommands itself has no order -- it's a hash table), grouped to match
-- the categories above. Every name here MUST have a ROOT_MAN entry -- checked by the cross-
-- verification the implementer ran after writing this (see the chat history), not by any
-- runtime code (root deliberately has no self-check machinery -- see the header comment).
local ROOT_COMMAND_ORDER = {
    "tphere", "goto", "kill", "heal", "god", "sethp", "forceauth", "forceadmin", "forcerevoked",
    "setpvp", "sethidden", "setdbg", "setbalance", "addbalance", "dumpplayer",
    "vtphere", "vteleport", "vdespawn", "vinv", "settank", "vcost", "vblock", "vowner",
    "forcecull", "dumpgroup",
    "forcetps", "antinormaltps", "anticrittps", "anticritsustain", "resetantilag",
    "uimove", "uishow", "uihide", "uidump",
    "cfgset", "cfgget",
    "explode", "clean", "setlimit", "announce", "reseed", "dump",
    "addowner", "removeowner", "addadmin", "removeadmin",
}

-- Full manpage-style reference, ONE entry per root command, in the exact same
-- description/whenToUse/variants/examples shape as the normal MAN_HELP system (see
-- showManPage) so the two systems read consistently even though root is otherwise
-- completely separate and undocumented outside itself.
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
        whenToUse = "Precisely testing low-HP UI/behavior (e.g. sethp 3 5 to see the near-death state) without relying on combat.",
        examples = { "?root sethp 3 1", "?root sethp 3 100000" },
    },
    ["forceauth"] = {
        syntax = "?root forceauth <peer_id> <0|1>",
        description = "Directly sets p.authed and calls the matching engine addAuth/removeAuth, bypasses every ?noworkshop/?auth rule (revoked state, already-authed guard).",
        whenToUse = "Testing authed-tier commands on a throwaway account without running the real entry flow, or force-fixing a desynced auth state.",
        variants = "Does NOT touch p.revoked, pair with forcerevoked if you also need to flip which of ?noworkshop/?auth would normally apply.",
        examples = { "?root forceauth 3 1", "?root forceauth 3 0" },
    },
    ["forceadmin"] = {
        syntax = "?root forceadmin <peer_id> <0|1>",
        description = "Directly sets p.is_admin and calls the engine addAdmin, bypasses the OWNERS/ADMINS/HTTP adminSet checks entirely.",
        whenToUse = "Testing admin-tier commands on an account not on any hardcoded/HTTP list.",
        examples = { "?root forceadmin 3 1" },
    },
    ["forcerevoked"] = {
        syntax = "?root forcerevoked <peer_id> <0|1>",
        description = "Directly sets p.revoked, which decides whether that player needs ?noworkshop (0) or ?auth (1) to re-enter.",
        whenToUse = "Testing the ?noworkshop/?auth mutual-exclusion error paths without actually running ?revoke or warning the player.",
        examples = { "?root forcerevoked 3 1" },
    },
    ["setpvp"] = {
        syntax = "?root setpvp <peer_id> <0|1>",
        description = "Directly sets p.pvp and re-queues vehicle settings. Unlike the real ?pvp command, this does NOT write to g_savedata, it does not persist across reload/reconnect.",
        whenToUse = "Quickly testing PvP-on/off behavior on someone else's account, or a temporary override you don't want saved.",
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
        description = "Sets ANY peer's debug-stream level, not just an admin's own (the real ?dbg only ever affects the caller).",
        whenToUse = "Turning on a live debug stream for a non-admin test account, or forcing an admin's stream on/off remotely.",
        examples = { "?root setdbg 3 5" },
    },
    ["setbalance"] = {
        syntax = "?root setbalance <peer_id> <amount>",
        description = "Directly overwrites g_savedata.wallet for that player's steam_id. No clamp, can be set negative.",
        whenToUse = "Setting up a specific economy test state (e.g. exactly enough for one ?tool purchase, or a negative balance to see how the rest of the economy reacts).",
        examples = { "?root setbalance 3 1000", "?root setbalance 3 -50" },
    },
    ["addbalance"] = {
        syntax = "?root addbalance <peer_id> <amount>",
        description = "Adds a raw delta to that player's wallet. No clamp, a negative amount can push the balance below zero.",
        whenToUse = "Nudging a balance up/down mid-test without recalculating the absolute target for setbalance.",
        examples = { "?root addbalance 3 500", "?root addbalance 3 -500" },
    },
    ["dumpplayer"] = {
        syntax = "?root dumpplayer <peer_id>",
        description = "Prints that peer's entire in-memory player record: steam_id, name, is_admin, authed, revoked, ui, pvp, antisteal, hidden, limit, dbgLevel, speed, alt, lastCargoMs.",
        whenToUse = "First command to run when a player's behavior doesn't match what you expect, see the exact state the script thinks they're in.",
        examples = { "?root dumpplayer 3" },
    },
    ["vtphere"] = {
        syntax = "?root vtphere <group_id>",
        description = "Teleports a vehicle group to YOUR current position. Works on ANY raw group id, tracked by this script or not.",
        whenToUse = "Recovering a vehicle stuck out of reach, or the same job the real ?vtp does but for a group you don't own.",
        variants = "vteleport does the same move but to explicit x/y/z instead of \"to you\".",
        examples = { "?root vtphere 42" },
    },
    ["vteleport"] = {
        syntax = "?root vteleport <group_id> <x> <y> <z>",
        description = "Teleports a vehicle group to explicit raw coordinates.",
        whenToUse = "Placing a test vehicle at an exact, repeatable position (e.g. lining it up on a cargo zone to test ?deliver's radius check).",
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
        description = "Sets one vehicle's invulnerability directly. Note: this is a VEHICLE id, not a group id, a multi-body group needs one call per body.",
        whenToUse = "Testing damage on a specific body inside a group without changing the whole group's PvP-driven invulnerability.",
        examples = { "?root vinv 7 1" },
    },
    ["settank"] = {
        syntax = "?root settank <vehicle_id> <tank_name> <amount> <fluid_type>",
        description = "Fills one tank on one vehicle to any raw amount/fluid type, no capacity or fluid-type check (unlike the real ?refuel).",
        whenToUse = "Setting up an exact fuel-state test (overfilled, wrong fluid, empty) instantly.",
        variants = "Fluid type ids: 0=freshwater, 1=diesel, 2=jetfuel, 3=air, 4=exhaust, 5=oil, 6=seawater, 7=steam, 8=slurry, 9=saturated slurry, 10=oxygen, 11=nitrogen, 12=hydrogen.",
        examples = { "?root settank 7 fuel_tank_1 500 1" },
    },
    ["vcost"] = {
        syntax = "?root vcost <group_id> <cost>",
        description = "Overwrites this script's TRACKED lag-cost number for a group, the exact value antilag's cost-ceiling check reads. Does not touch the real vehicle at all.",
        whenToUse = "Testing the antilag cost-ceiling trigger and its countdown/removal flow without building an actually expensive vehicle.",
        examples = { "?root vcost 42 999999" },
    },
    ["vblock"] = {
        syntax = "?root vblock <group_id> <0|1>",
        description = "Sets or clears blockedGroups for a raw group id, the same permanent mark a hard antilag limit leaves, without tripping one for real.",
        whenToUse = "Testing what happens when a straggler body tries to join an already-blocked group (onVehicleSpawn's CONFLICT path).",
        examples = { "?root vblock 42 1" },
    },
    ["vowner"] = {
        syntax = "?root vowner <group_id> <steam_id>",
        description = "Reassigns a group's tracked owner to any raw steam_id, online or not.",
        whenToUse = "Testing ownership-dependent behavior (limits, ?c, ?vtp permission checks) without actually re-spawning the vehicle under a different account.",
        examples = { "?root vowner 42 76561198000000000" },
    },
    ["forcecull"] = {
        syntax = "?root forcecull <group_id>",
        description = "Destroys a group immediately, skipping the countdown/warning popup and the public removal broadcast entirely.",
        whenToUse = "Instant cleanup during testing when you don't want antilag's normal 3s countdown UI in the way.",
        examples = { "?root forcecull 42" },
    },
    ["dumpgroup"] = {
        syntax = "?root dumpgroup <group_id>",
        description = "Prints a tracked group's full record: owner_steam, bodyCount (and a live recount), cost, voxels, announced, spawn_tick/spawn_ms, and its blocked/pendingDestroy status.",
        whenToUse = "Same idea as dumpplayer, first command to run when a vehicle's antilag/ownership behavior looks wrong.",
        examples = { "?root dumpgroup 42" },
    },
    ["forcetps"] = {
        syntax = "?root forcetps <n>",
        description = "Overrides the live tpsNow value directly. Reverts automatically on the next real TPS sample (every CONFIG.TPS_WINDOW_TICKS ticks, ~1s).",
        whenToUse = "THE command for testing antilag without actually lagging the server, set forcetps 5 to trigger the normal tier, or hold it below ANTILAG_CRITICAL_TPS for ANTILAG_CRITICAL_SUSTAIN_SEC seconds (shrink that with anticritsustain first) to trigger the mass cull.",
        variants = "Since it reverts within ~1s, you may need to re-run it repeatedly (or script multiple calls) to hold a fake TPS long enough to cross the critical sustain window.",
        examples = { "?root forcetps 5", "?root forcetps 60" },
    },
    ["antinormaltps"] = {
        syntax = "?root antinormaltps <n>",
        description = "Raw override of the live normal-tier TPS threshold. Unlike the real ?antilag <n>, this has NO 10-50 clamp.",
        whenToUse = "Testing extreme or invalid thresholds (0, negative, 1000) to see how the rest of antilag reacts, beyond what the clamped admin command allows.",
        examples = { "?root antinormaltps 0", "?root antinormaltps 55" },
    },
    ["anticrittps"] = {
        syntax = "?root anticrittps <n>",
        description = "Live override of CONFIG.ANTILAG_CRITICAL_TPS. Equivalent to cfgset ANTILAG_CRITICAL_TPS <n>, provided as a named shortcut.",
        whenToUse = "Raising the critical threshold close to the normal one to make it easy to cross both tiers while testing.",
        examples = { "?root anticrittps 35" },
    },
    ["anticritsustain"] = {
        syntax = "?root anticritsustain <sec>",
        description = "Live override of CONFIG.ANTILAG_CRITICAL_SUSTAIN_SEC, how long TPS must stay under the critical threshold before the mass cull fires.",
        whenToUse = "Shrinking this to 1-2s while testing so you don't have to hold forcetps for the full default 5 seconds each time.",
        examples = { "?root anticritsustain 1" },
    },
    ["resetantilag"] = {
        syntax = "?root resetantilag",
        description = "Clears every pending antilag countdown and hard-limit block, and force-hides both global antilag panels for everyone online.",
        whenToUse = "Cleaning up after a round of antilag testing (forcetps, vcost, etc) so leftover fake state doesn't affect real players next.",
        examples = { "?root resetantilag" },
    },
    ["uimove"] = {
        syntax = "?root uimove <main|center|nearby|antilagnormal|antilagcritical> <x> <y>",
        description = "Live-repositions one of the script's built-in UI panels. Takes effect on that panel's next refresh.",
        whenToUse = "THE command for testing where UIs should go, iterate on x/y live without editing and reloading the script for every tweak.",
        variants = "main/nearby refresh every UI_REFRESH_TICKS (visible almost immediately). The antilag panels only refresh while actively shown, trigger one with forcetps/anticritsustain first to see the move happen live.",
        examples = { "?root uimove main -0.5 0.3", "?root uimove antilagnormal -0.89 -0.1" },
    },
    ["uishow"] = {
        syntax = "?root uishow <peer_id> <ui_id> <x> <y> <text...>",
        description = "Raw server.setPopupScreen call, shows ANY text at ANY ui_id/position to ANY peer, completely bypassing every built-in panel's own logic and sendPopup's dedup cache.",
        whenToUse = "Prototyping a brand-new panel layout that doesn't exist in the script yet. Use a scratch ui_id (9999 or higher) so the real refresh loops don't fight you for it.",
        variants = "Reusing a built-in id (9001-9007) works too, but the owning system's normal refresh loop will overwrite your test on its own next cycle, it has no idea root touched that id.",
        examples = { "?root uishow 3 9999 0 0.5 Test panel line one" },
    },
    ["uihide"] = {
        syntax = "?root uihide <peer_id> <ui_id>",
        description = "Raw server.removePopup call for any peer/ui_id.",
        whenToUse = "Clearing a uishow test panel, or force-clearing a built-in panel that's stuck on-screen without waiting for its normal hide logic.",
        examples = { "?root uihide 3 9999" },
    },
    ["uidump"] = {
        syntax = "?root uidump",
        description = "Lists every built-in panel's ui_id and its CURRENT live x/y position.",
        whenToUse = "Always run this before uimove so you know your starting point and aren't guessing at current coordinates.",
        examples = { "?root uidump" },
    },
    ["cfgset"] = {
        syntax = "?root cfgset <key> <value>",
        description = "Generic live setter for any top-level CONFIG.* field. \"true\"/\"false\" become booleans, anything tonumber()-parseable becomes a number, everything else stays a raw string.",
        whenToUse = "Changing any config knob on the fly without a reload, fuel prices, lag weights, cooldowns, DLC flags, anything in CONFIG. The general-purpose escape hatch beyond the named shortcuts (anticrittps etc).",
        variants = "No key-existence check, a typo'd key silently creates a new, inert CONFIG field rather than erroring. Use cfgget first if unsure of the exact name.",
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
        description = "Despawns EVERY vehicle on the server at once (server.cleanVehicles()), not just this script's tracked ones.",
        whenToUse = "Hard reset of the vehicle world state mid-session, without a full script reload.",
        examples = { "?root clean" },
    },
    ["setlimit"] = {
        syntax = "?root setlimit <n>",
        description = "Sets the global vehicle limit directly. Unlike the real ?setlimit, there is NO CONFIG.MAX_LIMIT clamp.",
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
        whenToUse = "Forcing a fresh random sequence mid-session, e.g. to verify ?cargo's destination roll isn't stuck repeating the same result.",
        examples = { "?root reseed" },
    },
    ["dump"] = {
        syntax = "?root dump",
        description = "Server-wide live counters: players online, tracked groups/vehicles, pending antilag countdowns, blocked groups, current TPS/avg TPS, global vehicle limit, uptime, and active root session count.",
        whenToUse = "The \"is anything stuck\" command, run this first when something server-wide seems off.",
        examples = { "?root dump" },
    },
    ["addowner"] = {
        syntax = "?root addowner <steam_id>",
        description = "Adds a steam_id to CONFIG.OWNERS in memory, live, that player is OWNER rank immediately (no rejoin needed, applyAccess re-checks aren't required since rankOf() reads CONFIG.OWNERS directly on every call).",
        whenToUse = "Granting a co-tester OWNER rank for a session without editing the file and reloading.",
        variants = "IN-MEMORY ONLY, same as every other root effect, a script reload reverts this to whatever's hardcoded in the file. Edit CONFIG.OWNERS in the source directly for a permanent grant.",
        examples = { "?root addowner 76561198000000000" },
    },
    ["removeowner"] = {
        syntax = "?root removeowner <steam_id>",
        description = "Removes a steam_id from CONFIG.OWNERS in memory, live.",
        whenToUse = "Revoking a temporary OWNER grant made with addowner during the same session.",
        variants = "IN-MEMORY ONLY, see addowner's note. Also note this does NOT end that player's root session if one is already active (rootSessions is separate), pair with ?root disable run by them, or a reload, to fully revoke.",
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

-- ?root help [command] -- lists every root command grouped by category, or the full
-- man-page entry for one. Same rendering shape as showManPage's SYNOPSIS/DESCRIPTION/
-- WHEN TO USE/VARIANTS/EXAMPLES layout, kept separate on purpose -- root's help must
-- never touch COMMAND_HELP/MAN_HELP/KNOWN_CMDS, or ?root and every root subcommand would
-- leak into the normal ?help/?man listings and stop being indistinguishable from a typo.
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

--------------------------------------------------------------------------------
-- COMMANDS
--------------------------------------------------------------------------------
function onCustomCommand(full_message, peer_id, is_admin, is_auth, command, arg1, arg2, arg3)
    command = (command or ""):lower()
    local p = getP(peer_id)
    if not p then
        -- No player record for this peer (mid-join, or a reload that hasn't reseeded yet).
        -- Logged so a "my command did nothing" report is traceable to this exact cause.
        dbgLog(2, "CMD", "command " .. command .. " from peer " .. tostring(peer_id) ..
            " ignored, no player record yet")
        return
    end
    p.is_admin = (is_admin == true)

    -- COMMAND RECEIVED -- one structured line per invocation (identity, rank, command,
    -- args) BEFORE any permission/validation runs, so every attempt is traceable even
    -- when a command early-returns without its own log. Not in a hot loop -- fires once
    -- per typed command, so it can't spam. See dbgLog()'s level guide (3 = admin actions).
    -- DELIBERATELY skips ?root: root is a stealth, no-audit tier (reload is its only trace),
    -- and this log would otherwise stream root command args -- including a live verify code --
    -- to any admin running ?dbg. The code is single-use and steam_id-scoped so it's useless
    -- to others anyway, but root is designed to leave nothing in the debug stream.
    if command ~= "?root" then
        local argStr = ""
        if arg1 ~= nil then argStr = argStr .. " " .. tostring(arg1) end
        if arg2 ~= nil then argStr = argStr .. " " .. tostring(arg2) end
        if arg3 ~= nil then argStr = argStr .. " " .. tostring(arg3) end
        dbgLog(3, "CMD", p.name .. " [" .. rankOf(p) .. "] ran " .. command .. argStr)
    end

    -- ROOT ACCESS (owners only) ----------------------------------------------
    -- Handled at the very top so it's never blocked by any lower-tier gate. For a
    -- NON-owner this branch does nothing and falls through: execution continues to the
    -- normal flow and, since ?root is intentionally absent from every command table
    -- (KNOWN_CMDS/COMMAND_HELP/MAN_HELP), lands on the standard "Unknown Command" reply --
    -- exactly what a typo produces. That indistinguishability is the point. (The spec's
    -- literal "no response at all" would actually LEAK ?root here, since in this codebase
    -- unknown commands DO reply -- a silent ?root would stand out against that. So we
    -- honor the stated goal, "indistinguishable from an unknown command", over the letter.)
    if command == "?root" then
        if isOwner(p) then
            local steam_id = p.steam_id
            -- "?root <sub> <arg2> <arg3>" -- arg1 IS the subcommand here (onCustomCommand
            -- splits the FIRST token after the command word into arg1, same as every other
            -- command in this file: "?pay Sam 100" -> arg1="Sam" arg2="100"). Reliable,
            -- proven positional split -- see rootExtraArgs' comment for why this matters.
            local sub = arg1 and tostring(arg1):lower() or nil

            -- enable / verify / disable are the ONLY subcommands allowed outside an active
            -- session -- they ARE the entry flow. Everything else, including "help" and the
            -- command list it prints, is gated behind rootSessions[steam_id]: you cannot see
            -- or read any root command until you are actually in root.
            if sub == "enable" then
                handleRootEnable(peer_id, steam_id)
            elseif sub == "verify" then
                handleRootVerify(peer_id, steam_id, arg2 and tostring(arg2) or nil)
            elseif sub == "disable" then
                handleRootDisable(peer_id, steam_id)
            elseif not sub then
                -- Bare "?root" -- owner is confirmed, so guide them. Do NOT mention ?root help
                -- when they are out of session, since it is unavailable until they enter root.
                rootSay(peer_id, rootSessions[steam_id]
                    and "You are in root. Type ?root help for commands, ?root disable to leave."
                    or "Type ?root enable to begin.")
            elseif rootSessions[steam_id] then
                -- In session: "help" reads the command list/man pages, anything else dispatches.
                if sub == "help" then
                    rootHelp(peer_id, arg2 and tostring(arg2) or nil)
                else
                    -- args = {arg2, arg3, ...anything full_message reveals past arg3, best-effort}.
                    local handler = rootCommands[sub]
                    if handler then
                        local rargs = {}
                        if arg2 ~= nil then rargs[#rargs + 1] = tostring(arg2) end
                        if arg3 ~= nil then rargs[#rargs + 1] = tostring(arg3) end
                        local extra = rootExtraArgs(full_message, arg3)
                        for i = 1, #extra do rargs[#rargs + 1] = extra[i] end
                        handler(peer_id, rargs)
                    else
                        rootSay(peer_id, "That is not a root command. Type ?root help for the list.")
                    end
                end
            else
                -- Owner, confirmed, but no active session, and they typed help or a command.
                rootSay(peer_id, "You are not in root. Type ?root enable first.")
            end
            return
        end
        -- NON-owner: intentional fall-through (no return) -- see the comment above.
    end

    -- EVERYONE ----------------------------------------------------------------
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

    -- ?noworkshop (first-time auth) and ?auth (re-auth after a revoke) are DELIBERATELY
    -- separate and non-interchangeable -- see each other's error branch below.
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
        refreshUI(peer_id, lastPlayerCount) -- instant -- don't make them wait for the next UI_REFRESH_TICKS tick
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
        refreshUI(peer_id, lastPlayerCount) -- instant -- don't make them wait for the next UI_REFRESH_TICKS tick
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

    -- ?tp [id] -- teleports the caller to one of the world's named "teleport" zones
    -- (see loadTeleports()'s comment for why this only works if the world has them).
    -- Not gated behind ?auth -- this only moves the player, not anything vehicle-related.
    -- This is the location teleport (was ?goto); the admin "teleport to a player"
    -- command is ?tpp.
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

        -- Best-effort: sit the player in a seat of their vehicle if they own one that is
        -- PARKED AT this destination, so arriving at a hangar/dock where their creation
        -- sits drops them into it instead of just next to it.
        --
        -- CRITICAL guard: only if the vehicle is actually near this zone. server.setSeated
        -- forces the character into the seat wherever the vehicle is -- without the
        -- proximity check, a vehicle parked ELSEWHERE would yank the player straight back
        -- out of the location they just teleported to, silently undoing the ?tp. If no
        -- owned vehicle is here, they simply stand at the location (teleport already done).
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

    -- AUTHED ------------------------------------------------------------------
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
        if vtpGroupToPlayer(target, peer_id) then
            say(peer_id, "Your vehicle is here.")
        else
            say(peer_id, "That didn't work. Try again in a moment.")
        end
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

    -- Not saved (resets on rejoin), same pattern as ?antisteal.
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

    -- ?pay behaves differently for admins vs regular players (this replaces the old
    -- separate ?givemoney admin command -- one name, permission-aware behavior):
    --   Admin:   injects money into the target's balance, no deduction from the
    --			admin's own wallet. Negative amounts deduct from the target instead.
    --   Player:  a normal peer-to-peer payment -- deducted from YOUR balance first,
    --			fails with no charge if you can't afford it. Amount must be positive
    --			(a regular player can't use a negative amount to deduct from someone
    --			else without their consent).
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
        -- Checked HERE, before the request is even created -- if they can't afford it
        -- right now, there's no point sending them a request they'd just have to
        -- decline, so it never reaches them at all.
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

    -- ?cargo requests a job while standing at one of the 16 zones (that becomes the
    -- origin; any of the other 15 is picked as the destination). ?deliver completes
    -- it once enough vehicle MASS is parked near the destination -- see CONFIG's
    -- ECONOMY comment for why mass, not a "SIBTaT trailer" check, is what's actually
    -- verified here.
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
        }
        p.lastCargoMs = nowMs
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
        notify(peer_id, "Delivered",
            "Delivered to " .. p.cargoJob.dest_name .. " (" .. fmtCost(mass) .. "kg on site). Paid $" ..
            fmtMoney(payout) .. ". Balance: $" .. fmtMoney(getBalance(p.steam_id)) .. ".", "GREEN")
        dbgLog(4, "ECONOMY", p.name .. " delivered cargo to " .. p.cargoJob.dest_name .. " for $" .. fmtMoney(payout))
        p.cargoJob = nil
        return
    end

    -- ?refuel pays to top up ONLY diesel/jetfuel tanks on a vehicle of yours parked
    -- near one of the 16 zones. Separate from ?r, which stays free and untouched.
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

        -- Gather this player's tanks that are BOTH (a) diesel/jetfuel and (b) on a
        -- vehicle body sitting within FUEL_STATION_RADIUS of the same zone.
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

        -- Fill each tank, THEN verify via getVehicleTank that the fill actually took
        -- effect, and only count/charge for what's CONFIRMED, before ever touching the
        -- wallet. server.setVehicleTank has no documented return value -- "the call
        -- didn't error" is not proof it worked, only a real read-back is.
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

    -- ?tool				-- list every available id/name (prices included)
    -- ?tool <id> | <name>  -- BUY yourself one piece of equipment. Name lookup is
    -- case-insensitive and forgiving of underscore-vs-space ("fire_extinguisher",
    -- "Fire_Extinguisher", and "fire extinguisher" all resolve alike). Costs money
    -- (see CONFIG.TOOL_PRICE_*) -- charged ONLY once the equip is confirmed to have
    -- actually worked, never on a failed attempt.
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

        -- Real slots, from the SWSlotNumberEnum in the API docs: 1 = large item
        -- slot, 2-9 = the eight small item slots, 10 = the single outfit slot.
        --
        -- Picking an EMPTY slot isn't enough on its own -- an earlier version of
        -- this command did that, reported success, and the item still didn't show
        -- up in-game. server.setCharacterItem returns an is_success boolean that
        -- was being thrown away entirely (called through safeServer, which only
        -- checks whether the function exists, not whether the call actually
        -- worked). There's no documented rule for which equipment ids need the
        -- large slot vs a small one, so instead of guessing at a classification
        -- table, this ACTUALLY ATTEMPTS the equip on each empty slot in turn and
        -- checks the real result, moving to the next slot if that one's rejected.
        -- The game telling us which slots work beats us guessing.
        local slot, ok2
        if OUTFIT_IDS[eqId] then
            local queried, success = safeServerQuery("setCharacterItem", charId, 10, eqId, true, 100, 100)
            if queried and success then slot, ok2 = 10, true end
        else
            for candidate = 1, 9 do
                local queried, current = safeServerQuery("getCharacterItem", charId, candidate)
                -- Equipment id 0 (or nil, if the query came back empty) means that
                -- slot genuinely has nothing in it. If the query itself failed
                -- (API unavailable), try the slot anyway rather than skipping it.
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
            -- Charged ONLY here, after the equip is confirmed successful -- a failed
            -- attempt below never touches the wallet at all.
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

    -- MODERATOR (admin OR moderator) -------------------------------------------
    -- Own inline permission check rather than the ADMIN_CMDS gate below, since
    -- moderators (not full admins) need this one command to work.
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
        -- NOTE: onCustomCommand only ever gives 3 args total, so a reason is capped at
        -- arg2+arg3 (~2 words) -- there's no "rest of the message" the engine hands us.
        local reasonParts = {}
        if arg2 then reasonParts[#reasonParts + 1] = tostring(arg2) end
        if arg3 then reasonParts[#reasonParts + 1] = tostring(arg3) end
        local reason = #reasonParts > 0 and table.concat(reasonParts, " ") or nil
        warnPlayer(target, reason, p.name)
        return
    end

    -- ?msg <player> <text> -- a private message. server.announce's third argument
    -- targets ONE specific peer_id instead of broadcasting to everyone (-1 does that;
    -- a real peer_id doesn't) -- other players never see this line at all, it's not
    -- just hidden from their screen. Still logged at debug level 3, so only admins/
    -- moderators actively streaming ?dbg 3+ can see that it happened, and even then
    -- only from the log line below, not from anything shown in normal chat.
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

    -- ADMIN -------------------------------------------------------------------
    if not p.is_admin then
        -- Hide admin commands from non-admins: treat them as unknown.
        if ADMIN_CMDS[command] then
            notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
            dbgLog(3, "PERM", p.name .. " [" .. rankOf(p) .. "] denied " .. command .. ", not admin")
            return
        end
        -- non-admin unknowns fall through to the unknown-command handler at the end
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
            frozen[target] = { mode = "orbit", anchor = peer_id, angle = 0 }
            say(peer_id, "Now holding " .. players[target].name .. ", they'll orbit you.")
            notify(target, "On A Leash", "An admin is holding you, you're now orbiting them.", "RED")
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
            -- No verify-then-act here (unlike ?tpp/?bring): a NaN position IS the goal,
            -- there's nothing meaningful to read back. Still routed through safeServer so
            -- a missing API is a logged no-op, not a script-killing crash, and so we only
            -- announce the ejection once the call actually went through.
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
            tp.revoked = true                               -- they now need ?auth to get back in, not ?noworkshop -- see ?auth's handler
            server.removeAuth(target)
            local removed = destroyAllGroupsOf(tp.steam_id) -- de-authed players don't keep their vehicles
            say(peer_id, "Revoked auth from " .. tp.name .. " and removed " .. removed .. " of their creation(s).")
            notify(target, "Auth Revoked",
                "An admin revoked your auth.\nYour vehicles have been removed.\nType ?auth to re-request access.",
                "RED")
            refreshUI(target, lastPlayerCount) -- instant -- the auth screen should reappear for them right away
            dbgLog(3, "ADMIN", p.name .. " ran ?revoke -> " .. tp.name .. " (removed " .. removed .. ")")
            return
        end

        -- ?setlimit <n>			  -> ONE arg = global limit.
        -- ?setlimit <peer_id|name> <n> -> TWO args = that player's limit. Decided purely
        -- by whether arg2 was given, NOT by whether arg1 parses as a number -- a player
        -- with a numeric-looking name (e.g. "123") used to get misread as a global-limit
        -- call instead of a target name.
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

        -- ?flares -- despawns any tracked loose equipment (flares, coal, dropped
        -- weapons, anything not attached to a vehicle or held by a character). Dropped
        -- items already despawn on their own via onEquipmentDrop (see CONFIG's comment),
        -- so under normal play this list should already be empty by the time anyone runs
        -- this. It exists as a manual retry for anything that failed to despawn on its
        -- own. There's no API to scan the whole map for objects, so this can only act on
        -- equipment this script has actually seen dropped since it last loaded - it
        -- can't reach items that were already on the ground before that.
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

        -- ?announce <message> -- broadcasts a plain chat line AND a green toast to
        -- everyone online. onCustomCommand only ever gives 3 args total, so the message
        -- is whatever's in arg1/arg2/arg3 joined with spaces - about 3 words. Longer
        -- messages need to be split across multiple ?announce calls.
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

        -- ?dbg <0-5|off> -- sets THIS admin's live debug-stream level (see dbgLog() above
        -- for what each level means). Replaces the old one-shot dump: instead of a single
        -- snapshot on demand, picking a level streams every matching event to you live,
        -- for as long as it's set, until you turn it back off.
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

        -- ?antilag: no argument manually triggers a normal-tier cull check right now
        -- (same worst-group logic the TPS loop uses, run on demand). ?antilag <n> sets
        -- the live normal-tier TPS threshold, clamped 10-50 -- critical tier is fixed.
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
                        "and will be removed in " .. CONFIG.ANTILAG_COUNTDOWN_SEC .. "s.", "YELLOW")
                end
                -- cancelIfHealthy = FALSE on purpose: a manual admin trigger must be
                -- UNCONDITIONAL. If this were true, the countdown block would spare the
                -- group the instant it saw TPS was healthy (the normal case when an admin
                -- runs this deliberately), so the command would claim to cull and then
                -- silently do nothing. False means it removes after the countdown no
                -- matter what TPS does.
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

    -- UNKNOWN COMMAND ---------------------------------------------------------
    if not KNOWN_CMDS[command] then
        notify(peer_id, "Unknown Command", command .. " is not a command. Try ?help", "YELLOW")
        dbgLog(3, "CMD", p.name .. " [" .. rankOf(p) .. "] used unknown command " .. command)
    end
end
