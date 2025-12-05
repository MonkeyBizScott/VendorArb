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

-----------------------------------------------------------------------
-- Tooltip hook: show vendor buy price on item hover
-----------------------------------------------------------------------
local function OnTooltipSetItem(tooltip)
    if not VENDOR_PRICES then return end
    
    local _, itemLink = tooltip:GetItem()
    if not itemLink then return end
    
    local itemID = GetItemIDFromLink(itemLink)
    if not itemID then return end
    
    local vendorBuyPrice = VENDOR_PRICES[itemID]
    if vendorBuyPrice and vendorBuyPrice > 0 then
        tooltip:AddLine(" ")
        tooltip:AddDoubleLine(
            "|cff00ff00[VendorArb]|r Buy from vendor:",
            FormatMoneyIcons(vendorBuyPrice),
            1, 1, 0,  -- left text color (yellow)
            1, 1, 1   -- right text color (white)
        )
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
local VendorArbPrevButton = nil
local VendorArbNextButton = nil
local VendorArbPageText = nil
local resultRows = {}

-- Pagination state
local RESULTS_PER_PAGE = 15
local currentPage = 1

-- Sorting state
local sortColumn = "profit"  -- default sort
local sortAscending = false  -- default descending (best first)

local function SortResults()
    if #scanner.results == 0 then return end
    
    table.sort(scanner.results, function(a, b)
        local valA, valB
        if sortColumn == "vendorCost" then
            valA, valB = a.vendorCost or 0, b.vendorCost or 0
        elseif sortColumn == "ahPrice" then
            valA, valB = a.ahPrice or 0, b.ahPrice or 0
        elseif sortColumn == "profit" then
            valA, valB = a.profit or 0, b.profit or 0
        elseif sortColumn == "roi" then
            valA, valB = a.roi or 0, b.roi or 0
        else
            return false
        end
        
        if sortAscending then
            return valA < valB
        else
            return valA > valB
        end
    end)
    
    currentPage = 1  -- Reset to first page after sort
end

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
-- Update the results list display
-----------------------------------------------------------------------
local function UpdateResultsList()
    if not VendorArbResultsContent then return end

    local results = scanner.results
    local numResults = #results
    local totalPages = math.max(1, math.ceil(numResults / RESULTS_PER_PAGE))
    
    -- Clamp current page
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1 then currentPage = 1 end
    
    -- Calculate which results to show
    local startIdx = (currentPage - 1) * RESULTS_PER_PAGE + 1
    local endIdx = math.min(currentPage * RESULTS_PER_PAGE, numResults)
    local rowsToShow = endIdx - startIdx + 1
    if numResults == 0 then rowsToShow = 0 end

    -- Ensure we have enough rows for one page
    for i = #resultRows + 1, RESULTS_PER_PAGE do
        resultRows[i] = CreateResultRow(VendorArbResultsContent, i)
    end

    -- Update row data
    for i = 1, RESULTS_PER_PAGE do
        local row = resultRows[i]
        local resultIdx = startIdx + i - 1
        
        if resultIdx <= numResults then
            local r = results[resultIdx]
            
            -- Get itemID from link or stored value
            local itemID = r.itemID or GetItemIDFromLink(r.link)
            
            -- Try to get/refresh the link from itemID if we don't have it
            local link = r.link
            if not link and itemID then
                local _, itemLink = GetItemInfo(itemID)
                link = itemLink
                r.link = link  -- cache it
            end
            row.link = link
            
            -- Set item icon
            if itemID then
                local iconTexture = GetItemIcon(itemID)
                if iconTexture then
                    row.icon:SetTexture(iconTexture)
                end
            end
            
            row.itemText:SetText(link or r.name)
            row.countText:SetText(r.count .. " stack of 1")
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
    VendorArbResultsContent:SetHeight(math.max(1, rowsToShow * ROW_HEIGHT))
    
    -- Update pagination controls
    if VendorArbPageText then
        VendorArbPageText:SetText(string.format("Page %d of %d  (%d results)", currentPage, totalPages, numResults))
    end
    if VendorArbPrevButton then
        VendorArbPrevButton:SetEnabled(currentPage > 1)
    end
    if VendorArbNextButton then
        VendorArbNextButton:SetEnabled(currentPage < totalPages)
    end
end

local function PrevPage()
    if currentPage > 1 then
        currentPage = currentPage - 1
        UpdateResultsList()
    end
end

local function NextPage()
    local totalPages = math.max(1, math.ceil(#scanner.results / RESULTS_PER_PAGE))
    if currentPage < totalPages then
        currentPage = currentPage + 1
        UpdateResultsList()
    end
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

    local headers = {
        { text = "Name", offset = 5, width = 200, sortKey = nil },
        { text = "Qty", offset = 230, width = 70, sortKey = nil },
        { text = "Vendor Cost", offset = 310, width = 120, sortKey = "vendorCost" },
        { text = "AH Price", offset = 440, width = 120, sortKey = "ahPrice" },
        { text = "Profit", offset = 570, width = 120, sortKey = "profit" },
        { text = "ROI", offset = 700, width = 60, sortKey = "roi" },
    }
    
    f.headerButtons = {}

    for _, h in ipairs(headers) do
        if h.sortKey then
            -- Sortable column - create a button
            local btn = CreateFrame("Button", nil, headerFrame)
            btn:SetPoint("LEFT", headerFrame, "LEFT", h.offset, 0)
            btn:SetSize(h.width, 20)
            
            local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btnText:SetPoint("LEFT", 0, 0)
            btnText:SetText(h.text)
            btnText:SetTextColor(1, 0.82, 0)
            btn.text = btnText
            btn.sortKey = h.sortKey
            btn.baseText = h.text
            
            btn:SetScript("OnClick", function(self)
                if sortColumn == self.sortKey then
                    sortAscending = not sortAscending
                else
                    sortColumn = self.sortKey
                    sortAscending = false  -- Default to descending for new column
                end
                SortResults()
                UpdateResultsList()
                -- Update header indicators
                for _, b in pairs(f.headerButtons) do
                    if b.sortKey == sortColumn then
                        local arrow = sortAscending and " ^" or " v"
                        b.text:SetText(b.baseText .. arrow)
                    else
                        b.text:SetText(b.baseText)
                    end
                end
            end)
            
            btn:SetScript("OnEnter", function(self)
                self.text:SetTextColor(1, 1, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                self.text:SetTextColor(1, 0.82, 0)
            end)
            
            f.headerButtons[h.sortKey] = btn
            
            -- Set initial indicator for default sort
            if h.sortKey == sortColumn then
                local arrow = sortAscending and " ^" or " v"
                btnText:SetText(h.text .. arrow)
            end
        else
            -- Non-sortable column - just text
            local headerText = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            headerText:SetPoint("LEFT", headerFrame, "LEFT", h.offset, 0)
            headerText:SetText(h.text)
            headerText:SetTextColor(1, 0.82, 0)
        end
    end

    -- Scrollable results area
    local scrollFrame = CreateFrame("ScrollFrame", "VendorArbScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -2)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 40)
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
    
    -- Pagination controls at bottom
    local prevBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prevBtn:SetSize(80, 22)
    prevBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 10)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", PrevPage)
    VendorArbPrevButton = prevBtn
    
    local nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    nextBtn:SetSize(80, 22)
    nextBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -40, 10)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", NextPage)
    VendorArbNextButton = nextBtn
    
    local pageText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pageText:SetPoint("BOTTOM", f, "BOTTOM", 0, 15)
    pageText:SetText("Page 1 of 1  (0 results)")
    VendorArbPageText = pageText
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
-----------------------------------------------------------------------
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

            if itemID and VENDOR_PRICES and VENDOR_PRICES[itemID] then
                scanner.vendorItemsFound = scanner.vendorItemsFound + 1
                foundOnPage = foundOnPage + 1

                local vendorBuyCost = VENDOR_PRICES[itemID] * count  -- Total cost to buy from vendor
                local ahBuyout = buyoutPrice                         -- Current AH price (per stack)
                
                -- Calculate profit: sell at current AH price minus AH cut, compare to vendor cost
                local ahFee = math.floor(ahBuyout * AH_CUT)
                local netFromSale = ahBuyout - ahFee
                local profit = netFromSale - vendorBuyCost
                local roi = vendorBuyCost > 0 and (profit / vendorBuyCost) or 0

                if profit >= MIN_PROFIT_COPPER then
                    table.insert(scanner.results, {
                        name = name,
                        link = itemLink,
                        count = count,
                        vendorCost = vendorBuyCost,
                        ahPrice = ahBuyout,
                        profit = profit,
                        roi = roi,
                    })
                end
            end
        end
    end

    return foundOnPage
end

-----------------------------------------------------------------------
-- Finish scan: sort and display results
-----------------------------------------------------------------------
local function FinishScan()
    scanner.running = false

    -- Update progress
    if VendorArbProgressBar then VendorArbProgressBar:SetValue(1) end
    if VendorArbProgressText then VendorArbProgressText:SetText("100%") end

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

    -- Sort by profit descending first (to keep best profit per item during dedup)
    table.sort(scanner.results, function(a, b)
        return a.profit > b.profit
    end)

    -- Remove duplicates (keep best profit per item)
    local seen = {}
    local unique = {}
    for _, r in ipairs(scanner.results) do
        local itemID = GetItemIDFromLink(r.link)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            table.insert(unique, r)
        end
    end
    scanner.results = unique
    
    -- Apply user's current sort preference
    SortResults()

    if VendorArbStatus then
        VendorArbStatus:SetText(string.format(
            "Found %d profitable opportunities.",
            #scanner.results
        ))
    end

    -- Update the results list in the UI
    UpdateResultsList()

    -- Save results to SavedVariables (store itemID instead of link, since links don't serialize)
    VendorArbDB = VendorArbDB or {}
    VendorArbDB.results = {}
    for _, r in ipairs(scanner.results) do
        local itemID = GetItemIDFromLink(r.link)
        table.insert(VendorArbDB.results, {
            itemID = itemID,
            name = r.name,
            count = r.count,
            vendorCost = r.vendorCost,
            ahPrice = r.ahPrice,
            profit = r.profit,
            roi = r.roi,
        })
    end
    VendorArbDB.lastScan = date("%Y-%m-%d %H:%M:%S")
    print(ADDON_PREFIX, "Results saved.")
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
            VendorArbDB = VendorArbDB or { results = {}, lastScan = nil }
            -- Restore saved results (reconstruct links from itemIDs)
            if VendorArbDB.results and #VendorArbDB.results > 0 then
                scanner.results = {}
                for _, r in ipairs(VendorArbDB.results) do
                    local _, link = GetItemInfo(r.itemID)
                    table.insert(scanner.results, {
                        name = r.name,
                        link = link,  -- may be nil until item is cached
                        itemID = r.itemID,
                        count = r.count,
                        vendorCost = r.vendorCost,
                        ahPrice = r.ahPrice,
                        profit = r.profit,
                        roi = r.roi,
                    })
                end
                SortResults()
                print(ADDON_PREFIX, "Loaded", #scanner.results, "saved results from", VendorArbDB.lastScan or "unknown")
            end
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
        if VendorArbStatus then
            VendorArbStatus:SetText(string.format(
                "Scanning page %d/%d... Found %d profitable so far",
                scanPage + 1,
                totalScanPages + 1,
                #scanner.results
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
    if not VENDOR_PRICES then
        print(ADDON_PREFIX, "ERROR: VendorPrices.lua not loaded!")
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
    for _ in pairs(VENDOR_PRICES) do vendorItemCount = vendorItemCount + 1 end
    print(ADDON_PREFIX, "Starting scan. Checking AH against", vendorItemCount, "known vendor items...")

    scanner.running = true
    scanner.results = {}
    scanner.itemsChecked = 0
    scanner.vendorItemsFound = 0
    scanPage = 0
    totalScanPages = 0
    currentPage = 1

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
