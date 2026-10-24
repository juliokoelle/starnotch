# Astra: source art

`astra.py` builds Astra procedurally in Blender (shape, glass and core materials, face texture, lights) and renders every colour and state. Nothing else is needed: no `.blend` file, no textures.

## Re-render

Blender 5.2 or later, headless:

```sh
cd art/astra
/Applications/Blender.app/Contents/MacOS/Blender -b -P astra.py -- --colorways all --states all --out renders
```

- 6 colours (`nova`, `aurora`, `cosmo`, `sol`, `mint`, `rose`) × 13 states (`neutral`, `happy`, `joyful`, `sleepy`, `surprised`, `excited`, `confused`, `angry`, `thinking`, `sleep`, `love`, `determined`, `peek`) = 78 PNGs, 1024 × 1024 RGBA, named `astra_<colour>_<state>.png`.
- The halo and under-glow are part of the render (semi-transparent pixels), so the app adds no glow of its own.
- Useful flags: `--colorways nova --states neutral` for one image, `--samples 64` for quick drafts, `--skip-existing` to resume, `--no-halo`.
- The script also saves `astra.blend` next to it for inspection (`--save-blend PATH` to move it). Renders and the `.blend` are not checked in.

## Into the app

```sh
swift scripts/make-astra-pack.swift art/astra/renders Resources/Characters/astra.notchpack
```

This cuts every state to one shared frame (halo included; `peek` to its own bottom edge), scales to 240 px tall and writes the pack's manifest with the effort colours: low Mint, medium Nova, high Aurora, xhigh Cosmo, max Sol, ultra Rosé.

Optional, for a smaller repo: re-save the PNGs losslessly with a PNG optimiser (the checked-in set went from 5.8 to 4.7 MB with Pillow's `optimize=True`).
