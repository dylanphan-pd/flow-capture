# Potential features

Ideas discussed but not committed to. Nothing here is built yet. The committed backlog lives in [README.md](README.md#backlog).

Status key: 💡 idea · ❓ needs a quick check first

---

## 1. More FigJam-native tools in the overlay

Tools that land in FigJam as real, editable objects.

| Feature | What it adds | Value |
|---|---|---|
| Highlight box | ✅ Built: rectangle / oval tools (Shift = square / circle), outline only, native FigJam shapes | High |
| Numbered badge | Small numbered circle to order or reference things ("see 3") | High |
| Text label | ✅ Built: `T` tool, 7 colours, small / medium / large | High |
| Per-sticky colour | ✅ Built: 8 colours per sticky (FigJam's exact sticky palette; yellow = FigJam default) | High |
| Connector options | Partly built: colour, thickness and dashed. Still open: elbow / curved, arrowheads both ends, text label on the arrow | Medium |
| Arrow glued to sticky | Arrow attached to its sticky so moving one moves the other | Medium |
| Step title | The step's name as a heading above its screenshot | Medium |
| Shapes with text | Ellipse, diamond, etc. with text inside | Low |
| Hotspot link | Box on a screenshot connected to the step it leads to (see README backlog: flow mapping) | High |

Suggested first group: highlight box, numbered badge, text label, per-sticky colour.

### Baked into the screenshot (not native)
- **Blur / redact**: hide sensitive info; saved into the image so it can't be undone in FigJam (that is the point).
- **Spotlight**: dim everything except the area that matters.
- **Zoom callout**: magnified inset of a small detail.
- **Measure**: pixel distance between two points (see section 2).

### Probably not possible as native FigJam objects
- Freehand pen / highlighter (plugins can't create real FigJam pen strokes; only plain vector shapes).
- Stamps, emoji reactions, comments, cursors.

❓ All plugin-side details are from knowledge of the FigJam plugin API and are untested.

---

## 2. Design audit mode (after dev ships)

Use case: capture the built UI, mark deviations from the design, hand a clear list to developers.

Already works: exact-size presets and size pill (match Figma frame widths), annotations, one flow per audit pass, re-import for a second review round.

### Gaps and ideas
1. **Structured issues** 💡
   - Each sticky gets a *type* (spacing, colour, typography, copy, missing state, bug) and a *severity* (blocker, major, minor).
   - Sticky colour follows severity so the board reads at a glance.
   - Numbered badge on the screenshot matches the issue number.
2. **Detail-checking tools** 💡
   - **Colour picker**: click the frozen screenshot, read the exact colour.
   - **Measure**: drag between two points to read the distance (points and real pixels on Retina).
3. **Compare to design** 💡
   - **Overlay compare**: paste the design frame (copied from Figma as PNG) into the overlay and slide its opacity over the build.
   - **Side by side in FigJam**: plugin places the screenshot beside a selected frame at the same size.
4. **Capture context** ❓
   - Remember page address, browser, window size, date and a build label (typed once, e.g. "v2.4 staging").
   - Chrome/Edge may expose the page address through the same accessibility tools used for measuring — not confirmed.
5. **Summary for developers** 💡
   - Plugin adds a summary section: issue count by severity and type as a table.
   - Later: create Jira tickets from issues (Jira is already connected in this setup).

Suggested order: severity + type + badges → colour picker + measure → capture context → overlay compare → summary table → Jira tickets.

---

## 3. Figma design files (not only FigJam)

Same plugin, `editorType` for both. Differences:
- Stickies and connectors only exist in FigJam. In a Figma design file the plugin would build equivalents: yellow auto-layout frame with text for stickies, a line with arrowhead for arrows.
- **Use the team's Note component instead of a sticky**: user selects a Note instance once; plugin saves its component key and creates real instances (library must be enabled in the file). Text slot and size are read from the instance; open question is how the Note's text is exposed (component property vs nested layer, variants).
- Upside: hotspot links could become real prototype connections (Present mode), which FigJam can't do.
- ❓ Line / arrowhead properties not yet verified in the Figma API.

---

## 4. Browser capture accuracy

- **Corner radius per app** (also in README backlog): measure and preset for browsers and other apps.
- **Detect clean (app-mode) windows more reliably**: current rule (page starts less than 60pt below the window top) also matches fullscreen browsers.
- **Pick the largest web area** when measuring, not the first (a docked sidebar or DevTools can win; may explain Edge's odd 15pt right margin).
- **Don't leave Chromium accessibility mode switched on** after measuring.

---

## 4b. Hotkey conflicts
Default shortcuts are ⌥ + a digit (two keys). Option+digit types symbols in some layouts (e.g. ¡ ™), so the shortcut swallows those characters globally. If that bites, change them in Settings or consider function keys.

## 5. Flow Library window

See [README.md](README.md#backlog) (stage 1: read-only library with delete / rename / reorder; stage 2: re-edit a step).

---

## 6. Ideas to revisit later

- Cross-platform (Windows) version: core logic in a cross-platform framework (Tauri was discussed).
- Publishing the plugin for the team (needs an alternative to localhost networking, which only works for imported development plugins).
- Packaging as a signed `.app` with start-at-login.
- Custom size presets (add / remove), and remembering recent sizes.
