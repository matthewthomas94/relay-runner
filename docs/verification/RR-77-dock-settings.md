# RR-77 Dock Settings Verification

Manual macOS coverage is required because the behavior depends on Dock
reopen events delivered by AppKit.

1. Launch Relay Runner from the app bundle and confirm the menu-bar tray still
   opens normally.
2. Use the tray menu's Settings item and confirm the existing Settings window
   opens or focuses.
3. While Relay Runner has a visible Dock icon, click the Dock icon and confirm
   the Settings window opens or focuses and Relay Runner becomes the active app.
4. Start or attach an active Relay session, then repeat the Dock click and
   confirm the session remains active while Settings opens or focuses.
5. Launch the installer flow from an uninstalled bundle and confirm Dock clicks
   continue to focus the installer window instead of opening an empty Settings
   scene.
