# FS25 Script Sentry

Script Sentry is a read-only conflict, GUI-integrity, and frame-rate diagnostic mod for Farming Simulator 25.

## Current version

**0.5.3.0**

## What it does

- Detects confirmed Lua overwrites that prevent an earlier mod's code from continuing.
- Monitors loaded GUI screens for persistent, high-confidence structural and data faults.
- Detects semantic settings choices being incorrectly replaced by generic **OFF/ON** or **YES/NO** values.
- Learns normal dynamic menu population and complete GUI-layer replacements to reduce false positives.
- Provides a safe 15-second FPS and stutter check without wrapping gameplay callbacks.
- Keeps technical evidence in `log.txt` while presenting plain-language results to players.

## Player report

Confirmed findings are explained with four lines:

- **Mod** — the responsible mod, when ownership can be identified reliably.
- **Problem** — what appears to have been broken.
- **Affects** — the visible menu or control.
- **What to do** — the recommended player action.

Speculative GUI risks, normal menu lifecycle changes, and compatible shared-script chains remain technical log notes and are not presented as confirmed conflicts.

## Controls

- **Right Alt + 1** — open or cycle the Script Sentry review.
- **Right Alt + 2** — run the safe 15-second FPS/stutter check.
- **Space** — close the active report page.

Both diagnostic actions can be remapped through FS25's normal control settings.

## Read-only boundary

Script Sentry does not repair, disable, reorder, or edit another mod. It does not change a savegame, edit `inputBinding.xml`, select a conflict winner, collect telemetry, or parse generic log errors and warnings.

The FPS check reports overall performance and stuttering. It intentionally does not name an individual mod.

## Repository structure

The files at the repository root are arranged as an FS25 mod:

```text
modDesc.xml
icon.dds
src/
translations/
README.txt
PROVENANCE.txt
ScriptSentry_thumbnail.png
```

To build the game-ready archive, ZIP these files and folders directly so that `modDesc.xml` is at the root of `AAA_FS25_ScriptSentry.zip`.

The `AAA_` prefix is intentional so Script Sentry can observe later-loading script mods.

## Documentation

- [README.txt](README.txt) contains installation instructions, behavior details, and the complete version history.
- [PROVENANCE.txt](PROVENANCE.txt) documents the diagnostic claims and validation boundaries.
