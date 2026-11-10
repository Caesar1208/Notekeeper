--------------------------------------------------------------------------------
-- Tracker: notes ticked "On screen" are shown like the classic quest tracker, on an
-- optional see-through background: the title in gold, its tasks under it, each with a
-- tick box, so notes and tasks are ticked off right there. Click a title to open the
-- note. Drag the little header to move it; click it to fold the list away. A ticked
-- note stays (greyed) until it's archived. Hidden while nothing's tracked.
--------------------------------------------------------------------------------

local _, NK = ...

local MAX_NOTES, MAX_TASKS = 6, 10
local frame, lines = nil, {}

local PAD = 8                -- room inside the background

local function Build()
	frame = CreateFrame("Frame", "NotekeeperTracker", UIParent, "BackdropTemplate")
	frame:SetSize(230 + PAD * 2, 20)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	local pos = NK.db.settings.trackerPos
	if pos then frame:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3])
	else frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -250) end

	local head = CreateFrame("Button", nil, frame)
	head:SetPoint("TOPLEFT", PAD, -PAD + 2)
	head:SetPoint("TOPRIGHT", -PAD, -PAD + 2)
	head:SetHeight(16)
	head:RegisterForDrag("LeftButton")
	head:SetScript("OnDragStart", function() frame:StartMoving() end)
	head:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local point, _, _, x, y = frame:GetPoint(1)
		NK.db.settings.trackerPos = { point, x, y }
	end)
	head:SetScript("OnClick", function()
		NK.db.settings.trackerFolded = not NK.db.settings.trackerFolded
		NK.RefreshTracker()
	end)
	head:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Notekeeper", 1, 1, 1)
		GameTooltip:AddLine("Click to fold or unfold, drag to move. Click a task to tick it, a title to open the note.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	head:SetScript("OnLeave", GameTooltip_Hide)
	frame.headText = head:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	frame.headText:SetPoint("LEFT", 0, 0)
	frame.head = head
end

-- a line: a tick box and its text. A note's title (gold): the box ticks the note, the
-- text opens it. One of its tasks (white): the box or the text ticks the task.
local function Toggle(l)
	if l.task then
		local t = l.note.tasks and l.note.tasks[l.task]
		if t then NK.SetTaskDone(l.note, l.task, not t.done) end
	else
		NK.SetDone(l.note, not l.note.done)
	end
end

local function Line(n)
	local l = lines[n]
	if l then return l end
	l = CreateFrame("Button", nil, frame)
	l:SetHeight(16)
	l.check = CreateFrame("CheckButton", nil, l, "UICheckButtonTemplate")
	l.check:SetSize(16, 16)
	l.check:SetPoint("LEFT", -2, 0)
	l.check:SetScript("OnClick", function() Toggle(l) end)
	l.text = l:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	l.text:SetPoint("LEFT", 16, 0)
	l.text:SetPoint("RIGHT", 0, 0)
	l.text:SetJustifyH("LEFT")
	l.text:SetWordWrap(false)
	l:SetScript("OnClick", function(self)
		if self.task then Toggle(self) elseif NK.ShowNote then NK.ShowNote(self.note) end
	end)
	l:SetScript("OnEnter", function(self)
		self.text:SetTextColor(1, 1, 1)
		if not self.task and self.check:IsShown() then
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText(NK.Title(self.note), 1, 1, 1)
			GameTooltip:AddLine("Tick the box to tick the note off; click the title to open it.", nil, nil, nil, true)
			GameTooltip:Show()
		end
	end)
	l:SetScript("OnLeave", function(self)
		self.text:SetTextColor(self.r, self.g, self.b)
		GameTooltip:Hide()
	end)
	lines[n] = l
	return l
end

-- kind: "note" (title, with a box), "task" (with a box), "text" (no box)
local function Put(n, y, note, task, text, r, g, b, indent, kind, checked)
	local l = Line(n)
	l.note, l.task = note, task
	l:ClearAllPoints()
	l:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + indent, -y)
	l:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	l.r, l.g, l.b = r, g, b
	l.check:SetShown(kind ~= "text")
	l.check:SetChecked(checked and true or false)
	l.text:ClearAllPoints()
	l.text:SetPoint("LEFT", kind ~= "text" and 16 or 0, 0)
	l.text:SetPoint("RIGHT", 0, 0)
	l.text:SetFontObject(kind == "note" and "GameFontNormal" or "GameFontHighlightSmall")
	l.text:SetText(text)
	l.text:SetTextColor(r, g, b)
	l:SetHeight(kind == "note" and 18 or 16)
	l:Show()
	return y + (kind == "note" and 18 or 16)
end

function NK.RefreshTracker()
	if not NK.db then return end
	local tracked = {}
	for _, note in ipairs(NK.List(false)) do
		-- (a ticked one stays, greyed, until it's archived: a tick can be taken back)
		if note.tracked then tracked[#tracked + 1] = note end
	end
	if #tracked == 0 then if frame then frame:Hide() end return end
	if not frame then Build() end
	frame:Show()
	-- (the background: see-through to taste, Options; none at all leaves just the text)
	local a = NK.db.settings.trackerBg or 0
	frame:SetBackdropColor(0, 0, 0, a)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, a > 0 and math.min(1, a + 0.2) or 0)
	local folded = NK.db.settings.trackerFolded
	frame.headText:SetText((folded and "+ " or "- ") .. "Notes (" .. #tracked .. ")")
	local n, y = 0, PAD + 18
	if not folded then
		for k = 1, math.min(#tracked, MAX_NOTES) do
			local note = tracked[k]
			local d, total = NK.Progress(note)
			n = n + 1
			local dim = note.done and 0.55 or 1
			y = Put(n, y, note, nil, NK.Title(note) .. (total > 0 and ("  |cffaaaaaa" .. d .. "/" .. total .. "|r") or ""),
				dim, note.done and 0.55 or 0.82, note.done and 0.55 or 0, 0, "note", note.done)
			local tasks = note.tasks or {}
			if #tasks == 0 then
				local first = (note.body or ""):match("^%s*([^\n]+)")
				if first and (note.title or "") ~= "" then
					n = n + 1
					y = Put(n, y, note, nil, first, 0.8, 0.8, 0.8, 18, "text")
				end
			end
			for i = 1, math.min(#tasks, MAX_TASKS) do
				local t = tasks[i]
				if t.text ~= "" then                    -- (one being typed in the notebook waits)
				n = n + 1
				local g = t.done and 0.5 or 0.9
				y = Put(n, y, note, i, t.text, g, g, g, 12, "task", t.done)
				end
			end
			if #tasks > MAX_TASKS then
				n = n + 1
				y = Put(n, y, note, nil, "+ " .. (#tasks - MAX_TASKS) .. " more", 0.6, 0.6, 0.6, 28, "text")
			end
			y = y + 6
		end
	end
	for k = n + 1, #lines do lines[k]:Hide() end
	frame:SetHeight(math.max(PAD * 2 + 16, y + (folded and PAD or PAD - 6)))
end

NK.OnChange(function() NK.RefreshTracker() end)
