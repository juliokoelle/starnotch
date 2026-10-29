# Character packs

The characters in Starnotch come from packs. The app ships with three:

- **Astra**, the default: a little star in six colours (Nova, Mint, Aurora, Cosmo, Sol, Rosé), one colour per effort level. Built by `scripts/make-astra-pack.swift` from an image export, so new art is a pure asset swap.
- **Cat**: its eyes change with the effort level.
- **Pebbles**: five minimal round characters, drawn by `scripts/make-pebbles.swift`.

You can add your own.

## Where packs live

- In the app: `Starnotch.app/Contents/Resources/Characters/*.notchpack`
- Yours: `~/Library/Application Support/Starnotch/Characters/*.notchpack`

All packs found are loaded, app packs first. `[characters] packs = ["astra", "mine"]` in config.toml limits which ones; `[characters] main = "<id>"` picks the lead character (the one for music, dictation and capture); `[characters] fallback` the character for projects without a pick (default: the lead character). Restart the app after adding a pack.

## Format

A pack is a folder ending in `.notchpack`:

```
mine.notchpack/
  manifest.json
  fox/idle.png
  fox/working.png
  fox/celebrating.png
  ...
```

```json
{
  "format": 1,
  "id": "mine",
  "name": "My characters",
  "version": "1.0",
  "license": "CC BY 4.0",
  "characters": [
    {
      "id": "fox",
      "name": "Fox",
      "tint": "#F2A65A",
      "portrait": { "file": "fox/portrait.png", "sourceHeight": 240 },
      "states": {
        "idle": { "file": "fox/idle.png", "sourceHeight": 240 },
        "working": { "file": "fox/working.png", "sourceHeight": 240 }
      }
    }
  ]
}
```

- **`id`** values must be unique; a character id that another pack already has is skipped.
- **`tint`** colours the character's accents (rings, chips).
- **`sourceHeight`** is the figure's height in pixels in that file. Small figures look soft when drawn big, so the app falls back to the portrait when a sprite is less than half the drawn height.
- **Sprites** are PNGs with transparency. The bottom edge of the image is where the figure stands: the app lines it up with the edge of the card or the notch. 240 px tall works well for every size the app draws.
- **`license`** is shown nowhere yet, but say it: only ship characters you may redistribute. Pebbles is Apache 2.0 and fine to build on; Tara and the Cat are all rights reserved (see the `LICENSE` in their packs), so don't reuse their images.

## Effort levels

With colours following performance (Settings › Colour scale), a character can bring its own look per effort level: `low`, `medium`, `high`, `xhigh`, `max`, `ultra`.

```json
"levels": {
  "low":   { "name": "Mint", "tint": "#3ED6A0", "states": { "idle": { "file": "mint/neutral.png", "sourceHeight": 270 } } },
  "max":   { "name": "Max eyes", "states": { "working": { "file": "cat/level-max.png", "sourceHeight": 122 } } },
  "xhigh": { "name": "Cosmo", "colorway": "astra_cosmo" }
}
```

- **`states`** replace the base states at that level for the moods they cover (all of them for a full colour set like Astra's; only the busy ones for the Cat's eyes). Level sprites may be wider than upright poses.
- **`colorway`** tints the base sprites instead, with a built-in colorway or one of the pack's `recipes`.
- **`name`** shows in Settings; **`tint`** colours the glow and accents.
- A colour the user picks for a level in Settings wins over the character's own look; picking the character's tile there brings it back.

Pack-wide extras:

```json
"recipes": [ { "key": "astra_sol", "name": "Sol (tint)", "tint": "#FF9A3C", "tintAmount": 0.8 } ],
"characters": [ { "id": "astra", "finish": { "glow": 0.55, "highlight": 0.22 }, … } ]
```

- **`recipes`** add colorways to the Settings picker: `hue` (degrees), `saturation`, `brightness`, `contrast`, `shade` (multiply, 0 to 1), `tint` with `tintAmount` (wash in one colour, for gradient art).
- **`finish`** asks the app for a soft outer glow in the look's tint and a sheen on the upper half.
- **`"tintable": false`** on a character: the app never recolours it. No colorways, hue offsets or session colours; Settings shows its own looks and hides "Colour by: Session". Two sessions on the same level are told apart by their titles. The Cat uses this: only its eyes change.

## States

The app picks the best state a character has for what an agent is doing, in this order:

| Mood | States tried, best first |
|---|---|
| working | `focus_working`, `working`, `thinking`, `idle` |
| thinking (tools) | `thinking`, `search_research`, `reply_typing`, `working`, `idle` |
| typing (writing its answer) | `reply_typing`, `thinking`, `working`, `idle` |
| your turn | `curious`, `alert_important`, `surprised`, `idle` |
| failed | `sad`, `error_problem`, `surprised`, `idle` |
| idle | `sleepy`, `sleeping`, `shy`, `sleep_rest`, `idle` |
| asleep (idle 45 min) | `sleeping`, `sleep_rest`, `sleepy`, `idle` |
| finished | `celebrating`, `download_complete`, `happy`, `excited`, `idle` |
| listening (dictation) | `voice_listening`, `music_playback`, `music`, `idle` |
| music | `voice_listening`, `music_playback`, `music`, `happy`, `idle` |

`idle` alone is enough to start; then any state you add takes over its moods. Colour variants (Settings › Colour scale) are applied by the app to every sprite, so you don't draw them.
