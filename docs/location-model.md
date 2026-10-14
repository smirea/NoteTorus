# Named locations

Named locations turn raw note coordinates into reusable place identities without rewriting the location evidence stored on a note.

## Model

Each place in `config.json` has:

- A stable ID and user-editable name.
- An optional user-editable postal address.
- One canonical pin coordinate used by maps and external directions.
- Zero or more alias coordinates captured by notes.

The canonical pin comes from the selected Apple Maps address. The captured coordinate is retained as an alias because GPS drift, entrances, and a Maps address pin can differ. Assigning a note to an existing place adds its captured coordinate as another alias.

## Resolution

A note resolves to a place when its raw coordinate is within 200 meters of that place's canonical pin or any alias. An exact alias created by assignment wins an overlap; otherwise the closest coordinate wins, with equal distances resolved by name so results stay deterministic.

The radius is intentionally fixed and forgiving enough for normal phone GPS drift while remaining small enough to distinguish nearby venues. Notes continue to fall back to their captured city when no saved place matches.

Usage counts are derived from current notes rather than stored. Each note contributes to at most one place, so renaming or adding an alias updates every affected note and count consistently.

## Note interaction

Only the location label and icon above the map enter edit mode. The label morphs into a name field while an address field appears above it.

- Apple Maps reverse geocoding proposes the current pin's address when none is saved.
- Apple Maps autocomplete supplies address and point-of-interest suggestions near the note.
- Choosing a suggestion saves its formatted address and coordinate as the canonical pin.
- A manually edited address is resolved on submit or save when possible. If lookup is unavailable, the text is still saved and the previous pin remains.
- Other named places within 10 miles appear alphabetically with their derived note count and distance from the note to the canonical pin.
- Choosing an existing place assigns the note coordinate to it and exits edit mode.

The map and Google Maps link use the canonical pin. Note JSON continues to contain the original captured coordinate and city.

## Configuration and restore

`Application Support/Talkward/config.json` is the versioned configuration source for settings, named locations, API keys, and future app-wide configuration:

```json
{
  "schemaVersion": 2,
  "settings": {},
  "elevenLabsAPIKey": "…",
  "locations": [
    {
      "id": "…",
      "name": "Home",
      "address": "…",
      "pin": {
        "latitude": 41.0,
        "longitude": -87.0
      },
      "aliases": []
    }
  ]
}
```

The file is written atomically, included in device backup, and mirrored to `iCloud Drive/Talkward/config.json`. API keys are stored as plain text. On a fresh install with no local config, the app attempts to restore the iCloud copy before creating one from legacy settings. Once a local config exists it remains authoritative; iCloud note exports are still not imported or merged.

Unknown JSON fields are ignored and a missing top-level locations collection defaults safely, allowing the schema to grow without breaking older backups.
