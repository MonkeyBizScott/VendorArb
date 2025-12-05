# VendorArb

A World of Warcraft Classic Era addon that finds vendor → AH arbitrage opportunities.

## What it does

Scans the Auction House for items that can be purchased from vendors and resold on the AH for profit. Shows:
- Vendor buy cost
- Current AH price
- Profit after AH fees (5% cut)
- ROI percentage

## Features

- **AH Scanner**: Full auction house scan to find profitable items!
- **Tooltip Integration**: Hover over any item to see its vendor buy price (if available)
- **Progress Bar**: Visual progress indicator during scans

## Usage

1. Open the Auction House
2. Click the "VendorArb" tab, or type `/varb`
3. Click "Scan AH" to find arbitrage opportunities
4. Results are printed to chat, sorted by profit

## Installation

1. Download/clone this repository
2. Place the `VendorArb` folder in your `Interface/AddOns/` directory
3. Restart WoW or `/reload`

## Files

- `VendorArb.toc` - Addon metadata
- `VendorArb.lua` - Main addon code
- `VendorPrices.lua` - Database of 688 vendor-sold items with buy prices (from Wowhead)

## Data Source

Vendor prices are sourced from Wowhead's Classic database. The data includes items that NPCs sell (recipes, trade goods, limited supply items, etc.).

## Commands

- `/varb` - Start a scan (must have AH open)

## License

MIT
