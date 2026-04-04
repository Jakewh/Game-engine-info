# Game Engine Info

Millennium plugin that shows a game's engine directly on Steam game pages.

<img width="1904" height="891" alt="Snímek obrazovky_20260401_140954" src="https://github.com/user-attachments/assets/7d75ebd6-bc8f-43ab-bac8-5212b84ac696" />


<img width="2427" height="742" alt="Snímek obrazovky_20260401_174444" src="https://github.com/user-attachments/assets/4e371c92-9771-42d5-8d27-fde85ac4673d" />


## What it does

- Fetches app metadata from PCGamingWiki
- Shows the game engine type in every game page.
- Shows the game engine type in your library.

## Install in Millennium

- Ensure you have Millennium installed on your Steam client
- Navigate to Game Engine Info from the plugins page
- Click the "Copy Plugin ID" button
- Back in Steam, go to Steam menu > Millenium > Plugins > Install a plugin and paste the code
- Follow the remaining instructions to install and enable the plugin

## Notes

- Source is https://www.pcgamingwiki.com
- Fallback 1: Local installation directory detection (looks for Unity, Unreal, Godot, GameMaker, Ren'Py, LÖVE, CryEngine, Source, id Tech signatures in game folder)
- Fallback 2: Wikidata engine property lookup by game name
- Fallback 3: Wikipedia infobox engine lookup by game name
- Fallback 4: Generic internet search by game name (`<game> game engine`) with known engine keyword detection
- Fallback 5: https://steamdb.info (first item from Technologies section)
    - If SteamDB blocks direct requests, plugin retries with browser-like headers and then uses Brave web search by game name to find SteamDB app link
    - If engine info is not available, panel shows `Not found on PCGameWiki`

## Credits

[Millennium](https://github.com/shdwmtr/millennium)
