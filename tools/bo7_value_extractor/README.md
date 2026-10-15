# BO7 Movement Value Extractor

Turns exported BO7 asset files into `bo7_*` settings for this mod.

It reads the files that an asset exporter (Cordycep + Greyhound,
atian-cod-tools, ...) wrote. It does not open or decrypt the game's own
files. You run the exporter yourself.

## Steps

1. Export BO7's data assets with your exporter. The movement tuning should
   be in the `suit` asset, and also possibly in `gameprops`, `scriptbundle`,
   `keyvaluepairs`, `stringtable` and `weapontunables`. (These asset type
   names come from BO7's executable.)
2. Run `run.bat`, or run `python bo7_extract.py`, and pick the export folder.
3. Click **Scan**.
   - **All movement values** lists every number whose key looks like
     movement, grouped as sprint, tactical sprint, slide, dive, wall jump,
     mantle and so on.
   - **Suggested settings** matches those numbers to `bo7_*` settings and
     shows the mod's current value next to the BO7 value.
4. Double-click the suggestions you trust, then click **Write cfg**. Paste the
   `set` lines into `mp_mod.cfg`. The mod's `bo7_default()` only fills
   settings that are still empty, so these values take priority.

Command line:

    python bo7_extract.py scan "D:\exports\bo7" --out output [--accept-best] [--all]

## Accuracy notes

- BO7 and BO3 both measure in inches, so distances, speeds and gravity copy
  across directly.
- `mapping.json` holds best guesses at BO7's key names. Once you see the real
  key names in the values tab, update the `patterns` there.
- `bo7_speed` is a ratio against `bo3_sprint_speed` in `mapping.json`.
  Measure BO3's real sprint speed in your mod and set that first.
- Slide, dive and tactical sprint values are listed, but they don't map to a
  setting yet, because `omnimovement.dll` handles those moves.
