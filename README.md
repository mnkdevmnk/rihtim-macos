# Rıhtım

**English** · [Türkçe](README.tr.md)

A macOS add-on that puts the notch, the Dock and the menu bar under one app. It adds features on top of the real Dock without breaking it.

Rıhtım never hides the Dock, never draws a copy of it, never runs `killall Dock` and never writes to `com.apple.dock`. It only *watches* the Dock through the Accessibility API and places its widgets next to it in a separate panel.

> *Rıhtım* is Turkish for "quay" or "dock".

## Features

| Feature | What it does |
|---|---|
| **Dock previews** | Hover a Dock icon to see live thumbnails of its windows, including windows on other desktops. Click to switch (to that desktop if needed), ✕ to close. List view for apps with many windows, mini player on Music / Spotify. |
| **Dock gestures** | Click the frontmost app's icon to minimize or hide it, scroll on an icon to hide / show, ⌘ + right-click to quit, ⌥⌘ + right-click to force quit. |
| **Dock folders** | Hover a folder in the Dock (Downloads, Documents…) to browse it, open files, drag them out or reveal them in Finder. |
| **⌘⇥ switcher** | Replaces the system ⌘⇥ and shows window previews of the selected app. Can be moved to ⌥⇥. |
| **Window snapping** | Rectangle-style shortcuts (⌃⌥ + arrows for halves, U I J K for quarters, D F G for thirds…), drag to an edge with ⌘ to snap, drag to the side without ⌘ to move a window to the next desktop. |
| **Widget strip** | Music, calendar, weather, CPU / RAM / SSD, Claude usage, Coffee and device batteries on either side of the Dock, in Liquid Glass. Slides along with an auto-hiding Dock. |
| **Notch island** | Compact info on both sides of the notch; hover to open tabs for home cards, Claude sessions, a file shelf, clipboard history, a quick note, a calendar grid and a camera mirror. Draws a fake notch on screens without one. |
| **Volume & brightness HUD** | Volume and brightness keys are handled by Rıhtım and shown in the notch instead of the macOS overlay. |
| **Extra brightness** | Goes past 100% brightness on EDR-capable displays (⌘ + brightness up), never beyond the headroom the display reports. Panic switch: ⌃⌥⌘B or Esc three times. |
| **Menu bar modules** | Stats-style CPU, GPU, RAM, disk, sensors, network, battery, Bluetooth and world clocks, each with its own widgets (charts, gauges, text…), popups and threshold notifications. |
| **Coffee** | Keep-awake like `caffeinate`: indefinitely / 30 min / 1-2-4 h, optionally keeping the display on. |
| **Claude usage** | 5-hour and weekly usage of a Claude subscription, read from Claude Code's login, plus the state of recent Claude Code sessions. |
| **Languages** | English, Türkçe, Deutsch. Follows the system language by default; can be changed in Settings › General. |

### ⌘⇥ shortcuts (while ⌘ is held)
`⇥` / `⇧⇥` / `← →` pick app · `↑ ↓` or `` ` `` pick window · `Q` quit app · `H` hide · `W` close window · `Esc` cancel · release ⌘ to switch

## Install

### Build it yourself
Requires macOS 14+ and Xcode (or the Command Line Tools with Swift 5.9+).
```bash
git clone https://github.com/mnkdevmnk/rihtim-macos.git
cd rihtim-macos
./build.sh install      # builds Rihtim.app, puts Rihtim.dmg on the Desktop and installs to /Applications
```

### Prebuilt DMG
Every push to `main` is built on GitHub Actions; the DMG is attached to the run as **Rihtim**. Version tags (`v0.13.0`) also publish it under Releases.

The build is ad-hoc signed, so macOS blocks it on first launch. After copying it to Applications:
```bash
xattr -dr com.apple.quarantine /Applications/Rihtim.app
```

## Permissions
1. **Accessibility:** required to watch the Dock, for windows, gestures, snapping and ⌘⇥.
2. **Screen Recording:** for live thumbnails. After granting it, pick *"I've granted it, restart"* in the menu.
3. **Automation (Music / Spotify):** asked the first time a song plays.
4. **Calendars / Camera:** only when you use the calendar widget or the notch mirror.

## Privacy
Everything stays on your Mac. The only network requests are to Open-Meteo (weather for the city you pick) and, if you use Claude Code, Anthropic's usage endpoint with the login Claude Code already stored. Clipboard history lives in memory only and skips copies that password managers mark as concealed.

## Translations
UI strings are written in English in the source and translated in `Resources/Localization/<language>.strings`. To add a language, copy `de.strings`, translate the values, add the code to `L10n.supported` and to `AppLanguage`, then run:
```bash
python3 tools/check_l10n.py tr de
```
It lists keys that are missing from (or no longer used in) each table.

## Known limitations
- Windows on other Spaces rely on the same semi-private calls AltTab uses (`_AXUIElementCreateWithRemoteToken`, SkyLight focusing). If a macOS update breaks them, only windows on the current Space are listed.
- Taking over ⌘⇥ uses a SkyLight function AltTab also relies on. The system ⌘⇥ comes back even if Rıhtım crashes; if it ever doesn't, logging out and back in restores it.
- The widget strip only shows while the Dock is at the bottom of the screen.
- No music search and no iPhone battery: there's no public macOS API for either.

## License
[MIT](LICENSE)
