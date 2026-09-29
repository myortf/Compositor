# Smart Objects — design

Date: 2026-09-29
Status: approved for planning

## Goal

Let a user wrap a single raster layer into a non-destructive "smart object":
double-click it to edit its contents (paint, add layers, apply adjustments,
masks, effects) in isolation, then return to the main document and see the
result composited back in — while the smart object stays editable, at full
source resolution, indefinitely.

This mirrors Photoshop's embedded Smart Object: a layer whose pixels are the
rendered output of a small nested document that travels with the file and can
be reopened and re-edited at any time.

## Scope (v1)

- **Convert to Smart Object**: available on a single selected, non-group
  layer that carries an image asset (plain raster/image layer). Not offered
  for groups, adjustment layers, shape layers, text layers, or masks-only
  selections — these can be added in a later iteration if wanted.
- **Editing**: double-clicking a smart-object layer opens its nested content
  as a new tab in the existing tab strip (`ProjectWorkspace`/`ProjectTab`),
  exactly like opening any other project. The user works with the full
  Compositor toolset inside it.
- **Applying changes**: closing that tab (or otherwise returning to the
  parent document) re-renders the nested document's composite and writes it
  as the smart-object layer's new displayed pixels, as one undo step in the
  parent document. No re-render happens, and no undo step is recorded, if
  nothing changed inside.
- **Persistence**: the nested document's full layer stack is saved inside the
  `.comp` package alongside the parent, so it round-trips across close/reopen
  and stays editable later. Files from older Compositor versions are
  unaffected; older Compositor builds opening a file that contains smart
  objects see the layer as an ordinary flattened image layer.
- **Non-destructive scale**: unaffected by this feature — layers already
  scale without quality loss (`LayerTransform`); a smart object's nested
  document always renders at its own native pixel size regardless of how
  small the shell is currently scaled on the canvas.

### Explicitly out of scope (v1)

- Converting multiple selected layers / a folder into one smart object
  (would need a "merge into smart object" step first — the user can already
  achieve this with the existing Merge Group, then Convert to Smart Object,
  so this is a later convenience, not a blocker).
- Linked/duplicated smart objects that share content (Photoshop's implicit
  link on plain Duplicate). v1 duplicate makes an independent copy.
- Converting adjustment/shape/text layers or groups directly.
- Replacing a smart object's source content from an external file.
- Any "auto-update on every keystroke" live preview while the nested tab is
  open — the parent shows the last-applied render until the tab is closed.

## Data model

`ImageLayer` (`Compositor/Document/EditorSession.swift`) gets one new
optional field, following the same additive pattern as `shape`, `text`,
`effects`:

```swift
var smartObject: SmartObjectContent?
```

`SmartObjectContent` (new file, `Compositor/Document/SmartObject.swift`)
holds the nested document, mirroring `CanvasDocument`:

```swift
nonisolated struct SmartObjectContent: Equatable {
    var width: Int
    var height: Int
    var resolution: Double
    var layers: [ImageLayer]
}
```

The shell layer's own `asset` remains the flattened render of
`smartObject.layers` at `(width, height)` — this is what every existing
renderer, exporter, and older app build already knows how to draw. No
compositing code elsewhere needs to know smart objects exist; they only
matter to (a) the convert action, (b) the tab that edits the nested content,
and (c) the apply-on-close step that re-renders and writes back the asset.

A layer with `smartObject != nil` cannot be a group, cannot carry
`adjustment`, `shape`, or `text` (same mutual-exclusivity already enforced
for those kinds).

## File format

Additive change, version bump per `docs/project-format.md` convention
(next version, e.g. 12): a layer record gains an optional `smartObject`
object:

```json
"smartObject": {
  "width": 4032,
  "height": 3024,
  "resolution": 72,
  "manifestFile": "<layer UUID>.smartobject.json"
}
```

The nested manifest (`smartobjects/<layer UUID>.smartobject.json`) reuses the
existing project manifest schema (same `ProjectManifest` layer records,
recursively — a smart object's own layers can themselves carry masks,
adjustments, effects, text, even nested smart objects within depth limits
matching the existing 64-level group nesting guard). Its images live under
`smartobjects/<layer UUID>/images/`, parallel to the top-level `images/`
folder, so asset filenames never collide between nesting levels.

Because the field and folder are additive:
- Files declaring versions before the bump reject a `smartObject` field, per
  the existing convention (`ProjectStore` validation).
- Older app builds ignore the unknown field and the extra folder entirely and
  render the shell's own PNG — a smart object degrades gracefully to a
  regular image layer.

Limits: nested `width`/`height`/pixel-count/layer-count use the same
`DocumentLimits` as the top-level document. Round-trip tests (per AGENTS.md)
cover: save → reopen → contents unchanged; convert → edit inside → apply →
save → reopen → edited contents still editable; opening a file with a
`smartObject` field under a pre-bump declared version is rejected.

## UI / UX flow

1. **Convert**: right-click (or Layer menu) → "Convert to Smart Object" on an
   eligible layer. This wraps the layer's current pixels as
   `smartObject.layers = [copy of the layer as a single image layer at its
   own native pixel size]`, `width`/`height` = that native size. The shell
   layer keeps its existing transform, mask, opacity, blend mode, effects,
   name — visually nothing changes at the moment of conversion. The layer
   thumbnail gets a small badge (matching the existing corner-icon pattern
   used elsewhere in the Layers panel) marking it as a smart object.
2. **Enter**: double-click the smart-object layer (double-click on a plain
   image layer already opens nothing special today, so this is a new
   binding) opens a `ProjectTab` whose `EditorSession.document` is built from
   `smartObject`. The tab is tagged with a back-reference
   (`parentTabID`, `parentLayerID`) so it's distinguishable in the tab strip
   (e.g. title "◆ <layer name>") and knows where to write results.
3. **Edit**: normal Compositor editing inside that tab — its own undo
   history, own selection state, exactly like any other open project. Saving
   to disk is not required while working; the content lives in memory until
   applied back (see below) and then persists with the parent's next save,
   same as any other unsaved layer edit.
4. **Apply on close**: closing the tab (or clicking back to the parent tab
   with unsaved smart-object edits) triggers:
   - `drawLiveComposite` (already used by `mergeLayers()`) renders the nested
     `CanvasDocument` at its native `width`/`height` into a flattened
     `CGImage`.
   - If the result differs from the shell's current asset, the parent
     document's layer record's `asset` and `smartObject.layers` are updated,
     wrapped in a single undo step ("Update Smart Object"). If nothing
     changed, nothing is recorded.
   - The tab closes and focus returns to the parent tab, mirroring
     `ProjectWorkspace.select`.
5. **Closing with unsaved nested changes**: no extra confirmation dialog —
   applying is automatic and silent (unlike Photoshop's explicit "Save"),
   since the parent document's own undo/save already governs whether the
   result is kept. This keeps the interaction model simple and matches how
   every other Compositor edit already flows into one undo step.

## Rendering & compositing

No changes to `LayerRenderer`, `LiveMaskRenderer`, effects, or export code —
they only ever see the shell layer's `asset`, exactly like today. The only
new rendering call site is the apply-on-close step, which reuses
`EditorSession.drawLiveComposite(_:in:)` against the nested `CanvasDocument`,
the same primitive `mergeLayers()` already uses to flatten a layer subset.

## Undo behavior

- Parent document: one undo step per apply-on-close ("Update Smart Object"),
  plus one step for the initial "Convert to Smart Object".
- Nested document: its own independent, session-only undo stack, exactly
  like any other open project tab — consistent with
  "Undo history... is session-only" in `docs/project-format.md`.

## Edge cases

- **Resizing the canvas inside the smart object**: allowed: the nested
  document's `width`/`height` can change like any project's Canvas Size /
  Image Size. The shell's `transform.size` (its footprint on the parent
  canvas) does not change automatically — the rendered asset's pixel
  dimensions change, same as any other pixel-replacing edit (e.g. Image
  Size) already handles for ordinary layers.
- **Deleting the smart-object layer**: removes its nested content and
  `smartobjects/<layer UUID>/` folder on next save, same lifecycle as an
  orphaned mask file today.
- **Duplicating**: independent copy — a new nested manifest/UUID, no shared
  state (see "Out of scope" above for linked duplicates).
- **Nesting depth**: a smart object's own layers may include further smart
  objects; reuse the existing 64-level ancestor guard (`LayerHierarchy`) to
  bound recursion in both the renderer and the file-format validator.
- **Opening a smart-object tab that's already open**: reuse the existing tab
  instead of opening a second one for the same layer (mirrors how
  `ProjectWorkspace.addTab(reuseEmpty:)` already avoids duplicate empty
  tabs).
- **Quitting/closing the app with a smart-object tab open and unapplied
  edits**: treated as closing that tab first (apply-on-close runs), then the
  normal per-document close/save prompts proceed as today.

## Testing

`CompositorTests` additions, matching existing test file conventions:
- Convert eligibility: enabled only for a single non-group image layer;
  disabled for groups, adjustment/shape/text layers, multi-selection, no
  selection.
- Convert produces a shell layer whose displayed pixels are unchanged.
- Apply-on-close updates the shell's asset to the nested composite and
  records exactly one undo step; a no-op close records none.
- Round-trip: save → reopen → smart object still present, editable, and its
  nested layers unchanged.
- Backward compatibility: a manifest declaring a pre-bump version containing
  a `smartObject` field is rejected (existing `ProjectStore` validation
  pattern).
- Forward compatibility (documented, not automatable without an old binary):
  the additive-field convention means an older build renders the shell's own
  PNG and never sees `smartObject`.
- Nesting depth guard: a smart object containing a smart object containing a
  smart object (a few levels) still renders and saves; a manifest exceeding
  the depth guard is rejected.

## Open follow-ups (not part of this plan)

- Merge-multiple-layers-into-one-smart-object convenience action.
- Linked/shared smart object duplicates.
- Converting adjustment/shape/text layers or groups.
- Live-updating preview while the nested tab is open, instead of apply-on-close.
