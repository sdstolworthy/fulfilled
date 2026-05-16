# Inter font assets

These four `.ttf` files are bundled with the app per architecture
§2.2 (no runtime CDN font loading) and per ticket **T-012**.

## Source

- **Project**: rsms/inter
- **Release**: v4.1
- **Release URL**: https://github.com/rsms/inter/releases/tag/v4.1
- **Asset**: `Inter-4.1.zip`
- **Direct URL**: https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
- **Path within the zip**: `extras/ttf/Inter-{Regular,Medium,SemiBold,Bold}.ttf`

The four static `.ttf` files are pulled verbatim from `extras/ttf/` in
the release archive — no re-hinting, no subsetting, no transcoding.

## Weights bundled

| File                    | Weight |
| ----------------------- | ------ |
| `Inter-Regular.ttf`     | 400    |
| `Inter-Medium.ttf`      | 500    |
| `Inter-SemiBold.ttf`    | 600    |
| `Inter-Bold.ttf`        | 700    |

These weight slots are referenced verbatim by the `fonts:` block in
`client/pubspec.yaml`; do not rename the files without updating that
block.

## Refreshing

To bump the bundled Inter version:

1. Download the new `Inter-<version>.zip` from
   https://github.com/rsms/inter/releases.
2. Extract the four `extras/ttf/Inter-{Regular,Medium,SemiBold,Bold}.ttf`
   files over the existing ones in this directory.
3. Update the **Release** + **Asset** lines above.
4. Run a visual smoke test of the app — pay attention to tabular
   figures (T-02) and the design-system type ramp.

## License attribution

Deliberately not surfaced in v1 per PM punt; the OFL discharge UI is
a v2 cleanup item. Do **not** add a LICENSES.md or attribution screen
under this ticket.
