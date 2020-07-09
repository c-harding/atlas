# Atlas

Prepare maps for printing, using a tileserver based on Bing Maps’s Quadkey, and
showing OS grid references.

## Usage

```
TILE_SERVER="https://example.com/tiles?quadkey=%s" ./atlas
```

Or with live reloading:

```
ls . | TILE_SERVER="https://example.com/tiles?quadkey=%s" entr -r ./atla
```

This can then be browsed at `http://localhost:5000/?center=NY%2017125%2012104`.

The center argument is an OS grid reference, or comma-separated list thereof (one per page to be printed).

### Terminal usage

`./atlas`: serve a web server, as detailed above.

`./atlas TL123456`: display the map in a terminal, using [iTerm](https://www.iterm2.com)’s [image API](https://www.iterm2.com/documentation-images.html).

### HTTP Arguments

| **Query** | **Default** | **Description** |
|-|-|-|
| `scale` | 1 | Number of centimetres printed for each kilometre on the map. |
| `paper` | A4 | Either A4 or A4-portrait, for now |
| `center` |  | A comma-separated list of pages to print, given as OS grid references of their center point. This is required unless `fit` is given instead. |
| `fit` |  | A comma-separated list of points to print. A bounding rectangle will be calculated, and every page in this rectangle will be printed. |
| `partial` |  | If present, do not serve the `<head>`, only the new container. This allows AJAX requests for more maps, via the `addMap()` function. |
