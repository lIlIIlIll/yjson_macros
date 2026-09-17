# Clean Code and maintainability audit

## Audit snapshot

- Repository: `yjson_macros`
- Audited commit: `b9a48e2fea6bf25f557e16a3c6e2529845285e00`
- Audit date: 2026-09-17
- Scope: all production Cangjie source under `src/`
- Excluded as findings input: Git diff, commit history, earlier reviews, and generated build output
- Change policy for this audit: documentation only; no production source was changed

## 结论

The package has two production files and a small public macro surface, but the codec generator has grown into one large implementation module. The main maintainability risk is not the repository's total size. It is that `src/json_codec.cj` represents AST analysis, schema validation, runtime-protocol knowledge, optimization selection, source generation, and public provider generation in the same file and often in the same function.

This audit found no P0 issue. It found four P1 issues, four P2 issues, and one P3 issue. The first refactoring work should establish behavioral tests, then introduce a stable codec model and consolidate the three object-decoding pipelines. Splitting files before those seams exist would move complexity without reducing it.

## Scope and method

The audit read every production source file from the audited commit:

| File | Physical lines | Current role | Assessment |
| --- | ---: | --- | --- |
| `src/json_codec.cj` | 2,535 | `@JsonCodec`, `@JsonUsing`, and `@JsonSubtype`; AST inspection; codec planning; object, enum, and polymorphic codec source generation | Oversized implementation module with one God function and several duplicated generation paths |
| `src/json_literal.cj` | 463 | JSON-like literal model, parser, validation, binding capture, and source renderer for `@Json` and `@JsonValue` | Cohesive at the class level; one low-priority model-expression issue |

The repository contains no Cangjie test files. The audit therefore treats all proposed refactors as unprotected until a consumer-level test harness exists.

The structural scan used these checks:

- source and symbol inventory with `rg`;
- physical line and function-span inspection;
- direct reading of both production files;
- text-level duplicate detection with a 10-effective-line threshold;
- call-site and generated-protocol vocabulary counts.

The duplicate scan covered two files and 2,801 effective lines. It reported 296 duplicated effective lines, a 10.57% duplicate rate, 73 overlapping clone windows, and 188 clone instances. These figures are text-window evidence, not proof that every match has the same semantics.

## Priority definitions

- **P0**: blocks safe maintenance now or creates an immediate correctness or security risk.
- **P1**: creates a high probability of semantic drift across normal feature work.
- **P2**: materially slows changes or raises review cost, but has a bounded workaround.
- **P3**: local design debt that can wait until a nearby change supplies the right seam.

## 发现

### CCA-001: `renderCodec` is a God function inside an oversized generator module

- **Priority:** P1
- **File:** `src/json_codec.cj:1487`
- **Function or type:** `renderCodec`
- **Current responsibility:** The function discovers inherited fields, builds field-label tables, selects generated interfaces, declares cached codecs, emits semantic and direct writers, emits compact writers, emits semantic and fast readers, chooses mutable-object optimizations, and emits public providers and `YJson` overloads.
- **Why it is hard to maintain:** `renderCodec` spans lines 1487-2178 and contains 258 `appendLine` call sites. A change to one concern requires navigating conditions for unrelated readers, writers, inheritance, generics, providers, and performance paths. The function also switches repeatedly between compile-time decisions and the runtime source that those decisions emit. Reviewers must simulate both levels at once.
- **Suggested responsibility seam:** Keep one small `emitObjectCodec(model: ObjectCodecModel): Tokens` coordinator. Move model construction out of emission. Give read emission, write emission, and provider emission internal interfaces that accept the immutable model and append to one source writer.
- **Suggested file and type structure:**
  - `src/codec_model.cj`: `CodecModel`, `ObjectCodecModel`, `CodecFieldModel`, and constructor metadata.
  - `src/codec_analysis.cj`: AST-to-model analysis and validation.
  - `src/codec_object_emitter.cj`: the small coordinator.
  - `src/codec_read_emitter.cj`: semantic, fast, cursor, and mutable-object read emission.
  - `src/codec_write_emitter.cj`: semantic, direct, and compact write emission.
  - `src/codec_provider_emitter.cj`: generated providers and public overloads.
- **Modification risk:** High. Generated interfaces and hot paths are externally observable through compilation, JSON behavior, error paths, and performance.
- **Required tests:** Compile fixtures for class, struct, generic, inherited, open, and abstract declarations; round-trip tests through semantic, fast, cursor, direct, and compact paths; generated-provider availability tests; output and error-path parity; focused performance baselines for generated object encode and decode.

### CCA-002: object-decoding state machines are copied across three paths

- **Priority:** P1
- **File:** `src/json_codec.cj`
- **Function or type:** `appendDirectFastObjectRead` at line 1358, the semantic `read` block inside `renderCodec` at line 1826, and the cursor `readFastWithCursor` block inside `renderCodec` at line 1934. `appendMutableObjectFastRead` at line 1226 is a fourth related path.
- **Current responsibility:** Each path declares scratch values and seen flags, dispatches names, tracks duplicate and unknown fields, checks required fields, selects constructor defaults, creates the result, and assigns post-constructor mutable fields.
- **Why it is hard to maintain:** The same result-construction block appears at lines 1431-1478, 1869-1917, and 1999-2047. `dupcheck` also found repeated field-assignment windows at lines 1119-1134 and 1159-1174. The paths already differ in duplicate-key policy, unknown-field policy, reader calls, and context handling. Copying the common state machine makes an intentional backend difference difficult to distinguish from accidental drift.
- **Suggested responsibility seam:** Build one `ObjectDecodePlan` from the codec model. Emit the common phases from that plan: scratch declaration, field dispatch, required-field checks, constructor arguments, and post-constructor assignments. A small `ReadBackend` strategy should supply only backend-specific operations such as reading a name, reading a value, skipping a value, and entering or leaving context.
- **Suggested file and type structure:**
  - `src/codec_decode_plan.cj`: `ObjectDecodePlan`, `FieldDecodePlan`, and result-construction planning.
  - `src/codec_read_emitter.cj`: `SemanticReadBackend`, `FastReadBackend`, and `CursorReadBackend` as internal variants, not public extension points.
- **Modification risk:** High. Duplicate-key rules, unknown-field rules, default values, required fields, and path tracking can change independently if the shared plan is wrong.
- **Required tests:** A matrix over reordered fields, aliases, duplicates, unknown fields, missing required fields, constructor defaults, mutable post-constructor fields, option fields, scalar scratch values, nested containers, custom codecs, inherited fields, and every read backend. Assert values, error codes, and JSON paths.

### CCA-003: field types and codec capabilities are represented as repeated strings

- **Priority:** P1
- **File:** `src/json_codec.cj`
- **Function or type:** `CodecField`; `defaultFieldCodec`, `directScalarWrite`, `compactRawScalarFieldWrite`, `primitiveRawValueWrite`, `generatedBufferReserveTerm`, `generatedBufferAllScalar`, `generatedBufferContainerType`, `directScalarRead`, `directScalarFastRead`, `directScalarCursorFastRead`, `directFieldNeedsContext`, and `scalarScratchInitializer`.
- **Current responsibility:** These functions repeatedly normalize `field.typeText`, match exact strings such as `Array<Int64>`, and infer which runtime interfaces, read operations, write operations, context rules, and reserve hints apply.
- **Why it is hard to maintain:** Adding or correcting one supported type requires coordinated edits across many match tables. The same type can support semantic read, fast read, cursor read, or compact write in different combinations, but no single value records that capability set. The implementation can therefore advertise one path while omitting or misclassifying another. Exact string matching also makes aliases and qualified type spelling fragile.
- **Suggested responsibility seam:** Parse each field type once into a closed internal `FieldTypeShape`. Derive one immutable `FieldCapabilities` value that records codec selection, read backends, write backends, context needs, scratch initialization, and reserve behavior. Emitters should query that value instead of matching `typeText` again.
- **Suggested file and type structure:**
  - `src/codec_type_shape.cj`: `FieldTypeShape` and normalized container shapes.
  - `src/codec_capabilities.cj`: `FieldCapabilities` and capability derivation.
  - `CodecFieldModel` retains original source tokens only for emitted type spelling.
- **Modification risk:** High. The tables encode compatibility and performance behavior for primitive and container types.
- **Required tests:** A capability table test for every currently recognized primitive, option, array, list, map, nested map, generic, custom-codec, qualified, and user-defined type. Compile and run each type through every capability that the table advertises.

### CCA-004: source-string replacement acts as an implicit code-generation IR

- **Priority:** P1
- **File:** `src/json_codec.cj:751`
- **Function or type:** `compactRawDirectWriterRewrite`, `compactRawDirectFieldWrite`, `compactRawConcreteFieldWrite`, and the compact writer block at lines 1736-1800.
- **Current responsibility:** The code first renders one backend as a `String`, then changes receiver names and method names with chained `replace` calls to obtain another backend. The file contains 47 `.replace(` calls, including replacements for writer receivers, scalar methods, collection methods, and generated field-name symbols.
- **Why it is hard to maintain:** A generated identifier or method rename can silently make a replacement stop matching. A replacement can also affect an unintended substring. The compiler checks only the final generated program, so the macro implementation has no type-level proof that a transformation preserved the intended operation. This mixes semantic selection with textual rewriting.
- **Suggested responsibility seam:** Represent compact writes as internal operations such as `BeginObject`, `WriteKnownName`, `WriteScalar`, `WriteContainer`, `WriteNested`, and `EndObject`. Render those operations separately for cursor and direct-writer backends. If a full operation model is too large for one change, start with scalar field writes and migrate containers in later tasks.
- **Suggested file and type structure:**
  - `src/codec_write_plan.cj`: `CompactWriteOp` and `FieldWritePlan`.
  - `src/codec_write_emitter.cj`: direct-writer and cursor renderers.
- **Modification risk:** High. This is a performance-sensitive path with many specialized runtime entry points.
- **Required tests:** Exact JSON output for every specialized scalar and container path; option null and omission behavior; custom codecs; nested generated types; depth and path cleanup after exceptions; compile tests that cover every emitted runtime method; encode microbenchmarks for scalar-only and container-heavy records.

### CCA-005: codec metadata has a boolean cluster and long parameter lists

- **Priority:** P2
- **File:** `src/json_codec.cj:6`
- **Function or type:** `CodecField.init`, `appendDirectFastObjectRead`, and field-assignment emitters.
- **Current responsibility:** `CodecField` stores declaration facts, JSON naming, option analysis, codec selection, mutability, default behavior, null policy, and whether the field participates in output. Its initializer takes 11 parameters, including five Boolean values. `appendDirectFastObjectRead` takes seven parameters, while the assignment emitters take five or six.
- **Why it is hard to maintain:** Call sites do not explain which Boolean combination they create. Some combinations are meaningful only for inherited constructor-only fields, option fields, or custom codecs. The long emitter signatures pass a loosely related bag of state and make it easy to swap strings or omit a policy input.
- **Suggested responsibility seam:** Separate declaration facts from serialization policy and derived capability. Pass one `ObjectReadEmitContext` to read emitters. Construct field models through named factory functions that validate allowed states.
- **Suggested file and type structure:**
  - `CodecFieldDeclaration`: source name, type, mutability, and default.
  - `JsonFieldPolicy`: wire name, aliases, null policy, custom codec, and participation.
  - `FieldCapabilities`: derived read and write support.
  - `ObjectReadEmitContext`: model, labels, backend, target type, and source writer.
- **Modification risk:** Medium. The change is structural, but incorrect factories can alter inherited-field or option behavior.
- **Required tests:** Model-construction tests for ordinary, ignored, renamed, aliased, inherited constructor-only, optional, defaulted, immutable, and custom-codec fields. Compile fixtures should verify rejected combinations.

### CCA-006: macro diagnostics and generated runtime errors are coupled to emission logic

- **Priority:** P2
- **File:** `src/json_codec.cj` and `src/json_literal.cj`
- **Function or type:** AST probing and validation helpers, all codec emitters, and `JsonLiteralParser.fail`.
- **Current responsibility:** The implementation throws macro-expansion `Exception` values while it discovers fields and constructors. The same emission functions also build runtime `JsonException` source strings for duplicates, unknown fields, missing fields, compact codec availability, enum payloads, and polymorphic dispatch.
- **Why it is hard to maintain:** Compile-time diagnostics and generated runtime behavior have different contracts, but they are edited in the same control flow. Several AST probes catch broad exceptions and treat them as absence at lines 141, 151, 167, 289, 319, 337, and 450. That makes malformed input, an unsupported AST shape, and an expected missing property difficult to distinguish. Runtime error codes and path handling are repeated across backends.
- **Suggested responsibility seam:** Validate a codec model before emission and return one diagnostic vocabulary for expansion failures. Centralize runtime error emission by error kind so each backend supplies only the current path expression and field label.
- **Suggested file and type structure:**
  - `src/codec_diagnostics.cj`: validation rules and stable expansion messages.
  - `src/codec_runtime_errors.cj`: internal emitters for stable `JsonException` codes and path handling.
- **Modification risk:** Medium to high. Error messages, error codes, and paths may be observable contracts.
- **Required tests:** Negative compile fixtures for malformed annotations, duplicate names, missing types, invalid constructor mapping, and unsupported declarations. Runtime tests must assert error code and path parity across semantic, fast, and cursor readers.

### CCA-007: the generated-runtime dependency is correctly directed but too implicit

- **Priority:** P2
- **File:** `src/json_codec.cj`
- **Function or type:** all codec renderers and provider emitters.
- **Current responsibility:** The macro package deliberately avoids a compile-time dependency on the runtime package and emits references to the `generated-support v1` interface into caller code. Runtime symbols appear on 115 source lines; `GeneratedSupportV1` alone appears 86 times.
- **Why it is hard to maintain:** The dependency direction is appropriate for a separate macro package, but the protocol vocabulary is distributed across object, enum, and polymorphic emitters. A runtime rename or version change requires a broad textual search. It is difficult to prove that every emitted entry point belongs to the same protocol version.
- **Suggested responsibility seam:** Keep the macro-to-runtime dependency as generated source. Put protocol names, provider shapes, entry guards, reader and writer acquisition, and finish or release sequences behind one internal `GeneratedRuntimeV1Emitter`. Do not import the runtime package into the macro implementation.
- **Suggested file and type structure:**
  - `src/generated_runtime_v1_emitter.cj`: versioned protocol vocabulary and lifecycle emission.
  - `src/codec_provider_emitter.cj`: provider conformance and public overload generation using that vocabulary.
- **Modification risk:** High. This seam is an implicit cross-module compatibility contract.
- **Required tests:** Build a minimal consumer against the matching `yjson` runtime; compile every generated interface conformance; exercise reader and writer acquisition and cleanup; add a protocol inventory test that fails when emitted symbols change without an explicit version decision.

### CCA-008: enum and polymorphic renderers mix analysis, validation, lifecycle, and registration

- **Priority:** P2
- **File:** `src/json_codec.cj:2188` and `src/json_codec.cj:2349`
- **Function or type:** `renderEnumCodec` and `renderPolymorphicCodec`.
- **Current responsibility:** Each function validates declaration metadata, selects generic constraints, declares cached codecs, emits read and write bodies, manages context lifetime, and emits provider registration. `renderEnumCodec` spans 160 lines and `renderPolymorphicCodec` spans 128 lines.
- **Why it is hard to maintain:** These functions repeat lifecycle and provider patterns already present in object emission while also carrying domain-specific wire formats. Protocol changes therefore touch three large renderers. Moving only the functions into separate files would not remove the duplicated responsibilities.
- **Suggested responsibility seam:** Build `EnumCodecModel` and `PolymorphicCodecModel` first. Keep their wire-format emitters separate, but share the versioned runtime lifecycle and provider emitter introduced for CCA-007.
- **Suggested file and type structure:**
  - `src/codec_enum_model.cj` and `src/codec_enum_emitter.cj`.
  - `src/codec_polymorphic_model.cj` and `src/codec_polymorphic_emitter.cj`.
  - shared `generated_runtime_v1_emitter.cj` and `codec_provider_emitter.cj`.
- **Modification risk:** Medium to high. Enum payload ordering and polymorphic replay semantics are protocol behavior.
- **Required tests:** Empty and payload enum cases, renamed cases, generic payloads, missing and extra payload values, fast and semantic paths, registered and unregistered polymorphic subtypes, discriminator conflicts, buffered-value limits, inheritance, and cleanup after failures.

### CCA-009: the literal AST permits invalid states

- **Priority:** P3
- **File:** `src/json_literal.cj:42`
- **Function or type:** `JsonLiteralNode` and `JsonLiteralKind`.
- **Current responsibility:** One class represents null, Boolean, string, number, interpolation, array, and object nodes. Every instance contains `text`, `items`, and `fields`, although only one subset is meaningful for each `kind`.
- **Why it is hard to maintain:** The type does not encode its invariants. A new parser or renderer branch can construct a node with the wrong payload and still compile. The parser and renderer currently preserve the invariant by convention. The rest of `json_literal.cj` is comparatively cohesive: its largest function span is 48 lines, parser state is centralized in `JsonLiteralParser`, and renderer state is centralized in `JsonLiteralRenderer`.
- **Suggested responsibility seam:** Represent each node variant with only its valid payload. Use an enum with payloads if the project SDK supports the required private representation cleanly, or use a sealed private class family. Keep `JsonLiteralDocument` as the parser-to-renderer interface.
- **Suggested file and type structure:**
  - `src/json_literal_model.cj`: node variants, fields, bindings, and document.
  - `src/json_literal_parser.cj`: token cursor and grammar validation.
  - `src/json_literal_emitter.cj`: source rendering.
  - `src/json_literal.cj`: only public macro entry points.
- **Modification risk:** Low to medium. The model is private, but interpolation order, duplicate keys, and literal spelling must remain exact.
- **Required tests:** All literal kinds, escape decoding, strict number grammar, nested arrays and objects, static duplicate keys, dynamic key last-wins behavior, trailing commas, invalid tokens, empty or unterminated interpolation, and exactly-once left-to-right interpolation evaluation.

## Concerns reviewed without a separate finding

- **God class or God object:** No production class is a God object. `JsonLiteralParser` and `JsonLiteralRenderer` each own one coherent state machine. The God-function problem is `renderCodec`.
- **Deep control flow:** The problematic depth is concentrated in codec emission and in the generated read and write state machines. The literal parser uses bounded, grammar-shaped control flow.
- **State management:** Literal parser and renderer state is localized. Codec read state is duplicated rather than globally scattered; CCA-002 covers that risk.
- **Persistence, UI, or transport mixing:** This package has no persistence or UI code. Its significant layer mix is compile-time AST analysis, JSON wire protocol, runtime compatibility, and source emission in `json_codec.cj`.
- **Utils, Helper, or Manager dumping grounds:** No type or file uses these names. `json_codec.cj` is still acting as a dumping ground because unrelated generator phases accumulate there.
- **Cross-module dependency direction:** No reverse source import from the macro package to the runtime package was found. The implicit generated-protocol dependency is covered by CCA-007.
- **Mechanical file splitting:** `json_literal.cj` does not warrant splitting for line count alone. Any split should follow the parser-to-document-to-emitter seam.

## Recommended order

Do not start by moving functions into new files. First add behavioral evidence, then introduce the immutable codec model and type capabilities. Consolidate result construction and field dispatch before splitting `renderCodec`. Replace compact-writer string rewriting only after the type-capability model and compact-path tests exist.

See `docs/refactoring/refactoring-roadmap.md` for review-sized tasks and dependencies.
