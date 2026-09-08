# yjson_macros

`yjson_macros` is a standalone Cangjie macro module for `yjson`. It must be
compiled as a separate module because Cangjie does not allow a normal package
and a `macro package` to share one package tree.

The module provides:

- `@JsonCodec` for generated codecs on classes, structs, and enums;
- `@Json({...})` for compile-time-checked JSON-like literals that produce a
  mutable `JsonNode` tree;
- `@JsonValue({...})` as an explicit alias of `@Json`;
- `@JsonSubtype[wireName, ConcreteType]` for polymorphic subtype declarations;
- `@JsonUsing[codecExpression]` for custom codec selection.

Static literals support objects, arrays, strings, booleans, `null`, and JSON
numbers. Use `$()` for runtime values and dynamic string keys. Interpolations
are evaluated once from left to right. Later values replace earlier values for
the same dynamic key. Object fields require commas; a trailing comma is valid.

An application declares the runtime and macro modules separately:

```toml
[dependencies]
yjson = { git = "https://github.com/lIlIIlIll/yjson.git" }
yjson_macros = { git = "https://github.com/lIlIIlIll/yjson_macros.git" }
```

The `yjson` and `yjson_macros` modules must use matching release versions and
Cangjie SDK versions. Generated code uses the `generated-support v1` runtime
interface.
