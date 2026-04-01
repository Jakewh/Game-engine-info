# Game Engine Info

Millennium plugin that shows a game's engine directly on Steam game pages.

<img width="1904" height="891" alt="Snímek obrazovky_20260401_140954" src="https://github.com/user-attachments/assets/7d75ebd6-bc8f-43ab-bac8-5212b84ac696" />


## What it does

- Detects Steam game pages (`/app/<id>`)
- Fetches app metadata from SteamDB
- Extracts and displays the engine in a small info panel

## Install in Millennium

- Ensure you have Millennium installed on your Steam client
- Navigate to EUR Price Converter from the plugins page
- Click the "Copy Plugin ID" button
- Back in Steam, go to Steam menu > Millenium > Plugins > Install a plugin and paste the code
- Follow the remaining instructions to install and enable the plugin

## Notes

- Primary source is `https://steamdb.info/app/<id>/`
- If direct fetch is blocked by CORS, it falls back to `https://r.jina.ai/http://steamdb.info/app/<id>/`
- If engine info is not available on SteamDB, panel shows `not found`

## Credits

[Millennium](https://github.com/shdwmtr/millennium)
