# Controller Workbench Design System

## Direction

Controller Workbench is a native macOS operations surface. It uses the system's source-list,
materials, typography, controls, focus behavior, and semantic colors rather than simulating a game
console or a web dashboard. Density is deliberate: status is quick to scan, detailed values remain
readable, and every pane can scroll or reflow without resizing its window.

## Window Structure

- The primary window uses a collapsible source-list sidebar for Overview, Controllers, Profiles,
  Console, optional Developer Tools, and Settings.
- The Settings window opens at `960 × 640` points with a `720 × 480` minimum content size.
- Input Test opens at `900 × 620` points with a `700 × 500` minimum content size.
- Saved geometry is retained and clamped to the current screen's usable frame. Pane changes never
  force a resize. There is no arbitrary maximum window size.
- Readable detail content may constrain its own measure while workspaces and logs use available
  width.

## Materials and Color

- Window surfaces use `NSColor.windowBackgroundColor`; sidebars and secondary list surfaces use
  native source-list or control backgrounds.
- Cards use native `GroupBox` or a single control-background surface. Separators use
  `NSColor.separatorColor`.
- Text uses label, secondary-label, and tertiary-label semantic colors. Readiness uses system green,
  orange, and red only when those meanings apply.
- Xbox and PlayStation accents identify controller family or active input. Nintendo, Steam, and
  generic controllers remain semantic unless a recorded family color exists.
- Light and dark appearances come from semantic system colors; no appearance-specific decorative
  palette is introduced.

## Typography and Data

- Use system title/headline/body/caption roles and Dynamic Type behavior supplied by SwiftUI.
- Use monospaced design only for logs, packet values, identifiers, and numeric measurements.
- Headers lead with the destination name and an optional factual subtitle. Do not add decorative
  eyebrows.
- Data rows keep labels secondary and values primary. Unknown or absent values are named explicitly.

## Components

- **Source-list row:** SF Symbol, localized destination title, native selection and keyboard focus.
- **Page header:** destination title plus optional concise purpose.
- **Status card:** one readiness fact, semantic symbol/tone, status text, and an action only when the
  state is actionable.
- **Data row:** localized label paired with a selectable or readable value.
- **Workspace list/detail:** persistent list and detail columns at larger widths; a vertically
  stacked list and selected detail at narrow widths.
- **Controller/profile list glyph:** every row reserves one centered `28 × 28` point identity
  column. Symbols use a normalized compact scale, Catalina uses a compact mark rather than a text
  label, and the glyph is hidden from accessibility so titles and subtitles share one leading edge.
- **Diagnostic section:** dense native group with a clear label; controls are grouped by controller,
  capture, or protocol responsibility.
- **Console workspace:** compact action/status bar above one full-width monospaced log surface.

## Responsive Policies

### Workbench panes

- Overview leads with readiness, then reflows permission cards from four columns to two and then one.
- Controllers and Profiles share list/detail width when possible; below `620` points of pane width,
  the list becomes a compact upper region and the selected detail remains scrollable below.
- Settings places General and Developer groups side by side when space permits and stacks them below
  `650` points. Notification groups remain readable rather than widening the window.
- Developer controller facts change from three columns to stacked groups below `760` points.

### Profiles

- The selected editor section lives only for the current Profiles session and remains unchanged
  when profiles switch. It defaults to Assignments and never participates in draft or save state.
- The detail header keeps the editable name, scope, assignment count, activation state, save state,
  one primary activation action, and one native profile-actions pull-down. Delete, feedback, save
  status, and Save remain in a persistent footer.
- Sections are ordered Assignments, Combinations, Layers, and Controller. Assignments groups source
  mappings; Combinations separates chords and sequences; Layers retains activation, mapping, motion,
  edit, and removal controls; Controller owns metadata, output policy, motion, sticks, triggers,
  touch, and lighting while advanced configuration stays in specialized sheets.
- Section navigation is segmented at `620` points or wider and becomes a labeled native pop-up
  below that width. Assignment source and destination fields are inline at `680` points or wider
  and stack below that width.
- Joy-Con runtime pairing remains a compact banner above the editor and retains its existing sheet
  ownership. Section changes never save, discard, or bypass dirty-draft confirmation.
- Controller-family symbols and compact identity marks are permitted. Representative controller
  photographs, drawings, silhouettes, and diagrams are prohibited in Controllers and Profiles.

### Input Test

- **Compact (`< 780`):** status, live map, axes, motion, rumble, and lighting form one scroll.
- **Regular (`780..<1060`):** live map sits beside an axes/motion rail; rumble and lighting share the
  row below.
- **Wide (`≥ 1060`):** the live map occupies a stable left column and axes, motion, rumble, and
  lighting form a two-column dashboard on the right.
- Cards use content-driven heights. The controller map has a bounded ideal width; controls do not
  expand merely to fill empty space.

## Interaction and Accessibility

- Preserve destination persistence and protect dirty profile drafts before navigation.
- Preserve automatic Input Test sampling, reconnect recovery, controller-specific symbols,
  temporary lighting ownership, inline output errors, and toolbar Refresh.
- Every status composition exposes a combined localized VoiceOver value. Native list selection,
  tab order, focus rings, reduced-motion behavior, and system contrast remain intact.
- Battery charge renders a reported range such as `90–99%`, an exact value such as `100%`, or
  localized `Unknown`; no approximation prefix is used.
