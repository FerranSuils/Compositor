# Compositor automation API

Everything the app's tools, menus and panels can do is also an HTTP call, so a script, a pipeline or an AI agent can
edit photos without touching the window. The API runs inside Compositor and drives the same editing session the
window shows, so the canvas updates as commands land and every change is a normal undo step.

## Starting the server

The server is off unless you ask for it. It only listens on `127.0.0.1`, and it refuses requests made by web pages:
anything carrying an `Origin` header, a `Sec-Fetch-Site` other than `none`, or a `Host` other than `127.0.0.1`,
`localhost` or `[::1]` gets a 403. So a site open in your browser can't drive the editor; scripts, `curl` and agents
send none of these and are unaffected. Opening `http://127.0.0.1:4747/v1/ops` by typing it into the address bar still
works.

| How | Effect |
|---|---|
| `open -a Compositor --args --automation` | Listen on port 4747. |
| `open -a Compositor --args --automation-port 5000` | Listen on another port. |
| `open -a Compositor --args --automation-token s3cret` | Require `Authorization: Bearer s3cret` (or `?token=`) on every request. |
| `COMPOSITOR_AUTOMATION_PORT=4747 COMPOSITOR_AUTOMATION_TOKEN=… open -a Compositor` | Same, through the environment. |
| `defaults write com.wonderassembly.compositor automationPort -int 4747` | Always on. `defaults delete … automationPort` turns it off again. |
| `Compositor.app/Contents/MacOS/Compositor --automation-run script.json --quit` | Run a script file (the body of `POST /v1/run`) and exit with 0 or 1; results print as JSON on standard output. |

Compositor is sandboxed. The API can read and write files anywhere in your home folder, in `/tmp` and on mounted
volumes; for other places pass image bytes inline (`imageData`) or receive them from `project.render`.

## Endpoints

| Method and path | Purpose |
|---|---|
| `GET /v1/health` | App version, open projects, the active one. |
| `GET /v1/ops` | The catalog of operations with their parameters, generated from the running app. Start here. |
| `GET /v1/state?include=layers,selection,guides,tools` | The active project's state (all sections by default). `project=` picks another tab. |
| `GET /v1/render?format=png&layer=…&scale=0.5&crop=x,y,w,h` | The flattened composite as image bytes (`png`, `jpeg`, `tiff`, `heic`). |
| `POST /v1/run` | Runs one operation or a list of steps. |

### The payload

One operation is a JSON object with `op` and its parameters beside it (or under `params`):

```json
{ "op": "adjust.levels", "layer": "Portrait", "black": 12, "white": 240, "gamma": 1.1 }
```

The reply is `{"ok": true, "op": "adjust.levels", "result": {…}, "ms": 41}`, or an error with an HTTP status
and a message that names the offending key:

```json
{ "ok": false, "error": "\"opacity\" must be between 0 and 1" }
```

| Status | Meaning |
|---|---|
| 400 | A parameter is missing, mistyped or out of range. |
| 401 | A token is configured and the request didn't present it. |
| 403 | The request came from a web page (see above). |
| 404 | No such op, layer, project or file. |
| 409 | The session cannot do this now (an edit is open, the project is busy, unsaved changes); the message says why. `session.cancel` clears stuck edits. |
| 422 | The app refused the edit (an empty selection, a folder where pixels were needed, a decode failure). |

Several steps run in order as one request. They stop at the first failure unless `stopOnError` is false, and every step
reports back:

```json
{ "project": "shot", "stopOnError": true, "steps": [
  { "op": "layer.addImage", "path": "~/Pictures/shot.jpg", "name": "Photo" },
  { "op": "filter.cameraRaw", "exposure": 0.4, "contrast": 15, "detail": { "sharpenAmount": 40 } },
  { "op": "project.export", "path": "~/Desktop/shot.jpg", "quality": 0.9 }
] }
```

Requests are serialized: a second call waits for the first to finish.

### Conventions

- **Layers** are named by id or by unique name; `"active"` or leaving `layer` out means the active layer. Ops that take
  `layers` accept a list.
- **Points** are document pixels, origin top-left, as `[x, y]` or `{"x": …, "y": …}`. **Rects** are
  `[x, y, width, height]` or `{x, y, width, height}`. **Sizes** are `[width, height]`.
- **Colors** are `"#RRGGBB"`, `"#RRGGBBAA"`, `[r, g, b]` (0–1 or 0–255) or `{"red", "green", "blue"}`.
- **Enumerations** match the app's own names, ignoring case, spaces and underscores: `"Linear Dodge (Add)"`,
  `"linear dodge (add)"` and `"linearDodge(add)"` are the same blend mode. `app.info` lists them all.
- **Settings objects** are partial: only the keys you send change. `GET /v1/state` and the `*.get` ops report values in
  exactly the shape the setters take.
- `project` on a request or a step targets another open tab (id, title or path); otherwise the active tab.

## Operations

`GET /v1/ops` is the authoritative list, with every parameter. This is the map.

### project
`project.list`, `project.activate`, `project.new` (width, height, resolution, background color, newTab),
`project.open` (path), `project.save` (path for Save As; waits for the files), `project.close` (discard),
`project.export` (path, format, quality, matte, scale, layer/layers, crop), `project.render` (same, returns base64),
`project.import` (paths of PNG/JPEG/HEIC/TIFF/SVG/PSD/RAW, center, raw development settings),
`project.state`, `project.snapshotToFolder`.

### layer
`layer.list`, `layer.get`, `layer.select`, `layer.add`, `layer.addImage` (path, imageData or color; origin or center),
`layer.delete` (bakeClipping), `layer.rename`, `layer.setVisible`, `layer.setOpacity`, `layer.setBlendMode`,
`layer.move` (offset, or parent/above/atBottom, or outOfFolder), `layer.duplicate`, `layer.group`, `layer.addGroup`,
`layer.ungroup`, `layer.merge` (Merge Down / Merge Layers / Merge Group), `layer.flatten`, `layer.clip` (clipping
mask to a base), `layer.unclip`, `layer.setPixels`, `layer.setCollapsed`.

### mask
`mask.add` (reveal/hide all, or from the selection), `mask.setPixels` (image or uniform value), `mask.delete`,
`mask.setEnabled`, `mask.setLinked`, `mask.copy`, `mask.invert`, `mask.fill`, `mask.blur`, `mask.setPlacement`
(an unlinked mask's own box).

### transform
`transform.set` (x, y, width, height, rotation, flipX, flipY, sampling), `transform.move` (dx/dy or to),
`transform.scale` (factor, percent, width/height), `transform.rotate`, `transform.flip`, `transform.distort` (four
corners), `transform.setSampling`. All take one layer, several layers or a folder, as the Move tool does.

### effects
`effects.get`, `effects.set` (stroke, shadow, colorOverlay, innerShadow, outerGlow, innerGlow), `effects.remove`,
`effects.setEnabled`, `effects.copy`.

### adjustment
Adjustment layers: `adjustmentLayer.add` (kind: Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain, Add
Noise, Gaussian Blur, Motion Blur, Invert, Black & White, Color Balance), `adjustmentLayer.get`, `adjustmentLayer.set`.

On a layer's pixels, inside the selection: `adjust.levels` (ranges or `auto`), `adjust.hueSaturation` (per range,
bands, colorize), `adjust.curves`, `adjust.exposure`, `adjust.gradientMap`, `adjust.grain`, `adjust.blackWhite`,
`adjust.colorBalance`, `adjust.invert`.

Settings shapes:

```json
{ "levels":       { "channel": "RGB", "black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255,
                    "ranges": [ {…RGB…}, {…red…}, {…green…}, {…blue…} ] } }
{ "curves":       { "rgb": [[0,0],[128,140],[255,255]], "red": […], "green": […], "blue": […] } }
{ "hueSaturation":{ "range": "Reds", "hue": 10, "saturation": -20, "lightness": 0, "colorize": false,
                    "adjustments": { "Blues": { "hue": 0, "saturation": 15, "lightness": 0 } },
                    "bands": { "Reds": [315, 345, 15, 45] } } }
{ "exposure":     { "exposure": 0.5, "offset": 0, "gamma": 1 } }
{ "gradientMap":  { "shadows": "#101030", "highlights": "#FFE0B0", "reversed": false } }
{ "grain":        { "amount": 25, "size": 1.5, "roughness": 50, "seed": 7 } }
{ "blackWhite":   { "reds": 40, "yellows": 60, "greens": 40, "cyans": 60, "blues": 20, "magentas": 80, "tint": false, "tintHue": 40, "tintSaturation": 20 } }
{ "colorBalance": { "shadows": [0,0,0], "midtones": [10,0,-5], "highlights": [0,0,0], "preserveLuminosity": true } }
```

### filter
`filter.apply` (any kind) and one op per filter: `filter.gaussianBlur` (radius), `filter.motionBlur` (angle,
distance), `filter.addNoise` (amount, gaussian, monochromatic), `filter.vignette` (amount, color, midpoint, roundness,
feather, highlights), `filter.bloom` (amount, radius), `filter.tonalContrast` (amount, radius, shadows, midtones,
highlights), `filter.lensCorrection` (distortion), `filter.dither` (style, pixelSize, colors, dark, light, …),
`filter.removeBackground` (quality, refineEdges, matteContrast, shiftEdge; adds a layer mask),
`filter.contentAwareFill` (fills the selection), and `filter.cameraRaw`. `filter.defaults` shows a kind's settings.

Camera Raw takes the same nested groups the panel has; Light, Color and Effects sliders may also be flat:

```json
{ "op": "filter.cameraRaw", "layer": "Photo",
  "light":   { "exposure": 0.3, "contrast": 10, "highlights": -30, "shadows": 25, "whites": 0, "blacks": -5 },
  "color":   { "whiteBalance": "Custom", "temperature": 5, "tint": 0, "vibrance": 20, "saturation": 0 },
  "effects": { "texture": 10, "clarity": 8, "dehaze": 0,
               "glow": { "amount": 0, "style": "Diffusion", "range": 0, "spread": 0, "warmth": 0 },
               "vignette": { "amount": -20, "style": "Highlight Priority", "midpoint": 50, "roundness": 0, "feather": 50, "highlights": 0 },
               "grain": { "amount": 0, "size": 25, "roughness": 50 } },
  "curve":   { "shadows": 0, "darks": 0, "lights": 0, "highlights": 0, "preset": "mediumContrast",
               "rgb": [[0,0],[1,1]], "refineSaturation": 0 },
  "mixer":   { "hue": { "Oranges": 5 }, "saturation": [0,0,0,0,0,0,0,0], "luminance": { "Blues": -10 },
               "points": [ { "hue": 30, "saturation": 0.6, "luminance": 0.5, "hueShift": 10, "hueRange": 30 } ] },
  "grading": { "shadows": { "hue": 220, "saturation": 15, "luminance": 0 }, "highlights": { "hue": 40, "saturation": 10 }, "blending": 50, "balance": 0 },
  "detail":  { "sharpenAmount": 40, "sharpenRadius": 10, "sharpenDetail": 25, "sharpenMasking": 20, "noiseLuminance": 15, "noiseColor": 25 },
  "optics":  { "removeChromaticAberration": true, "distortion": 0, "purpleAmount": 0, "greenAmount": 0, "vignetteAmount": 0 },
  "geometry":{ "upright": "Off", "projection": "Perspective", "vertical": 0, "horizontal": 0, "rotate": 0, "aspect": 0, "scale": 0, "offsetX": 0, "offsetY": 0, "constrainCrop": false },
  "calibration": { "process": "Version 6", "shadowTint": 0, "redHue": 0, "redSaturation": 0, "greenHue": 0, "greenSaturation": 0, "blueHue": 0, "blueSaturation": 0 },
  "autoWhiteBalance": false, "hide": [] }
```

Camera Raw is destructive on the layer's pixels, like Filter > Camera Raw Filter; put the photo on its own layer to keep
an original.

### selection
`selection.get`, `selection.rect`, `selection.ellipse`, `selection.polygon`, `selection.wand`, `selection.object`,
`selection.subject`, `selection.colorRange`, `selection.fromLayer`, `selection.fromMask`, `selection.fromMaskImage`,
`selection.all`, `selection.none`, `selection.invert`, `selection.expand`, `selection.contract`, `selection.feather`,
`selection.setAntialiased`, `selection.move` (the outline), `selection.movePixels`, `selection.fill`,
`selection.clear`, `selection.copy`, `selection.copyMerged`, `selection.cut`, `selection.paste`,
`selection.layerViaCopy`, `selection.pixels` (base64 PNG of the selected pixels), `selection.transform` (floating
selection: move, scale, rotate, flip).

Every selection op takes `mode`: `replace` (default), `add`, `subtract` or `intersect`.

### paint
`paint.stroke` (points or strokes; mode paint/erase; mask; color, diameter, hardness, opacity, smoothing),
`paint.heal` (healingMode), `paint.clone` (source, aligned, sampleAllLayers), `paint.blur` (radius),
`paint.smudge`, `paint.liquify` (strength), `paint.gradient` (from, to, shape, style, reversed, opacity, mask),
`shape.add` (Rectangle, Ellipse, Line; rect or from/to; color, cornerRadius, lineWidth), `text.add`, `text.set`
(content, fontName, fontSize, color, alignment, tracking, leading, boxSize, colorRuns, fontRuns), `text.defaults`.

Strokes are lists of document points; there is no pressure, so vary `diameter` and `opacity` between strokes instead.

### canvas
`canvas.size` (width, height, relative, anchor, fill), `canvas.imageSize` (width, height, percent, resolution,
sampling), `canvas.trim` (basedOn, sides, tolerance), `canvas.crop` (rect or the selection), `canvas.flip`,
`canvas.setResolution`, `guides.list`, `guides.add`, `guides.set`, `guides.remove`, `view.set` (grid, guides,
rulers, snapping, pixel grid, transform controls, zoom).

### session
`history.undo`, `history.redo`, `history.get`, `history.markSaved`, `tool.select`, `tool.set` (brush, clone, wand,
objectSelection, gradient, shape, selection options), `color.set`, `color.sample`, `session.cancel`, `session.wait`
(timeout up to 3600 seconds),
`app.info`, `app.quit`.

## Clients

- `scripts/compositor_api.py`: a dependency-free Python client (`Compositor().run("layer.add", name="Grade")`,
  `.batch([...])`, `.render("out.png")`, `.ops()`), and a CLI: `python scripts/compositor_api.py ops`.
- `scripts/compositor-api.sh`: the same with curl.
- `scripts/automation-example.json`: a complete edit, from a photo to a graded, masked, titled export. Run it with
  `Compositor --automation-run scripts/automation-example.json --quit` or `POST` it to `/v1/run`.

A first session, with the app running with `--automation`:

```sh
curl -s localhost:4747/v1/health
curl -s localhost:4747/v1/run -d '{"op":"project.new","width":1200,"height":800,"background":"#FFFFFF"}'
curl -s localhost:4747/v1/run -d '{"op":"layer.addImage","path":"~/Pictures/cat.jpg","name":"Cat"}'
curl -s localhost:4747/v1/run -d '{"op":"filter.removeBackground","layer":"Cat","quality":"Advanced"}'
curl -s localhost:4747/v1/run -d '{"op":"adjustmentLayer.add","kind":"Levels","settings":{"black":10,"gamma":1.2}}'
curl -s localhost:4747/v1/render?format=jpeg -o cat.jpg
```

## Notes for implementers

- Ops live in `Compositor/Automation/AutomationCommands+*.swift`; each registers itself with a name, a group, a
  summary and its parameters, which is what `GET /v1/ops` reports. Add an op there and it is documented and routable.
- Commands run on the main actor through the session's own methods (the ones the menus and panels call), never by
  editing the document behind them, so gates, undo names and live previews stay consistent with the UI. Where the app
  has no direct method (intersect selections, mask blur, uniform gray masks, guide removal), the command edits the
  document inside `beginEdit`/`endEdit` so it is still one undo step.
- Session guards fail silently in the app; the API checks them first and turns `brushError`, `importError` and
  `cropError` into HTTP errors.
- Camera Raw and the other filters are not saved in the project; only their result is. Adjustment layers are saved.
