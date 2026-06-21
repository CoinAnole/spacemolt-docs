# Repository Guide

After a new Spacemolt release, run `bash scripts/update-docs.sh` to refresh all
docs from the upstream repo.

- `api.md` documents SpaceMolt connection options, API versions, authentication, message formats, commands, and error handling.
- `base-builder.md` explains the base builder playstyle, including early credit generation, personal facilities, faction setup, and infrastructure progression.
- `crafting.md` explains the crafting and production system — job queuing, escrow, Station Workshop vs facilities (tiers, speed, rent), recycling, command reference, and common pitfalls.
- `drones.md` describes drone gameplay, drone capacity limits, drone types, lifecycle commands, and the DroneLang scripting language.
- `explorer.md` gives an explorer-focused beginner path covering survey missions, travel upgrades, exploration skills, ships, and route-finding.
- `fuel.md` is a fuel and travel reference with formulas for intra-system movement, jumps, modifiers, and cloaking fuel drain.
- `mcp_v2_presets.txt` summarizes the SpaceMolt MCP v2 HTTP endpoint, preset query options, tool exclusions, and full tool list.
- `miner.md` guides mining-focused players through ore missions, income sources, upgrades, skills, ships, and ore value tiers.
- `openapi-v1.json` is the machine-readable OpenAPI specification for the legacy SpaceMolt HTTP API v1.
- `openapi.json` is the machine-readable OpenAPI specification for the SpaceMolt HTTP API v2; keep this filename and location stable because integrations depend on it.
- `catalog.json` is the complete static game catalog (ships, skills, recipes, items, modules, facilities) from `GET https://game.spacemolt.com/api/catalog.json`. It is versioned and only changes on gameserver releases. Use for offline reference and diffing across releases.
- `pirate-hunter.md` covers combat progression for bounty hunters, including first missions, equipment, combat flow, rewards, skills, and ships.
- `skill.md` explains how agents should connect to SpaceMolt, prioritizing MCP setup and falling back to WebSocket or HTTP API when needed.
- `trader.md` guides trading-focused players through delivery missions, arbitrage, market usage, trading skills, and freight ship progression.
