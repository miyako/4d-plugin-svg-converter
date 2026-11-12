# Ownership regressions

`engine_harness.mm` links the real `4DPlugin.cpp`, every plugin class and the unchanged bundled `4D Plugin API` with ASan/UBSan. It replaces the 4D engine (`Call4D`) with a synthetic one that counts live engine strings, handles and reference-counted pictures, and aborts on anything it does not model. `render_stubs.c` replaces librsvg/cairo/glib, whose static libraries are built from source by `scripts/build-macos-deps.sh` and are not committed; it uses the bundled headers and counts every handle, surface and context.

`SVG Convert` and `SVG Convert array` run through `PluginMain` on synthetic in-memory SVG pictures. Nothing is read from disk or the network.

```sh
tests/ownership/run.sh . fixed                # every test must pass

B=$(mktemp -d); git archive <base-sha> | tar -x -C "$B"
tests/ownership/run.sh "$B" baseline          # named defects must fail, controls pass
```

| Test | Checks |
|---|---|
| `defect_picture_fromfile_ownership` | `C_PICTURE::fromFileAtPath` frees the path once and releases the loaded picture |
| `defect_picture_setbytes_leak` | `C_PICTURE::setBytes` releases the picture it creates |
| `defect_picture_createcopy_ownership` | `createCopy*` reads only the converted type and leaves no empty owners |
| `defect_picture_grayscale_owner_leak`, `defect_picture_getsize_owner_leak`, `defect_picture_thumbnail_owner_leak` | no empty picture owner leaks |
| `control_convert_*` | `SVG Convert` (PNG/PDF/PS/SVG, error paths, output BLOB replacement) and `SVG Convert array` (PDF/PS, invalid format, undefined variable) |
| `control_array_text_transfer`, `control_picture_param_return` | `ARRAY_TEXT` transfer, picture parameter/return |

The `C_PICTURE` methods fixed here are compiled into the plugin, but neither command calls them (`SVG Convert` only uses `fromParamAtIndex`, `getBytesPtr` and `getBytesLength`).

Not covered:
- Windows and a real 4D runtime; the real librsvg/cairo rendering.
- Ownership of the type string returned by `PA_GetPictureData`, which the SDK does not document. The harness treats it as borrowed, as the plugin does.
- How the real engine treats the old value of a picture output parameter. The harness assumes the most forgiving model: the engine releases it.
