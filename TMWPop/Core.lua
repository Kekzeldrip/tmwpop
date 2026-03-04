--[[--------------------------------------------------------------------
    TMWPop – Core.lua
    Addon bootstrap, event bus, and slash-command handling.
----------------------------------------------------------------------]]

--- Global addon table --------------------------------------------------
TMWPop = TMWPop or {}
TMWPop.version = "0.1.0"

--- Saved-variable defaults ---------------------------------------------
local DEFAULTS = {
    profile    = "",   -- raw SimC profile text
    enabled    = true,
    iconScale  = 1.0,
    iconAlpha  = 1.0,
    locked     = false,
}

--- Internal state ------------------------------------------------------
local listeners = {}   -- event -> { callback, ... }

--[[--------------------------------------------------------------------
    Event Bus – lightweight pub/sub used by every module
----------------------------------------------------------------------]]

--- Register a callback for one or more events.
--- @param events string|table  single event name or list of names
--- @param fn     function      callback(event, ...)
function TMWPop.RegisterEvent(events, fn)
    if type(events) == "string" then events = { events } end
    for _, ev in ipairs(events) do
        listeners[ev] = listeners[ev] or {}
        listeners[ev][#listeners[ev] + 1] = fn
    end
end

--- Fire an internal event.
--- @param event string
function TMWPop.FireEvent(event, ...)
    local cbs = listeners[event]
    if not cbs then return end
    for i = 1, #cbs do
        cbs[i](event, ...)
    end
end

--[[--------------------------------------------------------------------
    WoW Frame + Blizzard-event wiring
----------------------------------------------------------------------]]

local frame = CreateFrame("Frame", "TMWPopCoreFrame", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addon = ...
        if addon == "TMWPop" then
            -- Initialise saved variables
            if not TMWPopDB then TMWPopDB = {} end
            for k, v in pairs(DEFAULTS) do
                if TMWPopDB[k] == nil then TMWPopDB[k] = v end
            end
            TMWPop.db = TMWPopDB
            TMWPop.FireEvent("CORE_LOADED")
        end

    elseif event == "PLAYER_LOGIN" then
        TMWPop.FireEvent("PLAYER_READY")

    elseif event == "PLAYER_LOGOUT" then
        TMWPop.FireEvent("SHUTDOWN")
    end
end)

--[[--------------------------------------------------------------------
    Slash commands:  /tmwpop, /twp
----------------------------------------------------------------------]]

SLASH_TMWPOP1 = "/tmwpop"
SLASH_TMWPOP2 = "/twp"

SlashCmdList["TMWPOP"] = function(msg)
    local cmd = strtrim(msg):lower()

    if cmd == "" or cmd == "help" then
        print("|cff00ccffTMWPop v" .. TMWPop.version .. "|r")
        print("  /twp import   – open profile import window")
        print("  /twp toggle   – enable / disable recommendations")
        print("  /twp lock     – lock / unlock icon position")
        print("  /twp reset    – reset icon position to centre")

    elseif cmd == "import" then
        TMWPop.FireEvent("SHOW_IMPORT")

    elseif cmd == "toggle" then
        TMWPop.db.enabled = not TMWPop.db.enabled
        print("|cff00ccffTMWPop|r " .. (TMWPop.db.enabled and "enabled" or "disabled"))

    elseif cmd == "lock" then
        TMWPop.db.locked = not TMWPop.db.locked
        TMWPop.FireEvent("LOCK_CHANGED", TMWPop.db.locked)
        print("|cff00ccffTMWPop|r icon " .. (TMWPop.db.locked and "locked" or "unlocked"))

    elseif cmd == "reset" then
        TMWPop.FireEvent("RESET_POSITION")

    else
        print("|cff00ccffTMWPop|r: unknown command – type /twp help")
    end
end
