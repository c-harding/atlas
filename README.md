# Atlas

Prepare maps for printing, using online slippy maps, such as Bing Maps’s [Quadkey](https://docs.microsoft.com/en-us/bingmaps/articles/bing-maps-tile-system) and generic [ZXY](https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames) tiles, and showing [OS grid references](https://en.wikipedia.org/wiki/Ordnance_Survey_National_Grid).

Every tile fetched is permanently cached.

For best results, view in Firefox.

## Usage

Choose tile servers by copying the `atlasrc.yaml.sample` to `atlasrc.yaml`.

Run the server
```
./atlas
```

Or with live reloading for development, using [`entr`](http://eradman.com/entrproject/):

```
ls ./atlas* | entr -r ./atlas
```

This can then be browsed at `http://localhost:5000/?center=NY%2017125%2012104`.

The `center` argument is an OS grid reference, or comma-separated list thereof (one per page to be printed).

### Terminal usage

`./atlas`: serve a web server, as detailed above.

`./atlas TL123456`: display the map in a terminal, using [iTerm](https://www.iterm2.com)’s [image API](https://www.iterm2.com/documentation-images.html).

The port can be set using the environment variable `ATLAS_PORT`, otherwise it will default to 5000.

### HTTP Arguments

| **Query** | **Default** | **Description** |
|-|-|-|
| `style` | | The namespace of the tile server to use. This defaults to the first tile server in your `atlasrc.yaml` file. |
| `scale` | 4 | Number of centimetres printed for each kilometre on the map. |
| `paper` | A4 | `A3`, `A4` or `A5`, or `A3-portrait` etc. This may have to be specified when printing too. |
| `margin` | 0.5 | How many centimetres of border to leave around the page. |
| `center` |  | A comma-separated list of pages to print, given as OS grid references of their center point. This is required unless `fit` is given instead. |
| `fit` |  | A comma-separated list of points to print. A bounding rectangle will be calculated, and every page in this rectangle will be printed. |
| `padding` | 0 | Include a minimum of `padding` kilometres around each of the provided points in `fit`. This has no effect if `fit` is not given. |
| `partial` |  | If present, do not serve the `<head>`, only the new container. This allows AJAX requests for more maps, via the `addMap()` function. |

### `atlasrc.yaml` config

This file contains an array of objects, each specifying a tile server source.

| Key | Description |
|-|-|
| `type` | The tile coordinate system to use, either `quadkey` or `zxy`. |
| `url` | The URL of a tile, with the tile id replaced by `%s` (for quadkey), or by `{z}`, `{x}` and `{y}` for zxy maps. In the latter case, `{a\|b\|c}` etc may also be used to randomize the source. |
| `namespace` | The user-facing name to identify the style as. This should be unique. |
| `folder` | The local folder on the server to cache these tiles in. This may be shared, but only when the tile identifiers are distinct. |
| `zoom` | The default zoom level to request the tiles at. Defaults to 15. If `zooms` is specified and `zoom` does not fall within it, the nearest value in `zooms` is taken. |
| `zooms` | An array or range (e.g. `!ruby/range 12..16`) of valid zoom levels. Defaults to the singleton `[zoom]`. |
| `grid_lines` | Whether or not to superimpose OS grid lines over the map. |
| `os_north` | Whether or not to rotate the map such that OS grid lines run exactly vertically. |

## Sample

`/?center=SW 341 254`

![Example print of Lands End, at 4cm:1km on A4](sample.jpg)
