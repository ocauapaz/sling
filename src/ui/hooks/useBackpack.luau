local Players = game:GetService("Players")

local equipHandler = require("../../api/setEquipHandler")()
local events = require("../../core/events")
local slotManager = require("../../core/slotManager")
local states = require("../../core/states")
local useCharacter = require("./useCharacter")
local useEventListener = require("./useEventListener")
local vide = require("../../../vide")

local effect = vide.effect
local untrack = vide.untrack
local derive = vide.derive
local cleanup = vide.cleanup

local player = Players.LocalPlayer

local function useBackpack()
	local itemsIndex = derive(function()
		local items = states.items()
		local map = {}
		for i, item in items do
			map[item] = i
		end
		return map
	end)

	local backpack: Backpack = player:FindFirstChildOfClass("Backpack") :: any
	local character = useCharacter()

	-- Additions and removals are batched: the server can give or take dozens of
	-- items in one frame, and writing `states.items` once per item re-ran every
	-- reader once per item (a 140-500 ms hitch for ~60 items out of ~150). They
	-- queue here and land in one write at the next resumption point.
	local pendingRemovals: { BackpackItem } = {}
	local pendingAdditions: { BackpackItem } = {}
	local flushScheduled = false

	local function flush()
		flushScheduled = false
		local char = untrack(character)
		local slots = untrack(states.slots)
		local currentItems = untrack(states.items)

		local removed: { BackpackItem } = {}
		local gapPastHotbar = false
		for _, item in pendingRemovals do
			-- Back in the backpack or the character before the flush: it stays.
			local parent = item.Parent
			if parent == backpack or parent == char then
				continue
			end
			local index = slotManager.getItemIndex(item)
			if not index then
				continue
			end
			currentItems[index] = nil
			if index > slots then
				gapPastHotbar = true
			end
			table.insert(removed, item)
		end
		table.clear(pendingRemovals)
		if gapPastHotbar then
			slotManager.closeInventoryGaps(currentItems)
		end

		local added: { BackpackItem } = {}
		for _, item in pendingAdditions do
			-- Gone again before the flush, or queued twice (backpack, then character).
			local parent = item.Parent
			if parent ~= backpack and parent ~= char then
				continue
			end
			if slotManager.getItemIndex(item) then
				continue
			end
			currentItems[slotManager.findLowestEmptySlot()] = item
			table.insert(added, item)
		end
		table.clear(pendingAdditions)

		if #removed == 0 and #added == 0 then
			return
		end
		states.items(currentItems)
		for _, item in removed do
			events.backpackItemRemoved.fire(item)
		end
		for _, item in added do
			events.backpackItemAdded.fire(item)
		end

		if #removed > 0 and table.maxn(untrack(states.items)) == 0 then
			events.backpackEmpty.fire()
		end
	end

	local function scheduleFlush()
		if flushScheduled then
			return
		end
		flushScheduled = true
		task.defer(flush)
	end

	local function onItemAdded(item: BackpackItem)
		local char = untrack(character)
		if item.Parent == char and untrack(states.equippedItem) ~= item then
			states.equippedItem(item)
		end

		if untrack(itemsIndex)[item] then
			return
		end
		table.insert(pendingAdditions, item)
		scheduleFlush()
	end

	local function onItemRemoved(item: BackpackItem)
		local parent = item.Parent
		local char = untrack(character)
		if parent ~= char and untrack(states.equippedItem) == item then
			states.equippedItem(nil :: any)
		end

		if parent == backpack or parent == char then
			return
		end
		if not untrack(itemsIndex)[item] then
			return
		end
		table.insert(pendingRemovals, item)
		scheduleFlush()
	end

	local function onChildAdded(child: Instance)
		if child:IsA("BackpackItem") then
			onItemAdded(child)
		end
	end

	local function onChildRemoved(child: Instance)
		if child:IsA("BackpackItem") then
			onItemRemoved(child)
		end
	end

	local function observeItems(parent: Instance)
		for _, child in parent:GetChildren() do
			onChildAdded(child)
		end
		useEventListener(parent.ChildAdded, onChildAdded)
		useEventListener(parent.ChildRemoved, onChildRemoved)
	end

	effect(function()
		local char = character()
		if not char then
			return
		end

		-- update backpack reference
		backpack = player:FindFirstChildOfClass("Backpack") :: any

		observeItems(char)
		observeItems(backpack)
		-- The loaded event hands out the items, so the spawn's batch lands first.
		flush()

		states.isBackpackLoaded(true)
		events.backpackLoaded.fire(untrack(states.items))

		cleanup(function()
			table.clear(pendingRemovals)
			table.clear(pendingAdditions)
			states.equippedItem(nil :: any)
			states.items({})
			states.isBackpackLoaded(false)
		end)
	end)

	effect(function()
		local equipped = states.equippedItem()
		local char = untrack(character)
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		if equipped then
			if equipped.Parent == char then
				return
			end

			if equipped:IsA("HopperBin") then -- NOTE: HopperBin
				warn(`[Sling] Cannot select '{equipped.Name}' hopper. HopperBin is deprecated and not supported.`)
				task.defer(function()
					states.equippedItem(nil :: any)
				end)
			else
				if equipHandler.callback then
					equipHandler.callback(equipped :: Tool)
				else
					humanoid:EquipTool(equipped :: Tool)
				end
			end
		else
			if equipHandler.callback then
				equipHandler.callback(nil)
			else
				humanoid:UnequipTools()
			end
		end
	end)

	local lastEquipped: BackpackItem? = nil
	effect(function()
		local equipped = states.equippedItem()
		if equipped ~= lastEquipped then
			if lastEquipped then
				events.backpackItemUnequipped.fire(lastEquipped)
			end
			if equipped then
				events.backpackItemEquipped.fire(equipped)
			end
			lastEquipped = equipped
		end
	end)

	return {
		itemsIndex = itemsIndex,
	}
end

return useBackpack
