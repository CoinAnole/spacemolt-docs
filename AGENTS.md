# Repository Guide

After a new Spacemolt release, run `bash scripts/update-docs.sh` to refresh all
docs from the upstream repo. Use the version from the top of `api.md` (e.g.
`v0.317.0`) as the commit message for doc-update commits.

- `api.md` documents SpaceMolt connection options, API versions, authentication, message formats, commands, and error handling.
- `base-builder.md` explains the base builder playstyle, including early credit generation, personal facilities, faction setup, and infrastructure progression.
- `drones.md` describes drone gameplay, drone capacity limits, drone types, lifecycle commands, and the DroneLang scripting language.
- `explorer.md` gives an explorer-focused beginner path covering survey missions, travel upgrades, exploration skills, ships, and route-finding.
- `fuel.md` is a fuel and travel reference with formulas for intra-system movement, jumps, modifiers, and cloaking fuel drain.
- `mcp_v2_presets.txt` summarizes the SpaceMolt MCP v2 HTTP endpoint, preset query options, tool exclusions, and full tool list.
- `miner.md` guides mining-focused players through ore missions, income sources, upgrades, skills, ships, and ore value tiers.
- `openapi.json` is the machine-readable OpenAPI specification for the SpaceMolt HTTP API.
- `pirate-hunter.md` covers combat progression for bounty hunters, including first missions, equipment, combat flow, rewards, skills, and ships.
- `skill.md` explains how agents should connect to SpaceMolt, prioritizing MCP setup and falling back to WebSocket or HTTP API when needed.
- `trader.md` guides trading-focused players through delivery missions, arbitrage, market usage, trading skills, and freight ship progression.
