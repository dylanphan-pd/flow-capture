# Flow Capture

macOS menu bar app for capturing UX flow steps, plus a FigJam plugin that receives them.

## Quick start (for testers)

> Early test version. Expect rough edges, and please tell me what breaks (see *Feedback* below).

**You need:** a Mac on macOS 13 or later and the [Figma desktop app](https://www.figma.com/downloads/) (plugins are imported from a file, which only works in the desktop app).

**1. Get the Mac app: pick one**

*Easiest: download it.* Get **Flow-Capture.zip** from the [Releases page](https://github.com/dylanphan-pd/flow-capture/releases/latest), unzip it, and drag **Flow Capture** into Applications. The first time you open it, macOS warns that it can't verify the app (it isn't from the App Store). Click *Done*, then open **System Settings → Privacy & Security**, scroll to the message about Flow Capture and click **Open Anyway**. You only do this once. (On older macOS: right-click the app → *Open* → *Open*.)

*Or build it yourself.* This needs Apple's small command line tools (not the full Xcode app): run `xcode-select --install` once if you've never built anything on this Mac.
```
git clone https://github.com/dylanphan-pd/flow-capture.git
cd flow-capture
./scripts/build-app.sh
```
```
cp -R "dist/Flow Capture.app" /Applications/ && open "/Applications/Flow Capture.app"
```
An app you build on your own Mac opens without the warning above.

Either way, a camera icon appears in the menu bar (there is no Dock icon).

**2. Allow permissions (once).** Press **⌥1** to capture. macOS asks for *Screen Recording*: switch on **Flow Capture** in System Settings → Privacy & Security → Screen Recording, then quit the app from its menu and open it again. Window resizing separately asks for *Accessibility*.

**3. Add the FigJam plugin.** In the Mac app's menu: *Settings…* → **Show Plugin Files** (this puts the plugin in a folder that stays put, copies the location of `manifest.json`, and shows it in Finder). In the Figma desktop app, open any FigJam board → *Plugins* → *Development* → *Import plugin from manifest…*, press **⌘⇧G**, paste (**⌘V**), press Return, then *Open*.

**4. Pair the two.** In the Mac app's menu: *Settings…* → *Copy Connection Token*. Run the plugin (*Plugins* → *Development* → *Flow Capture Receiver*) and paste the token. The footer turns green and says *Connected*.

**5. Try a flow.** Press **⌥1** on any app or browser window, add a sticky (`S`) or arrow (`A`), press **⏎**. Repeat for a few steps, then **⌥3** to finish the flow. In FigJam press **Place flow(s)**.

**Troubleshooting**
- *Building stops with "Symbol not found" or "dyld" (mentions `swift-package` or `llbuild`)* → Apple's command line tools on your Mac are damaged or out of date. Reinstall them, then build again:
  ```
  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install
  ```
- *Screenshot shows only the wallpaper* → Screen Recording isn't allowed yet (step 2), or you haven't reopened the app since allowing it.
- *Plugin says "Flow Capture app is not running"* → open the app from Applications.
- *A shortcut does nothing* → another app may use it. Change it in *Settings…*.
- *macOS says "Apple could not verify…" or the app can't be opened* → normal for a downloaded copy. Use **System Settings → Privacy & Security → Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/Flow Capture.app"` and open it again. Or build it yourself (step 1).

**Feedback.** Open an [issue](https://github.com/dylanphan-pd/flow-capture/issues) with your macOS version, what you pressed, and what you expected.

## Install as an app (recommended)
```
./scripts/build-app.sh
cp -R "dist/Flow Capture.app" /Applications/
open "/Applications/Flow Capture.app"
```
It runs from the menu bar only (no Dock icon, no terminal). Settings → *Open Flow Capture at login* starts it automatically.

**Permissions.** The first time you capture, macOS asks for **Screen Recording** (and **Accessibility** for window resizing). They are granted to *Flow Capture* itself, so you do this once. After granting Screen Recording, quit and reopen the app.

**Keeping permissions across rebuilds.** An unsigned build gets a new identity every time, so macOS may ask again. To avoid that, sign with a stable certificate: open Keychain Access → Certificate Assistant → Create a Certificate (type *Code Signing*), then
```
SIGN_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
```
(or just have an *Apple Development* certificate from Xcode; the script picks it up automatically).

**Upgrading from the terminal version.** On first launch the app copies your saved settings, shortcuts, trims and FigJam token across, and your captures stay where they were (`~/Library/Application Support/FlowCapture`). Quit the terminal copy first, since only one copy can own the hotkeys.

**Sharing it.** A build you make yourself opens normally on your Mac. For other people's Macs, macOS will warn about an unidentified developer unless the app is signed with an Apple Developer ID and notarized (paid developer account).

## Publishing a download (for the maintainer)
```
./scripts/make-release.sh
```
This builds one app that runs on both Apple Silicon and Intel Macs and writes `dist/Flow-Capture.zip`. On GitHub open *Releases → Draft a new release*, create a tag such as `v0.1.0`, drag the zip in, and publish. Keep the file name `Flow-Capture.zip`: the link `https://github.com/dylanphan-pd/flow-capture/releases/latest/download/Flow-Capture.zip` then always serves the newest version. The app is signed ad hoc (no Apple Developer account), which is why downloaders see the one-time "Open Anyway" step. Removing it requires signing with a Developer ID and notarizing (paid Apple account).

## Run from source
```
swift run
```
Grant **Screen Recording** and **Accessibility** to your terminal app when prompted.

| Action | Default shortcut (change in Settings…) |
|---|---|
| **Capture Window Content** (primary: page area of the front window, chrome trimmed) | ⌥1 |
| Capture Selection (drag an area; reopens on the previous area, resizable) | ⌥2 |
| Finish Flow → FigJam | ⌥3 |
| Preview Flow | ⌥4 |
| Remove Last Step (undo the last capture) | ⌥Z |

Menu also has *Discard Current Flow…* (throws away the flow being recorded, after confirming) next to *Remove Last Step*. *Browser ▸* Resize Window To / Open URL in Clean Window…; *Settings…* has the shortcut recorders, "Remember the last selection area", the FigJam token and storage.

The hotkey freezes the screen into an overlay (the page underneath can't be touched). The selection has **handles** — drag them to resize. Then annotate:

| Tool | Key | Notes |
|---|---|---|
| Sticky | `S` or drag from the toolbar | Return finishes the note, **Shift+Return** adds a line. A bar above the selected sticky sets its **colour** (8 swatches) and **list style** (bullets, numbers, none). |
| Arrow | `A` | Drag; drag the end dots to adjust. |
| Text | `T` | Click to place a plain text box (no background), type, Return to finish, Shift+Return for a new line. Empty boxes are discarded. |
| Rectangle | `R` | Drag; **hold Shift for a square**. Outline only; drag a corner dot to resize. |
| Oval | `O` | Drag; **hold Shift for a circle**. Outline only. |
| Select | `V` | Move things, double-click a sticky to edit, ⌫ deletes. |
| New area | `N` (or ••• menu) | Draw a different selection; annotations stay. |

Select any item to get a **style bar** above it: stickies — 8 colours + bullet/number list; arrows and shapes — 7 colours, 3 thicknesses, dashed; text — 7 colours + small/medium/large.

⏎ finishes, ⎋ cancels.

The toolbar starts below the MacBook notch and can be **dragged** by its grip (⋮⋮ on the left) or any empty part of the bar; it remembers where you left it. Double-click the grip to put it back.

**Trim & corners panel** (top-left of the overlay): collapsed it is a one-line preview — `Trim 32 · 1 · 1 · 1   R 18` — that updates live as you drag the selection handles. Click it or press `E` to expand the fields (T/R/B/L and Radius). In a field, **↑ / ↓** step the number by 1 (**Shift** = 10) and **Tab** moves to the next field. *Auto* re-measures a browser's page area; *Reset* restores the clean-window default (32 / 1 / 1 / 1, radius 18). "Remember…" saves your changes for that app (or for all clean windows). Overlay controls are compact by default; Settings → Capture overlay → Toolbar size switches between Compact, Regular and Large.

Annotations are stored as vectors, not pixels. Window presets size the *content area*: outer size = preset + saved margins.

## Recording a flow
Capture as many steps as you like — the menu bar icon shows the count. When the flow is done press **⌥3** (or menu → *Finish Flow → FigJam*). Nothing reaches FigJam until you finish.

## FigJam
1. FigJam → Plugins → Development → Import plugin from manifest → `figjam-plugin/manifest.json`
2. Run the plugin. Its panel (320 × 480) shows *Available Flow(s)* with a checkbox, editable name and a − to delete each flow, the *Place flow(s)* button, *Place automatically…*, a *Layout* accordion (wrap in sections, gap between steps, gap between flows), a collapsible *History (N)* with *Re-place*, and a footer with the connection dot plus *Change* and *Sign out*. Paste the token from Settings… → *Copy Connection Token* once; renames are saved back to the Mac app so History shows the name used in FigJam.
3. Switch to FigJam and run the plugin (⌥⌘P re-runs the last one). The whole finished flow is placed at once, left to right in capture order. Each step lands as a grouped clean screenshot + native FigJam stickies (with their colour and list style) + native connector arrows + native rectangle/oval shapes + native text (with the colour, thickness and dash style chosen in the overlay), at 1 screen point = 1 FigJam unit.
   The plugin also measures FigJam's real sticky size and default colour once and sends them to the app so the overlay draws stickies as FigJam will (until the plugin first runs, a 240×240 yellow guess is used). Yellow is FigJam's own default; the other sticky colours and all line / text colours use FigJam's exact palette values. After placing, the plugin reads each colour, thickness and dash back and lists anything FigJam did not apply (in a notification and in the panel). There is no Note colour setting in the plugin any more — colour is per sticky, chosen in the overlay. The app serves them on `127.0.0.1:47653`, token-protected.

## Not yet done
- Blur/redact and more shapes; sticky colours; sticky text size is approximate (20pt).
- Not yet exercised end to end: overlay interaction and the FigJam placement (connector coordinate space, grouping).
- Auto-detecting toolbar height (v2), Windows port (v2).
- Packaging as a signed `.app` (so permissions attach to Flow Capture rather than the terminal).

## Backlog
- Measure and preset the corner radius for browsers and other apps (currently 0; only iPhone Mirroring has one, 48).
- Flow mapping — show which click leads to which step:
  1. Link tool (`L`) in the overlay: drag a hotspot box; it targets the next step by default, or any step by clicking its filmstrip thumbnail (filmstrip becomes interactive). In FigJam: highlighted rectangle + real connector attached at both ends.
  2. Branches: "Start branch from step N" places the new flow on a row below its parent step, linked from the hotspot (plugin must lay out a tree, not one row).
  3. Optional toggle: auto-mark the last click as the hotspot on the previous step (extra permission; wrong when a click doesn't change the screen).
  Open question: should hotspots only link within one flow, or across flows from the start?
- Flow Library window (menu bar stays for capture; window for managing). Dock icon only while the window is open; menu item "Open Library…".
  - Left: flows — recording now / finished & waiting / already placed. Right: selected flow's steps as thumbnails with annotations.
  - Per step: delete, drag to reorder, double-click to re-open and edit annotations. Per flow: rename, delete, add a step to a finished flow, send status.
  - Settings tab: margin presets, storage + Clear Sent Captures, hotkeys, connection token.
  - Stage 1: read-only library + delete/rename/reorder. Stage 2: re-edit a step (overlay must load an existing capture with its annotations).
  - Closes the CRUD gaps from the code review (no per-step delete, no discarding a flow, no rename after finish).
- Code review follow-ups, suggested order: Screen Recording permission check with a clear message → per-step delete / undo last capture → plugin error handling (per-step try/catch + notify). Other review findings (placement overlap, wrong web area choice, atomic index writes, stale preset warning, Esc-cancel confirmation, accessibility side effect in Chromium) are listed in the review report. Done already: hotkeys are ignored while the overlay is open; fullscreen browsers are no longer mistaken for clean windows.
- Copy a flow to the clipboard (images + notes) to paste into Confluence / Google Docs. Not sure yet whether it is needed; would sit next to "Finish Flow → FigJam".

## License

[MIT](LICENSE) © 2026 Phong Phan
