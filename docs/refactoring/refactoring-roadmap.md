# Refactoring roadmap

## Goal

Reduce the maintenance risk identified in `clean-code-audit.md` without changing the public macro surface, generated JSON behavior, error contracts, or supported runtime protocol. Each task below is intended to be reviewable on its own. A task may add private files and types, but it must not introduce a public abstraction only to reduce line count.

## Constraints

- Preserve `@JsonCodec`, `@Json`, `@JsonValue`, `@JsonUsing`, and `@JsonSubtype` behavior.
- Preserve the generated-support v1 contract until a separate compatibility change explicitly versions it.
- Keep the macro package independent from a compile-time import of the `yjson` runtime package.
- Compare public behavior through compiled consumers. Do not rely only on generated-source snapshots.
- Keep performance-sensitive direct, fast, cursor, and compact paths measurable.
- Do not combine a file move with semantic cleanup unless the task explicitly requires both.

## Implementation status

Status as of 2026-09-17. This table records delivered behavior and deliberately
does not mark a roadmap item complete when only its first safe slice has landed.

| Task | Status | Evidence and remaining work |
| --- | --- | --- |
| R01 | Core complete | Added a pinned-runtime consumer harness covering object, struct, generic, custom-codec, enum, polymorphic, inherited-field, alias/default/error, byte-input, and literal behavior. The runtime revision is recorded in the runner. Performance baselines and negative compile fixtures remain completion-gate work. |
| R02 | Complete | Moved field/constructor/subtype/object models and AST analysis into `codec_model.cj` and `codec_analysis.cj`. Emission still consumes original type spelling. |
| R03 | In progress | Added `FieldTypeShape` and `FieldCapabilities`; primitive classification, scalar scratch selection, and generated-concrete selection use them. Container capabilities, reserve hints, and all compact-write decisions still use the existing tables. |
| R04 | Not started | Expansion diagnostics and emitted runtime errors remain in their current emitters. |
| R05 | Complete | Centralized scratch declarations, canonical-field planning, required-field checks, constructor argument/default selection, and post-constructor assignment in `codec_decode_plan.cj`; semantic, direct-fast, and cursor-fast readers share them. |
| R06 | In progress | Object read-method generation now has a dedicated emitter function and the fast backends share assignment emission. Backend dispatch loops remain separate and intentionally retain their reader- and policy-specific operations. |
| R07 | Not started | Compact-write string rewriting is unchanged. |
| R08 | Not started | Generated-support v1 vocabulary remains distributed. |
| R09 | In progress | Object provider and public-overload generation moved to `codec_provider_emitter.cj`; integration with a future runtime-protocol emitter remains pending on R08. |
| R10-R14 | Not started | These stay behind their declared dependencies; no mechanical file split was used to claim progress. |

During R03 characterization, the generic fixture exposed a pre-existing
generation bug: a field whose type is a generic parameter was treated as a
concrete generated-codec type. Generic parameter names are now excluded from
that optimization, and the regression is covered by the consumer harness.

## Current verification snapshot

| Check | Audit baseline | Current result |
| --- | ---: | ---: |
| `src/json_codec.cj` physical lines | 2,535 | 1,871 |
| `renderCodec` span | about 692 lines | 337 lines |
| Production source physical lines | 2,998 | 3,202 |
| Duplicated effective lines (10-line windows) | 296 / 2,801 | 0 / 2,989 |
| Duplicate rate | 10.57% | 0.00% |

The total production-source size increased because the refactor introduced
named models, policies, and plans instead of hiding the same decisions in one
function. The consumer harness is tracked separately. The acceptance signal is
the smaller coordinator, explicit responsibility boundaries, removed clone
windows, and passing behavior tests;
LOC reduction by itself is not a goal.

## Dependency map

| Task | Depends on | Enables |
| --- | --- | --- |
| R01 | None | Every source refactor |
| R02 | R01 | R03, R04, R05, R08, R09 |
| R03 | R02 | R06, R07, R10 |
| R04 | R02 | R06, R08, R09 |
| R05 | R02 | R06, R10 |
| R06 | R03, R04, R05 | R10 |
| R07 | R01, R03 | R10 |
| R08 | R01, R02, R04 | R10, R11, R12 |
| R09 | R01, R02, R04 | R10, R12 |
| R10 | R06, R07, R08, R09 | R13 |
| R11 | R08 | R13 |
| R12 | R08, R09 | R13 |
| R13 | R10, R11, R12 | Completion gate |
| R14 | R01 | Independent literal cleanup |

Tasks R08, R09, and R14 can run in parallel after their dependencies are complete. R11 and R12 can run in parallel after R08.

## Phase 0: establish behavioral evidence

### R01: add a consumer-level characterization harness

- **Change:** Add a test consumer that imports both `yjson` and `yjson_macros`. Cover object, struct, enum, polymorphic, generic, inherited, custom-codec, and literal macros. Record the exact runtime package revision used by the harness.
- **Files:** A dedicated test package or workspace under `tests/`, plus fixtures. Do not place runtime stubs inside the macro implementation.
- **Review unit:** Tests and harness only.
- **Dependencies:** None.
- **Validation:** Compile all positive fixtures. Compile negative fixtures and assert diagnostic fragments. Run semantic, fast, cursor, direct, and compact behavior tests. Capture focused encode and decode performance baselines without turning them into unstable unit-test thresholds.
- **Risk:** Low. The main risk is a harness that exercises only one generated path.

## Phase 1: create an immutable analysis model

### R02: extract AST analysis from source emission

- **Change:** Introduce private `CodecModel`, `ObjectCodecModel`, `CodecFieldDeclaration`, `JsonFieldPolicy`, and constructor metadata. Move `collectFields`, `constructorParams`, generic discovery, and annotation decoding into `codec_analysis.cj`. Keep emitted text byte-for-byte equivalent where practical.
- **Files:** Add `src/codec_model.cj` and `src/codec_analysis.cj`; reduce the analysis section of `src/json_codec.cj`.
- **Review unit:** Model and analyzer only. Existing renderers consume the new model without structural redesign.
- **Dependencies:** R01.
- **Validation:** Model-focused tests for every declaration shape. Compile all characterization fixtures. Compare generated declarations or tokens for representative fixtures, then run behavior tests.
- **Risk:** Medium. Inherited constructor-only fields and wrapper annotations are the fragile cases.

### R03: classify field types once

- **Change:** Add `FieldTypeShape` and `FieldCapabilities`. Replace repeated type-string normalization for codec selection and one read or write path at a time. Keep original type tokens for emitted spelling.
- **Files:** Add `src/codec_type_shape.cj` and `src/codec_capabilities.cj`.
- **Review unit:** First add classification with parity tests. Then migrate codec selection, reads, writes, and reserve hints in separate commits if needed.
- **Dependencies:** R02.
- **Validation:** Table tests for all recognized primitive and container shapes. Compile every capability that the table advertises. Run the full characterization harness after each migrated path.
- **Risk:** High. A wrong capability can compile one backend and fail another.

### R04: separate expansion diagnostics from runtime error emission

- **Change:** Move model validation and macro-expansion messages into `codec_diagnostics.cj`. Introduce internal runtime error emitters for duplicate, unknown, missing, enum, polymorphic, and compact-path failures. Preserve current message text, error code, and path.
- **Files:** Add `src/codec_diagnostics.cj` and `src/codec_runtime_errors.cj`.
- **Review unit:** Diagnostic extraction first, then runtime error templates.
- **Dependencies:** R02.
- **Validation:** Negative compile fixtures and cross-backend runtime assertions for error code and path.
- **Risk:** Medium to high because callers may assert diagnostics and runtime errors.

## Phase 2: consolidate object decode planning

### R05: extract result-construction planning

- **Change:** Build an `ObjectConstructionPlan` that owns constructor arguments, defaults, required fields, scalar scratch use, and post-constructor assignments. Replace the three copied result-construction blocks without changing field dispatch.
- **Files:** Add `src/codec_decode_plan.cj`; update existing object read emitters.
- **Review unit:** Only scratch declarations, required checks, and result construction. Do not change name dispatch in this task.
- **Dependencies:** R02.
- **Validation:** Constructor and default-value matrix across semantic, fast, and cursor readers. Include immutable fields, mutable fields, option fields, and absent defaulted scalars.
- **Risk:** High. This task changes a shared part of all decode paths.

### R06: introduce backend-specific object read emitters

- **Change:** Define one internal `ReadBackend` variant that supplies name reads, value reads, skips, and context operations. Emit the shared object state machine from `ObjectDecodePlan`. Migrate semantic, direct-fast, and cursor-fast paths one at a time.
- **Files:** Add `src/codec_read_emitter.cj`; remove `appendFastFieldAssignment`, `appendDirectFastFieldAssignment`, and copied dispatch loops after all migrations pass.
- **Review unit:** One backend migration per commit. Keep mutable-object specialization as a final subtask.
- **Dependencies:** R03, R04, R05.
- **Validation:** Reordered fields, aliases, duplicates, unknown fields, missing fields, nested values, custom codecs, path cleanup, and backend parity. Re-run duplicate detection and confirm that any remaining copies represent real backend differences.
- **Risk:** High. Reader policies differ and must not be flattened accidentally.

## Phase 3: replace compact-write text rewriting

### R07: render compact writes from structured operations

- **Change:** Introduce `FieldWritePlan` and a closed `CompactWriteOp` representation. Migrate scalar operations first, then containers, then nested generated codecs. Render cursor and direct-writer code separately. Remove receiver and method-name replacement chains only after each operation family moves.
- **Files:** Add `src/codec_write_plan.cj` and `src/codec_write_emitter.cj`.
- **Review unit:** One operation family per commit. Do not combine this task with object-emitter file moves.
- **Dependencies:** R01, R03.
- **Validation:** Exact JSON output and round trips for every specialized type; omission and null policy; depth and path cleanup; compile coverage for every emitted runtime method; focused performance comparisons with the R01 baseline.
- **Risk:** High. Compact writing is both behavior-sensitive and performance-sensitive.

## Phase 4: centralize the generated runtime contract

### R08: add a versioned runtime-protocol emitter

- **Change:** Add `GeneratedRuntimeV1Emitter` for protocol names, entry guards, reader and writer acquisition, finish or release sequences, and capability-interface names. Keep the dependency as emitted source rather than importing `yjson`.
- **Files:** Add `src/generated_runtime_v1_emitter.cj`.
- **Review unit:** Protocol vocabulary and lifecycle generation only.
- **Dependencies:** R01, R02, R04.
- **Validation:** Minimal consumer compilation against the matching runtime, an emitted-symbol inventory test, and cleanup tests for all acquired readers and writers.
- **Risk:** High because this is a cross-module compatibility seam.

### R09: extract provider and public-overload emission

- **Change:** Move generated provider conformances, codec globals, generic factories, inherited complete codecs, and `YJson` overloads into `codec_provider_emitter.cj`. Parameterize it with the model and `GeneratedRuntimeV1Emitter`.
- **Files:** Add `src/codec_provider_emitter.cj`.
- **Review unit:** Registration and public generated declarations only.
- **Dependencies:** R01, R02, R04.
- **Validation:** Compile fixtures for public and private types, generic types, inherited classes, open and abstract classes, compact providers, and explicit codec overload resolution.
- **Risk:** High. Incorrect emission can change source compatibility even when JSON behavior is unchanged.

## Phase 5: make object, enum, and polymorphic modules deep

### R10: reduce `renderCodec` to an object-emitter coordinator

- **Change:** After R06, R07, R08, and R09, move object emission into `codec_object_emitter.cj`. Keep `emitObjectCodec(model)` as its external interface. Delete obsolete string and parameter plumbing from `json_codec.cj`.
- **Files:** Add `src/codec_object_emitter.cj`; reduce `src/json_codec.cj` to public macro routing and model selection.
- **Review unit:** Mostly moves and wiring. No new capability or optimization in this task.
- **Dependencies:** R06, R07, R08, R09.
- **Validation:** Full R01 suite, emitted declaration inventory, duplicate scan, and performance comparison.
- **Risk:** Medium after the preceding seams exist; high if attempted early.

### R11: extract enum analysis and emission

- **Change:** Add `EnumCodecModel` and `emitEnumCodec`. Reuse runtime lifecycle and provider emission, but keep the enum array wire format local to the enum module.
- **Files:** Add `src/codec_enum_model.cj` and `src/codec_enum_emitter.cj`.
- **Review unit:** Enum path only.
- **Dependencies:** R08.
- **Validation:** Renamed cases, empty cases, payload cases, generic payloads, semantic and cursor paths, invalid case names, missing payloads, and extra payloads.
- **Risk:** Medium to high.

### R12: extract polymorphic analysis and emission

- **Change:** Add `PolymorphicCodecModel` and `emitPolymorphicCodec`. Keep replay and subtype dispatch local. Reuse diagnostics, runtime lifecycle, and provider emission.
- **Files:** Add `src/codec_polymorphic_model.cj` and `src/codec_polymorphic_emitter.cj`.
- **Review unit:** Polymorphic path only.
- **Dependencies:** R08, R09.
- **Validation:** Discriminator defaults and overrides, duplicate and conflicting discriminators, unknown runtime subtypes, missing and unknown input tags, inherited fields, buffered-value limits, and replay cleanup.
- **Risk:** Medium to high.

### R13: leave `json_codec.cj` as the public routing module

- **Change:** Keep only public macros, wrapper unwrapping, declaration-kind routing, and calls to analyzer and emitter modules. Remove dead helpers after call-site verification.
- **Files:** `src/json_codec.cj` and the extracted codec modules.
- **Review unit:** Deletion and routing only.
- **Dependencies:** R10, R11, R12.
- **Validation:** Full suite, public declaration inventory, no unused private helpers, duplicate scan, and a clean consumer build.
- **Risk:** Low to medium if earlier tasks are complete.

## Independent literal cleanup

### R14: encode literal-node invariants in types

- **Change:** Replace `JsonLiteralNode`'s kind-plus-unused-fields representation with payload-bearing variants. Keep `JsonLiteralDocument` as the parser-to-emitter interface. Split parser and emitter files only after the model change makes the seam explicit.
- **Files:** Add `src/json_literal_model.cj`, `src/json_literal_parser.cj`, and `src/json_literal_emitter.cj`; retain public macro routing in `src/json_literal.cj`.
- **Review unit:** Model conversion first, then file moves.
- **Dependencies:** R01.
- **Validation:** Literal grammar and behavior suite, including escapes, number boundaries, nesting, duplicate keys, dynamic keys, interpolation evaluation order, trailing commas, and negative syntax cases.
- **Risk:** Low to medium.

## Completion gate

The roadmap is complete only when all of these conditions hold:

- Every current public macro compiles in the consumer harness.
- Semantic, fast, cursor, direct, and compact paths have behavior parity where the current implementation promises parity.
- Error codes and JSON paths remain stable or change through an explicit compatibility decision.
- The generated-support v1 symbol inventory is unchanged or intentionally versioned.
- The duplicate scan is reviewed semantically. A lower percentage alone is not acceptance evidence.
- Performance-sensitive paths match the agreed baseline within a documented tolerance.
- `json_codec.cj` is a routing module rather than a second implementation layer over the extracted emitters.
