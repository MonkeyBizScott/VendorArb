-- MinimapButton.lua
-- Minimap button with item search functionality for VendorArb

local ADDON_PREFIX = "|cff00ff00[VendorArb]|r"

-----------------------------------------------------------------------
-- Money formatting (shared with main addon)
-----------------------------------------------------------------------
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0|t"

local function FormatMoneyIcons(copper)
    copper = copper or 0
    local negative = copper < 0
    copper = math.abs(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100

    local parts = {}
    if gold > 0 then
        table.insert(parts, gold .. GOLD_ICON)
    end
    if silver > 0 or gold > 0 then
        table.insert(parts, silver .. SILVER_ICON)
    end
    table.insert(parts, bronze .. COPPER_ICON)
    
    local str = table.concat(parts, " ")
    return negative and ("-" .. str) or str
end

-----------------------------------------------------------------------
-- Minimap Button
-----------------------------------------------------------------------
local minimapButton = CreateFrame("Button", "VendorArbMinimapButton", Minimap)
minimapButton:SetSize(32, 32)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:EnableMouse(true)
minimapButton:SetMovable(true)
minimapButton:RegisterForDrag("LeftButton")
minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- Button textures
local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT")

local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
icon:SetSize(20, 20)
icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
icon:SetPoint("CENTER", 0, 0)

local highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
highlight:SetSize(24, 24)
highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
highlight:SetPoint("CENTER", 0, 0)

-- Position on minimap (angle-based)
local function UpdateMinimapButtonPosition(angle)
    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Dragging logic
local isDragging = false
minimapButton:SetScript("OnDragStart", function(self)
    isDragging = true
    self:SetScript("OnUpdate", function(self)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        local angle = math.atan2(cy - my, cx - mx)
        UpdateMinimapButtonPosition(angle)
        VendorArbDB = VendorArbDB or {}
        VendorArbDB.minimapAngle = angle
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    isDragging = false
    self:SetScript("OnUpdate", nil)
end)

-- Load saved position
local function LoadMinimapPosition()
    local angle = VendorArbDB and VendorArbDB.minimapAngle or 225 * (math.pi / 180)
    UpdateMinimapButtonPosition(angle)
end

-----------------------------------------------------------------------
-- Search Popup Frame
-----------------------------------------------------------------------
local searchFrame = CreateFrame("Frame", "VendorArbSearchFrame", UIParent, "BackdropTemplate")
searchFrame:SetSize(350, 300)
searchFrame:SetPoint("CENTER")
searchFrame:SetFrameStrata("DIALOG")
searchFrame:SetMovable(true)
searchFrame:EnableMouse(true)
searchFrame:RegisterForDrag("LeftButton")
searchFrame:SetScript("OnDragStart", searchFrame.StartMoving)
searchFrame:SetScript("OnDragStop", searchFrame.StopMovingOrSizing)
searchFrame:Hide()

searchFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})

-- Title
local title = searchFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -15)
title:SetText("VendorArb Item Search")

-- Close button
local closeBtn = CreateFrame("Button", nil, searchFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- Search input
local searchBox = CreateFrame("EditBox", "VendorArbSearchBox", searchFrame, "InputBoxTemplate")
searchBox:SetSize(280, 20)
searchBox:SetPoint("TOP", 0, -45)
searchBox:SetAutoFocus(false)
searchBox:SetMaxLetters(50)

local searchLabel = searchFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
searchLabel:SetPoint("BOTTOM", searchBox, "TOP", 0, 5)
searchLabel:SetText("Search for items by name:")

-- Results scroll frame
local resultsFrame = CreateFrame("ScrollFrame", "VendorArbSearchResults", searchFrame, "UIPanelScrollFrameTemplate")
resultsFrame:SetPoint("TOP", searchBox, "BOTTOM", 0, -15)
resultsFrame:SetPoint("LEFT", 15, 0)
resultsFrame:SetPoint("RIGHT", -35, 0)
resultsFrame:SetPoint("BOTTOM", 0, 15)

local resultsContent = CreateFrame("Frame", nil, resultsFrame)
resultsContent:SetWidth(280)
resultsContent:SetHeight(1)
resultsFrame:SetScrollChild(resultsContent)

-- Result rows storage
local searchResultRows = {}
local ROW_HEIGHT = 45

-- Debounce timer for search
local searchTimer = nil
local SEARCH_DELAY = 0.3  -- seconds to wait after typing stops

-----------------------------------------------------------------------
-- Create search result row
-----------------------------------------------------------------------
local function CreateSearchResultRow(parent, index)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))
    
    -- Background
    if index % 2 == 0 then
        row:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground" })
        row:SetBackdropColor(0.15, 0.15, 0.15, 0.5)
    end
    
    -- Item icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(32, 32)
    row.icon:SetPoint("LEFT", 5, 0)
    
    -- Item name
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.nameText:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
    row.nameText:SetPoint("RIGHT", -5, 0)
    row.nameText:SetJustifyH("LEFT")
    
    -- Price info
    row.priceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.priceText:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
    row.priceText:SetPoint("RIGHT", -5, 0)
    row.priceText:SetJustifyH("LEFT")
    
    -- Tooltip on hover
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    return row
end

-----------------------------------------------------------------------
-- Search function
-----------------------------------------------------------------------
local function PerformSearch(query)
    if not query or query == "" then
        -- Clear results
        for _, row in ipairs(searchResultRows) do
            row:Hide()
        end
        resultsContent:SetHeight(1)
        return
    end
    
    query = query:lower()
    local results = {}
    
    -- Search through VendorArb_ItemDB
    if VendorArb_ItemDB then
        for itemID, data in pairs(VendorArb_ItemDB) do
            local itemName = GetItemInfo(itemID)
            if itemName and itemName:lower():find(query, 1, true) then
                table.insert(results, {
                    itemID = itemID,
                    name = itemName,
                    buyPrice = data.buy,
                    sellPrice = data.sell,
                })
            end
        end
    end
    
    -- Also search VENDOR_PRICES for curated vendor items
    if VENDOR_PRICES then
        for itemID, buyPrice in pairs(VENDOR_PRICES) do
            local itemName = GetItemInfo(itemID)
            if itemName and itemName:lower():find(query, 1, true) then
                -- Check if not already in results
                local found = false
                for _, r in ipairs(results) do
                    if r.itemID == itemID then
                        found = true
                        break
                    end
                end
                if not found then
                    local sellPrice = VendorArb_ItemDB and VendorArb_ItemDB[itemID] and VendorArb_ItemDB[itemID].sell
                    table.insert(results, {
                        itemID = itemID,
                        name = itemName,
                        buyPrice = buyPrice,
                        sellPrice = sellPrice,
                    })
                end
            end
        end
    end
    
    -- Sort results alphabetically
    table.sort(results, function(a, b)
        return a.name < b.name
    end)
    
    -- Limit results
    local maxResults = 20
    
    -- Ensure we have enough rows
    for i = #searchResultRows + 1, math.min(#results, maxResults) do
        searchResultRows[i] = CreateSearchResultRow(resultsContent, i)
    end
    
    -- Update rows
    for i, row in ipairs(searchResultRows) do
        if i <= #results and i <= maxResults then
            local r = results[i]
            row.itemID = r.itemID
            
            -- Set icon
            local iconTexture = GetItemIcon(r.itemID)
            if iconTexture then
                row.icon:SetTexture(iconTexture)
            end
            
            -- Set name
            local _, link = GetItemInfo(r.itemID)
            row.nameText:SetText(link or r.name)
            
            -- Set price info
            local priceStr = ""
            if r.buyPrice and r.buyPrice > 0 then
                priceStr = "Buy: " .. FormatMoneyIcons(r.buyPrice)
            end
            if r.sellPrice and r.sellPrice > 0 then
                if priceStr ~= "" then priceStr = priceStr .. "  |  " end
                priceStr = priceStr .. "Sell: " .. FormatMoneyIcons(r.sellPrice)
            end
            row.priceText:SetText(priceStr)
            
            row:Show()
        else
            row:Hide()
        end
    end
    
    -- Update scroll content height
    local visibleCount = math.min(#results, maxResults)
    resultsContent:SetHeight(math.max(1, visibleCount * ROW_HEIGHT))
    
    -- Show count if limited
    if #results > maxResults then
        title:SetText(string.format("VendorArb Item Search (%d+ results)", maxResults))
    elseif #results > 0 then
        title:SetText(string.format("VendorArb Item Search (%d results)", #results))
    else
        title:SetText("VendorArb Item Search (no results)")
    end
end

-- Search on text change (debounced to prevent lag)
searchBox:SetScript("OnTextChanged", function(self)
    -- Cancel any pending search
    if searchTimer then
        searchTimer:Cancel()
    end
    -- Schedule new search after delay
    searchTimer = C_Timer.NewTimer(SEARCH_DELAY, function()
        PerformSearch(self:GetText())
    end)
end)

searchBox:SetScript("OnEnterPressed", function(self)
    PerformSearch(self:GetText())
    self:ClearFocus()
end)

searchBox:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
    searchFrame:Hide()
end)

-----------------------------------------------------------------------
-- Toggle search frame
-----------------------------------------------------------------------
local function ToggleSearchFrame()
    if searchFrame:IsShown() then
        searchFrame:Hide()
    else
        searchFrame:Show()
        searchBox:SetFocus()
    end
end

-----------------------------------------------------------------------
-- Minimap button clicks
-----------------------------------------------------------------------
minimapButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        ToggleSearchFrame()
    elseif button == "RightButton" then
        -- Right-click opens AH tab if available
        if AuctionFrame and AuctionFrame:IsShown() then
            local tab = _G["AuctionFrameTab" .. (vendorArbTabID or 4)]
            if tab then
                tab:Click()
            end
        else
            print(ADDON_PREFIX, "Open the Auction House to access the VendorArb tab.")
        end
    end
end)

-- Tooltip
minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("VendorArb")
    GameTooltip:AddLine("|cffffffffLeft-Click:|r Search Items", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffRight-Click:|r Open VendorArb Tab (at AH)", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffDrag:|r Move Button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

-----------------------------------------------------------------------
-- Slash command for search
-----------------------------------------------------------------------
SLASH_VARBSEARCH1 = "/varbsearch"
SLASH_VARBSEARCH2 = "/vas"
SlashCmdList["VARBSEARCH"] = function(msg)
    ToggleSearchFrame()
    if msg and msg ~= "" then
        searchBox:SetText(msg)
        PerformSearch(msg)
    end
end

-----------------------------------------------------------------------
-- Initialize on load
-----------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        LoadMinimapPosition()
        print(ADDON_PREFIX, "Minimap button ready. Left-click to search items, right-click at AH for VendorArb tab.")
    end
end)

-- Close search frame with Escape key
tinsert(UISpecialFrames, "VendorArbSearchFrame")
