--------------------------------------------------------------------------------
-- UI: the notebook. A classic dialog-bordered window:
--   left:  the notes (Notes / Archive), with a ! for ones that can pop up and d/n for tasks
--   right: the chosen note on a quest-log parchment page: title, text, and its tasks
--   below: "Pop up when" for the note or for one of its tasks (whichever you're on:
--          click a task, or its !, to give it conditions of its own), and the note's ticks
-- Esc closes it; drag it by its edges to move it.
--------------------------------------------------------------------------------

local _, NK = ...

local W, H = 700, 560
local LIST_W = 214
local ROW_H, TASK_H = 20, 22
local INK = { 0.18, 0.11, 0.04 }            -- the quest log's dark brown
local MARK = "Interface\\GossipFrame\\AvailableQuestIcon"
local REPEAT_MARK = "Interface\\GossipFrame\\ActiveQuestIcon"

local win                                  -- the window, built on first opening
local view = "notes"                       -- "notes" or "archive"
local selected                             -- the note on the page
local target                               -- the task whose conditions are being edited (nil: the note's)
local loading = false                      -- (filling fields: their OnTextChanged isn't the player typing)

local function Sound(name)
	local kit = SOUNDKIT and SOUNDKIT[name]
	if kit then PlaySound(kit) end
end

local function Tip(owner, title, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(type(title) == "function" and title() or title, 1, 1, 1)
		local t = type(text) == "function" and text() or text
		if t then GameTooltip:AddLine(t, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", GameTooltip_Hide)
end

local function Inset(parent)
	local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	f:SetBackdropColor(0, 0, 0, 0.55)
	f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	return f
end

-- a scroll frame's bar only while there's something to scroll
local function AutoBar(scroll)
	local bar = scroll.ScrollBar
	if type(bar) ~= "table" then
		local name = scroll:GetName()
		bar = type(name) == "string" and _G[name .. "ScrollBar"]
	end
	if type(bar) ~= "table" or not bar.SetShown then return end
	local function update()
		local range = scroll:GetVerticalScrollRange() or 0
		bar:SetShown(range > 0.5)
	end
	scroll:HookScript("OnScrollRangeChanged", update)
	update()
end

-- a note with nothing in it at all: dropped when you move off it (no "(untitled)" litter)
local function Empty(note)
	return note and (note.title or ""):match("^%s*$") and (note.body or ""):match("^%s*$")
		and #(note.tasks or {}) == 0 and (note.when or ""):match("^%s*$") and true or false
end
local function Discard(note)
	if note and NK.db.notes[note.id] and Empty(note) then NK.Delete(note) end
end

local function Check(parent, label, tip)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	c.label = c:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	c.label:SetPoint("LEFT", c, "RIGHT", 0, 1)
	c.label:SetText(label)
	c:SetHitRectInsets(0, -c.label:GetStringWidth() - 4, 0, 0)
	if tip then Tip(c, label, tip) end
	return c
end

local function Ago(t)
	local d = time() - (t or time())
	if d < 3600 then return "just now" end
	if d < 86400 then return math.floor(d / 3600) .. "h ago" end
	return math.floor(d / 86400) .. "d ago"
end

local function Short(text, n)
	text = (text or ""):gsub("\n", " ")
	if #text > n then return text:sub(1, n - 3) .. "..." end
	return text
end

local Refresh, Select, LoadPage, LoadTasks, LoadWhen, FocusTask, ShowSound, SoundMenu

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

local function Row(i)
	local rows = win.rows
	if rows[i] then return rows[i] end
	local r = CreateFrame("Button", nil, win.listChild)
	r:SetHeight(ROW_H)
	r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
	r:SetPoint("RIGHT", 0, 0)
	r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	r.check:SetSize(20, 20)
	r.check:SetPoint("LEFT", 0, 0)
	r.check:SetScript("OnClick", function(self)
		Sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
		NK.SetDone(r.note, self:GetChecked())
	end)
	Tip(r.check, "Done", "Tick the note off. Ticked notes are archived as Options says.")
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(14, 14)
	r.text = r:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)
	r.right = r:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	r.right:SetPoint("RIGHT", -4, 0)
	r:SetScript("OnClick", function(self) Select(self.note) end)
	rows[i] = r
	return r
end

local function FillList()
	local archive = view == "archive"
	local list = NK.List(archive)
	for i, note in ipairs(list) do
		local r = Row(i)
		r.note = note
		r.check:SetShown(not archive)
		r.check:SetChecked(note.done and true or false)
		local x = archive and 2 or 20
		local marked = NK.HasConditions(note)
		r.icon:ClearAllPoints()
		r.icon:SetPoint("LEFT", x, 0)
		r.icon:SetTexture(note.repeating and REPEAT_MARK or MARK)
		r.icon:SetDesaturated((note.done or archive) and true or false)
		r.icon:SetShown(marked)
		local d, n = NK.Progress(note)
		r.right:SetText(archive and Ago(note.archivedAt) or (n > 0 and (d .. "/" .. n) or ""))
		r.text:ClearAllPoints()
		r.text:SetPoint("LEFT", x + (marked and 16 or 0), 0)
		r.text:SetPoint("RIGHT", r.right:GetText() ~= "" and -(r.right:GetStringWidth() + 8) or -4, 0)
		r.text:SetText(NK.Title(note))
		if note.done or archive then r.text:SetTextColor(0.6, 0.6, 0.6) else r.text:SetTextColor(1, 0.82, 0) end
		if note == selected then r:LockHighlight() else r:UnlockHighlight() end
		r:Show()
	end
	for i = #list + 1, #win.rows do win.rows[i]:Hide() end
	win.listChild:SetHeight(math.max(1, #list * ROW_H))
	win.empty:SetShown(#list == 0)
	win.empty:SetText(archive and "Nothing archived yet." or "No notes yet.\nClick New note to write one.")
	local open = #NK.List(false)
	win.tabNotes:SetText(open > 0 and ("Notes (" .. open .. ")") or "Notes")
end

Refresh = function()
	if not (win and win:IsShown()) then return end
	if view == "notes" then win.tabNotes:LockHighlight() win.tabArchive:UnlockHighlight()
	else win.tabArchive:LockHighlight() win.tabNotes:UnlockHighlight() end
	FillList()
end

--------------------------------------------------------------------------------
-- The conditions editor: for the note, or the task in `target`
--------------------------------------------------------------------------------

local function TargetTask() return target and selected and selected.tasks and selected.tasks[target] end

local function TargetWhen()
	if not selected then return "" end
	local t = TargetTask()
	if target then return t and t.when or "" end
	return selected.when or ""
end

local function SetTargetWhen(text)
	if not selected then return end
	if target then NK.EditTask(selected, target, "when", text) else NK.Edit(selected, "when", text) end
end

local function Status()
	local conds, bad = NK.Parse(TargetWhen())
	local what = target and "this task" or "the note"
	if #bad > 0 then
		win.status:SetText("|cffff5050Can't read:|r " .. table.concat(bad, ", ") .. "  |cff999999(hover the ? for help)|r")
	elseif #conds == 0 then
		win.status:SetText("|cff999999No conditions: " .. what .. " won't pop up by itself.|r")
	else
		local says = {}
		for _, c in ipairs(conds) do says[#says + 1] = NK.Phrase(c) end
		win.status:SetText("|cff80ff80Pops up|r " .. what .. " |cff80ff80when|r " .. table.concat(says, ", "))
	end
end

local function StyleTask(r)
	local t = selected and selected.tasks and selected.tasks[r.index]
	if not t then return end
	r.edit:SetTextColor(INK[1], INK[2], INK[3], t.done and 0.4 or 1)
	local has = #NK.CondsOf(t.when) > 0
	r.cond.icon:SetDesaturated(not has or t.done and true or false)
	r.cond.icon:SetAlpha(has and 1 or 0.25)
	r.bg:SetShown(r.index == target)
end

LoadWhen = function()
	if not selected then return end
	loading = true
	win.whenBox:SetText(TargetWhen())
	loading = false
	win.whenBox:SetCursorPosition(0)
	local t = TargetTask()
	win.scope:SetText(t and ("Task: " .. Short(t.text ~= "" and t.text or "(new task)", 24)) or "Whole note")
	Status()
	for _, r in ipairs(win.taskRows) do if r:IsShown() then StyleTask(r) end end
end

local function SetTarget(i)
	if target == i then return end
	target = i
	LoadWhen()
end

-- a tag from the Add menu onto the end of the conditions
local function AddTag(tag)
	if not selected then return end
	local when = TargetWhen():match("^%s*(.-)[%s,]*$")
	for part in when:gmatch("[^,;\n]+") do
		if part:match("^%s*(.-)%s*$"):lower() == tag:lower() then return end
	end
	SetTargetWhen(when == "" and tag or (when .. ", " .. tag))
	LoadWhen()
end

--------------------------------------------------------------------------------
-- The checklist on the page: a row per task (tick, text, !, x). Enter makes the next
-- one, backspace on an empty one removes it, tab moves between them. Clicking into a
-- task (or its !) puts its conditions in the editor below.
--------------------------------------------------------------------------------

local function ShowProgress()
	local d, n = NK.Progress(selected or {})
	win.progress:SetText(n > 0 and ("(" .. d .. "/" .. n .. ")") or "")
end

-- a task removed or put in before the one being edited: `target` follows it
local function Removed(i)
	if target == i then target = nil elseif target and target > i then target = target - 1 end
end
local function Inserted(i)
	if target and target >= i then target = target + 1 end
end

local function TaskRow(i)
	if win.taskRows[i] then return win.taskRows[i] end
	local r = CreateFrame("Frame", nil, win.taskChild)
	r:SetHeight(TASK_H)
	r:SetPoint("TOPLEFT", 0, -(i - 1) * TASK_H)
	r:SetPoint("RIGHT")
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(INK[1], INK[2], INK[3], 0.10)
	r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	r.check:SetSize(20, 20)
	r.check:SetPoint("LEFT", 0, 0)
	r.check:SetScript("OnClick", function(self)
		if not selected then return end
		Sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
		NK.SetTaskDone(selected, r.index, self:GetChecked())
	end)
	r.edit = CreateFrame("EditBox", nil, r)
	r.edit:SetAutoFocus(false)
	r.edit:SetFontObject(QuestFont)
	r.edit:SetPoint("LEFT", 22, 0)
	r.edit:SetPoint("RIGHT", -40, 0)
	r.edit:SetHeight(TASK_H)
	r.edit:SetScript("OnEscapePressed", r.edit.ClearFocus)
	r.edit:SetScript("OnEditFocusGained", function() SetTarget(r.index) end)
	r.hint = r:CreateFontString(nil, "ARTWORK", "QuestFont")
	r.hint:SetPoint("LEFT", r.edit, "LEFT", 0, 0)
	r.hint:SetText("New task...")
	r.hint:SetTextColor(INK[1], INK[2], INK[3], 0.35)
	-- (left empty, with no conditions either: it goes, once the focus has moved on)
	r.edit:SetScript("OnEditFocusLost", function(self)
		if self:GetText() ~= "" or not selected then return end
		local i, note = r.index, selected
		C_Timer.After(0, function()
			local t = note.tasks and note.tasks[i]
			if not t or t.text ~= "" or (t.when or "") ~= "" or not NK.db.notes[note.id] then return end
			if note == selected then Removed(i) end
			NK.RemoveTask(note, i)
			if note == selected then LoadTasks() LoadWhen() end
		end)
	end)
	r.edit:SetScript("OnArrowPressed", function(_, key)
		if key == "UP" then FocusTask(r.index - 1) elseif key == "DOWN" then FocusTask(r.index + 1) end
	end)
	r.edit:SetScript("OnTextChanged", function(self, user)
		r.hint:SetShown(self:GetText() == "")
		if user and not loading and selected then
			NK.EditTask(selected, r.index, "text", self:GetText())
			if target == r.index then
				win.scope:SetText("Task: " .. Short(self:GetText() ~= "" and self:GetText() or "(new task)", 24))
			end
		end
	end)
	r.edit:SetScript("OnEnterPressed", function(self)
		if not selected then return end
		-- (Enter on an empty task: done adding)
		if self:GetText() == "" then self:ClearFocus() return end
		Inserted(r.index + 1)
		local at = NK.AddTask(selected, "", r.index + 1)
		LoadTasks()
		FocusTask(at)
	end)
	r.edit:SetScript("OnTabPressed", function() FocusTask(r.index + (IsShiftKeyDown() and -1 or 1)) end)
	r.edit:SetScript("OnKeyDown", function(self, key)
		if key ~= "BACKSPACE" or self:GetText() ~= "" or not selected then return end
		-- (next frame: the key's done with this box before the rows move up)
		local i, note = r.index, selected
		C_Timer.After(0, function()
			if selected ~= note or not (note.tasks and note.tasks[i]) or note.tasks[i].text ~= "" then return end
			Removed(i)
			NK.RemoveTask(note, i)
			LoadTasks()
			FocusTask(math.max(1, i - 1))
		end)
	end)

	-- its conditions: a ! (lit when it has some); click to edit them below
	r.cond = CreateFrame("Button", nil, r)
	r.cond:SetSize(16, 16)
	r.cond:SetPoint("RIGHT", -20, 0)
	r.cond.icon = r.cond:CreateTexture(nil, "ARTWORK")
	r.cond.icon:SetAllPoints()
	r.cond.icon:SetTexture(MARK)
	r.cond:SetScript("OnClick", function()
		SetTarget(r.index)
		win.whenBox:SetFocus()
	end)
	Tip(r.cond, "This task's conditions", function()
		local t = selected and selected.tasks and selected.tasks[r.index]
		local conds = NK.CondsOf(t and t.when)
		if #conds == 0 then return "None yet. Click to give this task conditions of its own: it then pops up by itself, apart from the note." end
		local says = {}
		for _, c in ipairs(conds) do says[#says + 1] = NK.Phrase(c) end
		return "Pops up " .. table.concat(says, ", ") .. ".\nClick to edit."
	end)

	r.del = CreateFrame("Button", nil, r)
	r.del:SetSize(16, 16)
	r.del:SetPoint("RIGHT", -2, 0)
	r.del.x = r.del:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	r.del.x:SetPoint("CENTER", 0, 1)
	r.del.x:SetText("x")
	r.del.x:SetTextColor(INK[1], INK[2], INK[3], 0.45)
	r.del:SetScript("OnEnter", function(self)
		self.x:SetTextColor(0.6, 0.05, 0.02, 1)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Remove this task", 1, 1, 1)
		GameTooltip:Show()
	end)
	r.del:SetScript("OnLeave", function(self)
		self.x:SetTextColor(INK[1], INK[2], INK[3], 0.45)
		GameTooltip:Hide()
	end)
	r.del:SetScript("OnClick", function()
		if not selected then return end
		Removed(r.index)
		NK.RemoveTask(selected, r.index)
		LoadTasks()
		LoadWhen()
	end)
	win.taskRows[i] = r
	return r
end

LoadTasks = function()
	local tasks = selected and selected.tasks or {}
	loading = true
	for i, t in ipairs(tasks) do
		local r = TaskRow(i)
		r.index = i
		r.edit:SetText(t.text or "")
		r.edit:SetCursorPosition(0)
		r.hint:SetShown((t.text or "") == "")
		r.check:SetChecked(t.done and true or false)
		r:Show()
		StyleTask(r)
	end
	loading = false
	for i = #tasks + 1, #win.taskRows do win.taskRows[i]:Hide() end
	win.addTask:ClearAllPoints()
	win.addTask:SetPoint("TOPLEFT", 0, -#tasks * TASK_H)
	win.addTask:SetPoint("RIGHT")
	win.taskChild:SetHeight((#tasks + 1) * TASK_H)
	ShowProgress()
end

FocusTask = function(i)
	local r = win.taskRows[i]
	if not (r and r:IsShown()) then return end
	r.edit:SetFocus()
	r.edit:SetCursorPosition(#(r.edit:GetText() or ""))
	-- (scrolled so the row's in view)
	local s = win.taskScroll
	s:UpdateScrollChildRect()
	local top, height, now = (i - 1) * TASK_H, s:GetHeight(), s:GetVerticalScroll()
	if top < now then s:SetVerticalScroll(top)
	elseif top + TASK_H > now + height then
		s:SetVerticalScroll(math.min(top + TASK_H - height, s:GetVerticalScrollRange()))
	end
end

--------------------------------------------------------------------------------
-- The page
--------------------------------------------------------------------------------

LoadPage = function()
	local note = selected
	local has = note ~= nil
	win.page:SetShown(has)
	win.noPage:SetShown(not has)
	for _, w in ipairs(win.pageWidgets) do w:SetShown(has) end
	if not has then return end
	target = nil
	loading = true
	win.titleBox:SetText(note.title or "")
	win.body:SetText(note.body or "")
	loading = false
	win.titleBox:SetCursorPosition(0)
	win.body:SetCursorPosition(0)
	win.titleHint:SetShown((note.title or "") == "")
	win.bodyHint:SetShown((note.body or "") == "")
	LoadTasks()
	win.taskScroll:SetVerticalScroll(0)
	LoadWhen()
	win.done:SetChecked(note.done and true or false)
	win.shared:SetChecked(note.char == nil)
	win.repeating:SetChecked(note.repeating and true or false)
	win.tracked:SetChecked(note.tracked and true or false)
	ShowSound()
	local archive = note.archived
	win.archiveBtn:SetText(archive and "Restore" or "Archive")
	win.done:SetShown(not archive)
	local made = date("%d %b %Y", note.created or time())
	win.meta:SetText(archive and ("Written " .. made .. ", archived " .. date("%d %b %Y", note.archivedAt or time()))
		or ("Written " .. made))
end

Select = function(note)
	if selected and selected ~= note then Discard(selected) end
	selected = note
	if note then view = note.archived and "archive" or "notes" end
	Refresh()
	LoadPage()
end

--------------------------------------------------------------------------------
-- Menus (the game's own dropdown menus)
--------------------------------------------------------------------------------

local function AddMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(target and "Pop this task up when..." or "Pop this note up when...")
		for _, c in ipairs(NK.ConditionChoices()) do
			if c.divider then root:CreateDivider()
			else root:CreateButton(c.text, function() AddTag(c.tag) end) end
		end
	end)
end

-- which conditions the editor shows: the note's, or one task's
local function ScopeMenu(owner)
	if not selected then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Conditions for...")
		local function is(v) return (target or 0) == v end
		local function set(v) SetTarget(v ~= 0 and v or nil) end
		root:CreateRadio("The whole note", is, set, 0)
		local tasks = selected.tasks or {}
		if #tasks > 0 then root:CreateDivider() end
		for i, t in ipairs(tasks) do
			local mark = #NK.CondsOf(t.when) > 0 and "|cffffd100!|r " or ""
			root:CreateRadio(mark .. Short(t.text ~= "" and t.text or "(new task)", 40), is, set, i)
		end
	end)
end

-- sound choices as radios under `root`: get/set the chosen key; picking one plays it
local function SoundRadios(root, get, set, withDefault)
	local function is(v) return get() == v end
	local function pick(v) set(v) if v ~= "default" then NK.PlaySound(v) end end
	if withDefault then
		root:CreateRadio("Default (" .. NK.SoundLabel(NK.db.settings.reminderSound) .. ")", is, function(v)
			set(v) NK.PlaySound(NK.db.settings.reminderSound)
		end, "default")
	end
	root:CreateRadio("No sound", is, pick, "none")
	for _, s in ipairs(NK.Sounds()) do root:CreateRadio(s.label, is, pick, s.key) end
end

ShowSound = function()
	if not selected then return end
	win.soundBtn:SetText(selected.sound and ("Sound: " .. NK.SoundLabel(selected.sound)) or "Sound: Default")
	if selected.sound == "none" then win.soundBtn:SetText("No sound") end
end

SoundMenu = function(owner)
	if not selected then return end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("This note's reminders play...")
		SoundRadios(root, function() return selected.sound or "default" end, function(v)
			NK.Edit(selected, "sound", v ~= "default" and v or nil)
			ShowSound()
		end, true)
	end)
end

local function OptionsMenu(owner)
	local s = NK.db.settings
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Archive ticked-off notes")
		local function done(v) return s.archiveDone == v end
		local function setDone(v) s.archiveDone = v NK.Sweep() end
		root:CreateRadio("At once", done, setDone, 0)
		root:CreateRadio("After a minute", done, setDone, 60)
		root:CreateRadio("After an hour", done, setDone, 3600)
		root:CreateRadio("After a day", done, setDone, 86400)
		root:CreateRadio("After a week", done, setDone, 7 * 86400)
		root:CreateRadio("Never", done, setDone, -1)
		root:CreateDivider()
		root:CreateTitle("Archive notes left untouched for")
		local function idle(v) return s.archiveIdle == v end
		local function setIdle(v) s.archiveIdle = v NK.Sweep() end
		root:CreateRadio("A week", idle, setIdle, 7)
		root:CreateRadio("A month", idle, setIdle, 30)
		root:CreateRadio("Three months", idle, setIdle, 90)
		root:CreateRadio("Never", idle, setIdle, -1)
		root:CreateDivider()
		root:CreateCheckbox("Pop-up reminders (off: a chat line)", function() return s.popups end, function() s.popups = not s.popups end)
		local snd = root:CreateButton("Reminder sound: " .. NK.SoundLabel(s.reminderSound))
		snd:CreateTitle("Reminders play (unless a note has its own)...")
		SoundRadios(snd, function() return s.reminderSound end, function(v) s.reminderSound = v end)
		local bg = root:CreateButton("On-screen notes background")
		local function isBg(v) return math.abs((s.trackerBg or 0) - v) < 0.01 end
		local function setBg(v) s.trackerBg = v if NK.RefreshTracker then NK.RefreshTracker() end end
		bg:CreateRadio("None", isBg, setBg, 0)
		bg:CreateRadio("Light", isBg, setBg, 0.25)
		bg:CreateRadio("Medium", isBg, setBg, 0.4)
		bg:CreateRadio("Dark", isBg, setBg, 0.65)
		root:CreateCheckbox("Minimap button", function() return not s.minimap.hide end, function()
			s.minimap.hide = not s.minimap.hide
			NK.UpdateMinimapButton()
		end)
		root:CreateDivider()
		root:CreateButton("Show a test reminder", function() NK.TestPopup() end)
	end)
end

--------------------------------------------------------------------------------
-- Building the window
--------------------------------------------------------------------------------

local function TextBox(parent, font, multi)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetAutoFocus(false)
	e:SetFontObject(font)
	e:SetTextColor(INK[1], INK[2], INK[3])
	e:SetMultiLine(multi and true or false)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	return e
end

local function Build()
	win = CreateFrame("Frame", "NotekeeperFrame", UIParent, "BackdropTemplate")
	win:SetSize(W, H)
	win:SetFrameStrata("HIGH")
	win:SetToplevel(true)
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		NK.db.settings.windowPos = { point, x, y }
	end)
	win:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	local pos = NK.db.settings.windowPos
	if pos then win:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3]) else win:SetPoint("CENTER", 0, 40) end
	tinsert(UISpecialFrames, "NotekeeperFrame")
	win:SetScript("OnShow", function() Sound("IG_QUEST_LOG_OPEN") Refresh() LoadPage() end)
	win:SetScript("OnHide", function()
		Sound("IG_QUEST_LOG_CLOSE")
		if Empty(selected) then Discard(selected) selected = nil end
	end)

	local header = win:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetSize(300, 64)
	header:SetPoint("TOP", 0, 12)
	local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", header, "TOP", 0, -14)
	title:SetText("Notekeeper")

	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	-- left: tabs and the list
	win.tabNotes = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	win.tabNotes:SetSize(LIST_W / 2 - 2, 22)
	win.tabNotes:SetPoint("TOPLEFT", 20, -32)
	win.tabNotes:SetText("Notes")
	win.tabNotes:SetScript("OnClick", function() Discard(selected) view = "notes" selected = nil Refresh() LoadPage() end)
	win.tabArchive = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	win.tabArchive:SetSize(LIST_W / 2 - 2, 22)
	win.tabArchive:SetPoint("LEFT", win.tabNotes, "RIGHT", 4, 0)
	win.tabArchive:SetText("Archive")
	win.tabArchive:SetScript("OnClick", function() Discard(selected) view = "archive" selected = nil Refresh() LoadPage() end)

	local listBox = Inset(win)
	listBox:SetPoint("TOPLEFT", win.tabNotes, "BOTTOMLEFT", -2, -4)
	listBox:SetSize(LIST_W + 4, H - 32 - 22 - 4 - 50)
	local scroll = CreateFrame("ScrollFrame", "NotekeeperListScroll", listBox, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	win.listChild = CreateFrame("Frame", nil, scroll)
	win.listChild:SetSize(LIST_W - 28, 1)
	scroll:SetScrollChild(win.listChild)
	AutoBar(scroll)
	win.rows = {}
	win.empty = listBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	win.empty:SetPoint("TOPLEFT", 12, -16)
	win.empty:SetPoint("RIGHT", -12, 0)
	win.empty:SetJustifyH("LEFT")

	local new = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	new:SetSize(LIST_W / 2 - 2, 22)
	new:SetPoint("BOTTOMLEFT", 20, 18)
	new:SetText("New note")
	new:SetScript("OnClick", function() NK.OpenNewNote() end)
	local opts = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	opts:SetSize(LIST_W / 2 - 2, 22)
	opts:SetPoint("LEFT", new, "RIGHT", 4, 0)
	opts:SetText("Options")
	opts:SetScript("OnClick", OptionsMenu)

	-- right: the parchment page
	local px = 20 + LIST_W + 14
	local pw = W - px - 20
	win.page = CreateFrame("Frame", nil, win, "BackdropTemplate")
	win.page:SetPoint("TOPLEFT", px, -32)
	win.page:SetSize(pw, 330)
	win.page:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 } })
	win.page:SetBackdropBorderColor(0.45, 0.33, 0.18, 1)
	local parchment = win.page:CreateTexture(nil, "BACKGROUND")
	parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
	parchment:SetPoint("TOPLEFT", 3, -3)
	parchment:SetPoint("BOTTOMRIGHT", -3, 3)
	-- (the paper fills only the texture's top-left; cropped inside its torn edges, the page's border frames it)
	parchment:SetTexCoord(0.02, 0.55, 0.02, 0.61)

	win.titleBox = TextBox(win.page, QuestTitleFont)
	win.titleBox:SetPoint("TOPLEFT", 14, -10)
	win.titleBox:SetPoint("RIGHT", -14, 0)
	win.titleBox:SetHeight(24)
	win.titleBox:SetMaxLetters(80)
	win.titleHint = win.page:CreateFontString(nil, "ARTWORK", "QuestTitleFont")
	win.titleHint:SetPoint("LEFT", win.titleBox, "LEFT", 0, 0)
	win.titleHint:SetText("Title")
	win.titleHint:SetTextColor(INK[1], INK[2], INK[3], 0.35)

	local rule = win.page:CreateTexture(nil, "ARTWORK")
	rule:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Divider")
	rule:SetSize(pw - 20, 16)
	rule:SetPoint("TOP", win.titleBox, "BOTTOM", 0, 2)
	rule:SetTexCoord(0, 0.95, 0, 1)
	rule:SetVertexColor(0.55, 0.42, 0.25)

	local bodyScroll = CreateFrame("ScrollFrame", "NotekeeperBodyScroll", win.page, "UIPanelScrollFrameTemplate")
	bodyScroll:SetPoint("TOPLEFT", 14, -46)
	bodyScroll:SetPoint("RIGHT", -30, 0)
	bodyScroll:SetHeight(84)
	win.body = TextBox(bodyScroll, QuestFont, true)
	win.body:SetWidth(pw - 46)
	win.body:SetHeight(84)
	bodyScroll:SetScrollChild(win.body)
	AutoBar(bodyScroll)
	if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then
		win.body:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
		win.body:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, bodyScroll) end)
	end
	bodyScroll:EnableMouse(true)
	bodyScroll:SetScript("OnMouseDown", function() win.body:SetFocus() win.body:SetCursorPosition(#win.body:GetText()) end)
	win.bodyHint = win.page:CreateFontString(nil, "ARTWORK", "QuestFont")
	win.bodyHint:SetPoint("TOPLEFT", bodyScroll, "TOPLEFT", 0, 0)
	win.bodyHint:SetText("Write your note here...")
	win.bodyHint:SetTextColor(INK[1], INK[2], INK[3], 0.35)

	-- (on the title or the text: the editor below is the note's)
	win.titleBox:SetScript("OnEditFocusGained", function() SetTarget(nil) end)
	win.body:SetScript("OnEditFocusGained", function() SetTarget(nil) end)
	win.titleBox:SetScript("OnTabPressed", function() win.body:SetFocus() end)
	-- (Tab from the text: on to the tasks; the first, or a new one)
	win.body:SetScript("OnTabPressed", function()
		if not selected then return end
		if #(selected.tasks or {}) == 0 then NK.AddTask(selected, "") LoadTasks() end
		FocusTask(1)
	end)
	win.titleBox:SetScript("OnEnterPressed", function() win.body:SetFocus() end)
	win.titleBox:SetScript("OnTextChanged", function(self, user)
		win.titleHint:SetShown(self:GetText() == "")
		if user and not loading and selected then NK.Edit(selected, "title", self:GetText()) end
	end)
	win.body:SetScript("OnTextChanged", function(self, user)
		win.bodyHint:SetShown(self:GetText() == "")
		if user and not loading and selected then NK.Edit(selected, "body", self:GetText()) end
	end)

	-- the checklist under the text
	local tasksTitle = win.page:CreateFontString(nil, "ARTWORK", "QuestFont")
	tasksTitle:SetPoint("TOPLEFT", bodyScroll, "BOTTOMLEFT", 0, -10)
	tasksTitle:SetText("Tasks")
	tasksTitle:SetTextColor(INK[1], INK[2], INK[3])
	win.progress = win.page:CreateFontString(nil, "ARTWORK", "QuestFont")
	win.progress:SetPoint("LEFT", tasksTitle, "RIGHT", 6, 0)
	win.progress:SetTextColor(INK[1], INK[2], INK[3], 0.6)
	local toTasks = CreateFrame("Button", nil, win.page, "UIPanelButtonTemplate")
	toTasks:SetSize(116, 20)
	toTasks:SetPoint("TOPRIGHT", bodyScroll, "BOTTOMRIGHT", 18, -6)
	toTasks:SetText("Lines to tasks")
	Tip(toTasks, "Lines to tasks", "Every line of the note's text becomes a task on the checklist (and leaves the text). "
		.. "Lines starting with - or [x] work too: [x] ones come in ticked.")
	toTasks:SetScript("OnClick", function()
		if not selected then return end
		if NK.LinesToTasks(selected) == 0 then
			NK.Print("write one task per line in the note's text first, then click Lines to tasks.")
			return
		end
		loading = true
		win.body:SetText(selected.body or "")
		loading = false
		win.bodyHint:SetShown(true)
		LoadTasks()
		LoadWhen()
	end)

	local taskScroll = CreateFrame("ScrollFrame", "NotekeeperTaskScroll", win.page, "UIPanelScrollFrameTemplate")
	taskScroll:SetPoint("TOPLEFT", tasksTitle, "BOTTOMLEFT", -4, -6)
	taskScroll:SetPoint("BOTTOMRIGHT", -30, 10)
	win.taskScroll = taskScroll
	win.taskChild = CreateFrame("Frame", nil, taskScroll)
	win.taskChild:SetSize(pw - 44, TASK_H)
	taskScroll:SetScrollChild(win.taskChild)
	AutoBar(taskScroll)
	win.taskRows = {}
	win.addTask = CreateFrame("Button", nil, win.taskChild)
	win.addTask:SetHeight(TASK_H)
	local plus = win.addTask:CreateFontString(nil, "ARTWORK", "QuestFont")
	plus:SetPoint("LEFT", 4, 0)
	plus:SetText("+  Add a task")
	plus:SetTextColor(INK[1], INK[2], INK[3], 0.5)
	win.addTask:SetScript("OnEnter", function() plus:SetTextColor(INK[1], INK[2], INK[3], 1) end)
	win.addTask:SetScript("OnLeave", function() plus:SetTextColor(INK[1], INK[2], INK[3], 0.5) end)
	win.addTask:SetScript("OnClick", function()
		if not selected then return end
		-- (an empty one at the end already: type in that)
		local tasks = selected.tasks or {}
		if #tasks > 0 and tasks[#tasks].text == "" then FocusTask(#tasks) return end
		local at = NK.AddTask(selected, "")
		LoadTasks()
		FocusTask(at)
	end)

	win.noPage = win:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	win.noPage:SetPoint("TOPLEFT", px + 20, -60)
	win.noPage:SetWidth(pw - 40)
	win.noPage:SetJustifyH("LEFT")
	win.noPage:SetText("Pick a note on the left, or click New note.\n\n"
		.. "A note can have a checklist of tasks, and the note or any task in it can pop up by itself: "
		.. "give it conditions under the page, like entering a city, reaching a level or opening a vendor.")

	-- under the page: whose conditions, the conditions, ticks, buttons
	win.pageWidgets = {}
	local function keep(w) win.pageWidgets[#win.pageWidgets + 1] = w return w end

	local whenLabel = keep(win:CreateFontString(nil, "ARTWORK", "GameFontNormal"))
	whenLabel:SetPoint("TOPLEFT", win.page, "BOTTOMLEFT", 2, -12)
	whenLabel:SetText("Pop up when:")
	win.scope = keep(CreateFrame("Button", nil, win, "UIPanelButtonTemplate"))
	win.scope:SetSize(176, 20)
	win.scope:SetPoint("LEFT", whenLabel, "RIGHT", 8, 0)
	win.scope:SetScript("OnClick", ScopeMenu)
	Tip(win.scope, "Conditions for...", "The whole note, or one of its tasks. Clicking into a task (or its !) picks it too; "
		.. "clicking the title or text picks the note again.")
	local help = keep(CreateFrame("Button", nil, win))
	help:SetSize(22, 16)
	help:SetPoint("LEFT", win.scope, "RIGHT", 6, 0)
	local q = help:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	q:SetPoint("CENTER")
	q:SetText("|cff80c0ff(?)|r")
	Tip(help, "Conditions", "Any one of these pops it up. Separate them with commas.\n\n"
		.. "|cffffd100zone:|rStormwind  entering a zone or area\n"
		.. "|cffffd100city|r  any city or inn\n"
		.. "|cffffd100dungeon|r  any dungeon (|cffffd100dungeon:|rDeadmines: that one)\n"
		.. "|cffffd100level:|r20  reaching level 20\n"
		.. "|cffffd100login|r  logging in\n"
		.. "|cffffd100vendor  bank  mail  auction  trainer  flight|r  opening one\n"
		.. "|cffffd100target:|rHogger  targeting someone\n\n"
		.. "Part of a name is enough, and case doesn't matter. Or use Add to pick one.\n"
		.. "A task's own conditions pop up just that task.")

	-- the note's reminder sound
	win.soundBtn = keep(CreateFrame("Button", nil, win, "UIPanelButtonTemplate"))
	win.soundBtn:SetSize(104, 20)
	win.soundBtn:SetPoint("TOPRIGHT", win.page, "BOTTOMRIGHT", 0, -9)
	win.soundBtn:SetScript("OnClick", SoundMenu)
	Tip(win.soundBtn, "Reminder sound", "The sound this note's reminders (and its tasks') play. "
		.. "Default is the one in Options. Picking one plays it.")

	win.whenBox = keep(CreateFrame("EditBox", nil, win, "InputBoxTemplate"))
	win.whenBox:SetAutoFocus(false)
	win.whenBox:SetHeight(20)
	win.whenBox:SetPoint("TOPLEFT", whenLabel, "BOTTOMLEFT", 6, -6)
	win.whenBox:SetWidth(pw - 84)
	win.whenBox:SetScript("OnTextChanged", function(self, user)
		if user and not loading and selected then
			SetTargetWhen(self:GetText())
			Status()
			for _, r in ipairs(win.taskRows) do if r:IsShown() then StyleTask(r) end end
		end
	end)
	win.whenBox:SetScript("OnEnterPressed", win.whenBox.ClearFocus)
	local add = keep(CreateFrame("Button", nil, win, "UIPanelButtonTemplate"))
	add:SetSize(70, 22)
	add:SetPoint("LEFT", win.whenBox, "RIGHT", 6, 0)
	add:SetText("Add")
	add:SetScript("OnClick", AddMenu)
	Tip(add, "Add a condition", "Pick one, filled in from where you are now.")

	win.status = keep(win:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"))
	win.status:SetPoint("TOPLEFT", win.whenBox, "BOTTOMLEFT", -6, -5)
	win.status:SetWidth(pw)
	win.status:SetJustifyH("LEFT")
	win.status:SetWordWrap(false)

	win.done = keep(Check(win, "Done", "Tick the note off. Ticked notes are archived as Options says."))
	win.done:SetPoint("TOPLEFT", win.status, "BOTTOMLEFT", -2, -6)
	win.done:SetScript("OnClick", function(self) if selected then NK.SetDone(selected, self:GetChecked()) end end)
	win.shared = keep(Check(win, "All characters", "Show this note, and pop it up, on all your characters, not just the one that wrote it."))
	win.shared:SetPoint("LEFT", win.done, "RIGHT", 60, 0)
	win.shared:SetScript("OnClick", function(self)
		if selected then NK.Edit(selected, "char", (not self:GetChecked()) and NK.Me() or nil) end
	end)
	win.repeating = keep(Check(win, "Every time", "The note's own conditions keep popping it up every time (\"repair at the vendor\"), "
		.. "with OK and Stop instead of Later and Done. It isn't archived for being left untouched."))
	win.repeating:SetPoint("LEFT", win.shared, "RIGHT", 100, 0)
	win.repeating:SetScript("OnClick", function(self)
		if selected then NK.Edit(selected, "repeating", self:GetChecked() or nil) end
	end)
	win.tracked = keep(Check(win, "On screen", "Show this note and its tasks on screen while you play, like the quest tracker. "
		.. "Click a task there to tick it."))
	win.tracked:SetPoint("LEFT", win.repeating, "RIGHT", 80, 0)
	win.tracked:SetScript("OnClick", function(self)
		if selected then NK.Edit(selected, "tracked", self:GetChecked() or nil) end
	end)

	win.meta = keep(win:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall"))
	win.meta:SetPoint("BOTTOMLEFT", px + 2, 24)

	local delete = keep(CreateFrame("Button", nil, win, "UIPanelButtonTemplate"))
	delete:SetSize(80, 22)
	delete:SetPoint("BOTTOMRIGHT", -20, 18)
	delete:SetText("Delete")
	delete:SetScript("OnClick", function()
		if not selected then return end
		local empty = (selected.title or "") == "" and (selected.body or "") == "" and #(selected.tasks or {}) == 0
		if IsShiftKeyDown() or empty then
			NK.Delete(selected) selected = nil Refresh() LoadPage()
		else
			StaticPopup_Show("NOTEKEEPER_DELETE", NK.Title(selected))
		end
	end)
	Tip(delete, "Delete", "Gone for good (shift-click: without asking). Archive keeps it instead.")
	win.archiveBtn = keep(CreateFrame("Button", nil, win, "UIPanelButtonTemplate"))
	win.archiveBtn:SetSize(80, 22)
	win.archiveBtn:SetPoint("RIGHT", delete, "LEFT", -4, 0)
	win.archiveBtn:SetScript("OnClick", function()
		if not selected then return end
		if selected.archived then NK.Restore(selected) view = "notes" else NK.Archive(selected) view = "archive" end
		Refresh() LoadPage()
	end)
end

StaticPopupDialogs["NOTEKEEPER_DELETE"] = {
	text = "Delete \"%s\" for good?",
	button1 = DELETE or "Delete",
	button2 = CANCEL or "Cancel",
	OnAccept = function()
		if selected then NK.Delete(selected) selected = nil Refresh() LoadPage() end
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

--------------------------------------------------------------------------------
-- Entry points (Core.lua's /nk, the minimap button, keybindings, the popup)
--------------------------------------------------------------------------------

function NK.ToggleWindow()
	if not win then Build() end
	win:SetShown(not win:IsShown())
end

function NK.OpenNewNote(title)
	if not win then Build() end
	-- (already on an empty new note: that one, not another)
	if Empty(selected) and not title and win:IsShown() then win.titleBox:SetFocus() return end
	local note = NK.New(title or "", "", "")
	win:Show()
	Select(note)
	win.titleBox:SetFocus()
end

function NK.ShowNote(note)
	if not win then Build() end
	win:Show()
	if note and NK.db.notes[note.id] then Select(note) end
end

_G.Notekeeper_New = function() NK.OpenNewNote() end

-- the data changed: the list follows; on the page only the ticks and marks do (you may be typing)
NK.OnChange(function(note)
	if not (win and win:IsShown()) then return end
	if selected and not NK.db.notes[selected.id] then selected = nil LoadPage() end
	if note and note == selected then
		win.done:SetChecked(note.done and true or false)
		for i, t in ipairs(note.tasks or {}) do
			local r = win.taskRows[i]
			if r and r:IsShown() then r.check:SetChecked(t.done and true or false) StyleTask(r) end
		end
		ShowProgress()
		-- (archived by the rules while it's open: the page shows where it went)
		if note.archived and view == "notes" then view = "archive" LoadPage() end
	end
	Refresh()
end)
