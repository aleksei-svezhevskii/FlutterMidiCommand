# Migrate flutter_midi_command to Melos 8.2.2 (pub workspaces)

## Context
- Current: melos `^6.3.2` (dev_dep), 6.3.3 resolved locally, global 8.0.0, CI pins 6.3.3.
- Target: **melos 8.2.2** (latest). SDK bumps: **minimal** (only `example/`).
- Toolchain present: Dart 3.12.2 / Flutter 3.44.4 — pub workspaces fully supported.
- Headline change (Melos 7+): local package linking is delegated to **native Dart
  pub workspaces** instead of generated `pubspec_overrides.yaml`. `melos.yaml` is
  gone; config moves into the root `pubspec.yaml` under a `melos:` key.
- Side benefit: dissolves the "keep internal constraints loose" /
  "native edits don't reach the build" pain in project memory — workspace members
  always resolve to their in-repo path locally.

## Facts driving the plan
- Root pubspec (`flutter_midi_command`) **is itself a package** → `useRootAsPackage: true`.
- `workspace:` needs **explicit paths** (no globs). Members:
  packages/flutter_midi_command_{android,ble,darwin,linux,platform_interface,web,windows}
  + `example`.
- Workspace members need SDK lower bound ≥ 3.6.0. Only `example/` is too low
  (>=3.1.0) → bump to **3.6.0**. All others already ≥3.7.0 (untouched).
- Scripts in melos.yaml are plain `run:` strings shelling out to
  `dart run melos exec ... -- "..."` — NOT the structured `exec:` YAML form, so
  the 8.0 exec-format breaking change does **not** touch them; they port as-is.
- Built-in `melos analyze` was removed in 7.x, but this repo uses a **custom**
  `analyze` script → unaffected.

## ⚠️ #1 correctness item (breaks CI if missed)
The 7 member `pubspec_overrides.yaml` files are **committed to git**. In pub
workspaces, `dependency_overrides` are only legal in the **workspace root**. A
member package that still ships a `pubspec_overrides.yaml` makes `pub get` (and
therefore `melos bootstrap`) **error out on a fresh CI checkout**. They must be
`git rm`'d, not just locally deleted.

## Steps

### 1. Remove the old override machinery
- [ ] `dart run melos clean` (drops melos-managed overrides).
- [ ] `git rm` every `pubspec_overrides.yaml`: root, example, and all 7 packages.
      Audit confirms all entries are local-path links → all removable (nothing
      hand-authored worth keeping; workspace membership replaces them).
- [ ] Add `pubspec_overrides.yaml` to `.gitignore`.

### 2. Root pubspec.yaml → workspace root + melos config
- [ ] Add `workspace:` listing the 8 member paths above.
- [ ] Bump `melos: ^6.3.2` → `^8.2.2` in dev_dependencies.
- [ ] Add a `melos:` section porting melos.yaml:
      - `name: flutter_midi_command_workspace`
      - `useRootAsPackage: true`
      - `command: { version: { workspaceChangelog: false } }` (keep — root shares
        CHANGELOG.md with the workspace).
      - all `scripts:` (bootstrap/analyze/test/build/format) verbatim.
- [ ] Delete `melos.yaml`.

### 3. Mark every member package
- [ ] Add `resolution: workspace` to each of the 7 package pubspec.yaml files.
- [ ] Add `resolution: workspace` to `example/pubspec.yaml` and bump its SDK
      lower bound `>=3.1.0` → `>=3.6.0`.

### 4. CI (.github/workflows/ci.yml) — make it pass
- [ ] `MELOS_VERSION: '6.3.3'` → `'8.2.2'` (used by all 10 jobs).
- [ ] Keep the `dart pub global activate melos` + `melos bootstrap` pattern —
      still valid; bootstrap now performs a single workspace `pub get`.
- [ ] No script renames needed: `melos run analyze/analyze:example/test/...`,
      the `--scope`/`--ignore` exec flags, and `melos run format` all survive.
- [ ] `pigeon_contracts` job: `dart run pigeon` runs from repo root, where pigeon
      is a root dev_dependency → resolves via the shared workspace `.dart_tool`.
      Re-verify the generated-file `git diff --exit-code` still passes.
- [ ] Fresh checkout must be override-free — depends entirely on step 1's
      `git rm` (see #1 item). This is the make-or-break for CI.
- [ ] `FLUTTER_VERSION: '3.44.2'` (Dart 3.12) already supports workspaces — leave.

### 5. Verify locally (mirror CI order)
- [ ] `dart run melos bootstrap` — expect one root `pub get`, **no**
      pubspec_overrides regenerated, all members path-linked.
- [ ] `dart run melos list` — confirm all 8 members detected.
- [ ] `dart run pigeon --input pigeons/midi_api.dart` then the CI format+diff
      commands — confirm no contract drift.
- [ ] `dart run melos run analyze`, `analyze:example`, `test`, `test:web:chrome`.
- [ ] `git status` — every `pubspec_overrides.yaml` gone from tracking + ignored.
- [ ] Confirm example resolves in-repo package sources (the old overrides' job) —
      now guaranteed by workspace membership.

### 6. Follow-ups / risks
- [ ] Update IntelliJ `.iml` / IDEA melos files referencing melos.yaml (cosmetic).
- [ ] Re-check federated **release** flow: workspaces fix local bootstrap, but
      pub.dev publish ordering + loose `^` constraints still matter. Revisit
      `federated-release-constraints` memory after migration.
- [ ] After verification, update project memory
      (`flutter-midi-command-build-setup`, `federated-release-constraints`) — the
      override-based dev workflow they describe is superseded by workspaces.

## Review — executed & verified 2026-07-30

Done exactly as planned. Summary of the diff:
- **Removed** (git rm): all 8 `pubspec_overrides.yaml` + `melos.yaml`.
- **`.gitignore`**: replaced the "intentionally tracked overrides" note with a
  plain `pubspec_overrides.yaml` ignore.
- **Root `pubspec.yaml`**: added `workspace:` (8 explicit members), bumped
  `melos: ^6.3.2 → ^8.2.2`, added `melos:` block (`name`, `useRootAsPackage:
  true`, `command.version.workspaceChangelog: false`, all scripts verbatim).
- **7 package pubspecs**: added `resolution: workspace`.
- **`example/pubspec.yaml`**: added `resolution: workspace`, SDK `>=3.1.0 →
  >=3.6.0`.
- **CI**: `MELOS_VERSION: 6.3.3 → 8.2.2` (no other CI edits needed).

Verification (mirrors CI jobs):
- `flutter pub get` → single root resolve, **no** overrides regenerated, only
  root `pubspec.lock`. ✅
- `dart run melos list` → all 9 (8 members + root). ✅
- `dart run melos run analyze` / `analyze:example` / `test` → all SUCCESS. ✅
- pigeon regen + format + `git diff --exit-code` on contract paths → no drift. ✅

Not run locally (need browser/emulators/native runners — unchanged script
mechanism, exercised in CI): `test:web:chrome`, `test:native:*`, example
integration/build jobs.

Notes:
- Each `flutter analyze`/`flutter test` triggers a quick workspace re-resolve —
  cosmetic noise, expected under workspaces.
- Pre-existing untracked cruft dir
  `packages/flutter_midi_command_linux/flutter_midi_command_platform_interface/`
  (gitignored build/.dart_tool/.iml) — unrelated, left as-is.
- Not committed — left staged/working for review.

Follow-ups still open: `.iml`/IDEA files (cosmetic); revisit federated release
flow + update project memory (override-based dev workflow now superseded).
