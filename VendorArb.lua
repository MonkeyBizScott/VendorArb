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
            "|cff00ff00[VendorArb]|r Vendor Buy:",
            FormatMoney(vendorBuyPrice),
            0, 1, 0,  -- left text color (green)
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

-----------------------------------------------------------------------
-- Create the panel UI
-----------------------------------------------------------------------
local function CreateVendorArbPanel()
    if VendorArbPanel then return end
    if not AuctionFrame then return end

    local f = CreateFrame("Frame", "VendorArbPanel", AuctionFrame)
    f:SetAllPoints(AuctionFrame)
    f:Hide()
    VendorArbPanel = f

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.25)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 20, -40)
    title:SetText("Vendor -> AH Arbitrage Finder")

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    desc:SetText("Find items to buy from vendors and sell on the AH for profit.")

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
    status:SetText("Press 'Scan AH' to find arbitrage opportunities.")
    VendorArbStatus = status

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -10)
    btn:SetText("Scan AH")
    btn:SetScript("OnClick", function()
        if StartScan then StartScan() end
    end)
    f.ScanButton = btn

    -- Progress bar
    local barWidth, barHeight = 400, 20
    local progressBg = CreateFrame("Frame", nil, f, "BackdropTemplate")
    progressBg:SetSize(barWidth, barHeight)
    progressBg:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -15)
    progressBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    progressBg:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    progressBg:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

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

    tab:SetScript("OnClick", function(self)
        PanelTemplates_SetTab(auctionFrame, vendorArbTabID)
        if AuctionFrameBrowse then AuctionFrameBrowse:Hide() end
        if AuctionFrameBid then AuctionFrameBid:Hide() end
        if AuctionFrameAuctions then AuctionFrameAuctions:Hide() end
        if VendorArbPanel then VendorArbPanel:Show() end
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    end)

    hooksecurefunc("AuctionFrameTab_OnClick", function(self, index)
        local id = index or (self and self.GetID and self:GetID())
        if VendorArbPanel and id ~= vendorArbTabID then
            VendorArbPanel:Hide()
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
        return
    end

    -- Sort by profit descending
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

    print(ADDON_PREFIX, "Top vendor->AH arbitrage opportunities:")
    print(ADDON_PREFIX, "(Buy from vendor, sell on AH)")

    local maxRows = math.min(MAX_RESULTS_PRINT, #scanner.results)
    for i = 1, maxRows do
        local r = scanner.results[i]
        print(string.format(
            "%s %s x%d | |cffffffffVendor: %s|r | |cffffff00AH: %s|r | |cff00ff00Profit: %s (%.0f%%)|r",
            ADDON_PREFIX,
            r.link or r.name,
            r.count,
            FormatMoney(r.vendorCost),
            FormatMoney(r.ahPrice),
            FormatMoney(r.profit),
            r.roi * 100
        ))
    end

    if VendorArbStatus then
        VendorArbStatus:SetText(string.format(
            "Found %d profitable items. Top %d printed to chat.",
            #scanner.results,
            maxRows
        ))
    end
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
        if name == "Blizzard_AuctionUI" then
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
