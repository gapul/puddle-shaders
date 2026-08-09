# puddle-shaders

Metal wallpapers for [Puddle](https://github.com/gapul/Puddle). Each `.metal` file is one
wallpaper: Puddle compiles it at runtime and hot-reloads it when it changes.

## Install

In Puddle: **Add Wallpaper → From URL…**, and give it the address of a release asset. Or from
anywhere that can open a URL:

```console
$ open -g 'puddle:install?url=https://github.com/gapul/puddle-shaders/releases/latest/download/worldmap.zip'
```

Puddle downloads it into `~/Library/Application Support/Puddle/Wallpapers/`, adds a wallpaper
pointing at the shader inside, and watches it from there. Installing the same URL again
replaces what is there.

Or just clone this and point Puddle at a file — the shaders are ordinary files, nothing here
needs installing.

## The shaders

| | |
|---|---|
| `dotmatrix` | Dot grid that answers to the focused workspace. The cheap one — this is the daily driver. |
| `worldmap` | Coastline line art on an equirectangular map, with lights running along the outlines. |
| `globe` | The same coastlines on a rotating sphere. |
| `constellation` | Drifting stars, joined when they come close. |
| `topographic` | Contour lines over drifting noise. |
| `aurora`, `aurora-gradient` | Slow colour fields. |
| `rose-pine` | Flat Rosé Pine palette study. |
| `audio-bars` | Spectrum bars from the system audio tap (declare `audio` on the wallpaper). |

All of them follow dark/light, and most read `user[0]` as the focused workspace to pick a
palette — see the [wallpaper source contract](https://github.com/gapul/Puddle/blob/main/docs/wallpaper-source-contract.md)
for what a shader is handed, and the gapul convention for what the inputs file means.

## The two big ones

`worldmap` and `globe` are 260-odd lines of shader and 20,000 lines of baked distance field.
The field lives in `*-tables.metal` and is spliced back in with `#include`, which Puddle
resolves itself — Metal's runtime compiler has no include search path.

Regenerate the tables from [Natural Earth](https://www.naturalearthdata.com) 50m land polygons:

```console
$ python3 tools/bake_world_sdf.py
```

Do not hand-edit the tables, and do not run a decimator over them: the shader indexes them by
exact dimensions.

## License

MIT.
