# Plan: drive analyzer to zero infos/warnings, then tighten the gate

## Inventory (60 issues, ALL `info`-level — 0 warnings, 0 errors)

| Cluster | Rule | Count | Where |
|---|---|---|---|
| A | `use_build_context_synchronously` | 4 | example/lib/main.dart (249, 281, 297, 650) |
| B | `avoid_print` | 19 | windows pkg (18), example/lib/recorder.dart (1) |
| C | `constant_identifier_names` | 13 | lib/flutter_midi_command_messages.dart (11), platform_interface/lib/midi_port.dart (2) |
| D | `camel_case_types` | 17 | linux/lib/src/alsa_seq_bindings.dart (generated FFI) |
| E | `library_private_types_in_public_api` | 7 | linux bindings (2), web/lib/flutter_midi_command_web.dart (5) |

Decision per cluster: **fix** real issues, **suppress** generated/intentional ones.

---

## Phase 1 — Fix in code (genuine issues)

### A. `use_build_context_synchronously` (example/lib/main.dart) — FIX
- [ ] Read each of the 4 sites; add `if (!context.mounted) return;` (or `if (!mounted) return;` for State) immediately after the preceding `await`, before the context use.
- [ ] Two sites (281, 297) already have an *unrelated* mounted guard — guard the correct context.
- Risk: low (example app). Verify example still builds.

### B. `avoid_print` (windows pkg + example) — FIX
- Windows pkg already depends on flutter, so `debugPrint` (package:flutter/foundation.dart) is available.
- [ ] windows: flutter_midi_command_windows.dart (5) + windows_midi_device.dart (13): replace `print(...)` with `debugPrint(...)`; add `import 'package:flutter/foundation.dart';` where needed.
- [ ] example/lib/recorder.dart:79: replace `print("recording exported")` with `debugPrint(...)`.
- Note: these are debug/error logs; debugPrint is the minimal correct fix and is stripped in release. (Larger refactor — routing through a logHandler — is out of scope.)

---

## Phase 2 — Suppress generated FFI (correct, not fixable)

### D + E(linux). alsa_seq_bindings.dart — SUPPRESS
- [ ] Extend the existing top-of-file ignore line to:
      `// ignore_for_file: non_constant_identifier_names, constant_identifier_names, camel_case_types, library_private_types_in_public_api`
- Rationale: generated bindings must mirror the C `snd_seq_*` names; cannot rename.

---

## Phase 3 — Suppress intentional public-API names (breaking to change)

### C. constant_identifier_names — SUPPRESS (do NOT rename)
- Renaming `CC/PC/NoteOn/.../PitchBend` and `IN/OUT` is a **breaking API change** at 1.0.x; they follow MIDI / port-direction domain conventions.
- [ ] Add `// ignore_for_file: constant_identifier_names` to lib/flutter_midi_command_messages.dart
- [ ] Add `// ignore_for_file: constant_identifier_names` to packages/flutter_midi_command_platform_interface/lib/midi_port.dart

---

## Phase 4 — Web private-types (DECISION NEEDED)

### E(web). flutter_midi_command_web.dart:576-581 — `buildWebMidiDevices` exposes private `_Web*Snapshot` types
Two options:
- **(a) Make the snapshot classes public** (`_WebDeviceSnapshot` → `WebDeviceSnapshot`, etc.) — cleaner if `buildWebMidiDevices` is an intended `@visibleForTesting` surface. More edits, no behavior change.
- **(b) `// ignore_for_file: library_private_types_in_public_api`** — fastest, if the helper is test-only.
- [ ] CONFIRM: (a) or (b). Default recommendation: (b) if test-only, else (a).

---

## Phase 5 — Tighten the gate (after count == 0)

- [ ] In melos.yaml `scripts.analyze`: drop `--no-fatal-infos --no-fatal-warnings` (or at minimum `--no-fatal-warnings`) so the gate fails at zero.
- [ ] Decide example policy: keep `analyze:example` lenient OR also strict (its 5 issues are fixed in Phase 1, so it can go strict too).
- [ ] Ensure CI uses `melos run analyze` (+ `analyze:example`), not the built-in `melos analyze`, for one consistent policy.

---

## Phase 6 — Verify
- [ ] `melos run analyze` → 0 issues
- [ ] `melos run analyze:example` → 0 issues
- [ ] `melos run test` → all pass
- [ ] Commit in logical chunks (fixes vs suppressions vs gate change).

## Review

Done 2026-06-30. All 60 infos resolved; 0 warnings/errors.
- Fixed: 4 `use_build_context_synchronously` (example main.dart, switched the
  `context`-param guards to `context.mounted`); 19 `avoid_print` → `debugPrint`
  (added `package:flutter/foundation.dart` to both windows files, dropped the
  now-redundant `dart:typed_data` in windows_midi_device.dart).
- Suppressed: linux generated FFI (`camel_case_types`,
  `library_private_types_in_public_api`); public-API constant names
  (`constant_identifier_names` in messages.dart + midi_port.dart); web
  test-visible helper (`library_private_types_in_public_api`).
- Gate: melos `analyze`/`analyze:example` scripts now run plain `flutter
  analyze` (fatal on infos + warnings). Phase 4 web = ignore (per decision).
- Verified: `melos run analyze`, `analyze:example` (No issues found!), and
  `melos run test` all SUCCESS.
