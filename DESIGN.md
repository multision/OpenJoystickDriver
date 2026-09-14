# Controller Workbench Design System

Physical connection and OpenJoystickDriver session state are separate. Suspension is reversible:
the physical controller remains inventoried while input, physical effects, and OJD-owned virtual
output are neutralized. Automatic compatibility mode publishes no duplicate virtual device for a
native HID controller. Explicit compatibility modes opt into an OJD-owned virtual identity.

## Direction

Controller Workbench is a native macOS operations surface. It uses native source lists,
materials, typography, controls, focus, and semantic colors, not a simulated game console or web
dashboard. Density is deliberate: status is quick to scan, detailed values remain
readable, and every pane can scroll or reflow without resizing its window.

## Window Structure

- The primary window uses a collapsible source-list sidebar for Overview, Controllers, Profiles,
  Console, optional Developer Tools, and Settings.
- The workbench opens at `1040 × 700` points with an `800 × 560` minimum content size.
- Input Test opens at `900 × 620` points with a `700 × 500` minimum content size.
- Retain saved geometry, clamped to the current screen's usable frame. Pane changes never
  force a resize. No arbitrary maximum window size applies.
- Readable detail content may constrain its own measure while workspaces and logs use available
  width.

## Materials And Color

- Window surfaces use `NSColor.windowBackgroundColor`; sidebars and secondary list surfaces use
  native source-list or control backgrounds.
- Cards use native `GroupBox` or a single control-background surface. Separators use
  `NSColor.separatorColor`.
- Text uses label, secondary-label, and tertiary-label semantic colors. Green means explicitly
  active or healthy, orange means actionable attention, red means failure, and grey means neutral,
  inactive, disconnected, unknown, or loading. Blue is reserved for selection and a documented
  controller-family identity.
- Color never carries state by itself. Every state includes text or a supported SF Symbol, and one
  visible surface owns each state and action.
- Xbox and PlayStation accents identify controller family or active input. Nintendo, Steam, and
  generic controllers remain semantic unless a recorded family color exists.
- Light and dark appearances use semantic system colors, not appearance-specific decorative
  palettes.

## Typography And Data

- Use system title/headline/body/caption roles and Dynamic Type behavior supplied by SwiftUI.
- Use monospaced design only for logs, packet values, identifiers, and numeric measurements.
- Headers lead with the destination name and an optional factual subtitle. Do not add decorative
  eyebrows.
- Data rows use secondary labels and primary values. Name unknown or absent values explicitly.

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
- **Interface icon:** an SF Symbol supported by the running macOS release. Gate newer symbols with
  `#available` and use another supported symbol or localized text on older releases. Do not add
  custom interface images, emoji, Unicode pictograms, generated artwork, or SVG fallbacks.

## Responsive Policies

### Workbench Panes

- Overview leads with readiness, then reflows permission cards from four columns to two and then one.
- Controllers and Profiles are side by side only when the pane preserves a `200...240` point list
  and at least `600` points of detail width. Otherwise, including the `800 × 560` minimum window,
  the list becomes a compact upper region and the selected detail remains scrollable below.
- Controller facts use one column below `560` detail points and two columns otherwise. Identity
  choices use one column below `360` inner points, two columns from `360` through `679`, and four
  columns at `680` or wider. Rows are content driven and do not reserve blank cells.
- Settings places General and Developer groups side by side when space permits and stacks them below
  `650` points. Notification groups remain readable rather than widening the window.
- Developer controller facts change from three columns to stacked groups below `760` points.

### Profiles

- The selected editor section lasts only for the current Profiles session, survives profile
  switches, defaults to Assignments, and never enters draft or save state.
- The detail header keeps the profile identity, one pencil action for metadata, scope, assignment
  count, activation state, one primary activation action, and one native profile-actions pull-down.
  Changing sections resets the detail scroll position. The persistent footer is the sole
  owner of save progress, result, error, and Save; Delete and feedback remain there as well.
- Sections are ordered Assignments, Combinations, Layers, and Controller. Assignments groups source
  mappings; Combinations separates chords and sequences; Layers retains activation, mapping, motion,
  edit, and removal controls; Controller owns metadata, output policy, motion, sticks, triggers,
  touch, and lighting while advanced configuration stays in specialized sheets.
- Local Add, Remove, and Adjust actions use compact `plus`, `minus.circle`, and `pencil` buttons with
  28-point targets, localized fallbacks, help, and accessibility labels. Profile activation, Save,
  Cancel, bulk clearing, and destructive profile deletion remain labeled.
- Profile editors use the conservative intersection of matching live controller capabilities, then
  an exact catalog declaration when disconnected. Unknown controllers expose only ordinary base
  controls and virtual or system destinations. Unsupported saved values remain visible and removable
  and are never rewritten by an unrelated save.
- Small profile sheets share one content-sized title, help, validation, and footer scaffold. Stick,
  trigger, and touch sheets use a compact disabled state and grow only for enabled content; motion
  remains bounded to one scroll area.
- Section navigation is segmented at `620` points or wider and becomes a labeled native pop-up
  below it. Assignment source and destination fields are inline at `680` points or wider
  and stack below it.
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

## Interaction And Accessibility

- Preserve destination persistence and protect dirty profile drafts before navigation.
- Preserve automatic Input Test sampling, reconnect recovery, controller-specific symbols,
  temporary lighting ownership, inline output errors, and toolbar Refresh.
- Every status composition exposes a combined localized VoiceOver value. Native list selection,
  tab order, focus rings, reduced-motion behavior, and system contrast remain intact.
- Battery charge renders a reported range such as `90–99%`, an exact value such as `100%`, or
  localized `Unknown`; no approximation prefix is used.

## Product Roles

- The menu bar owns one concise readiness, controller, and active-profile summary; a conditional
  attention action; connected-controller shortcuts; Open Workbench; Settings; Help/About; and Quit.
  It does not own manual refresh, profile editing, packet tools, reports, logs, or contributor
  diagnostics.
- The workbench owns setup and repair, permissions, updates, controller input/output, identity,
  complete profile mapping, logs and reports, runtime health, self-test, passive USB inspection,
  packet capture, and contributor diagnostics. Views call shared typed services and never shell out.
- Structured output and scripting forms, packaging, catalog and DriverKit generation, and other
  headless automation remain CLI-only.

## Application Presence

- `LSUIElement` remains enabled and menu-only launch uses the accessory activation policy.
- Opening Workbench or Input Test switches to the regular policy and shows the Dock icon. Minimized
  windows still count as open. Closing the last of those two windows restores accessory policy;
  About and transient system panels do not keep the Dock icon visible.
