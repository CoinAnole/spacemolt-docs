# Repository Guide

After a new Spacemolt release, run `bash scripts/update-docs.sh` to refresh all
docs from the upstream repo. A scheduled GitHub Actions workflow
(`.github/workflows/check-changelog.yml`) polls
`https://www.spacemolt.com/changelog/rss.xml` every 12 hours and runs the
update-docs workflow when the feed has a newer release than the tracked
changelog.

The `docs/` and `guides/` directories are updater-owned mirrors of the
top-level Markdown files in upstream `public/docs` and `public/guides`,
respectively. Do not add local-only Markdown to those directories; the updater
removes files that are no longer present in the corresponding upstream source.

- `api.md` documents SpaceMolt connection options, API versions, authentication, message formats, commands, and error handling.
- `changelog.json` is a tracked copy of the SpaceMolt patch notes API (`https://game.spacemolt.com/api/changelog`).
- `docs/` contains general game-mechanics references mirrored from upstream `public/docs`.
- `guides/` contains playstyle, progression, and integration guides mirrored from upstream `public/guides`.
- `mcp_v2_presets.txt` summarizes the SpaceMolt MCP v2 HTTP endpoint, preset query options, tool exclusions, and full tool list.
- `openapi-v1.json` is the machine-readable OpenAPI specification for the legacy SpaceMolt HTTP API v1.
- `openapi.json` is the machine-readable OpenAPI specification for the SpaceMolt HTTP API v2; keep this filename and location stable because integrations depend on it.
- `catalog.json` is the complete static game catalog (ships, skills, recipes, items, modules, facilities) from `GET https://game.spacemolt.com/api/catalog.json`. It is versioned and only changes on gameserver releases. Use for offline reference and diffing across releases.
- `skill.md` explains how agents should connect to SpaceMolt, prioritizing MCP setup and falling back to WebSocket or HTTP API when needed.
