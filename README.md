# Munin

Munin is a macOS menu bar clipboard history app written in SwiftUI and AppKit. It watches the system pasteboard, stores recent text and image copies, and lets you re-copy or quick-paste older entries without opening a full app window.

## What It Is Used For

Munin is meant for people who copy and paste repeatedly during normal desktop work and want lightweight clipboard history available from the menu bar.

It supports two main workflows:

- Open the menu bar panel to browse recent clipboard items, inspect long text, preview copied images, re-copy an item, or delete it.
- Use a global keyboard shortcut to open a centered quick-paste popup, choose one of the most recent entries, and paste it back into the currently focused app.

## How It Works

The app runs as an accessory app (`LSUIElement`), so it lives in the macOS menu bar instead of the Dock.

At launch it:

- Creates a menu bar status item with a clipboard icon.
- Builds the main history panel and a separate quick-paste popup.
- Loads saved clipboard history from disk.
- Starts monitoring the general pasteboard.
- Registers a configurable global hotkey for quick paste.
- Starts listening for likely `Cmd+C` and `Cmd+X` events so it can check the pasteboard immediately after copy or cut.

### Clipboard Capture

`ClipboardStore` is the core of the app.

- It polls `NSPasteboard.general` every 0.2 seconds.
- When the pasteboard changes, it tries to capture either text or image content.
- Text can come from plain string, `NSString`, RTF, or HTML pasteboard types.
- Images can come from `NSImage`, PNG data, or TIFF data.
- Captured entries are stored as `ClipboardEntry` values.

### Dedupe

Munin avoids filling history with repeated copies of the same content.

- Text entries are normalized and hashed with SHA-256.
- Image entries are hashed from normalized pixel data when possible, with a PNG-data fallback.
- A rolling signature cache is used to skip recently seen duplicates.
- The app also suppresses the next pasteboard change after it re-copies an entry itself, so selecting an old item does not create an immediate duplicate.

### Persistence

History is persisted as JSON so it survives app restarts.

- Maximum history size: 100 entries
- File location:
  `~/Library/Application Support/com.studio11.munin/clipboard-history.json`

On startup, Munin loads the saved history, trims it to the maximum size, and rebuilds its dedupe cache.

## User Interface

### Menu Bar Panel

Left-clicking the menu bar icon opens the main history panel.

- Text entries can be expanded if they exceed the collapsed preview.
- Image entries are shown inline with a preview.
- Clicking an entry copies it back to the pasteboard.
- Hovering an entry exposes delete controls.

Right-clicking the menu bar icon opens a small status menu with a `Config` item for shortcut settings.

### Quick Paste Popup

Munin also provides a keyboard-driven quick-paste popup.

- Default shortcut: `Cmd+Shift+V`
- Shows up to the 10 most recent entries
- Arrow keys move selection
- `Return` or `Enter` inserts the selected item
- `Escape` closes the popup

When you choose an entry, Munin:

1. Writes that item back to the pasteboard.
2. Hides itself.
3. Returns focus to the previous app.
4. Simulates `Cmd+V` to paste into the focused app.

## Permissions

The quick-paste flow simulates a paste keystroke with Accessibility APIs. Because of that, Munin may prompt for Accessibility permission the first time quick paste is used.

Without Accessibility permission:

- Clipboard history capture still works.
- Re-copying from the panel still works.
- Automatic insertion into the focused app from the quick-paste popup will not work.

## Project Structure

- [Munin/AppDelegate.swift](/Users/vrs11/work/Munin/Munin/Munin/AppDelegate.swift) contains the app lifecycle, status item, panels, hotkey registration, shortcut preferences, and copy-command monitor.
- [Munin/ClipboardStore.swift](/Users/vrs11/work/Munin/Munin/Munin/ClipboardStore.swift) contains pasteboard monitoring, capture, dedupe, and persistence.
- [Munin/ClipboardListView.swift](/Users/vrs11/work/Munin/Munin/Munin/ClipboardListView.swift) contains the main history UI and quick-paste popup UI.
- [Munin/ClipboardEntry.swift](/Users/vrs11/work/Munin/Munin/Munin/ClipboardEntry.swift) defines the stored clipboard model for text and images.

## Requirements

- macOS 13.0+
- Xcode 16 or newer is the practical target based on the shared scheme metadata

## Build And Run

### Xcode

1. Open `Munin.xcodeproj` in Xcode.
2. Select the `Munin` scheme.
3. Build and run the app.

Because this is a menu bar app, it will appear in the status bar rather than opening a standard window.

### Command Line

```bash
xcodebuild -project Munin.xcodeproj -scheme Munin -configuration Debug -sdk macosx build
```

## Notes For Development

- The app uses a mixed SwiftUI/AppKit approach because it needs menu bar integration, floating panels, global hotkeys, and low-level keyboard / accessibility APIs.
- There are currently no test targets in the project.
- A startup log is written to `/tmp/munin-startup.log`.
