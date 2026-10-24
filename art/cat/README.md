# The cat: source images

`make_cat_pack.py` turns the cat's single images (1254 × 1254 RGBA) into `Resources/Characters/cat.notchpack`: it removes the warm rim and colour spill from the cut-outs (whiskers kept), aligns every sitting image on one frame (same height, head centre and baseline), scales to 240 px and writes the manifest.

```sh
python3 art/cat/make_cat_pack.py <images folder> Resources/Characters/cat.notchpack
```

Needs Pillow and numpy. The file names it expects are listed at the top of the script: six eye levels (low to ultra, sitting, neutral face), six expressions (happy, asleep, sleepy, surprised, focused, grumpy) and one lying peek with the max eyes. The source images are not checked in.

While the cat works, its eyes show the session's effort level; the expressions (happy, sleepy, asleep, surprised, grumpy) bring their own eyes. The cat is never recoloured (`"tintable": false`).
