-- VendorArb.lua
-- Find vendor->AH arbitrage: items you can buy from vendors and sell on AH for profit

local ADDON_PREFIX = "|cff00ff00[VendorArb]|r"

-----------------------------------------------------------------------
-- Config
-----------------------------------------------------------------------
local AH_CUT = 0.05              -- 5% AH cut on successful sale
local MIN_PROFIT_COPPER = 100    -- Minimum profit to show (1 silver)
local MAX_RESULTS_PRINT = 30     -- How many results to print to chat

-----------------------------------------------------------------------
-- Utils
-----------------------------------------------------------------------
local function FormatMoney(copper)
    copper = copper or 0
    local negative = copper < 0
    copper = math.abs(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100

    local str
    if gold > 0 then
        str = string.format("%dg %02ds %02dc", gold, silver, bronze)
    elseif silver > 0 then
        str = string.format("%ds %02dc", silver, bronze)
    else
        str = string.format("%dc", bronze)
    end
    
    return negative and ("-" .. str) or str
end

-- Format money with currency icons
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

-- Extract itemID from an item link
local function GetItemIDFromLink(itemLink)
    if not itemLink then return nil end
    local itemID = itemLink:match("item:(%d+)")
    return itemID and tonumber(itemID) or nil
end

-- If at a merchant, try to get the unit price with your current reputation discount
local function GetRepAdjustedVendorUnitPrice(itemID)
    if not itemID then return nil end
    if not MerchantFrame or not MerchantFrame:IsShown() then return nil end
    if not GetMerchantNumItems then return nil end

    local num = GetMerchantNumItems()
    if not num or num <= 0 then return nil end

    for i = 1, num do
        local link = GetMerchantItemLink(i)
        if link then
            local mid = GetItemIDFromLink(link)
            if mid == itemID then
                local name, texture, price, quantity, numAvailable, isUsable, extendedCost = GetMerchantItemInfo(i)
                if extendedCost then
                    -- Items with alternate currency; skip
                    return nil
                end
                if price and price > 0 then
                    quantity = (quantity and quantity > 0) and quantity or 1
                    return math.floor(price / quantity)
                end
            end
        end
    end
    return nil
end

-----------------------------------------------------------------------
-- Tooltip hook: show vendor buy price on item hover
-----------------------------------------------------------------------
local function OnTooltipSetItem(tooltip)
    local _, itemLink = tooltip:GetItem()
    if not itemLink then return end
    
    local itemID = GetItemIDFromLink(itemLink)
    if not itemID then return end
    
    -- Get buy price from curated VENDOR_PRICES, sell price from full ItemDB
    local buyPrice = VENDOR_PRICES and VENDOR_PRICES[itemID]
    local sellPrice = VendorArb_ItemDB and VendorArb_ItemDB[itemID] and VendorArb_ItemDB[itemID].sell
    
    if (buyPrice and buyPrice > 0) or (sellPrice and sellPrice > 0) then
        tooltip:AddLine(" ")
        if buyPrice and buyPrice > 0 then
            tooltip:AddDoubleLine(
                "[VA] Vendor Buy:",
                FormatMoneyIcons(buyPrice),
                1, 0.82, 0,  -- left text color (yellow)
                1, 1, 1   -- right text color (white)
            )

            -- If you're talking to a merchant that sells this item, show your rep-adjusted price
            local repUnitPrice = GetRepAdjustedVendorUnitPrice(itemID)
            if repUnitPrice and repUnitPrice > 0 and repUnitPrice ~= buyPrice then
                local rightText = FormatMoneyIcons(repUnitPrice)
                -- Try to show discount percentage compared to base if we can infer it
                if buyPrice and buyPrice > 0 and repUnitPrice < buyPrice then
                    local pct = (1 - (repUnitPrice / buyPrice)) * 100
                    -- Round to nearest 5% to match rep tiers
                    local nearest = 5 * math.floor((pct / 5) + 0.5)
                    if nearest > 0 then
                        rightText = string.format("%s (-%d%%)", rightText, nearest)
                    end
                end
                tooltip:AddDoubleLine(
                    "[VA] Vendor Buy (rep):",
                    rightText,
                    1, 0.82, 0,
                    0.8, 1, 0.8
                )
            end
        end
        if sellPrice and sellPrice > 0 then
            tooltip:AddDoubleLine(
                "[VA] Vendor Sell:",
                FormatMoneyIcons(sellPrice),
                1, 0.82, 0,  -- left text color (yellow)
                1, 1, 1   -- right text color (white)
            )
        end
        tooltip:Show()
    end
end

-- Hook all the tooltip types
local function SetupTooltipHook()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
        -- Retail/newer Classic API
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipSetItem)
    else
        -- Classic Era API
        GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        ShoppingTooltip1:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        ShoppingTooltip2:HookScript("OnTooltipSetItem", OnTooltipSetItem)
    end
end

-- Setup tooltip hooks on load
C_Timer.After(0, SetupTooltipHook)

-----------------------------------------------------------------------
-- Scanner state
-----------------------------------------------------------------------
local scanner = {
    running = false,
    results = {},
    itemsChecked = 0,
    vendorItemsFound = 0,
}

-----------------------------------------------------------------------
-- Sort state
-----------------------------------------------------------------------
local sortState = {
    column = "profit",  -- Default sort column
    ascending = false,  -- Default descending (highest first)
}

-----------------------------------------------------------------------
-- Data persistence
-----------------------------------------------------------------------
local function SaveData()
    VendorArbDB = VendorArbDB or {}
    VendorArbDB.results = scanner.results
    VendorArbDB.scanTime = time()
    VendorArbDB.sortState = {
        column = sortState.column,
        ascending = sortState.ascending,
    }
end

local function LoadData()
    if not VendorArbDB then
        VendorArbDB = {}
        return
    end
    
    if VendorArbDB.results then
        scanner.results = VendorArbDB.results
    end
    
    if VendorArbDB.sortState then
        sortState.column = VendorArbDB.sortState.column or "profit"
        sortState.ascending = VendorArbDB.sortState.ascending or false
    end
end

local function GetTimeSinceLastScan()
    if not VendorArbDB or not VendorArbDB.scanTime then
        return nil
    end
    local elapsed = time() - VendorArbDB.scanTime
    if elapsed < 60 then
        return "just now"
    elseif elapsed < 3600 then
        return string.format("%d min ago", math.floor(elapsed / 60))
    elseif elapsed < 86400 then
        return string.format("%d hr ago", math.floor(elapsed / 3600))
    else
        return string.format("%d days ago", math.floor(elapsed / 86400))
    end
end

local function UpdateStatusText()
    if not VendorArbStatus then return end
    
    local numResults = #scanner.results
    if numResults > 0 then
        local timeStr = GetTimeSinceLastScan()
        if timeStr then
            VendorArbStatus:SetText(string.format(
                "Showing %d opportunities (scanned %s). Click 'Scan AH' to refresh.",
                numResults, timeStr
            ))
        else
            VendorArbStatus:SetText(string.format(
                "Showing %d profitable opportunities.",
                numResults
            ))
        end
    else
        VendorArbStatus:SetText("Press 'Scan AH' to find arbitrage opportunities.")
    end
end

-----------------------------------------------------------------------
-- UI elements
-----------------------------------------------------------------------
local vendorArbTabID = nil
local VendorArbPanel = nil
local VendorArbStatus = nil
local VendorArbProgressBar = nil
local VendorArbProgressText = nil
local VendorArbTitleText = nil
local VendorArbScanButton = nil
local VendorArbResultsScrollFrame = nil
local VendorArbResultsContent = nil
local resultRows = {}

-----------------------------------------------------------------------
-- Create a result row
-----------------------------------------------------------------------
local ROW_HEIGHT = 20

local function CreateResultRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

    -- Alternating background
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if index % 2 == 0 then
        bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
    else
        bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    end

    -- Highlight on hover
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(0.3, 0.3, 0.0, 0.3)

    -- Item icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
    row.icon:SetPoint("LEFT", 2, 0)

    -- Item name/link (after icon)
    row.itemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.itemText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.itemText:SetWidth(200)
    row.itemText:SetJustifyH("LEFT")

    -- Count/Quantity
    row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.countText:SetPoint("LEFT", row, "LEFT", 230, 0)
    row.countText:SetWidth(70)
    row.countText:SetJustifyH("LEFT")

    -- Vendor cost
    row.vendorText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.vendorText:SetPoint("LEFT", row, "LEFT", 310, 0)
    row.vendorText:SetWidth(120)
    row.vendorText:SetJustifyH("RIGHT")

    -- AH price
    row.ahText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ahText:SetPoint("LEFT", row, "LEFT", 440, 0)
    row.ahText:SetWidth(120)
    row.ahText:SetJustifyH("RIGHT")

    -- Profit
    row.profitText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.profitText:SetPoint("LEFT", row, "LEFT", 570, 0)
    row.profitText:SetWidth(120)
    row.profitText:SetJustifyH("RIGHT")
    row.profitText:SetTextColor(0, 1, 0)

    -- ROI %
    row.roiText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.roiText:SetPoint("LEFT", row, "LEFT", 700, 0)
    row.roiText:SetWidth(60)
    row.roiText:SetJustifyH("RIGHT")
    row.roiText:SetTextColor(0, 1, 0)

    -- Tooltip on hover
    row:SetScript("OnEnter", function(self)
        if self.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    return row
end

-----------------------------------------------------------------------
-- Sort the results based on current sort state
-----------------------------------------------------------------------
local function SortResults()
    local col = sortState.column
    local asc = sortState.ascending
    
    table.sort(scanner.results, function(a, b)
        local valA, valB
        
        if col == "vendorCost" then
            valA, valB = a.vendorCost, b.vendorCost
        elseif col == "ahPrice" then
            valA, valB = a.ahPrice, b.ahPrice
        elseif col == "profit" then
            valA, valB = a.profit, b.profit
        elseif col == "roi" then
            valA, valB = a.roi, b.roi
        else
            valA, valB = a.profit, b.profit  -- fallback
        end
        
        if asc then
            return valA < valB
        else
            return valA > valB
        end
    end)
end

-----------------------------------------------------------------------
-- Update the results list display
-----------------------------------------------------------------------
local function UpdateResultsList()
    if not VendorArbResultsContent then return end
    
    -- Apply current sort
    SortResults()

    local results = scanner.results
    local numResults = #results

    -- Ensure we have enough rows
    for i = #resultRows + 1, numResults do
        resultRows[i] = CreateResultRow(VendorArbResultsContent, i)
    end

    -- Update row data
    for i, row in ipairs(resultRows) do
        if i <= numResults then
            local r = results[i]
            row.link = r.link
            
            -- Set item icon
            local itemID = GetItemIDFromLink(r.link)
            if itemID then
                local iconTexture = GetItemIcon(itemID)
                if iconTexture then
                    row.icon:SetTexture(iconTexture)
                end
            end
            
            row.itemText:SetText(r.link or r.name)
            row.countText:SetText("per unit")
            row.vendorText:SetText(FormatMoneyIcons(r.vendorCost))
            row.ahText:SetText(FormatMoneyIcons(r.ahPrice))
            row.profitText:SetText(FormatMoneyIcons(r.profit))
            row.roiText:SetText(string.format("%.0f%%", r.roi * 100))
            row:Show()
        else
            row:Hide()
        end
    end

    -- Update scroll content height
    VendorArbResultsContent:SetHeight(math.max(1, numResults * ROW_HEIGHT))
end

-----------------------------------------------------------------------
-- Create the panel UI
-----------------------------------------------------------------------
local function CreateVendorArbPanel()
    if VendorArbPanel then return end
    if not AuctionFrame then return end

    local f = CreateFrame("Frame", "VendorArbPanel", AuctionFrame)
    f:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 8, -50)
    f:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -8, 35)
    f:SetFrameLevel(AuctionFrame:GetFrameLevel() + 10)  -- Ensure we're above other content
    f:Hide()
    VendorArbPanel = f

    -- Use AH-style marble background texture (tiled)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble", "REPEAT", "REPEAT")
    bg:SetHorizTile(true)
    bg:SetVertTile(true)
    
    -- Update texture coords when frame resizes to tile properly
    f:SetScript("OnSizeChanged", function(self, width, height)
        local tileSize = 256  -- Standard texture size
        bg:SetTexCoord(0, width/tileSize, 0, height/tileSize)
    end)
    -- Initial sizing
    C_Timer.After(0, function()
        local width, height = f:GetSize()
        if width > 0 and height > 0 then
            bg:SetTexCoord(0, width/256, 0, height/256)
        end
    end)

    -- Status text at top
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -15)
    status:SetText("Press 'Scan AH' to find arbitrage opportunities.")
    VendorArbStatus = status

    -- Scan button in top-right area
    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(100, 22)
    btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -10)
    btn:SetText("Scan AH")
    btn:SetScript("OnClick", function()
        if StartScan then StartScan() end
    end)
    VendorArbScanButton = btn
    f.ScanButton = btn

    -- Progress bar (next to status)
    local barWidth, barHeight = 200, 16
    local progressBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    progressBg:SetSize(barWidth, barHeight)
    progressBg:SetPoint("LEFT", status, "RIGHT", 15, 0)
    progressBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    progressBg:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    progressBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    f.ProgressBg = progressBg

    local progressBar = CreateFrame("StatusBar", nil, progressBg)
    progressBar:SetPoint("TOPLEFT", 4, -4)
    progressBar:SetPoint("BOTTOMRIGHT", -4, 4)
    progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    progressBar:SetStatusBarColor(0.0, 0.8, 0.0, 1)
    progressBar:SetMinMaxValues(0, 1)
    progressBar:SetValue(0)
    VendorArbProgressBar = progressBar

    local progressText = progressBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressText:SetPoint("CENTER", progressBar, "CENTER", 0, 0)
    progressText:SetText("")
    VendorArbProgressText = progressText

    -- Column headers
    local headerY = -40
    local headerFrame = CreateFrame("Frame", nil, f)
    headerFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, headerY)
    headerFrame:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, headerY)
    headerFrame:SetHeight(20)

    local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)

    -- Arrow indicators for sort direction
    local ARROW_UP = " ▲"
    local ARROW_DOWN = " ▼"
    
    local headerButtons = {}
    
    local headers = {
        { text = "Name", offset = 5, width = 220, sortKey = nil },
        { text = "Pricing", offset = 230, width = 75, sortKey = nil },
        { text = "Vendor Cost", offset = 310, width = 125, sortKey = "vendorCost" },
        { text = "Min AH Price", offset = 440, width = 125, sortKey = "ahPrice" },
        { text = "Profit", offset = 570, width = 125, sortKey = "profit" },
        { text = "ROI", offset = 700, width = 70, sortKey = "roi" },
    }
    
    -- Function to update header text with sort arrows
    local function UpdateHeaderArrows()
        for _, hBtn in ipairs(headerButtons) do
            if hBtn.sortKey then
                local arrow = ""
                if sortState.column == hBtn.sortKey then
                    arrow = sortState.ascending and ARROW_UP or ARROW_DOWN
                end
                hBtn.text:SetText(hBtn.baseText .. arrow)
            end
        end
    end

    for i, h in ipairs(headers) do
        if h.sortKey then
            -- Create clickable button for sortable columns
            local headerBtn = CreateFrame("Button", nil, headerFrame)
            headerBtn:SetPoint("LEFT", headerFrame, "LEFT", h.offset, 0)
            headerBtn:SetSize(h.width, 20)
            headerBtn.sortKey = h.sortKey
            headerBtn.baseText = h.text
            
            local headerText = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT", 0, 0)
            headerText:SetText(h.text)
            headerText:SetTextColor(1, 0.82, 0)
            headerBtn.text = headerText
            
            -- Highlight on hover
            headerBtn:SetScript("OnEnter", function(self)
                self.text:SetTextColor(1, 1, 0)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText("Click to sort by " .. self.baseText)
                GameTooltip:Show()
            end)
            headerBtn:SetScript("OnLeave", function(self)
                self.text:SetTextColor(1, 0.82, 0)
                GameTooltip:Hide()
            end)
            
            -- Click to sort
            headerBtn:SetScript("OnClick", function(self)
                if sortState.column == self.sortKey then
                    -- Toggle direction if same column
                    sortState.ascending = not sortState.ascending
                else
                    -- New column, default to descending (highest first)
                    sortState.column = self.sortKey
                    sortState.ascending = false
                end
                UpdateHeaderArrows()
                UpdateResultsList()
                SaveData()  -- Persist sort preference
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            end)
            
            table.insert(headerButtons, headerBtn)
        else
            -- Non-sortable column (just text)
            local headerText = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT", headerFrame, "LEFT", h.offset, 0)
            headerText:SetText(h.text)
            headerText:SetTextColor(1, 0.82, 0)
        end
    end
    
    -- Initial arrow update
    UpdateHeaderArrows()

    -- Scrollable results area
    local scrollFrame = CreateFrame("ScrollFrame", "VendorArbScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -2)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 10)
    VendorArbResultsScrollFrame = scrollFrame

    local scrollContent = CreateFrame("Frame", "VendorArbScrollContent", scrollFrame)
    scrollContent:SetWidth(scrollFrame:GetWidth() - 20)
    scrollContent:SetHeight(1)
    scrollFrame:SetScrollChild(scrollContent)
    VendorArbResultsContent = scrollContent

    -- Update content width when scrollframe resizes
    scrollFrame:SetScript("OnSizeChanged", function(self, width, height)
        scrollContent:SetWidth(width - 20)
    end)
end

-----------------------------------------------------------------------
-- Create the AH tab
-----------------------------------------------------------------------
local function CreateVendorArbTab()
    if vendorArbTabID then return end
    if not AuctionFrame then return end

    CreateVendorArbPanel()

    local auctionFrame = AuctionFrame
    local numTabs = auctionFrame.numTabs or 0
    local i = 1
    while _G["AuctionFrameTab"..i] do
        i = i + 1
    end
    numTabs = math.max(numTabs, i - 1)

    vendorArbTabID = numTabs + 1

    local tabName = "AuctionFrameTab"..vendorArbTabID
    local tab = CreateFrame("Button", tabName, auctionFrame, "AuctionTabTemplate")
    tab:SetID(vendorArbTabID)
    tab:SetText("VendorArb")

    local lastTab = _G["AuctionFrameTab"..numTabs]
    if lastTab then
        tab:SetPoint("LEFT", lastTab, "RIGHT", -8, 0)
    else
        tab:SetPoint("BOTTOMLEFT", auctionFrame, "BOTTOMLEFT", 15, -30)
    end

    PanelTemplates_SetNumTabs(auctionFrame, vendorArbTabID)
    PanelTemplates_EnableTab(auctionFrame, vendorArbTabID)

    -- Create custom title bar text
    VendorArbTitleText = AuctionFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    VendorArbTitleText:SetPoint("TOP", AuctionFrame, "TOP", 0, -18)
    VendorArbTitleText:SetText("VendorArb")
    VendorArbTitleText:Hide()

    tab:SetScript("OnClick", function(self)
        PanelTemplates_SetTab(auctionFrame, vendorArbTabID)
        
        -- Hide all standard AH frames
        if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
        if AuctionFrameBid then AuctionFrameBid:Hide() end
        if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
        
        -- Hide Auctionator frames if present
        if AuctionatorShoppingFrame then AuctionatorShoppingFrame:Hide() end
        if AuctionatorSellingFrame then AuctionatorSellingFrame:Hide() end
        if AuctionatorCancellingFrame then AuctionatorCancellingFrame:Hide() end
        if AuctionatorConfigFrame then AuctionatorConfigFrame:Hide() end
        
        -- Hide any children of AuctionFrame that look like content panels
        for _, child in ipairs({AuctionFrame:GetChildren()}) do
            if child ~= VendorArbPanel and child.Hide and child:IsShown() then
                local name = child:GetName()
                -- Hide unnamed frames or frames that look like content panels
                if not name or (name and (name:find("Frame") or name:find("Panel"))) then
                    -- Don't hide tabs, title, portrait, or our own panel
                    if not name or (not name:find("Tab") and not name:find("Portrait") and not name:find("Title")) then
                        child:Hide()
                    end
                end
            end
        end
        
        if VendorArbPanel then 
            VendorArbPanel:Show()
            UpdateStatusText()
            UpdateResultsList()
        end
        if VendorArbTitleText then VendorArbTitleText:Show() end
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    end)

    -- Function to hide our panel
    local function HideVendorArbPanel()
        if VendorArbPanel then VendorArbPanel:Hide() end
        if VendorArbTitleText then VendorArbTitleText:Hide() end
    end

    -- Hook the standard Blizzard AH tabs directly
    for i = 1, 3 do
        local blizzTab = _G["AuctionFrameTab" .. i]
        if blizzTab then
            blizzTab:HookScript("OnClick", HideVendorArbPanel)
        end
    end
    
    -- Hook OnShow for the standard AH frames - when they show, hide our panel
    if AuctionFrameBrowse then
        AuctionFrameBrowse:HookScript("OnShow", HideVendorArbPanel)
    end
    if AuctionFrameBid then
        AuctionFrameBid:HookScript("OnShow", HideVendorArbPanel)
    end
    if AuctionFrameAuctions then
        AuctionFrameAuctions:HookScript("OnShow", HideVendorArbPanel)
    end
    
    -- Hook to hide our panel when other tabs are clicked (for addon tabs)
    hooksecurefunc("AuctionFrameTab_OnClick", function(self, index)
        local id = index or (self and self.GetID and self:GetID())
        if id ~= vendorArbTabID then
            HideVendorArbPanel()
        end
    end)
    
    -- Also hook PanelTemplates_SetTab for addons that use it directly
    hooksecurefunc("PanelTemplates_SetTab", function(frame, id)
        if frame == AuctionFrame and id ~= vendorArbTabID then
            HideVendorArbPanel()
        end
    end)
    
    -- Hook any future tabs that get added
    hooksecurefunc("PanelTemplates_SetNumTabs", function(frame, numTabs)
        if frame == AuctionFrame then
            for i = 1, numTabs do
                local otherTab = _G["AuctionFrameTab" .. i]
                if otherTab and i ~= vendorArbTabID and not otherTab.vendorArbHooked then
                    otherTab:HookScript("OnClick", HideVendorArbPanel)
                    otherTab.vendorArbHooked = true
                end
            end
        end
    end)
end

-----------------------------------------------------------------------
-- Core: Scan current AH page for vendor items
-- Track the lowest price per unit for each vendor item
-----------------------------------------------------------------------
local lowestPrices = {}  -- itemID -> { pricePerUnit, name, link }

local function ProcessCurrentPage()
    local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")
    if totalAuctions == 0 or numBatchAuctions == 0 then
        return 0
    end

    local foundOnPage = 0

    for i = 1, numBatchAuctions do
        local name, _, count, _, _, _, _, _, _, buyoutPrice, _, _, _, _, _, _ = GetAuctionItemInfo("list", i)
        local itemLink = GetAuctionItemLink("list", i)

        if name and itemLink and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
            local itemID = GetItemIDFromLink(itemLink)
            scanner.itemsChecked = scanner.itemsChecked + 1

            if itemID and VendorArb_ItemDB and VendorArb_ItemDB[itemID] then
                scanner.vendorItemsFound = scanner.vendorItemsFound + 1
                foundOnPage = foundOnPage + 1

                -- Calculate price per unit for this listing
                local pricePerUnit = buyoutPrice / count
                
                -- Track the lowest price per unit for this item
                if not lowestPrices[itemID] or pricePerUnit < lowestPrices[itemID].pricePerUnit then
                    lowestPrices[itemID] = {
                        pricePerUnit = pricePerUnit,
                        name = name,
                        link = itemLink,
                    }
                end
            end
        end
    end

    return foundOnPage
end

-----------------------------------------------------------------------
-- Finish scan: calculate profits using lowest prices and display
-----------------------------------------------------------------------
local function FinishScan()
    scanner.running = false

    -- Update progress
    if VendorArbProgressBar then VendorArbProgressBar:SetValue(1) end
    if VendorArbProgressText then VendorArbProgressText:SetText("100%") end

    -- Convert lowest prices to results with profit calculations
    scanner.results = {}
    for itemID, data in pairs(lowestPrices) do
        local vendorCost = VendorArb_ItemDB[itemID].buy  -- Cost per unit from vendor
        local ahPrice = data.pricePerUnit         -- Lowest AH price per unit
        
        -- Calculate profit: sell at lowest AH price minus AH cut, compare to vendor cost
        local ahFee = math.floor(ahPrice * AH_CUT)
        local netFromSale = ahPrice - ahFee
        local profit = netFromSale - vendorCost
        local roi = vendorCost > 0 and (profit / vendorCost) or 0

        if profit >= MIN_PROFIT_COPPER then
            table.insert(scanner.results, {
                name = data.name,
                link = data.link,
                count = 1,  -- Normalized to per-unit
                vendorCost = vendorCost,
                ahPrice = math.floor(ahPrice),
                profit = math.floor(profit),
                roi = roi,
            })
        end
    end

    print(string.format(
        "%s Scan complete: %d auctions checked, %d vendor items found, %d profitable",
        ADDON_PREFIX,
        scanner.itemsChecked,
        scanner.vendorItemsFound,
        #scanner.results
    ))

    if #scanner.results == 0 then
        if VendorArbStatus then
            VendorArbStatus:SetText("No profitable vendor->AH opportunities found.")
        end
        UpdateResultsList()
        return
    end

    if VendorArbStatus then
        VendorArbStatus:SetText(string.format(
            "Found %d profitable opportunities.",
            #scanner.results
        ))
    end

    -- Save results to persist across sessions
    SaveData()

    -- Update the results list in the UI
    UpdateResultsList()
end

-----------------------------------------------------------------------
-- Multi-page scan driver
-----------------------------------------------------------------------
local scanPage = 0
local totalScanPages = 0

local scanFrame = CreateFrame("Frame")
scanFrame:Hide()

scanFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "VendorArb" then
            -- Load saved data when our addon loads
            LoadData()
        elseif name == "Blizzard_AuctionUI" then
            CreateVendorArbTab()
        end

    elseif event == "AUCTION_HOUSE_SHOW" then
        CreateVendorArbTab()

    elseif event == "AUCTION_ITEM_LIST_UPDATE" and scanner.running then
        ProcessCurrentPage()

        -- Get total pages on first result
        if scanPage == 0 then
            local _, total = GetNumAuctionItems("list")
            totalScanPages = math.floor((total - 1) / 50)
        end

        -- Update progress
        local progress = totalScanPages > 0 and ((scanPage + 1) / (totalScanPages + 1)) or 0.5
        if VendorArbProgressBar then VendorArbProgressBar:SetValue(progress) end
        if VendorArbProgressText then VendorArbProgressText:SetText(string.format("%d%%", math.floor(progress * 100))) end
        -- Count unique items found so far
        local uniqueCount = 0
        for _ in pairs(lowestPrices) do uniqueCount = uniqueCount + 1 end
        
        if VendorArbStatus then
            VendorArbStatus:SetText(string.format(
                "Scanning page %d/%d... Found %d unique vendor items",
                scanPage + 1,
                totalScanPages + 1,
                uniqueCount
            ))
        end

        -- Next page
        if scanPage < totalScanPages then
            scanPage = scanPage + 1
            local function QueryNext()
                if not scanner.running then return end
                if CanSendAuctionQuery() then
                    QueryAuctionItems("", nil, nil, scanPage, nil, nil, false, false, nil)
                else
                    C_Timer.After(0.1, QueryNext)
                end
            end
            C_Timer.After(0.05, QueryNext)
        else
            FinishScan()
        end

    elseif event == "AUCTION_HOUSE_CLOSED" and scanner.running then
        print(ADDON_PREFIX, "Auction House closed; scan aborted.")
        scanner.running = false
    end
end)

scanFrame:RegisterEvent("ADDON_LOADED")
scanFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
scanFrame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
scanFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

-----------------------------------------------------------------------
-- Start scan
-----------------------------------------------------------------------
StartScan = function()
    if not VendorArb_ItemDB then
        print(ADDON_PREFIX, "ERROR: ItemDB.lua not loaded!")
        return
    end

    if scanner.running then
        print(ADDON_PREFIX, "Scan already in progress.")
        return
    end

    if not AuctionFrame or not AuctionFrame:IsShown() then
        print(ADDON_PREFIX, "Open the Auction House first.")
        return
    end

    -- Count vendor items
    local vendorItemCount = 0
    for _ in pairs(VendorArb_ItemDB) do vendorItemCount = vendorItemCount + 1 end
    print(ADDON_PREFIX, "Starting scan. Checking AH against", vendorItemCount, "known vendor items...")

    scanner.running = true
    scanner.results = {}
    scanner.itemsChecked = 0
    scanner.vendorItemsFound = 0
    lowestPrices = {}  -- Reset lowest price tracking
    scanPage = 0
    totalScanPages = 0

    if VendorArbProgressBar then VendorArbProgressBar:SetValue(0) end
    if VendorArbProgressText then VendorArbProgressText:SetText("0%") end
    if VendorArbStatus then VendorArbStatus:SetText("Starting scan...") end

    -- Start with first page query
    QueryAuctionItems("", nil, nil, 0, nil, nil, false, false, nil)
end

-----------------------------------------------------------------------
-- Slash command
-----------------------------------------------------------------------
SLASH_VENDORARB1 = "/varb"
SlashCmdList["VENDORARB"] = function(msg)
    StartScan()
end

print(ADDON_PREFIX, "loaded. Open the AH and use /varb or click the VendorArb tab to scan.")
