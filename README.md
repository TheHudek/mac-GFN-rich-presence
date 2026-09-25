# GFN Presence

Menu bar app for macOS that shows the **actual game** you're playing on NVIDIA GeForce NOW in Discord Rich Presence — with the game's official artwork — instead of just "Playing NVIDIA GeForce NOW".

## Features

- **Automatic detection** from GeForce NOW's local log (no Screen Recording or Accessibility permission)
- **Official Discord game presence** when the title is in Discord's detectable games list ("Playing Fortnite", etc.)
- **Fallback presence** for unrecognized games via your own Discord Developer Application
- **Manual game picker** from your GeForce NOW library (plus custom titles)
- **On / Off privacy switch** that persists until you change it again
- Menu bar only — no Dock icon, no separate window

## Requirements

- macOS 14+
- GeForce NOW for Mac
- Discord desktop app running
- Xcode 16+ (to build)

## One-time setup

### 1. Create a Discord Developer Application (fallback)

Used when a game isn't in Discord's official list (presence still shows the title + GeForce NOW artwork).

1. Open the [Discord Developer Portal](https://discord.com/developers/applications) and sign in
2. **New Application** — name it something like `a game on GeForce NOW` (this name appears for unrecognized games)
3. Copy the **Application ID**
4. After building/running GFN Presence, open the menu bar panel → **Fallback App ID…** → paste the ID → Save

### 2. Disable GeForce NOW's built-in Discord presence

Otherwise Discord may show both "Playing GeForce NOW" and the real game.

1. Open GeForce NOW → Settings
2. Find the Discord / Rich Presence option and turn it **off**

### 3. Allow Discord activity sharing

Discord → Settings → **Activity Privacy** → enable activity sharing / rich presence display so friends can see what you're playing.

## Where to look in Discord

Rich Presence from this app shows on your **profile** as **Playing Fortnite** (or whichever game) — check by clicking your avatar in a server, or User Settings → Profiles.

It will **not** appear under Settings → Activity → **Registered Games** → "Current Game". That list only detects local game processes. GeForce NOW games run in the cloud, so "No game detected" there is expected — leave **NVIDIA GeForce NOW** toggled off in that list.

## Build & run

```bash
# Generate the Xcode project (after cloning)
xcodegen generate

# Build
xcodebuild -scheme GFNPresence -configuration Debug build

# Or open in Xcode
open GFNPresence.xcodeproj
```

Run the **GFN Presence** scheme. A game controller icon appears in the menu bar.

Optional: enable **Launch at Login** from the panel.

## How detection works

The app tails:

`~/Library/Application Support/NVIDIA/GeForceNOW/console.log`

and watches for launch / stream-begin / stream-end lines. It matches the Windows executable name (and title aliases) against Discord's public detectable applications list so Discord shows the real game name and icon.

## Privacy

Toggle **Rich Presence** off in the menu bar panel. That clears Discord activity immediately and stays off across app restarts until you turn it back on.

## License

MIT
