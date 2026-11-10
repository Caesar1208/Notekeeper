--------------------------------------------------------------------------------
-- Popup: a reminder in a classic dialog box near the top of the screen.
--
-- A note's own condition shows the whole note: its text and its checklist.
-- A task's condition shows just that task (and any others of the note that went off
-- at the same moment). Done ticks off what was shown: the note, or those tasks.
-- Later leaves it for next time. Tasks can be ticked right on the popup, and the
-- note's title opens it in the notebook. Several reminders queue up; in combat they
-- wait until it's over.
--------------------------------------------------------------------------------

local _, NK = ...

local MAX_TASKS = 8
local TASK_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"

-- { note, whole = bool, tasks = { [i] = true }, why }: the first one is shown
local queue = {}
local frame

local function Sound(note) NK.PlaySound(NK.ReminderSound(note)) end

-- the tasks a reminder shows, in order: all of them for a whole note, else the ones that went off
local function Shown(item)
	local list = {}
	local tasks = item.note.tasks or {}
	for i = 1, #tasks do
		if item.whole or item.tasks[i] then list[#list + 1] = i end
	end
	return list
end

-- a task reminder whose tasks are all ticked has done its job
local function Finished(item)
	local note = item.note
	if note.id ~= -1 and (not NK.db.notes[note.id] or note.archived or note.done) then return true end
	if item.whole then return false end
	for i in pairs(item.tasks) do
		local t = note.tasks and note.tasks[i]
		if t and not t.done then return false end
	end
	return true
end

--------------------------------------------------------------------------------
-- The box
--------------------------------------------------------------------------------

local Render, Next

local function Button(text, w)
	local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	b:SetSize(w or 90, 22)
	b:SetText(text)
	return b
end

local function Tip(b, fn)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(fn(), 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
end

local function Build()
	frame = CreateFrame("Frame", "NotekeeperPopup", UIParent, "BackdropTemplate")
	frame:SetSize(360, 150)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		NK.db.settings.popupPos = { point, x, y }
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})

	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetTexture(NK.ICON)
	frame.icon:SetSize(36, 36)
	frame.icon:SetPoint("TOPLEFT", 20, -20)
	local ring = frame:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	ring:SetSize(60, 60)
	ring:SetPoint("CENTER", frame.icon, "CENTER", 0, 0)

	-- the title: opens the note in the notebook
	local tb = CreateFrame("Button", nil, frame)
	tb:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 10, 0)
	tb:SetPoint("RIGHT", -36, 0)
	tb:SetHeight(20)
	frame.title = tb:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	frame.title:SetAllPoints()
	frame.title:SetJustifyH("LEFT")
	frame.title:SetWordWrap(false)
	tb:SetScript("OnClick", function()
		local item = queue[1]
		if item and NK.ShowNote then NK.ShowNote(item.note) end
	end)
	tb:SetScript("OnEnter", function(self)
		frame.title:SetTextColor(1, 1, 1)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Open in Notekeeper", 1, 1, 1)
		GameTooltip:Show()
	end)
	tb:SetScript("OnLeave", function()
		frame.title:SetTextColor(1, 0.82, 0)
		GameTooltip:Hide()
	end)
	frame.titleButton = tb

	frame.why = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.why:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 0, -1)
	frame.why:SetPoint("RIGHT", -24, 0)
	frame.why:SetJustifyH("LEFT")

	frame.body = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	frame.body:SetPoint("TOPLEFT", frame.icon, "BOTTOMLEFT", 0, -12)
	frame.body:SetPoint("RIGHT", -22, 0)
	frame.body:SetJustifyH("LEFT")
	frame.body:SetJustifyV("TOP")
	frame.body:SetSpacing(2)

	frame.lines = {}
	frame.more = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.count = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.count:SetPoint("BOTTOMLEFT", 22, 24)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	close:SetScript("OnClick", function() NK.PopupLater() end)

	frame.later = Button("Later")
	frame.later:SetPoint("BOTTOMRIGHT", -20, 18)
	frame.later:SetScript("OnClick", function() NK.PopupLater() end)
	Tip(frame.later, function()
		local item = queue[1]
		return item and item.whole and item.note.repeating and "Close it; it'll pop up again next time" or "Remind me again next time"
	end)

	frame.done = Button("Done")
	frame.done:SetPoint("RIGHT", frame.later, "LEFT", -6, 0)
	frame.done:SetScript("OnClick", function() NK.PopupDone() end)
	Tip(frame.done, function()
		local item = queue[1]
		if not item then return "Done" end
		if not item.whole then return "Tick off " .. (#Shown(item) == 1 and "this task" or "these tasks") end
		return item.note.repeating and "Stop reminding me (tick it off)" or "Tick the note off"
	end)

	local pos = NK.db.settings.popupPos
	if pos then frame:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
	else frame:SetPoint("TOP", UIParent, "TOP", 0, -170) end
	frame:Hide()
end

-- a task's line on the popup: a tick box, its text, a ! when it's what went off
local function Line(i)
	local c = frame.lines[i]
	if c then return c end
	c = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	c:SetSize(20, 20)
	c.mark = c:CreateTexture(nil, "ARTWORK")
	c.mark:SetTexture(TASK_ICON)
	c.mark:SetSize(13, 13)
	c.mark:SetPoint("LEFT", c, "RIGHT", 0, 0)
	c.text = c:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	c.text:SetPoint("RIGHT", frame, "RIGHT", -22, 0)
	c.text:SetJustifyH("LEFT")
	c.text:SetWordWrap(false)
	c:SetScript("OnClick", function(self)
		local item = queue[1]
		if not item then return end
		self.text:SetTextColor(self:GetChecked() and 0.5 or 1, self:GetChecked() and 0.5 or 1, self:GetChecked() and 0.5 or 1)
		NK.SetTaskDone(item.note, self.index, self:GetChecked())
		-- (all the shown tasks ticked: on to the next reminder)
		if queue[1] == item and Finished(item) then Next() end
	end)
	frame.lines[i] = c
	return c
end

Render = function()
	local item = queue[1]
	if not item then if frame then frame:Hide() end return end
	if InCombatLockdown() then return end                       -- (PLAYER_REGEN_ENABLED shows it)
	if not frame then Build() end
	local note = item.note
	frame.title:SetText(NK.Title(note))
	frame.why:SetText(item.why or "")

	-- the text: for the whole note only (a task's reminder is about the task)
	local body = ""
	if item.whole then
		body = (note.body or ""):match("^%s*(.-)%s*$")
		if (note.title or ""):match("^%s*$") then body = body:gsub("^[^\n]*\n?", "", 1) end   -- (its first line is the title)
		if #body > 400 then body = body:sub(1, 400) .. "..." end
	end
	frame.body:SetText(body)
	local height = 20 + 36 + 12 + (body ~= "" and (frame.body:GetStringHeight() + 12) or 0)

	-- the tasks
	local list = Shown(item)
	local count = math.min(#list, MAX_TASKS)
	local anchor = body ~= "" and frame.body or frame.icon
	for n = 1, count do
		local i = list[n]
		local t = note.tasks[i]
		local c = Line(n)
		c.index = i
		c:ClearAllPoints()
		c:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", n == 1 and -2 or 0, n == 1 and -6 or 0)
		c:SetChecked(t.done and true or false)
		local marked = item.tasks[i] and true or false
		c.mark:SetShown(marked)
		c.text:ClearAllPoints()
		c.text:SetPoint("LEFT", c, "RIGHT", marked and 14 or 2, 1)
		c.text:SetPoint("RIGHT", frame, "RIGHT", -22, 0)
		c.text:SetText(t.text ~= "" and t.text or "...")
		local g = t.done and 0.5 or 1
		c.text:SetTextColor(g, g, g)
		c:Show()
		anchor = c
	end
	for n = count + 1, #frame.lines do frame.lines[n]:Hide() end
	frame.more:ClearAllPoints()
	frame.more:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", count > 0 and 24 or 0, -2)
	frame.more:SetText(#list > count and ("+ " .. (#list - count) .. " more in the notebook") or "")
	height = height + (count > 0 and (count * 20 + 6) or 0) + (#list > count and 16 or 0)

	frame.count:SetText(#queue > 1 and ("1 of " .. #queue) or "")
	local repeating = item.whole and note.repeating
	frame.done:SetText(repeating and "Stop" or "Done")
	frame.later:SetText(repeating and "OK" or "Later")
	frame:SetHeight(math.max(118, math.min(height + 48, 460)))
	if not frame:IsShown() then
		frame:Show()
		Sound(note)
	end
end

Next = function()
	table.remove(queue, 1)
	if frame then frame:Hide() end
	Render()
end

--------------------------------------------------------------------------------
-- In and out of the queue
--------------------------------------------------------------------------------

-- Conditions.lua: trig = { whole, tasks = { i, ... }, why }. One reminder per note:
-- a note that's waiting already takes the new tasks in.
function NK.Remind(note, trig)
	if not NK.db.settings.popups then
		NK.Print("|cffffffff%s|r  (%s)", NK.Title(note), trig.why or "")
		Sound(note)
		return
	end
	for n, item in ipairs(queue) do
		if item.note == note then
			item.whole = item.whole or trig.whole
			for _, i in ipairs(trig.tasks or {}) do item.tasks[i] = true end
			if n == 1 and frame and frame:IsShown() then Render() end
			return
		end
	end
	local item = { note = note, whole = trig.whole and true or false, tasks = {}, why = trig.why }
	for _, i in ipairs(trig.tasks or {}) do item.tasks[i] = true end
	queue[#queue + 1] = item
	if #queue == 1 then Render() elseif frame and frame:IsShown() then frame.count:SetText("1 of " .. #queue) end
end

-- Done (a repeating note's Stop): ticks off what the reminder was about
function NK.PopupDone()
	local item = table.remove(queue, 1)
	if not item then return end
	if frame then frame:Hide() end
	if item.whole then
		NK.SetDone(item.note, true)
	else
		for i in pairs(item.tasks) do NK.SetTaskDone(item.note, i, true) end
	end
	Render()
end

function NK.PopupLater()
	local item = queue[1]
	if item then
		local tasks = {}
		for i in pairs(item.tasks) do tasks[#tasks + 1] = i end
		NK.Snooze(item.note, item.whole, tasks)
	end
	Next()
end

function NK.TestPopup()
	NK.Remind({ id = -1, title = "Example reminder", when = "",
		body = "This is how a note looks when its condition happens. Done ticks it off; Later keeps it for next time.",
		tasks = { { text = "Tasks can be ticked off right here" }, { text = "Like this one", done = true } },
	}, { whole = true, why = "Entered Stormwind City" })
end

-- notes ticked, archived or deleted elsewhere drop out of the queue, and so do task
-- reminders whose tasks were all ticked
NK.OnChange(function()
	local first = queue[1]
	for n = #queue, 1, -1 do
		if Finished(queue[n]) then table.remove(queue, n) end
	end
	if queue[1] ~= first then
		if frame then frame:Hide() end
		Render()
	elseif first and frame and frame:IsShown() then
		Render()                                  -- (a task ticked in the notebook: the box follows)
	end
end)

local combat = CreateFrame("Frame")
combat:RegisterEvent("PLAYER_REGEN_ENABLED")
combat:SetScript("OnEvent", function() if queue[1] and not (frame and frame:IsShown()) then Render() end end)
