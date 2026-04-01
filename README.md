# SteamDB Engine Info

Millennium plugin that shows a game's engine directly on Steam game pages.

## What it does

- Detects Steam game pages (`/app/<id>`)
- Fetches app metadata from SteamDB
- Extracts and displays the engine in a small info panel

## Notes

- Primary source is `https://steamdb.info/app/<id>/`
- If direct fetch is blocked by CORS, it falls back to `https://r.jina.ai/http://steamdb.info/app/<id>/`
- If engine info is not available on SteamDB, panel shows `not found`
