--------------------------------------------------------------------------------
-- Conditions: when a note, or one task in it, pops up. A "when" is a list of tags,
-- separated by commas or new lines; any one of them happening is enough:
--
--   zone:Stormwind      entering a zone or area whose name has this in it
--   city                entering any city or inn (anywhere you rest)
--   dungeon             entering any dungeon or raid   (dungeon:Deadmines: that one)
--   level:20            reaching level 20 (and every login after, until it's done)
--   login               logging in
--   vendor  bank  mail  auction  trainer  flight
--                       opening one of those    (vendor:Haggle: that vendor)
--   target:Hogger       targeting someone with this in their name
--
-- Names are matched loosely: case doesn't matter and part of a name is enough.
-- A leading # or @ is fine too (#city), and "area", "inn", "instance", "mailbox",
-- "ah" and "taxi" work as other names for zone, city, dungeon, mail, auction, flight.
--------------------------------------------------------------------------------

local _, NK = ...

-- kind -> arg: "text" or "number"; needs: the arg is required; says: the popup's "why"
NK.KINDS = {
	zone    = { arg = "text", needs = true, says = "Entered %s", phrase = "entering %s" },
	city    = { says = "Entered a city or inn", phrase = "entering a city or inn" },
	dungeon = { arg = "text", says = "Entered %s", phrase = "entering a dungeon" },
	level   = { arg = "number", needs = true, says = "Reached level %s", phrase = "reaching level %s" },
	login   = { says = "Logged in", phrase = "logging in" },
	vendor  = { arg = "text", says = "At a vendor", phrase = "at a vendor" },
	bank    = { says = "At the bank", phrase = "at the bank" },
	mail    = { says = "At a mailbox", phrase = "at a mailbox" },
	auction = { says = "At the auction house", phrase = "at the auction house" },
	trainer = { arg = "text", says = "At a trainer", phrase = "at a trainer" },
	flight  = { says = "At a flight master", phrase = "at a flight master" },
	target  = { arg = "text", needs = true, says = "Targeted %s", phrase = "targeting %s" },
}
local ALIAS = {
	area = "zone", subzone = "zone", rest = "city", inn = "city", town = "city", instance = "dungeon",
	raid = "dungeon", mailbox = "mail", ah = "auction", taxi = "flight", flightmaster = "flight",
	merchant = "vendor", lvl = "level",
}

-- "zone:Stormwind, level:20" -> { { kind = "zone", arg = "Stormwind" }, { kind = "level", arg = 20 } },
-- and the parts it couldn't read
local function Parse(when)
	local conds, bad = {}, {}
	for part in (when or ""):gmatch("[^,;\n]+") do
		part = part:match("^%s*(.-)%s*$"):gsub("^[#@]", "")
		if part ~= "" then
			local kind, arg = part:match("^([%a]+)%s*:%s*(.-)$")
			kind = (kind or part):lower()
			kind = ALIAS[kind] or kind
			local spec = NK.KINDS[kind]
			if arg == "" then arg = nil end
			if spec and spec.arg == "number" then arg = tonumber(arg) end
			if not spec or (spec.needs and arg == nil) or (arg ~= nil and not spec.arg) then
				bad[#bad + 1] = part
			else
				conds[#conds + 1] = { kind = kind, arg = arg }
			end
		end
	end
	return conds, bad
end
NK.Parse = Parse

-- read once per text (notes and tasks share it)
local cache = {}
function NK.CondsOf(when)
	if not when or when == "" then return {} end
	local c = cache[when]
	if not c then c = Parse(when) cache[when] = c end
	return c
end

-- a note that can pop up: by its own conditions, or an open task's
function NK.HasConditions(note)
	if #NK.CondsOf(note.when) > 0 then return true end
	for _, t in ipairs(note.tasks or {}) do
		if not t.done and #NK.CondsOf(t.when) > 0 then return true end
	end
	return false
end

-- a condition in the editor's words: "entering Stormwind", "at a vendor (Haggle)"
function NK.Phrase(cond)
	local spec = NK.KINDS[cond.kind]
	local p = spec and spec.phrase or cond.kind
	if p:find("%%s") then return p:format(tostring(cond.arg)) end
	if cond.kind == "dungeon" and cond.arg then return "entering " .. cond.arg end
	if cond.arg then return p .. " (" .. cond.arg .. ")" end
	return p
end

-- what happened, in the popup's words: "Entered Stormwind City", "At a vendor (Haggle)"
function NK.Says(cond, value)
	local spec = NK.KINDS[cond.kind]
	local s = spec and spec.says or cond.kind
	if s:find("%%s") then return s:format(tostring(value or cond.arg or "")) end
	if type(value) == "string" and value ~= "" then return s .. " (" .. value .. ")" end
	return s
end

local function Matches(cond, value)
	if cond.kind == "level" then return type(value) == "number" and value >= cond.arg end
	if cond.arg == nil then return true end
	return type(value) == "string" and value:lower():find(cond.arg:lower(), 1, true) ~= nil
end

-- the first of a "when"'s conditions this event matches
local function Hit(when, kind, value)
	for _, cond in ipairs(NK.CondsOf(when)) do
		if cond.kind == kind and Matches(cond, value) then return cond end
	end
end

--------------------------------------------------------------------------------
-- Firing: each note (whole) and each task has its own cooldown, so subzones that
-- flicker don't pop the same thing up twice
--------------------------------------------------------------------------------

local COOLDOWN = 60
local lastShown = {}
local function Key(note, i) return note.id .. ":" .. (i or 0) end
local function Ready(note, i) return GetTime() - (lastShown[Key(note, i)] or -COOLDOWN) >= COOLDOWN end

local function Fire(kind, value)
	if not NK.db then return end
	for _, note in pairs(NK.db.notes) do
		if not note.archived and not note.done and NK.Visible(note) then
			local why
			local whole = false
			local cond = Hit(note.when, kind, value)
			if cond and Ready(note) then whole, why = true, NK.Says(cond, value) end
			local tasks = {}
			for i, t in ipairs(note.tasks or {}) do
				if not t.done then
					local tc = Hit(t.when, kind, value)
					if tc and Ready(note, i) then
						tasks[#tasks + 1] = i
						why = why or NK.Says(tc, value)
					end
				end
			end
			if whole or #tasks > 0 then
				local now = GetTime()
				if whole then lastShown[Key(note)] = now end
				for _, i in ipairs(tasks) do lastShown[Key(note, i)] = now end
				if NK.Remind then NK.Remind(note, { whole = whole, tasks = tasks, why = why }) end
			end
		end
	end
end
NK.Fire = Fire

-- "Later" on the popup: quiet for the cooldown from now
function NK.Snooze(note, whole, tasks)
	if whole then lastShown[Key(note)] = GetTime() end
	for _, i in ipairs(tasks or {}) do lastShown[Key(note, i)] = GetTime() end
end

--------------------------------------------------------------------------------
-- The game's events -> Fire
--------------------------------------------------------------------------------

local lastZone, lastSub, wasResting, wasInside, lastTarget
local events = CreateFrame("Frame")

local function Where(quiet)
	local zone = GetRealZoneText and GetRealZoneText() or GetZoneText()
	local sub = GetSubZoneText and GetSubZoneText() or ""
	if zone and zone ~= "" and zone ~= lastZone then
		lastZone = zone
		if not quiet then Fire("zone", zone) end
	end
	if sub ~= lastSub then
		lastSub = sub
		if sub ~= "" and not quiet then Fire("zone", sub) end
	end
	local resting = IsResting() and true or false
	if resting and not wasResting and not quiet then Fire("city", sub ~= "" and sub or zone) end
	wasResting = resting
	local inside, kind = IsInInstance()
	inside = inside and (kind == "party" or kind == "raid")
	if inside and not wasInside and not quiet then Fire("dungeon", zone) end
	wasInside = inside
end

local NPC = {
	MERCHANT_SHOW = "vendor", BANKFRAME_OPENED = "bank", MAIL_SHOW = "mail",
	AUCTION_HOUSE_SHOW = "auction", TRAINER_SHOW = "trainer", TAXIMAP_OPENED = "flight",
}

events:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" then
		local initial, reloading = ...
		-- (a /reload isn't arriving anywhere: just note where we are)
		Where(reloading and not initial)
		if initial then
			Fire("login")
			Fire("level", UnitLevel("player"))
		end
	elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS"
		or event == "PLAYER_UPDATE_RESTING" then
		Where(false)
	elseif event == "PLAYER_LEVEL_UP" then
		Fire("level", (...))
	elseif event == "PLAYER_TARGET_CHANGED" then
		local name = UnitName("target")
		if name and name ~= lastTarget then Fire("target", name) end
		lastTarget = name
	elseif NPC[event] then
		Fire(NPC[event], UnitName("npc") or "")
	end
end)

function NK.StartTriggers()
	for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
		"PLAYER_UPDATE_RESTING", "PLAYER_LEVEL_UP", "PLAYER_TARGET_CHANGED" }) do
		events:RegisterEvent(e)
	end
	for e in pairs(NPC) do pcall(events.RegisterEvent, events, e) end   -- (one a client lacks is skipped)
end

--------------------------------------------------------------------------------
-- The editor's "Add" menu: each entry's tag, filled in from where you are
--------------------------------------------------------------------------------

function NK.ConditionChoices()
	local zone = GetRealZoneText and GetRealZoneText() or ""
	local sub = GetSubZoneText and GetSubZoneText() or ""
	local level = UnitLevel("player") or 1
	local target = UnitName("target")
	local list = {}
	local function add(text, tag) list[#list + 1] = { text = text, tag = tag } end
	if zone ~= "" then add("Entering " .. zone, "zone:" .. zone) end
	if sub ~= "" and sub ~= zone then add("Entering " .. sub, "zone:" .. sub) end
	add("Entering any city or inn", "city")
	add("Entering any dungeon", "dungeon")
	local max = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
	if level < max then add("Reaching level " .. (level + 1), "level:" .. (level + 1)) end
	if target then add("Targeting " .. target, "target:" .. target) end
	add("Logging in", "login")
	list[#list + 1] = { divider = true }
	add("At a vendor", "vendor")
	add("At the bank", "bank")
	add("At a mailbox", "mail")
	add("At the auction house", "auction")
	add("At a trainer", "trainer")
	add("At a flight master", "flight")
	return list
end
