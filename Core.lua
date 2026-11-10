--------------------------------------------------------------------------------
-- Notekeeper: notes and tasks, auto-archived, that can pop up on conditions.
-- Core: saved data, the notes themselves, archiving, slash commands, minimap button.
--------------------------------------------------------------------------------

local ADDON, NK = ...
_G.Notekeeper = NK

NK.ACCENT = "ffd100"     -- the classic UI's gold
NK.ICON = "Interface\\Icons\\INV_Misc_Note_01"

function NK.Print(msg, ...)
	if select("#", ...) > 0 then msg = msg:format(...) end
	DEFAULT_CHAT_FRAME:AddMessage("|cff" .. NK.ACCENT .. "Notekeeper|r: " .. msg)
end

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

-- NotekeeperDB = { notes = { [id] = note }, nextId, settings = { ... } }
-- note = { id, title, body, when, tasks = { { text, done, when }, ... }, done, doneAt, created,
--          edited, archived, archivedAt, char ("Name-Realm": only that character; nil: every
--          character), repeating }
local DEFAULTS = {
	archiveDone = 0,         -- seconds after a task is ticked off; 0: at once (a moment later); -1: never
	archiveIdle = -1,        -- days a note can sit untouched before it's archived; -1: never
	reminderSound = "TELL_MESSAGE",   -- a SOUNDKIT name, or "none"; a note's own `sound` overrides it
	trackerBg = 0.4,                  -- the on-screen notes' background: 0 (none) .. 0.75
	popups = true,
	minimap = { angle = 215, hide = false },
	popupPos = nil,          -- { point, x, y } once the popup's been dragged
	windowPos = nil,
}

local function Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then t[k] = Fill({}, v) else t[k] = v end
		elseif type(v) == "table" and type(t[k]) == "table" then
			Fill(t[k], v)
		end
	end
	return t
end

function NK.Me()
	local name, realm = UnitFullName("player")
	if not realm or realm == "" then realm = GetRealmName() or "" end
	return (name or "?") .. "-" .. realm:gsub("%s", "")
end

--------------------------------------------------------------------------------
-- Notes
--------------------------------------------------------------------------------

local listeners = {}
-- something changed (a note added, edited, ticked, archived): the window and the triggers refresh
function NK.OnChange(fn) listeners[#listeners + 1] = fn end
function NK.Changed(note)
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, note)
		if not ok then geterrorhandler()(err) end
	end
end

-- the notes this character sees: its own and the shared ones
function NK.Visible(note)
	return note.char == nil or note.char == NK.Me()
end

-- notes in the list order: newest first (by when they were made)
function NK.List(archived)
	local list = {}
	for _, note in pairs(NK.db.notes) do
		if (note.archived and true or false) == (archived and true or false) and NK.Visible(note) then
			list[#list + 1] = note
		end
	end
	table.sort(list, function(a, b)
		if archived then return (a.archivedAt or 0) > (b.archivedAt or 0) end
		if (a.done and 1 or 0) ~= (b.done and 1 or 0) then return not a.done end   -- (open tasks above done ones)
		return (a.created or 0) > (b.created or 0)
	end)
	return list
end

function NK.Title(note)
	local t = note.title and note.title:match("^%s*(.-)%s*$") or ""
	if t ~= "" then return t end
	local first = (note.body or ""):match("^%s*([^\n]+)")
	if first and first ~= "" then return first:sub(1, 60) end
	local task = note.tasks and note.tasks[1]
	if task and task.text ~= "" then return task.text:sub(1, 60) end
	return "(untitled)"
end

function NK.New(title, body, when)
	local db = NK.db
	local now = time()
	local note = {
		id = db.nextId, title = title or "", body = body or "", when = when or "",
		created = now, edited = now, char = NK.Me(),
	}
	db.notes[note.id] = note
	db.nextId = db.nextId + 1
	NK.Changed(note)
	return note
end

function NK.Edit(note, field, value)
	if note[field] == value then return end
	note[field] = value
	note.edited = time()
	NK.Changed(note)
end

local function ArchiveNow(note)
	if note.archived then return end
	note.archived, note.archivedAt = true, time()
	NK.Changed(note)
end

function NK.SetDone(note, done)
	done = done and true or false
	if (note.done and true or false) == done then return end
	note.done = done
	note.doneAt = done and time() or nil
	NK.Changed(note)
	-- (archived "at once": after a moment, so the tick is seen and can be undone)
	local delay = NK.db.settings.archiveDone
	if done and delay == 0 then
		C_Timer.After(1.5, function() if note.done and not note.archived then ArchiveNow(note) end end)
	elseif done and delay > 0 and delay <= 600 then
		-- (a short delay: right on time, not at the next minute's sweep)
		C_Timer.After(delay + 0.5, NK.Sweep)
	end
end

function NK.Archive(note) ArchiveNow(note) end

--------------------------------------------------------------------------------
-- Tasks: a note's checklist (note.tasks = { { text, done, when }, ... }), like a story's
-- subtasks, each with conditions of its own if you like. Ticking the last one ticks
-- the note; unticking one (or adding an open one) unticks it again.
--------------------------------------------------------------------------------

local function Tasks(note) note.tasks = note.tasks or {} return note.tasks end

function NK.Progress(note)
	local done, total = 0, 0
	for _, t in ipairs(note.tasks or {}) do
		total = total + 1
		if t.done then done = done + 1 end
	end
	return done, total
end

function NK.AddTask(note, text, at, done)
	local tasks = Tasks(note)
	at = math.max(1, math.min(at or #tasks + 1, #tasks + 1))
	table.insert(tasks, at, { text = text or "", done = done or nil })
	note.edited = time()
	NK.Changed(note)
	if note.done and not done then NK.SetDone(note, false) end
	return at
end

-- a task's text or its conditions ("when", the same tags as a note's)
function NK.EditTask(note, i, field, value)
	local t = Tasks(note)[i]
	if not t or t[field] == value then return end
	t[field] = value
	note.edited = time()
	NK.Changed(note)
end
function NK.SetTaskText(note, i, text) NK.EditTask(note, i, "text", text) end

function NK.SetTaskDone(note, i, done)
	local t = Tasks(note)[i]
	if not t then return end
	t.done = done and true or nil
	note.edited = time()
	NK.Changed(note)
	local d, n = NK.Progress(note)
	if n > 0 and d == n then NK.SetDone(note, true)
	elseif note.done and not done then NK.SetDone(note, false) end
end

function NK.RemoveTask(note, i)
	local tasks = Tasks(note)
	if not tasks[i] then return end
	table.remove(tasks, i)
	note.edited = time()
	NK.Changed(note)
end

-- the note's text, one task per line, moved into its checklist ("- ", "* ", "[ ]" and "[x]" understood)
function NK.LinesToTasks(note)
	local added = 0
	for line in ((note.body or "") .. "\n"):gmatch("([^\n]*)\n") do
		local text = line:match("^%s*(.-)%s*$")
		if text ~= "" then
			local done = text:match("^%[[xX]%]") ~= nil
			text = text:gsub("^[-*]%s+", ""):gsub("^%[[ xX]?%]%s*", "")
			if text ~= "" then
				local tasks = Tasks(note)
				tasks[#tasks + 1] = { text = text, done = done or nil }
				added = added + 1
			end
		end
	end
	if added == 0 then return 0 end
	note.body = ""
	note.edited = time()
	NK.Changed(note)
	local d, n = NK.Progress(note)
	if n > 0 and d == n then NK.SetDone(note, true) end
	return added
end

function NK.Restore(note)
	if not note.archived then return end
	note.archived, note.archivedAt = nil, nil
	note.done, note.doneAt = nil, nil
	note.edited = time()      -- (so the idle rule doesn't archive it again straight away)
	NK.Changed(note)
end

function NK.Delete(note)
	NK.db.notes[note.id] = nil
	NK.Changed(nil)
end

-- the archiving rules, run now and then: done tasks after their delay, idle notes after theirs
function NK.Sweep()
	local s, now = NK.db.settings, time()
	for _, note in pairs(NK.db.notes) do
		if not note.archived then
			if note.done then
				if s.archiveDone >= 0 and now - (note.doneAt or now) >= s.archiveDone then ArchiveNow(note) end
			elseif s.archiveIdle > 0 and not note.repeating then
				if now - (note.edited or now) >= s.archiveIdle * 86400 then ArchiveNow(note) end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Reminder sounds: the game's own; only the ones this client has are offered
--------------------------------------------------------------------------------

local SOUNDS = {
	{ "TELL_MESSAGE", "Whisper" },
	{ "READY_CHECK", "Ready check" },
	{ "RAID_WARNING", "Raid warning" },
	{ "IG_QUEST_LIST_COMPLETE", "Quest complete" },
	{ "MAP_PING", "Map ping" },
	{ "AUCTION_WINDOW_OPEN", "Auction house bell" },
	{ "IG_PLAYER_INVITE", "Party invite" },
	{ "ALARM_CLOCK_WARNING_3", "Alarm clock" },
	{ "UI_RAID_BOSS_WHISPER_WARNING", "Boss whisper" },
	{ "LOOT_WINDOW_COIN_SOUND", "Coins" },
}

function NK.Sounds()
	local list = {}
	for _, s in ipairs(SOUNDS) do
		if SOUNDKIT and SOUNDKIT[s[1]] then list[#list + 1] = { key = s[1], label = s[2] } end
	end
	return list
end

function NK.SoundLabel(key)
	if key == "none" then return "No sound" end
	for _, s in ipairs(SOUNDS) do if s[1] == key then return s[2] end end
	return key or "?"
end

function NK.PlaySound(key)
	local kit = key and key ~= "none" and SOUNDKIT and SOUNDKIT[key]
	if kit then PlaySound(kit, "Master") end
end

-- a note's reminder sound: its own, else the default
function NK.ReminderSound(note)
	return (note and note.sound) or NK.db.settings.reminderSound
end

--------------------------------------------------------------------------------
-- Minimap button (classic round one; drag it around the minimap's edge)
--------------------------------------------------------------------------------

local mini
local function PlaceMini()
	local a = math.rad(NK.db.settings.minimap.angle or 215)
	local r = (Minimap:GetWidth() / 2) + 5
	mini:ClearAllPoints()
	mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function NK.UpdateMinimapButton()
	local hide = NK.db.settings.minimap.hide
	if hide then if mini then mini:Hide() end return end
	if not mini then
		mini = CreateFrame("Button", "NotekeeperMinimapButton", Minimap)
		mini:SetSize(31, 31)
		mini:SetFrameStrata("MEDIUM")
		mini:SetFrameLevel(8)
		mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		mini:RegisterForDrag("LeftButton")
		mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local bg = mini:CreateTexture(nil, "BACKGROUND")
		bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
		bg:SetSize(20, 20)
		bg:SetPoint("TOPLEFT", 7, -5)
		local icon = mini:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(NK.ICON)
		icon:SetSize(17, 17)
		icon:SetPoint("TOPLEFT", 7, -6)
		icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local border = mini:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		border:SetSize(53, 53)
		border:SetPoint("TOPLEFT")
		mini:SetScript("OnClick", function(_, button)
			if button == "RightButton" then NK.NewFromAnywhere() else NK.Toggle() end
		end)
		mini:SetScript("OnDragStart", function(self)
			self:SetScript("OnUpdate", function()
				local mx, my = Minimap:GetCenter()
				local cx, cy = GetCursorPosition()
				local scale = Minimap:GetEffectiveScale()
				NK.db.settings.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
				PlaceMini()
			end)
		end)
		mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		mini:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine("Notekeeper")
			local open = #NK.List(false)
			GameTooltip:AddLine(open == 1 and "1 note" or (open .. " notes"), 1, 1, 1)
			GameTooltip:AddLine("|cff00ff00Click|r to open, |cff00ff00right-click|r for a new note, drag to move.", 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		mini:SetScript("OnLeave", GameTooltip_Hide)
	end
	PlaceMini()
	mini:Show()
end

--------------------------------------------------------------------------------
-- Opening the window (UI.lua fills these in), keybinding, slash commands
--------------------------------------------------------------------------------

function NK.Toggle() if NK.ToggleWindow then NK.ToggleWindow() end end
function NK.NewFromAnywhere(title)
	if NK.OpenNewNote then NK.OpenNewNote(title) end
end

_G.Notekeeper_Toggle = function() NK.Toggle() end
_G.BINDING_HEADER_NOTEKEEPER = "Notekeeper"
_G.BINDING_NAME_NOTEKEEPER_TOGGLE = "Open / close Notekeeper"
_G.BINDING_NAME_NOTEKEEPER_NEW = "New note"

SLASH_NOTEKEEPER1 = "/nk"
SLASH_NOTEKEEPER2 = "/notekeeper"
SlashCmdList.NOTEKEEPER = function(msg)
	msg = (msg or ""):match("^%s*(.-)%s*$")
	local cmd, rest = msg:match("^(%S+)%s*(.*)$")
	cmd = cmd and cmd:lower()
	if not cmd then
		NK.Toggle()
	elseif cmd == "add" or cmd == "new" then
		if rest ~= "" then
			-- /nk add Buy arrows @vendor   (anything after an @ is its condition)
			local text, when = rest:match("^(.-)%s*@(.*)$")
			local note = NK.New(text or rest, "", when or "")
			NK.Print("added \"%s\"%s.", NK.Title(note), when and (" (" .. when .. ")") or "")
		else
			NK.NewFromAnywhere()
		end
	elseif cmd == "minimap" then
		NK.db.settings.minimap.hide = not NK.db.settings.minimap.hide
		NK.UpdateMinimapButton()
		NK.Print("minimap button %s.", NK.db.settings.minimap.hide and "hidden" or "shown")
	elseif cmd == "test" then
		if NK.TestPopup then NK.TestPopup() end
	else
		NK.Print("/nk: open the notebook")
		NK.Print("/nk add <text> [@condition]: a quick note, e.g. /nk add Buy arrows @vendor")
		NK.Print("/nk minimap: show or hide the minimap button")
		NK.Print("/nk test: show what a reminder looks like")
	end
end

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self, event, name)
	if event == "ADDON_LOADED" and name == ADDON then
		NotekeeperDB = NotekeeperDB or {}
		local db = NotekeeperDB
		db.notes = db.notes or {}
		db.nextId = db.nextId or 1
		db.settings = db.settings or {}
		-- (v0.1's sound on/off: off carries over as "no sound")
		if db.settings.sound == false and db.settings.reminderSound == nil then db.settings.reminderSound = "none" end
		db.settings.sound = nil
		Fill(db.settings, DEFAULTS)
		NK.db = db
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_LOGIN" then
		NK.Sweep()
		C_Timer.NewTicker(60, NK.Sweep)
		NK.UpdateMinimapButton()
		if NK.StartTriggers then NK.StartTriggers() end
		if NK.RefreshTracker then NK.RefreshTracker() end
	end
end)
