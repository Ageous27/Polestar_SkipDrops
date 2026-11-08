-- Skip Polestar leveling quests whose work is farming mob drops.
-- Object pickups and named 100% loots stay. Does not edit Polestar.

local ADDON = ...

local applying
local sessionKeep = {} -- quest id -> true: player brought this quest back while the filter was on
local origSkipQuest

local function db()
	local d = PolestarSkipDropsCharDB
	if type(d) ~= "table" then
		d = { enabled = true, skipped = {} }
		PolestarSkipDropsCharDB = d
	end
	if type(d.skipped) ~= "table" then d.skipped = {} end
	if type(d.savedPerGroup) ~= "table" then d.savedPerGroup = {} end
	if d.enabled == nil then d.enabled = true end
	return d
end

-- While the filter is on, Polestar keeps elite/escort/group quests in the route.
local function includeGroupQuests()
	local PS = Polestar
	if not (PS and PS.Get and PS.Set) then return end
	local d = db()
	local current = PS.Get("behavior.groupQuests")
	if current ~= "do" then
		if d.savedGroupQuests == nil then d.savedGroupQuests = current or "ask" end
		PS.Set("behavior.groupQuests", "do")
	end
	local st = PS.CharState and PS.CharState()
	local answers = st and st.groupQuests
	if type(answers) ~= "table" then return end
	local E = PS.Engine
	for q, ans in pairs(answers) do
		if ans == "skip" then
			if d.savedPerGroup[q] == nil then d.savedPerGroup[q] = "skip" end
			if E and E.AnswerGroup then
				E.AnswerGroup(q, "do")
			else
				answers[q] = "do"
			end
		end
	end
end

local function restoreGroupQuests()
	local PS = Polestar
	local d = db()
	if d.savedGroupQuests ~= nil and PS and PS.Set then
		PS.Set("behavior.groupQuests", d.savedGroupQuests)
		d.savedGroupQuests = nil
	end
	if type(d.savedPerGroup) ~= "table" then return end
	local E = PS and PS.Engine
	local st = PS and PS.CharState and PS.CharState()
	for q, ans in pairs(d.savedPerGroup) do
		if E and E.AnswerGroup then
			E.AnswerGroup(q, ans)
		elseif st and type(st.groupQuests) == "table" then
			st.groupQuests[q] = ans
		end
	end
	d.savedPerGroup = {}
end

local function printMsg(text)
	local chat = DEFAULT_CHAT_FRAME
	if chat and chat.AddMessage then
		chat:AddMessage("|cff88ccffPolestar Skip Drops|r: " .. text)
	end
end

local function isLeveling(guide)
	return guide ~= nil and (guide.category == nil or guide.category == "Leveling")
end

-- Farm drop collect: mob source and more than a single named loot.
-- Object gathers and count-1 unique NPC loots are kept.
local function isFarmCollect(goal)
	if not goal or goal.t ~= "collect" or type(goal.quest) ~= "number" then return false end
	if goal.fromKind == "object" then return false end
	local npcs = goal.fromNpcs
	local nNpcs = type(npcs) == "table" and #npcs or 0
	if nNpcs > 1 then return true end
	if goal.spread then return true end
	if (goal.count or 1) > 1 then return true end
	return false
end

local function farmQuests(guide)
	local set = {}
	if not (guide and type(guide.steps) == "table") then return set end
	for _, step in ipairs(guide.steps) do
		local goals = step.goals
		if type(goals) == "table" then
			for _, goal in ipairs(goals) do
				if isFarmCollect(goal) then set[goal.quest] = true end
			end
		end
	end
	return set
end

local function wrapSkipQuest()
	local E = Polestar and Polestar.Engine
	if origSkipQuest or not (E and E.SkipQuest) then return end
	origSkipQuest = E.SkipQuest
	E.SkipQuest = function(questID, on)
		if not applying and on == false and type(questID) == "number" then
			local ours = db().skipped
			if ours[questID] then
				sessionKeep[questID] = true
				ours[questID] = nil
			end
		end
		return origSkipQuest(questID, on)
	end
end

local function skipNow(E, questID)
	if origSkipQuest then
		return origSkipQuest(questID, true)
	end
	return E.SkipQuest(questID, true)
end

local function unskipNow(E, questID)
	if origSkipQuest then
		return origSkipQuest(questID, false)
	end
	return E.SkipQuest(questID, false)
end

local function apply()
	local PS = Polestar
	if not PS then return end
	wrapSkipQuest()
	local E = PS.Engine
	local C = PS.Compat
	if not db().enabled then return end
	includeGroupQuests()
	if not (E and E.GetGuide and E.SkipQuest and C) then return end
	local guide = E.GetGuide()
	if not isLeveling(guide) then return end

	local farm = farmQuests(guide)
	local ours = db().skipped
	local toSkip, last = {}, nil
	for id in pairs(farm) do
		if sessionKeep[id] then
			-- Player unskipped this while the filter was on.
		elseif C.IsOnQuest and C.IsOnQuest(id) then
			-- Already taken.
		elseif C.IsQuestCompleted and C.IsQuestCompleted(id) then
			-- Already done.
		elseif E.IsQuestSkipped and E.IsQuestSkipped(id) then
			if not ours[id] then
				-- A skip the player (or another tool) made. Leave it.
			end
		else
			local keep, loses = false, E.SkipLoses and E.SkipLoses(id)
			if type(loses) == "table" then
				for i = 1, #loses do
					local lost = loses[i] and loses[i].id
					if lost and not farm[lost] then
						keep = true
						break
					end
				end
			end
			if not keep then
				toSkip[#toSkip + 1] = id
				last = id
			end
		end
	end
	if #toSkip == 0 then return end

	applying = true
	local st = PS.CharState and PS.CharState()
	if type(st) == "table" then
		if type(st.skippedQuests) ~= "table" then st.skippedQuests = {} end
		for i = 1, #toSkip do
			local id = toSkip[i]
			st.skippedQuests[id] = true
			ours[id] = true
		end
		skipNow(E, last)
	else
		for i = 1, #toSkip do
			local id = toSkip[i]
			ours[id] = true
			skipNow(E, id)
		end
	end
	applying = false
end

local function setEnabled(on)
	local d = db()
	on = on and true or false
	if d.enabled == on then
		printMsg(on and "already on" or "already off")
		return
	end
	d.enabled = on
	local PS = Polestar
	local E = PS and PS.Engine
	if not on then
		sessionKeep = {}
		if E and E.SkipQuest then
			applying = true
			local ours = d.skipped
			local ids = {}
			for id in pairs(ours) do ids[#ids + 1] = id end
			for i = 1, #ids do
				unskipNow(E, ids[i])
				ours[ids[i]] = nil
			end
			applying = false
		else
			d.skipped = {}
		end
		restoreGroupQuests()
		printMsg("off. Drop-farm quests are back; group quests use your previous Polestar setting.")
		return
	end
	printMsg("on. Skipping drop-farm collects; elite and group quests stay in the guide.")
	apply()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" then
		if name ~= ADDON then return end
		db()
		if Polestar and Polestar.On then
			Polestar.On("GUIDE_CHANGED", apply)
			Polestar.On("GUIDES_REGISTERED", apply)
			Polestar.On("SETTING_CHANGED", function(path)
				if path == "behavior.groupQuests" and db().enabled and Polestar.Get and Polestar.Get(path) ~= "do" then
					Polestar.Set("behavior.groupQuests", "do")
				end
			end)
		end
		wrapSkipQuest()
		if Polestar and Polestar.IsLoggedIn and Polestar.IsLoggedIn() then apply() end
	elseif event == "PLAYER_LOGIN" then
		apply()
	end
end)

SLASH_POLARSKIPDROPS1 = "/psdrops"
SlashCmdList.POLARSKIPDROPS = function(msg)
	msg = type(msg) == "string" and msg:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
	if msg == "on" or msg == "enable" then
		setEnabled(true)
	elseif msg == "off" or msg == "disable" then
		setEnabled(false)
	elseif msg == "toggle" then
		setEnabled(not db().enabled)
	else
		printMsg((db().enabled and "on" or "off") .. ". /psdrops on|off|toggle")
	end
end
