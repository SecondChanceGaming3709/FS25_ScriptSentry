SCRIPT SENTRY 0.5.4.0 — SPECIALIZATION CONFLICT MONITOR
==============================================================

Script Sentry is a passive diagnostic mod for Farming Simulator 25. It reviews
live Lua function chains, watches mod-registered vehicle and placeable
specialization routes, monitors loaded GUI screens for observable integrity
problems, and provides an optional safe 15-second FPS/stutter check.

It never repairs, disables, reorders, or edits another mod. Findings remain in
the current game session and the normal game log.

PLAYER REPORT
-------------

NO CONFIRMED CONFLICT
    Script Sentry did not find anything the player needs to act on.

CONFIRMED PROBLEM
    Script Sentry found a persistent, high-confidence GUI fault or a script
    overwrite which prevented earlier code from continuing.

The player dialog does not show speculative GUI risks, normal menu lifecycle
activity, compatible shared-script chains, callback names, or internal control
paths. Those technical observations remain available in log.txt for mod authors.

SCRIPT AND SPECIALIZATION MONITOR
---------------------------------

Version 0.5.4 closes the registry blind spot which prevented Script Sentry from
seeing many conflicts involving Follow Me and other vehicle features. FS25 keeps
these callbacks inside type-function and event-listener registries rather than
ordinary global tables.

During mod loading, Script Sentry now passively records:
- Mod specialization class functions when GIANTS loads the specialization
- Functions added through SpecializationUtil.registerFunction
- Chains built through SpecializationUtil.registerOverwrittenFunction
- Specialization event listeners, including onDraw, onUpdateTick, and
  onRegisterActionEvents

It then verifies that registered functions, specialization callbacks, and event
listeners remain connected. A later mod which directly replaces a Follow Me
function without continuing the prior code can now be named as the writer. A
proper super-function chain remains a technical shared-chain note and is not
falsely called a conflict.

For Follow Me specifically, the player report now explains when the affected
route is the vehicle-selection line rather than displaying callback names. A
direct replacement or an observed call to GIANTS' listener-removal helper can
name the later mod. If a mod edits the listener table directly and leaves no
attributable code behind, Script Sentry reports the confirmed removal but states
honestly that the responsible mod could not be identified.

The observers forward the exact original callback objects, arguments, and return
values. They are removed after startup and never become part of vehicle gameplay
callbacks. Low-frequency read-only checks continue during play so a later direct
replacement can still be detected.

GENERAL GUI INTEGRITY MONITOR
-----------------------------

Version 0.5.1 uses a confidence-first monitor. At startup it records every
discoverable loaded GUI screen, then continues checking screens created later.
It learns selectors which begin empty and ignores ordinary menu repopulation.
Version 0.5.3 also learns wholesale screen-layer replacements used by large GUI
overhauls instead of treating their intentionally retired controls as damage.

Confirmed player-facing checks include:
- Existing controls left detached but still referenced
- A mapped settings option being replaced by generic OFF/ON or NO/YES choices
- Option states outside the available choice range
- Callback names which no longer resolve to callable functions
- Broken parent/child relationships
- NaN or infinite GUI positions and sizes

Duplicate IDs, unresolved localization text, full-screen setup calls, and intact
shared-script chains are technical notes only. They are not presented to the
player as conflicts.

OWNERSHIP AND FALSE-POSITIVE CONTROLS
-------------------------------------

Script Sentry combines call-stack ownership, the currently loading mod, and
ownership recorded while shared functions are constructed. Reports name the
observed writer only when one of those reliable routes is available.

Controls loaded by a mod are marked as belonging to that mod. A cloned row can
therefore receive its own text and state without being mistaken for damage to
the source row. Mod-loaded controls are also protected from later unrelated
mods. Findings which may be temporary are required to persist through two
scans before they are shown.

Many FS25 screens legitimately populate empty lists, swap option contents,
rebuild controls, rebind controller fields, and reconstruct settings mappings.
Script Sentry ignores those lifecycle changes. A temporary fault must persist,
and most structural faults require a reliable mod owner, before being confirmed.

The monitor is structural, not artistic. It cannot reliably decide whether a
color is unattractive, spacing is tasteful, a technically valid custom-rendered
widget looks correct, or a working callback matches the author's intention.
Those limits are stated rather than guessed around.

THE REVIEW DIALOG
-----------------

- Opens automatically after the startup scan
- Remains visible until SPACE is pressed
- Shows one confirmed problem per page
- Uses four plain-language lines: Mod, Problem, Affects, and What to do
- Shows no internal control paths, callbacks, or raw before/after evidence
- Shows at most three confirmed problems; complete evidence remains in log.txt
- RIGHT ALT + 1 reopens the review and cycles through longer reports
- Uses FS25's existing modal MENU_ACTIVATE action for SPACE
- Adds no persistent gameplay badge or help-HUD line
- Waits for Know Your Limits to finish its startup notice before opening
- Continues monitoring after the startup dialog has closed
- Saves later GUI findings silently instead of opening when another menu closes

THE SAFE FPS CHECK
------------------

Press RIGHT ALT + 2 while a slowdown is happening. Continue driving, working,
or looking toward the problem for 15 seconds.

The result shows average FPS, the slowest frame, how many frames fell below
30 FPS, whether the test captured a slowdown or stutter, and what to test next.

This safe check does not rank or name individual mods. The earlier per-mod
profiler required timing wrappers inside other mods' live callbacks. Version
0.5.2 removes those wrappers completely so Script Sentry cannot appear between
a mod hook and the game during normal play.

READ-ONLY BOUNDARY
------------------

Script Sentry does not:
- Repair GUI data or change another mod
- Select winners, resolve conflicts, or alter load order
- Disable, park, mute, or remove mods
- Edit a savegame or inputBinding.xml
- Replace source(), gameplay functions, or input functions
- Collect telemetry or upload a player's findings
- Create a saved database or separate report file
- Parse generic log errors and warnings

Observed GUI methods and GIANTS helper calls are forwarded with the same
arguments and return values. The exact original mod hook is passed into each
GIANTS wrapper constructor. Startup observers are then restored. The lightweight
GUI integrity routes remain active so late-created screens can still be checked.

INSTALLATION AND CONTROLS
-------------------------

1. Keep the filename AAA_FS25_ScriptSentry.zip so it loads before ordinary
   script mods.
2. Put the ZIP in the Farming Simulator 2025 mods folder.
3. Enable it for the save and load normally.
4. Press SPACE to close the startup review.

RIGHT ALT + 1  Open/cycle the startup and GUI-integrity review
RIGHT ALT + 2  Run a safe 15-second FPS/stutter check

Both diagnostic actions can be remapped through FS25's normal controls menu.

VERSION 0.5.4.0
---------------

- Added passive monitoring for mod specialization classes, registered type
  functions, overwritten specialization chains, and event listeners.
- Fixed the major blind spot that prevented Script Sentry from seeing many
  Follow Me-style vehicle callback replacements.
- A destructive replacement now reports the later writer and the displaced mod
  when ownership can be verified.
- Intact super-function chains are still recorded only as compatible technical
  notes; sharing a callback does not by itself prove a conflict.
- Added low-frequency runtime rescans for tracked script and specialization
  functions without wrapping gameplay callbacks.
- Added regression simulations for a destructive Follow Me replacement and a
  correctly chained compatible extension.
- Added exact no-line regressions for a replaced drawNearbyVehicles function
  and a removed onDraw event listener.
- Added plain-language reporting for the missing Follow Me vehicle-selection
  line, including an honest unknown-mod result when no writer remains to inspect.

VERSION 0.5.3.1
---------------

- Fixed the review dialog automatically appearing after the player closed a
  normal game menu.
- GUI problems found during play still update the review and log, but the
  player chooses when to view them with RIGHT ALT + 1.
- The single automatic startup review is unchanged.

VERSION 0.5.3.0
---------------

- Fixed a false red Animal Screen report caused by an overhaul intentionally
  retiring its temporary legacy GUI layer during startup.
- Added a general lifecycle rule for wholesale screen-layer replacement; this
  is not a mod-name-specific exception.
- A replacement layout becomes the new structural baseline, including its
  intentional duplicate template IDs and retired internal field references.
- Isolated removed controls that remain referenced are still reported as red.
- OFF/ON or YES/NO replacement of semantic settings, including the original
  Measuring, Temperature, and Area Unit problem, remains detected.

VERSION 0.5.2.0
---------------

- Emergency compatibility hotfix: removed all performance wrappers from mod
  hooks, event listeners, and specialization callbacks.
- Script Sentry is no longer inserted into live gameplay call chains, even when
  the FPS check is idle.
- RIGHT ALT + 2 now performs a safe frame-rate and stutter check without naming
  an individual mod.
- The FPS result clearly states what was measured, what was not attributed, and
  the next player troubleshooting step.
- Added regression coverage proving hook and callback function identity remains
  unchanged.

VERSION 0.5.1.0
---------------

- Replaced the developer-style startup dump with a plain-language player report.
- Shows only confirmed problems, one per page, with the responsible mod, visible
  effect, affected menu, and recommended action.
- Hides speculative GUI risks and compatible shared-script chains from players;
  technical observations remain in log.txt.
- Fixed false corruption reports from empty selectors being populated and from
  dynamic option lists changing while menus open or switch categories.
- Removed routine setTexts tracing from the log to reduce noise.
- Limited the player report to three pages and added the patch version to its
  title so the active build is immediately visible.
- Reworded the FPS report around average FPS, likely cause, and what to test;
  callback coverage and profiling internals remain in log.txt.

VERSION 0.5.0.1
---------------

- Fixed widespread false positives caused by normal controller-field rebinding
  and settings-mapping reconstruction during GUI refreshes.
- Missing controls are now red only when a stale controller or mapping reference
  proves that the detached control is still in use.
- Duplicate IDs are compared only among sibling controls, matching GUI scope.
- Callback checks now respect baseline validity and dynamic control ownership.
- Limited the startup dialog to eight entries across four pages while retaining
  the complete evidence in log.txt.

VERSION 0.5.0.0
---------------

- Replaced the three-unit-control checker with a general GUI integrity monitor.
- Added baselines for every discoverable loaded GUI screen.
- Added structural, mapping, option, callback, localization, hierarchy, state,
  duplicate-ID, geometry, and whole-screen-reinitialization checks.
- Added ownership tracking for mod-loaded controls and later cross-mod changes.
- Added RED GUI CORRUPTION and AMBER GUI RISK result types with evidence.
- Added two-scan confirmation for findings which can occur temporarily.
- Improved mutation attribution through active mod callbacks and the currently
  loading mod.
- Retained the original unit corruption as a general semantic-option rule; no
  player-specific message or hardcoded personal report is displayed.

VERSION 0.4.1.0
---------------

- Added live checks for Measuring, Temperature, and Area unit controls.
- Added clone-aware text, field-binding, and option-mapping observation.
- Continued checking after startup to catch settings created on first open.

VERSION 0.4.0.1
---------------

- Coordinated the startup dialog with Know Your Limits.
- Assigned RIGHT ALT + 1 to review and RIGHT ALT + 2 to performance scanning.

VERSION 0.4.0.0
---------------

- Added the on-demand 15-second Lua performance scan.

LIMITS
------

Function identity does not prove semantic compatibility. An intact shared chain
can still misbehave, and a direct overwrite can occasionally be intentional.
Custom hand-written wrappers and direct table writes may not expose a reliable
owner. When ownership is unavailable, Script Sentry says the mod could not be
identified rather than guessing.

GUI coverage applies to discoverable FS25 GUI element trees and observable
public mutations. Private renderers, engine-only widgets, and purely visual or
behavioral design mistakes may be outside Lua-level inspection.

PC/Mac script mod. Singleplayer diagnostic preview.
