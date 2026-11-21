#!/bin/bash

# Full uninstall — kills the running app, drops the .app bundle, and removes
# every per-user artifact CatchMatch writes (Preferences, Caches, Saved
# Application State, Containers, Logs, Application Support).
#
# Bundle ID is still `com.michelstorms.dlp2music` — the Xcode project subdir
# kept its historical name, only the shipped product name became CatchMatch.

# Close the app
killall CatchMatch 2>/dev/null

# Delete default settings
defaults delete com.michelstorms.dlp2music 2>/dev/null

# Reset granted permissions (Settings → Privacy & Security)
tccutil reset All com.michelstorms.dlp2music

# Delete the app
rm -rf /Applications/CatchMatch.app

# Remove per-user files
rm -rf ~/Library/Application\ Support/dlp2music
rm -rf ~/Library/Preferences/com.michelstorms.dlp2music.plist
rm -rf ~/Library/Caches/com.michelstorms.dlp2music
rm -rf ~/Library/Saved\ Application\ State/com.michelstorms.dlp2music.savedState
rm -rf ~/Library/Logs/dlp2music

# Remove sandboxed app container (if Sandbox capability is enabled)
rm -rf ~/Library/Containers/com.michelstorms.dlp2music
rm -rf ~/Library/Group\ Containers/*.com.michelstorms.dlp2music*
