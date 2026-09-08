macro package yjson_macros

import std.ast.*
import std.collection.*

private class CodecField {
    let name: String
    let typeText: String
    let jsonNameExpr: String
    let aliases: ArrayList<String>
    let mutable: Bool
    let hasDefault: Bool
    let isOption: Bool
    let optionInner: String
    let includeNull: Bool
    let codecExpr: String
    let writeField: Bool

    init(
        name: String,
        typeText: String,
        jsonNameExpr: String,
        aliases: ArrayList<String>,
        mutable: Bool,
        hasDefault: Bool,
        isOption: Bool,
        optionInner: String,
        includeNull: Bool,
        codecExpr: String,
        writeField!: Bool = true
    ) {
        this.name = name
        this.typeText = typeText
        this.jsonNameExpr = jsonNameExpr
        this.aliases = aliases
        this.mutable = mutable
        this.hasDefault = hasDefault
        this.isOption = isOption
        this.optionInner = optionInner
        this.includeNull = includeNull
        this.codecExpr = codecExpr
        this.writeField = writeField
    }
}

private class CodecConstructorParam {
    let name: String
    let typeText: String
    let hasDefault: Bool
    let defaultExpr: String

    init(name: String, typeText: String, hasDefault: Bool, defaultExpr: String) {
        this.name = name
        this.typeText = typeText
        this.hasDefault = hasDefault
        this.defaultExpr = defaultExpr
    }
}

private class PolymorphicSubtype {
    let wireNameExpr: String
    let typeText: String

    init(wireNameExpr: String, typeText: String) {
        this.wireNameExpr = wireNameExpr
        this.typeText = typeText
    }
}

private func hasModifier(decl: Decl, kind: TokenKind): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.keyword.kind == kind) { return true }
    }
    false
}

private func hasAnnotation(decl: Decl, name: String): Bool {
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) { return true }
    }
    false
}

private func annotationArguments(decl: Decl, name: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                result.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    result
}

private func constructorAnnotationArguments(constructor: Constructor, name: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (annotation in constructor.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                result.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    result
}

private func hasInitializer(decl: VarDecl): Bool {
    try {
        let _ = decl.expr
        true
    } catch (_: ASTException) {
        false
    }
}

private func optionInner(typeNode: TypeNode): Option<String> {
    match (typeNode) {
        case q: QualifiedType =>
            if (q.identifier.value == "Option" && q.typeArguments.size == 1) {
                return Some(q.typeArguments[0].toTokens().toString().trimAscii())
            }
        case p: ParenType => return optionInner(p.parenthesizedType)
        case _ => ()
    }
    None<String>
}

private func optionInnerText(typeText: String): Option<String> {
    let normalized = typeText.replace(" ", "")
    if (normalized.startsWith("Option<") && normalized.endsWith(">") &&
        normalized.size > 8) {
        return Some(normalized[7..normalized.size - 1])
    }
    None<String>
}

private func unwrapField(decl: Decl): Decl {
    match (decl) {
        case wrapper: MacroExpandDecl =>
            return try { unwrapField(parseDecl(wrapper.macroInputs)) } catch (_) { decl }
        case _ => decl
    }
}

private func fieldHasMarker(wrapper: Decl, field: Decl, name: String): Bool {
    if (hasAnnotation(field, name)) { return true }
    match (wrapper) {
        case macroDecl: MacroExpandDecl =>
            if (macroDecl.identifier.value == name) { return true }
            return try { fieldHasMarker(parseDecl(macroDecl.macroInputs), field, name) } catch (_) { false }
        case _ => false
    }
}

private func collectFieldArguments(wrapper: Decl, field: Decl, name: String): ArrayList<String> {
    let result = annotationArguments(field, name)
    var current = wrapper
    while (true) {
        match (current) {
            case macroDecl: MacroExpandDecl =>
                if (macroDecl.identifier.value == name && macroDecl.macroAttrs.size != 0) {
                    result.add(macroDecl.macroAttrs.toString().trimAscii())
                }
                try {
                    current = parseDecl(macroDecl.macroInputs)
                } catch (_) { break }
            case _ => break
        }
    }
    result
}

private func retainedExpression(value: String): String {
    let text = value.trimAscii()
    if (text.size >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        return text[1..text.size - 1]
    }
    text
}

private func namedArgumentValue(value: String): String {
    let tokens = cangjieLex(retainedExpression(value))
    let result = Tokens()
    var foundColon = false
    for (token in tokens) {
        if (!foundColon && token.kind == TokenKind.COLON) {
            foundColon = true
            continue
        }
        if (foundColon) { result.append(token) }
    }
    if (foundColon) { result.toString().trimAscii() } else { retainedExpression(value) }
}

private func addUnique(values: ArrayList<String>, value: String): Unit {
    for (existing in values) {
        if (existing == value) { return }
    }
    values.add(value)
}

private func parseSubtypeExpression(expression: String): PolymorphicSubtype {
    let tokens = cangjieLex(retainedExpression(expression))
    let left = Tokens()
    let right = Tokens()
    var depth: Int64 = 0
    var foundComma = false
    for (token in tokens) {
        match (token.kind) {
            case TokenKind.LPAREN | TokenKind.LSQUARE | TokenKind.LCURL => depth++
            case TokenKind.RPAREN | TokenKind.RSQUARE | TokenKind.RCURL => depth--
            case TokenKind.COMMA =>
                if (depth == 0 && !foundComma) { foundComma = true; continue }
            case _ => ()
        }
        if (foundComma) { right.append(token) } else { left.append(token) }
    }
    let wireName = left.toString().trimAscii()
    let typeText = right.toString().trimAscii()
    if (!foundComma || wireName.isEmpty() || typeText.isEmpty()) {
        throw Exception("@JsonSubtype expects a wire name and concrete type, for example @JsonSubtype[\"dog\", Dog]")
    }
    PolymorphicSubtype(wireName, typeText)
}

private func collectFields(body: Body): ArrayList<CodecField> {
    let result = ArrayList<CodecField>()
    let seenJsonNames = HashSet<String>()
    for (member in body.decls) {
        let decl = unwrapField(member)
        if (let Some(field) <- (decl as VarDecl)) {
            if (hasModifier(field, TokenKind.STATIC) || fieldHasMarker(member, field, "JsonIgnore")) { continue }
            let isPublic = hasModifier(field, TokenKind.PUBLIC)
            let isPrivate = hasModifier(field, TokenKind.PRIVATE)
            if (isPrivate || !isPublic) {
                continue
            }
            let typeNode = try { field.declType } catch (_: ASTException) {
                throw Exception("@JsonCodec requires an explicit type for `${field.identifier.value}`")
            }
            let names = collectFieldArguments(member, field, "JsonName")
            let jsonExpr = if (names.isEmpty()) { "\"${field.identifier.value}\"" } else { names[0] }
            if (seenJsonNames.contains(jsonExpr)) {
                throw Exception("duplicate JSON name ${jsonExpr}")
            }
            seenJsonNames.add(jsonExpr)
            let aliases = collectFieldArguments(member, field, "JsonAlias")
            for (alias in aliases) {
                if (seenJsonNames.contains(alias)) { throw Exception("duplicate JSON name or alias ${alias}") }
                seenJsonNames.add(alias)
            }
            let fieldTypeText = typeNode.toTokens().toString().trimAscii()
            let astInner = optionInner(typeNode)
            let inner = if (astInner.isSome()) { astInner } else {
                optionInnerText(fieldTypeText)
            }
            let customCodecs = collectFieldArguments(member, field, "JsonUsing")
            for (encoded in collectFieldArguments(member, field, "JsonUsingMetadata")) {
                customCodecs.add(retainedExpression(encoded))
            }
            if (customCodecs.size > 1) {
                throw Exception("@JsonUsing accepts exactly one codec expression for `${field.identifier.value}`")
            }
            result.add(CodecField(
                field.identifier.value,
                fieldTypeText,
                jsonExpr,
                aliases,
                field.keyword.kind == TokenKind.VAR,
                hasInitializer(field),
                inner.isSome(),
                inner.getOrDefault({ => "" }),
                fieldHasMarker(member, field, "JsonIncludeNull"),
                if (customCodecs.isEmpty()) { "" } else { customCodecs[0] }
            ))
        }
    }
    result
}

private func unwrapParams(params: Iterable<FuncParam>): ArrayList<FuncParam> {
    let result = ArrayList<FuncParam>()
    for (param in params) {
        match (param) {
            case wrapper: MacroExpandParam =>
                try {
                    result.add((wrapper.macroInputDecl as FuncParam).getOrThrow())
                } catch (_) { result.add(param) }
            case _ => result.add(param)
        }
    }
    result
}

private func constructorParams(body: Body): ArrayList<CodecConstructorParam> {
    var best = ArrayList<FuncParam>()
    for (member in body.decls) {
        let decl = unwrapField(member)
        match (decl) {
            case fn: FuncDecl =>
                if (fn.identifier.value == "init" || fn.identifier.kind == TokenKind.INIT) {
                    let params = unwrapParams(fn.funcParams)
                    if (params.size > best.size) { best = params }
                }
            case primary: PrimaryCtorDecl =>
                let params = unwrapParams(primary.funcParams)
                if (params.size > best.size) { best = params }
            case _ => ()
        }
    }
    let result = ArrayList<CodecConstructorParam>()
    for (param in best) {
        var hasDefault = false
        var defaultExpr = ""
        try {
            defaultExpr = param.expr.toTokens().toString().trimAscii()
            hasDefault = true
        } catch (_: ASTException) {}
        result.add(CodecConstructorParam(
            param.identifier.value,
            param.paramType.toTokens().toString().trimAscii(),
            hasDefault,
            defaultExpr
        ))
    }
    result
}

private func genericNames(decl: Decl): ArrayList<String> {
    let result = ArrayList<String>()
    try {
        let generic = decl.genericParam
        for (token in generic.parameters) {
            if (token.kind == TokenKind.IDENTIFIER) { result.add(token.value) }
        }
    } catch (_: ASTException) {}
    result
}

private func joinStrings(values: ArrayList<String>, separator: String): String {
    let sb = StringBuilder()
    for (index in 0..values.size) {
        if (index != 0) { sb.append(separator) }
        sb.append(values[index])
    }
    sb.toString()
}

private func typeUsesName(typeText: String, name: String): Bool {
    for (token in cangjieLex(typeText)) {
        if (token.kind == TokenKind.IDENTIFIER && token.value == name) { return true }
    }
    false
}

private func renderedConstraints(decl: Decl, fields: ArrayList<CodecField>, generics: ArrayList<String>): String {
    let parts = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        if (text.startsWith("where ")) { parts.add(text[6..text.size]) } else { parts.add(text) }
    }
    for (name in generics) {
        var participates = false
        for (field in fields) {
            if (field.codecExpr.isEmpty() && typeUsesName(field.typeText, name)) { participates = true; break }
        }
        if (participates) { parts.add("${name} <: GeneratedCodecProviderV1<${name}>") }
    }
    if (parts.isEmpty()) { return "" }
    let sb = StringBuilder(" where ")
    for (index in 0..parts.size) {
        if (index != 0) { sb.append(", ") }
        sb.append(parts[index])
    }
    sb.toString()
}

private func renderedEnumConstraints(decl: EnumDecl, generics: ArrayList<String>): String {
    let parts = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        if (text.startsWith("where ")) { parts.add(text[6..text.size]) } else { parts.add(text) }
    }
    for (name in generics) {
        var participates = false
        for (constructor in decl.constructors) {
            for (typeNode in constructor.typeArguments) {
                if (typeUsesName(typeNode.toTokens().toString().trimAscii(), name)) {
                    participates = true
                    break
                }
            }
            if (participates) { break }
        }
        if (participates) { parts.add("${name} <: GeneratedCodecProviderV1<${name}>") }
    }
    if (parts.isEmpty()) { return "" }
    " where " + joinStrings(parts, ", ")
}

private func defaultFieldCodec(typeText: String): String {
    match (typeText) {
        case "Bool" => return "JsonCodecs.bool"
        case "Int64" => return "JsonCodecs.int64"
        case "Int32" => return "JsonCodecs.int32"
        case "Int16" => return "JsonCodecs.int16"
        case "Int8" => return "JsonCodecs.int8"
        case "UInt64" => return "JsonCodecs.uint64"
        case "UInt32" => return "JsonCodecs.uint32"
        case "UInt16" => return "JsonCodecs.uint16"
        case "UInt8" => return "JsonCodecs.uint8"
        case "Float64" => return "JsonCodecs.float64"
        case "Float32" => return "JsonCodecs.float32"
        case "Float16" => return "JsonCodecs.float16"
        case "String" => return "JsonCodecs.string"
        case "BigInt" => return "JsonCodecs.bigInt"
        case "Decimal" => return "JsonCodecs.decimal"
        case "Rune" => return "JsonCodecs.rune"
        case _ => ()
    }

    try {
        match (parseType(cangjieLex(typeText))) {
            case q: QualifiedType =>
                let arguments = q.typeArguments
                if (q.identifier.value == "Option" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.option(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "Array" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.array(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "ArrayList" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.arrayList(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "HashMap" && arguments.size == 2) {
                    let key = arguments[0].toTokens().toString().trimAscii()
                    if (key == "String") {
                        let value = arguments[1].toTokens().toString().trimAscii()
                        return "JsonCodecs.stringMap(" + defaultFieldCodec(value) + ")"
                    }
                }
            case p: ParenType =>
                return defaultFieldCodec(p.parenthesizedType.toTokens().toString().trimAscii())
            case _ => ()
        }
    } catch (_) {
        // Keep provider-based fallback for user-defined and future types.
    }
    "generatedCodecV1Of<${typeText}>()"
}

private func cachedFieldCodecName(field: CodecField): String {
    "__yJsonFieldCodec_${field.name}"
}

private func cachedFastFieldCodecName(field: CodecField): String {
    "__yJsonFastFieldCodec_${field.name}"
}

private func cachedCursorFastFieldCodecName(field: CodecField): String {
    "__yJsonCursorFastFieldCodec_${field.name}"
}


// Canonical generated field names are immutable literals. Keep one byte view
// per field so direct compact writers do not call String.rawData() on every
// encoded object. Custom names remain on the String overloads because their
// expression may be computed or otherwise carry user-defined semantics.
private func generatedKnownNameBytesName(field: CodecField): String {
    // Delimit the generated identifier so a field such as `f1` cannot match
    // the prefix of another field such as `f10` during source-level rewrites.
    "__yJsonKnownNameBytes_${field.name}__"
}

// A non-generic user model emitted by @JsonCodec owns a private concrete
// codec global with the same source-level name.  Keep this deliberately
// narrow: container/builtin/custom-codec fields must continue through their
// cached protocol codec because no generated concrete global is guaranteed
// for them.
private func simpleGeneratedTypeName(field: CodecField): String {
    if (field.isOption || !field.codecExpr.isEmpty()) { return "" }
    let normalized = field.typeText.replace(" ", "")
    if (normalized.contains("<") || normalized.contains(">") || normalized.contains(".")) {
        return ""
    }
    match (normalized) {
        case "Bool" | "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" |
             "Float16" | "Float32" | "Float64" | "Rune" | "String" |
             "BigInt" | "Decimal" | "DateTime" | "Duration" |
             "JsonNode" | "JsonValue" | "JsonValueView" => ""
        case _ => normalized
    }
}

private func fieldCodec(field: CodecField): String {
    cachedFieldCodecName(field)
}

private func fieldCodecInitializer(field: CodecField): String {
    if (field.codecExpr.isEmpty()) { defaultFieldCodec(field.typeText) } else { "(${field.codecExpr})" }
}

private func directScalarWrite(field: CodecField, value: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "writer.writeBool(${value})"
        case "Int64" => "writer.writeInt64(${value})"
        case "Int32" | "Int16" | "Int8" => "writer.writeInt64(Int64(${value}))"
        case "UInt64" => "writer.writeUInt64(${value})"
        case "UInt32" | "UInt16" | "UInt8" => "writer.writeUInt64(UInt64(${value}))"
        case "Float64" => "writer.writeFloat64(${value})"
        case "Float32" | "Float16" => "writer.writeFloat64(Float64(${value}))"
        case "String" => "writer.writeString(${value})"
        case "Array<Int64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64Array(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeInt64(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "Array<Float64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactFloat64Array(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeFloat64(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "Array<String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringArray(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeString(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "ArrayList<String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringArrayList(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeString(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "HashMap<String,Int64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64Map(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItem) in ${value}) { writer.writeName(__fastName); writer.writeInt64(__fastItem) }; writer.endObject() } } finally { context.leaveValue() }"
        case "HashMap<String,String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringMap(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItem) in ${value}) { writer.writeName(__fastName); writer.writeString(__fastItem) }; writer.endObject() } } finally { context.leaveValue() }"
        case "HashMap<String,Array<Int64>>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64ArrayMap(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItems) in ${value}) { writer.writeName(__fastName); writer.startArray(); for (__fastItem in __fastItems) { writer.writeInt64(__fastItem) }; writer.endArray() }; writer.endObject() } } finally { context.leaveValue() }"
        case "Option<String>" => "__yJsonWriteStringOption(${value}, writer)"
        case "Option<Int64>" => "__yJsonWriteInt64Option(${value}, writer)"
        case _ => ""
    }
}

private func compactRawScalarFieldWrite(field: CodecField, value: String, first: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
    if (field.typeText.replace(" ", "") == "Option<Int64>") {
        let someWrite = "${first} = __writer.writeRawObjectEntry${nameKind}Int64(${first}, " +
            "${field.jsonNameExpr}, __rawItem)"
        if (!field.includeNull) {
            return "if (let Some(__rawItem) <- ${value}) { ${someWrite} }"
        }
        return "match (${value}) { case Some(__rawItem) => ${someWrite}; " +
            "case None => ${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "writer.writeRawNull() }"
    }
    if (field.typeText.replace(" ", "") == "Option<String>") {
        let someWrite = "${first} = __writer.writeRawObjectEntry${nameKind}String(${first}, " +
            "${field.jsonNameExpr}, __rawItem)"
        if (!field.includeNull) {
            return "if (let Some(__rawItem) <- ${value}) { ${someWrite} }"
        }
        return "match (${value}) { case Some(__rawItem) => ${someWrite}; " +
            "case None => ${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "writer.writeRawNull() }"
    }
    if (field.isOption) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "String" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}String(${first}, ${field.jsonNameExpr}, ${value})"
        case "Bool" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Bool(${first}, ${field.jsonNameExpr}, ${value})"
        case "Int64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Int64(${first}, ${field.jsonNameExpr}, ${value})"
        case "Int32" | "Int16" | "Int8" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Int64(${first}, ${field.jsonNameExpr}, Int64(${value}))"
        case "UInt64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}UInt64(${first}, ${field.jsonNameExpr}, ${value})"
        case "UInt32" | "UInt16" | "UInt8" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}UInt64(${first}, ${field.jsonNameExpr}, UInt64(${value}))"
        case "Float64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Float64(${first}, ${field.jsonNameExpr}, ${value})"
        case "Float32" | "Float16" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Float64(${first}, ${field.jsonNameExpr}, Float64(${value}))"
        case "Array<Int64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64Array(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64Array(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "Array<Float64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameFloat64Array(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactFloat64Array(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "Array<String>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameStringArray(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringArray(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "ArrayList<Int64>" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64ArrayList(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "ArrayList<String>" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringArrayList(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,Int64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64Map(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64Map(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,String>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameStringMap(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringMap(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,Array<Int64>>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64ArrayMap(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64ArrayMap(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case _ => compactRawPrimitiveContainerFieldWrite(field, value, first, nameKind)
    }
}

private func primitiveRawValueWrite(typeText: String, value: String): String {
    match (typeText.replace(" ", "")) {
        case "Bool" => "GeneratedSupportV1.writeRawBool(__writer, ${value})"
        case "Int8" | "Int16" | "Int32" | "Int64" =>
            "GeneratedSupportV1.writeRawInt64(__writer, Int64(${value}))"
        case "UInt8" | "UInt16" | "UInt32" | "UInt64" =>
            "GeneratedSupportV1.writeRawUInt64(__writer, UInt64(${value}))"
        case "Float16" | "Float32" | "Float64" =>
            "GeneratedSupportV1.writeRawFloat64(__writer, Float64(${value}))"
        case "String" => "GeneratedSupportV1.writeRawString(__writer, ${value})"
        case _ => ""
    }
}

private func collectionInnerType(typeText: String): String {
    let normalized = typeText.replace(" ", "")
    if (normalized.startsWith("Array<") && normalized.endsWith(">")) {
        return normalized[6..normalized.size - 1]
    }
    if (normalized.startsWith("ArrayList<") && normalized.endsWith(">")) {
        return normalized[10..normalized.size - 1]
    }
    ""
}

private func compactRawPrimitiveArrayValue(
    value: String,
    innerType: String,
    stem: String
): String {
    let itemWrite = primitiveRawValueWrite(innerType, "${value}[__rawIndex_${stem}]")
    if (itemWrite.isEmpty()) { return "" }
    "__writer.writeRawBeginArray(); " +
        "for (__rawIndex_${stem} in 0..${value}.size) { " +
        "if (__rawIndex_${stem} > 0) { __writer.writeRawByte(b',') }; " +
        "${itemWrite} }; __writer.writeRawEndArray()"
}

private func compactRawPrimitiveContainerFieldWrite(
    field: CodecField,
    value: String,
    first: String,
    nameKind: String
): String {
    let normalized = field.typeText.replace(" ", "")
    let innerType = collectionInnerType(normalized)
    if (!innerType.isEmpty()) {
        let body = compactRawPrimitiveArrayValue(value, innerType, field.name)
        if (!body.isEmpty()) {
            return "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, " +
                "${field.jsonNameExpr}); ${body}"
        }
    }

    let mapPrefix = "HashMap<String,"
    if (!normalized.startsWith(mapPrefix) || !normalized.endsWith(">")) { return "" }
    let mapValueType = normalized[mapPrefix.size..normalized.size - 1]
    let scalarWrite = primitiveRawValueWrite(mapValueType, "__rawMapItem_${field.name}")
    if (!scalarWrite.isEmpty()) {
        return "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, " +
            "${field.jsonNameExpr}); __writer.writeRawBeginObject(); " +
            "var __rawMapFirst_${field.name} = true; " +
            "for ((__rawMapName_${field.name}, __rawMapItem_${field.name}) in ${value}) { " +
            "__rawMapFirst_${field.name} = __writer.writeRawObjectEntryName(" +
            "__rawMapFirst_${field.name}, __rawMapName_${field.name}); ${scalarWrite} }; " +
            "__writer.writeRawEndObject()"
    }

    let mapInnerType = collectionInnerType(mapValueType)
    if (mapInnerType.isEmpty()) { return "" }
    let arrayBody = compactRawPrimitiveArrayValue(
        "__rawMapItems_${field.name}", mapInnerType, "map_${field.name}")
    if (arrayBody.isEmpty()) { return "" }
    "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
        "__writer.writeRawBeginObject(); var __rawMapFirst_${field.name} = true; " +
        "for ((__rawMapName_${field.name}, __rawMapItems_${field.name}) in ${value}) { " +
        "__rawMapFirst_${field.name} = __writer.writeRawObjectEntryName(" +
        "__rawMapFirst_${field.name}, __rawMapName_${field.name}); ${arrayBody} }; " +
        "__writer.writeRawEndObject()"
}

private func compactRawCodecName(field: CodecField): String {
    "__yJsonCompactRaw_${field.name}"
}

private func compactRawCursorCodecName(field: CodecField): String {
    "__yJsonCompactRawCursor_${field.name}"
}

private func compactRawFieldWrite(field: CodecField, value: String, first: String): String {
    let scalar = compactRawScalarFieldWrite(field, value, first)
    if (!scalar.isEmpty()) { return scalar }
    if (!directScalarWrite(field, value).isEmpty()) { return "" }
    let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
    if (field.isOption && !field.includeNull) {
        "if (${value}.isSome()) { ${first} = __writer.writeRawObjectEntry${nameKind}(" +
            "${first}, ${field.jsonNameExpr}); match (${compactRawCursorCodecName(field)}) { " +
            "case Some(__rawCursor) => __rawCursor.writeCompactWithCursor(${value}, writer, __writer); " +
            "case None => match (${compactRawCodecName(field)}) { " +
            "case Some(__raw) => __raw.writeCompactRaw(${value}, writer); " +
            "case None => throw JsonException(\"Compact raw codec is unavailable\") } } }"
    } else {
        "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "match (${compactRawCursorCodecName(field)}) { " +
            "case Some(__rawCursor) => __rawCursor.writeCompactWithCursor(${value}, writer, __writer); " +
            "case None => match (${compactRawCodecName(field)}) { " +
            "case Some(__raw) => __raw.writeCompactRaw(${value}, writer); " +
            "case None => throw JsonException(\"Compact raw codec is unavailable\") } }"
    }
}

private func compactRawDirectWriterRewrite(value: String): String {
    value
        .replace("__directWriter.", "writer.")
        .replace("__writer.", "writer.")
        .replace(
            "GeneratedSupportV1.writeRawBool(__writer,",
            "GeneratedSupportV1.writeRawBool(writer,")
        .replace(
            "GeneratedSupportV1.writeRawInt64(__writer,",
            "GeneratedSupportV1.writeRawInt64(writer,")
        .replace(
            "GeneratedSupportV1.writeRawUInt64(__writer,",
            "GeneratedSupportV1.writeRawUInt64(writer,")
        .replace(
            "GeneratedSupportV1.writeRawFloat64(__writer,",
            "GeneratedSupportV1.writeRawFloat64(writer,")
        .replace(
            "GeneratedSupportV1.writeRawString(__writer,",
            "GeneratedSupportV1.writeRawString(writer,")
}

private func compactRawDirectFieldWrite(field: CodecField, value: String, first: String): String {
    let scalar = compactRawScalarFieldWrite(field, value, first)
    if (!scalar.isEmpty()) {
        let direct = scalar.replace("__writer.", "__directWriter.")
            .replace(
                "writeRawObjectEntryKnownNameString(",
                "writeRawObjectEntryKnownNameStringBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameBool(",
                "writeRawObjectEntryKnownNameBoolBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameInt64(",
                "writeRawObjectEntryKnownNameInt64Buffer(")
            .replace(
                "writeRawObjectEntryKnownNameUInt64(",
                "writeRawObjectEntryKnownNameUInt64Buffer(")
            .replace(
                "writeRawObjectEntryKnownNameFloat64(",
                "writeRawObjectEntryKnownNameFloat64Buffer(")
            .replace(
                "writeRawObjectEntryKnownNameInt64Array(",
                "writeRawObjectEntryKnownNameInt64ArrayBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameFloat64Array(",
                "writeRawObjectEntryKnownNameFloat64ArrayBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameStringArray(",
                "writeRawObjectEntryKnownNameStringArray(")
            .replace(
                "writeRawObjectEntryKnownNameInt64Map(",
                "writeRawObjectEntryKnownNameInt64MapBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameStringMap(",
                "writeRawObjectEntryKnownNameStringMapBuffer(")
            .replace(
                "writeRawObjectEntryKnownNameInt64ArrayMap(",
                "writeRawObjectEntryKnownNameInt64ArrayMapBuffer(")
        return direct
    }
    compactRawFieldWrite(field, value, first)
}

private func compactRawConcreteFieldWrite(field: CodecField, value: String, first: String): String {
    let scalar = compactRawScalarFieldWrite(field, value, first)
    if (!scalar.isEmpty()) {
        return compactRawDirectFieldWrite(field, value, first)
    }
    if (!field.codecExpr.isEmpty() || field.isOption) {
        return compactRawDirectWriterRewrite(
            compactRawFieldWrite(field, value, first))
    }
    let concreteType = simpleGeneratedTypeName(field)
    if (!concreteType.isEmpty()) {
        let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
        return "${first} = writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "__yJsonConcrete_${concreteType}.writeCompactRawWithWriter(${value}, writer)"
    }
    let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
    let prefix = "${first} = writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); "
    let fallback = compactRawDirectWriterRewrite(
        compactRawFieldWrite(field, value, first))
    if (fallback.isEmpty()) { return "" }
    let marker = "match (${compactRawCursorCodecName(field)}) { " +
        "case Some(__rawCursor) => __rawCursor.writeCompactWithCursor(${value}, writer, GeneratedSupportV1.writeCursor(writer)); " +
        "case None => "
    let suffix = fallback
        .replace(prefix, "")
    prefix + marker + suffix + " }"
}

private func supportsStaticCompactRawWrite(fields: ArrayList<CodecField>): Bool {
    for (field in fields) {
        if (!field.writeField) { continue }
        if (!field.codecExpr.isEmpty() ||
            compactRawFieldWrite(field, "__value", "__first").isEmpty()) {
            return false
        }
    }
    true
}

private func compactRawFieldNeedsContext(field: CodecField): Bool {
    !field.codecExpr.isEmpty() || field.isOption
}

private func compactRawNeedsContext(fields: ArrayList<CodecField>): Bool {
    for (field in fields) {
        if (field.writeField && compactRawFieldNeedsContext(field)) {
            return true
        }
    }
    false
}

// Direct buffer field methods can omit their repeated capacity check when the
// generated object reserves a conservative bound once up front.  Keep this
// list limited to value shapes whose bound is local and deterministic; maps,
// nested objects, and string arrays retain their checked writer paths.
private func generatedBufferReserveTerm(field: CodecField, value: String): String {
    if (!field.writeField || !field.codecExpr.isEmpty() || field.isOption) { return "" }
    let name = "(${field.jsonNameExpr}).size"
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${name} + 8"
        case "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" => "${name} + 24"
        case "Float16" | "Float32" | "Float64" => "${name} + 44"
        // The fast method scans each string first.  Unescaped values need only
        // their exact byte length here; escaped values take the checked fused
        // writer, which reserves its six-byte escape bound locally.
        case "String" => "${name} + ${value}.size + 8"
        case _ => ""
    }
}

private func generatedBufferReserveHint(fields: ArrayList<CodecField>, valuePrefix: String): String {
    let terms = ArrayList<String>()
    for (field in fields) {
        let term = generatedBufferReserveTerm(field, "${valuePrefix}.${field.name}")
        if (!term.isEmpty()) { terms.add(term) }
    }
    if (terms.isEmpty()) { return "" }
    "2 + " + joinStrings(terms, " + ")
}

private func generatedBufferAllScalar(fields: ArrayList<CodecField>): Bool {
    var hasField = false
    for (field in fields) {
        if (!field.writeField) { continue }
        hasField = true
        if (!field.codecExpr.isEmpty() || field.isOption) { return false }
        if (field.jsonNameExpr != "\"${field.name}\"") { return false }
        match (field.typeText.replace(" ", "")) {
            case "Bool" | "Int8" | "Int16" | "Int32" | "Int64" |
                 "UInt8" | "UInt16" | "UInt32" | "UInt64" |
                 "Float16" | "Float32" | "Float64" | "String" => ()
            case _ => return false
        }
    }
    hasField
}

private func generatedBufferContainerType(typeText: String): Bool {
    match (typeText.replace(" ", "")) {
        case "Array<Int64>" | "Array<Float64>" | "Array<String>" |
             "HashMap<String,Int64>" | "HashMap<String,String>" |
             "HashMap<String,Array<Int64>>" => true
        case _ => false
    }
}

private func generatedBufferAllContainer(fields: ArrayList<CodecField>): Bool {
    var hasField = false
    for (field in fields) {
        if (!field.writeField) { continue }
        hasField = true
        if (!field.codecExpr.isEmpty() || field.isOption ||
            field.jsonNameExpr != "\"${field.name}\"" ||
            !generatedBufferContainerType(field.typeText)) {
            return false
        }
    }
    hasField
}

private func directScalarRead(field: CodecField, reader: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${reader}.readBool()"
        case "Int64" => "${reader}.readInt64()"
        case "UInt64" => "${reader}.readUInt64()"
        case "Float64" => "${reader}.readFloat64()"
        case "String" => "${reader}.readString()"
        case "ArrayList<String>" => "__yJsonReadStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadStringOption(${reader})"
        case "Option<Int64>" => "__yJsonReadInt64Option(${reader})"
        case "BigInt" => "${reader}.readBigInt()"
        case "Decimal" => "${reader}.readDecimal()"
        case _ => ""
    }
}

private func directScalarFastRead(field: CodecField, reader: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${reader}.readRawBool()"
        case "Int64" => "${reader}.readRawInt64()"
        case "Int32" => "${reader}.readRawInt32()"
        case "Int16" => "${reader}.readRawInt16()"
        case "Int8" => "${reader}.readRawInt8()"
        case "UInt64" => "${reader}.readRawUInt64()"
        case "UInt32" => "${reader}.readRawUInt32()"
        case "UInt16" => "${reader}.readRawUInt16()"
        case "UInt8" => "${reader}.readRawUInt8()"
        case "String" => "${reader}.readRawString()"
        case "ArrayList<String>" => "__yJsonReadFastStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadFastInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadFastStringOption(${reader})"
        case "Option<Int64>" => "__yJsonReadFastInt64Option(${reader})"
        case "Decimal" => "jsonFastReadDecimal(${reader})"
        case "Float64" => "jsonFastReadFloat64(${reader})"
        case "Float32" => "jsonFastReadFloat32(${reader})"
        case "Float16" => "jsonFastReadFloat16(${reader})"
        case "ArrayList<BigInt>" => "__yJsonReadFastArrayListBigInt(${reader})"
        case "HashMap<String,BigInt>" => "__yJsonReadFastHashMapStringBigInt(${reader})"
        case "ArrayList<Decimal>" => "__yJsonReadFastArrayListDecimal(${reader})"
        case "HashMap<String,Decimal>" => "__yJsonReadFastHashMapStringDecimal(${reader})"
        case _ => ""
    }
}

private func directScalarCursorFastRead(field: CodecField): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "__reader.readRawBool()"
        case "Int64" => "__reader.readRawInt64()"
        case "Int32" => "__reader.readRawInt32()"
        case "Int16" => "__reader.readRawInt16()"
        case "Int8" => "__reader.readRawInt8()"
        case "UInt64" => "__reader.readRawUInt64()"
        case "UInt32" => "__reader.readRawUInt32()"
        case "UInt16" => "__reader.readRawUInt16()"
        case "UInt8" => "__reader.readRawUInt8()"
        case "String" => "__reader.readRawString()"
        case "Float64" => "__reader.readRawFloat64()"
        case "Float32" => "__reader.readRawFloat32()"
        case "Float16" => "__reader.readRawFloat16()"
        case "Array<Int64>" => "__reader.readRawInt64Array()"
        case "Array<String>" => "__reader.readRawStringArray()"
        case "HashMap<String,Int64>" => "__reader.readRawInt64Map()"
        case "HashMap<String,String>" => "__reader.readRawStringMap()"
        case "HashMap<String,Array<Int64>>" => "__reader.readRawInt64ArrayMap()"
        case "Option<Int64>" =>
            "if (__reader.tryReadRawNull()) { None<Int64> } else { Some(__reader.readRawInt64()) }"
        case "Option<String>" =>
            "if (__reader.tryReadRawNull()) { None<String> } else { Some(__reader.readRawString()) }"
        case _ => directScalarFastRead(field, "reader")
    }
}

private func directFieldNeedsContext(field: CodecField): Bool {
    let typeText = field.typeText.replace(" ", "")
    typeText == "ArrayList<String>" || typeText == "HashMap<String,Int64>" ||
        typeText == "HashMap<String,String>" || typeText == "HashMap<String,Array<Int64>>" ||
        typeText == "Option<String>" || typeText == "ArrayList<BigInt>" ||
        typeText == "HashMap<String,BigInt>" || typeText == "ArrayList<Decimal>" ||
        typeText == "HashMap<String,Decimal>"
}

private func fastReadFieldNeedsContext(field: CodecField): Bool {
    directScalarCursorFastRead(field).isEmpty() || directFieldNeedsContext(field)
}

private func fastReadNeedsContext(fields: ArrayList<CodecField>): Bool {
    for (field in fields) {
        if (field.writeField && fastReadFieldNeedsContext(field)) {
            return true
        }
    }
    false
}

private func scalarScratchInitializer(field: CodecField): Option<String> {
    if (field.isOption || !field.codecExpr.isEmpty()) { return None<String> }
    let typeText = field.typeText.replace(" ", "")
    match (typeText) {
        case "Bool" => Some("false")
        case "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" |
             "Float16" | "Float32" | "Float64" => Some("${typeText}(0)")
        case _ => None<String>
    }
}

private func usesScalarScratch(field: CodecField): Bool {
    scalarScratchInitializer(field).isSome()
}

private func genericDecl(generics: ArrayList<String>): String {
    if (generics.isEmpty()) { return "" }
    "<" + joinStrings(generics, ", ") + ">"
}

private func fieldByName(fields: ArrayList<CodecField>, name: String): Option<CodecField> {
    for (field in fields) {
        if (field.name == name) { return Some(field) }
    }
    None<CodecField>
}

private func constructorParamByName(
    params: ArrayList<CodecConstructorParam>,
    name: String
): Option<CodecConstructorParam> {
    for (param in params) {
        if (param.name == name) { return Some(param) }
    }
    None<CodecConstructorParam>
}

private func fieldIsRequired(field: CodecField, params: ArrayList<CodecConstructorParam>): Bool {
    if (field.isOption) { return false }
    if (let Some(param) <- constructorParamByName(params, field.name)) {
        return !param.hasDefault
    }
    !field.hasDefault
}

private func appendLine(sb: StringBuilder, level: Int64, value: String): Unit {
    for (_ in 0..level) { sb.append("    ") }
    sb.append(value)
    sb.append(r'\n')
}

private func appendFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    field: CodecField,
    label: String,
    checkDuplicate: Bool
): Unit {
    let codec = fieldCodec(field)
    let directRead = directScalarCursorFastRead(field)
    let readValue = if (directRead.isEmpty()) {
        "GeneratedSupportV1.readWithCursorCached(${cachedCursorFastFieldCodecName(field)}, " +
            "${cachedFastFieldCodecName(field)}, ${codec}, reader, __reader)"
    } else {
        directRead
    }
    let assignValue = "__value_${field.name} = " +
        (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
    if (checkDuplicate) {
        appendLine(sb, level, "if (__seen_${field.name}) { context.pushField(${label}); try { throw JsonException(\"Duplicate JSON field\", code: \"duplicate_key\", path: context.currentPath()) } finally { context.popPath() } }")
    }
    if (directRead.isEmpty() || directFieldNeedsContext(field)) {
        appendLine(sb, level, "context.pushField(${label})")
        appendLine(sb, level, "try { ${assignValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, level, assignValue)
    }
    appendLine(sb, level, "__seen_${field.name} = true")
}

// A default-constructed mutable class can be populated in place while the
// fast reader walks its object fields.  This avoids one Option allocation per
// non-scalar field and the final temporary-to-object copy, while retaining
// the generic name dispatcher for reordered/unknown input.
private func canUseMutableObjectFastRead(
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>
): Bool {
    if (!params.isEmpty()) { return false }
    var hasField = false
    for (field in fields) {
        if (!field.writeField) { continue }
        hasField = true
        if (!field.mutable || field.isOption || !field.codecExpr.isEmpty()) {
            return false
        }
        if (directScalarCursorFastRead(field).isEmpty() &&
            simpleGeneratedTypeName(field).isEmpty()) {
            return false
        }
    }
    hasField
}

private func appendMutableObjectFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    field: CodecField,
    label: String,
    checkDuplicate: Bool
): Unit {
    let directRead = directScalarCursorFastRead(field)
    let concreteType = simpleGeneratedTypeName(field)
    let readValue = if (!concreteType.isEmpty()) {
        "__yJsonConcrete_${concreteType}.readFastWithCursor(reader, __reader)"
    } else {
        directRead
    }
    if (checkDuplicate) {
        appendLine(sb, level, "if (__seen_${field.name}) { context.pushField(${label}); try { throw JsonException(\"Duplicate JSON field\", code: \"duplicate_key\", path: context.currentPath()) } finally { context.popPath() } }")
    }
    if (directRead.isEmpty() || directFieldNeedsContext(field)) {
        appendLine(sb, level, "context.pushField(${label})")
        appendLine(sb, level, "try { __result.${field.name} = ${readValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, level, "__result.${field.name} = ${readValue}")
    }
    appendLine(sb, level, "__seen_${field.name} = true")
}

private func appendMutableObjectFastRead(
    sb: StringBuilder,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>,
    targetType: String
): Unit {
    let fastReadContext = fastReadNeedsContext(fields)
    appendLine(sb, 2, "let __fastReader = __reader.generatedReaderV1()")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "let __result = ${targetType}()")
    for (field in fields) {
        if (field.writeField) {
            appendLine(sb, 3, "var __seen_${field.name} = false")
        }
    }
    appendLine(sb, 3, "__reader.startRawObject()")
    appendLine(sb, 3, "var __first = true")
    var orderedFieldCount: Int64 = 0
    for (field in fields) {
        if (field.writeField) { orderedFieldCount++ }
    }
    if (orderedFieldCount > 0) {
        appendLine(sb, 3, "while (true) {")
        var canonicalLabelIndex: Int64 = 0
        for (field in fields) {
            if (field.writeField) {
                appendLine(sb, 4, "if (!__reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                appendMutableObjectFastFieldAssignment(sb, 4, field, field.jsonNameExpr, false)
                appendLine(sb, 4, "__first = false")
            }
            canonicalLabelIndex += 1 + field.aliases.size
        }
        appendLine(sb, 4, "break")
        appendLine(sb, 3, "}")
    }
    appendLine(sb, 3, "while (__reader.hasRawObjectField(__first)) {")
    appendLine(sb, 4, "let __nameId = __reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
    appendLine(sb, 4, "match (__nameId) {")
    var labelIndex: Int64 = 0
    for (field in fields) {
        if (!field.writeField) { continue }
        appendLine(sb, 5, "case ${labelIndex} =>")
        appendMutableObjectFastFieldAssignment(sb, 6, field, field.jsonNameExpr, true)
        labelIndex += 1
        for (alias in field.aliases) {
            appendLine(sb, 5, "case ${labelIndex} =>")
            appendMutableObjectFastFieldAssignment(sb, 6, field, alias, true)
            labelIndex += 1
        }
    }
    appendLine(sb, 5, "case _ => __reader.skipValue(context.remainingDepth())")
    appendLine(sb, 4, "}")
    appendLine(sb, 4, "__first = false")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "__reader.endRawObject()")
    for (field in fields) {
        if (field.writeField && fieldIsRequired(field, params)) {
            appendLine(sb, 3, "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: ${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
    appendLine(sb, 3, "return __result")
    appendLine(sb, 2, if (fastReadContext) {
        "} finally { context.leaveValue() }"
    } else {
        "} finally { let _ = context }"
    })
}

private func appendFastCanonicalDecodedResult(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>,
    targetType: String
): Unit {
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption || usesScalarScratch(field)) {
                    args.add("__value_${field.name}")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, level, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption || usesScalarScratch(field)) {
                    appendLine(sb, level, "__result.${field.name} = __value_${field.name}")
                } else {
                    appendLine(sb, level, "__result.${field.name} = __value_${field.name}.getOrThrow()")
                }
            }
        }
        appendLine(sb, level, "return __result")
    } else {
        appendLine(sb, level, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption || usesScalarScratch(field)) {
                appendLine(sb, level, "__result.${field.name} = __value_${field.name}")
            } else {
                appendLine(sb, level, "__result.${field.name} = __value_${field.name}.getOrThrow()")
            }
        }
        appendLine(sb, level, "return __result")
    }
}

private func renderCodec(decl: Decl, body: Body, isClass: Bool): Tokens {
    let name = decl.identifier.value
    let fields = collectFields(body)
    let params = constructorParams(body)
    var inheritedObjectType = ""
    if (isClass) {
        match (decl) {
            case classDecl: ClassDecl =>
                if (!classDecl.superTypes.isEmpty()) {
                    inheritedObjectType = classDecl.superTypes[0].toTokens().toString().trimAscii()
                    for (param in params) {
                        if (fieldByName(fields, param.name).isSome()) { continue }
                        let inner = optionInner(parseType(cangjieLex(param.typeText)))
                        fields.add(CodecField(
                            param.name,
                            param.typeText,
                            "\"${param.name}\"",
                            ArrayList<String>(),
                            false,
                            param.hasDefault,
                            inner.isSome(),
                            inner.getOrDefault({ => "" }),
                            false,
                            "",
                            writeField: false
                        ))
                    }
                }
            case _ => ()
        }
    }
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedConstraints(decl, fields, generics)
    let codecName = "__YJsonCodec_${name}"
    let sb = StringBuilder()
    let fastLabels = ArrayList<(CodecField, String)>()
    let fastLabelBytes = ArrayList<String>()
    for (field in fields) {
        fastLabels.add((field, field.jsonNameExpr))
        fastLabelBytes.add("(${field.jsonNameExpr}).rawData()")
        for (alias in field.aliases) {
            fastLabels.add((field, alias))
            fastLabelBytes.add("(${alias}).rawData()")
        }
    }
    let staticCompact = supportsStaticCompactRawWrite(fields)
    let compactNeedsContext = compactRawNeedsContext(fields)
    var compactHasDirectField = false
    for (field in fields) {
        if (field.writeField && !compactRawScalarFieldWrite(field, "__value", "__first").isEmpty()) {
            compactHasDirectField = true
            break
        }
    }
    let directInterface = if (staticCompact) {
        "GeneratedCompactCursorWriteCodecV1<${targetType}> & " +
            "GeneratedCompactArrayListElementCodecV1<${targetType}>"
    } else {
        "GeneratedDirectWriteCodecV1<${targetType}> & " +
            "GeneratedCursorWriteCodecV1<${targetType}>"
    }
    let codecInterfaces = "GeneratedObjectCodecV1<${targetType}> & " +
        "GeneratedCodecV1<${targetType}> & GeneratedCursorReadCodecV1<${targetType}> & " +
        directInterface
    appendLine(sb, 0, "private class ${codecName}${genericText} <: ${codecInterfaces}${constraints} {")
    for (field in fields) {
        let fullyDirect = !directScalarWrite(field, "__value").isEmpty() &&
            !directScalarRead(field, "reader").isEmpty() &&
            !directScalarFastRead(field, "reader").isEmpty()
        if (!fullyDirect) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${fieldCodecInitializer(field)}")
            if (directScalarCursorFastRead(field).isEmpty()) {
                appendLine(sb, 1, "private let ${cachedFastFieldCodecName(field)}: Option<GeneratedCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __fast: GeneratedCodecV1<${field.typeText}> => Some(__fast); case _ => None<GeneratedCodecV1<${field.typeText}>> }")
                appendLine(sb, 1, "private let ${cachedCursorFastFieldCodecName(field)}: Option<GeneratedCursorReadCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __fast: GeneratedCursorReadCodecV1<${field.typeText}> => Some(__fast); case _ => None<GeneratedCursorReadCodecV1<${field.typeText}>> }")
            }
            if (compactRawScalarFieldWrite(field, "__value", "__first").isEmpty() &&
                directScalarWrite(field, "__value").isEmpty()) {
                appendLine(sb, 1, "private let ${compactRawCodecName(field)}: Option<GeneratedCompactWriteCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __raw: GeneratedCompactWriteCodecV1<${field.typeText}> => Some(__raw); case _ => None<GeneratedCompactWriteCodecV1<${field.typeText}>> }")
                appendLine(sb, 1, "private let ${compactRawCursorCodecName(field)}: Option<GeneratedCursorWriteCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __rawCursor: GeneratedCursorWriteCodecV1<${field.typeText}> => Some(__rawCursor); case _ => None<GeneratedCursorWriteCodecV1<${field.typeText}>> }")
            }
        }
    }
    appendLine(sb, 1, "private let __yJsonFastFieldNames: Array<Array<Byte>> = unsafe { [" +
        joinStrings(fastLabelBytes, ", ") + "] }")
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "match (writer) { case __direct: GeneratedSupportV1Writer => writeDirect(value, __direct); return; case _ => () }")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFields(value, writer)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeObjectFields(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    // Scalar-only records do not otherwise touch the path context. Keep the
    // generated signature uniform without producing consumer build warnings.
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (directWrite.isEmpty()) {
            "${codec}.write(value.${field.name}, writer)"
        } else {
            directWrite
        }
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${writeValue} } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            if (directWrite.isEmpty() || directFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${writeValue} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, writeValue)
            }
        }
    }
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeDirect(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
    appendLine(sb, 2, (if (staticCompact) {
        "if (writer.tryBeginGeneratedCompactRawValue()) { writeCompactRaw(value, writer); return }"
    } else {
        "if (supportsCompactRaw() && writer.tryBeginGeneratedCompactRawValue()) { writeCompactRaw(value, writer); return }"
    }))
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFieldsDirect(value, writer)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "private func writeObjectFieldsDirect(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (directWrite.isEmpty()) {
            "GeneratedSupportV1.writeNested(${codec}, value.${field.name}, writer)"
        } else { directWrite }
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${writeValue} } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            if (directWrite.isEmpty() || directFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${writeValue} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, writeValue)
            }
        }
    }
    appendLine(sb, 1, "}")
    let rawChecks = ArrayList<String>()
        for (field in fields) {
            if (!field.writeField) { continue }
            if (compactRawScalarFieldWrite(field, "__value", "__first").isEmpty() &&
                directScalarWrite(field, "__value").isEmpty()) {
                rawChecks.add("match (${compactRawCursorCodecName(field)}) { " +
                    "case Some(__rawCursor) => __rawCursor.supportsCompactCursorWrite(); " +
                    "case None => match (${compactRawCodecName(field)}) { " +
                    "case Some(__raw) => __raw.supportsCompactRaw(); case None => false } }")
            }
        }
    appendLine(sb, 1, "public func supportsCompactRaw(): Bool { " +
            (if (rawChecks.isEmpty()) { "true" } else { joinStrings(rawChecks, " && ") }) + " }")
    appendLine(sb, 1, "public func writeCompactRaw(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
        appendLine(sb, 2, "writeCompactRawWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))")
    appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func writeCompactRawWithCursor(value: ${targetType}, writer: GeneratedSupportV1Writer, __writer: GeneratedSupportV1WriteCursor): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterValue()")
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "__writer.writeRawBeginObject()")
        appendLine(sb, 3, "var __first = true")
        for (field in fields) {
            if (!field.writeField) { continue }
            let rawWrite = compactRawFieldWrite(field, "value.${field.name}", "__first")
            if (compactRawFieldNeedsContext(field)) {
                appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 3, "try { ${rawWrite} } finally { context.popPath() }")
            } else {
                appendLine(sb, 3, rawWrite)
            }
        }
        appendLine(sb, 3, "__writer.writeRawEndObject()")
        appendLine(sb, 2, "} finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func supportsCompactCursorWrite(): Bool { supportsCompactRaw() }")
    appendLine(sb, 1, "public func writeCompactWithCursor(value: ${targetType}, writer: GeneratedSupportV1Writer, __writer: GeneratedSupportV1WriteCursor): Unit { writeCompactRawWithCursor(value, writer, __writer) }")
    if (staticCompact) {
        var compactNeedsWriterCursor = false
        for (field in fields) {
            if (!field.writeField) { continue }
            let rawWrite = compactRawConcreteFieldWrite(field, "value.${field.name}", "__first")
            if (rawWrite.contains("__rawCursor")) {
                compactNeedsWriterCursor = true
                break
            }
        }
        appendLine(sb, 1, "public func writeCompactRawWithWriter(value: ${targetType}, writer: JsonDirectWriter): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterValue()")
        appendLine(sb, 2, "try {")
        if (compactHasDirectField) {
            appendLine(sb, 2, "let __buffer = writer.generatedBufferV1()")
            let reserveHint = generatedBufferReserveHint(fields, "value")
            if (!reserveHint.isEmpty()) {
                appendLine(sb, 2, "__buffer.reserveCapacity(${reserveHint})")
            } else if (fields.size >= 8) {
                // Wide generated objects otherwise grow the direct buffer in
                // the middle of the field loop.  A bounded per-field hint
                // avoids those reallocations without over-reserving small
                // records or value-heavy arrays/maps.
                appendLine(sb, 2, "__buffer.reserveCapacity(${fields.size * 32 + 2})")
            }
        }
        if (compactNeedsWriterCursor) {
            appendLine(sb, 2, "let __writer = writer.generatedCursorV1()")
        }
        let scalarBufferBatch = generatedBufferAllScalar(fields)
        let containerBufferBatch = generatedBufferAllContainer(fields)
        appendLine(sb, 2, if (scalarBufferBatch || containerBufferBatch) {
            "writer.writeRawBeginObject()"
        } else {
            "writer.writeRawBeginObject()"
        })
        appendLine(sb, 2, "var __first = true")
        for (field in fields) {
            if (!field.writeField) {
                continue
            }
            let rawWrite = compactRawConcreteFieldWrite(field, "value.${field.name}", "__first")
            var concreteRawWrite = rawWrite
            if (scalarBufferBatch) {
                concreteRawWrite = concreteRawWrite
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameStringBuffer(",
                        "writer.writeRawObjectEntryKnownNameStringFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameInt64Buffer(",
                        "__buffer.writeObjectEntryNameInt64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameUInt64Buffer(",
                        "__buffer.writeObjectEntryNameUInt64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameFloat64Buffer(",
                        "__buffer.writeObjectEntryNameFloat64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameBoolBuffer(",
                        "__buffer.writeObjectEntryNameBoolNoEscapeFast("
                    )
            }
            if (containerBufferBatch) {
                concreteRawWrite = concreteRawWrite
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameInt64ArrayBuffer(",
                        "writer.writeRawObjectEntryKnownNameInt64ArrayBuffer("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameInt64MapBuffer(",
                        "writer.writeRawObjectEntryKnownNameInt64MapBuffer("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameInt64ArrayMapBuffer(",
                        "writer.writeRawObjectEntryKnownNameInt64ArrayMapBuffer("
                    )
            }
            if (scalarBufferBatch || containerBufferBatch) {
                // Canonical names are compile-time String literals. Use the
                // String overloads on the concrete target so the hot path can
                // copy the literal's raw bytes directly instead of invoking
                // Array<Byte>.copyTo for every field.
                for (fieldName in fields) {
                    if (fieldName.writeField &&
                        fieldName.jsonNameExpr == "\"${fieldName.name}\"") {
                        concreteRawWrite = concreteRawWrite.replace(
                            generatedKnownNameBytesName(fieldName),
                            fieldName.jsonNameExpr
                        )
                    }
                }
            }
            concreteRawWrite = compactRawDirectWriterRewrite(concreteRawWrite)
            if (compactNeedsContext && compactRawFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${concreteRawWrite} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, concreteRawWrite)
            }
        }
        appendLine(sb, 3, "writer.writeRawEndObject()")
        appendLine(sb, 2, "} finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func writeCompactRawArrayList(value: YJsonArrayList<${targetType}>, writer: GeneratedSupportV1Writer): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterValue()")
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "let __writer = GeneratedSupportV1.writeCursor(writer)")
        appendLine(sb, 3, "__writer.reserveRawCollectionCapacity(value.size)")
        appendLine(sb, 3, "__writer.writeRawBeginArray()")
        appendLine(sb, 3, "if (!value.isEmpty()) {")
        appendLine(sb, 4, "context.pushIndex(0)")
        appendLine(sb, 4, "try {")
        appendLine(sb, 5, "for (__index in 0..value.size) {")
        appendLine(sb, 6, "if (__index > 0) { __writer.writeRawByte(b','); context.updateLastIndex(__index) }")
        appendLine(sb, 6, "writeCompactRawWithCursor(value[__index], writer, __writer)")
        appendLine(sb, 5, "}")
        appendLine(sb, 4, "} finally { context.popPath() }")
        appendLine(sb, 3, "}")
        appendLine(sb, 3, "__writer.writeRawEndArray()")
        appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    }
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    for (field in fields) {
        if (field.isOption) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = None<${field.optionInner}>")
        } else if (let Some(initializer) <- scalarScratchInitializer(field)) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = ${initializer}")
        } else {
            appendLine(sb, 3, "var __value_${field.name}: Option<${field.typeText}> = None<${field.typeText}>")
        }
        appendLine(sb, 3, "var __seen_${field.name} = false")
    }
    appendLine(sb, 3, "reader.startObject()")
    appendLine(sb, 3, "while (reader.hasObjectField()) {")
    appendLine(sb, 4, "let __name = reader.readName()")
    appendLine(sb, 4, "match (__name) {")
    for (field in fields) {
        let codec = fieldCodec(field)
        let directRead = directScalarRead(field, "reader")
        let readValue = if (directRead.isEmpty()) { "${codec}.read(reader)" } else { directRead }
        let labels = ArrayList<String>()
        labels.add(field.jsonNameExpr)
        labels.add(all: field.aliases)
        appendLine(sb, 5, "case " + joinStrings(labels, " | ") + " =>")
        appendLine(sb, 6, "if (__seen_${field.name} && GeneratedSupportV1.readOptions(reader).rejectsDuplicateKeys()) { throw JsonException(\"Duplicate JSON field: \" + __name, code: \"duplicate_key\", path: context.currentPath()) }")
        let assignValue = "__value_${field.name} = " +
            (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
        if (directRead.isEmpty() || directFieldNeedsContext(field)) {
            appendLine(sb, 6, "context.pushField(__name)")
            appendLine(sb, 6, "try { ${assignValue} } finally { context.popPath() }")
        } else {
            appendLine(sb, 6, assignValue)
        }
        appendLine(sb, 6, "__seen_${field.name} = true")
    }
    appendLine(sb, 5, "case _ =>")
    appendLine(sb, 6, "if (GeneratedSupportV1.readOptions(reader).rejectsUnknownFields()) { throw JsonException(\"Unknown JSON field: \" + __name, code: \"unknown_field\", path: context.currentPath()) }")
    appendLine(sb, 6, "reader.skipValue()")
    appendLine(sb, 4, "}")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "reader.endObject()")
    for (field in fields) {
        if (fieldIsRequired(field, params)) {
            appendLine(sb, 3, "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: ${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption) {
                    args.add("__value_${field.name}")
                } else if (usesScalarScratch(field)) {
                    if (param.hasDefault) {
                        args.add("if (__seen_${field.name}) { __value_${field.name} } else { ${param.defaultExpr} }")
                    } else {
                        args.add("__value_${field.name}")
                    }
                } else if (param.hasDefault) {
                    args.add("if (__seen_${field.name}) { __value_${field.name}.getOrThrow() } else { ${param.defaultExpr} }")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, 3, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
                else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
                else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
            }
        }
        appendLine(sb, 3, "return __result")
    } else {
        appendLine(sb, 3, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
            else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
            else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
        }
        appendLine(sb, 3, "return __result")
    }
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")

    // The fast reader is generated against the versioned v1 support protocol,
    // never a concrete core reader class.
    let fastReadContext = fastReadNeedsContext(fields)
    let mutableObjectFastRead = canUseMutableObjectFastRead(fields, params)
    appendLine(sb, 1, "public func readFast(reader: GeneratedSupportV1Reader): ${targetType} {")
    appendLine(sb, 2, "readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func readFastWithCursor(reader: GeneratedSupportV1Reader, __reader: GeneratedSupportV1ReadCursor): ${targetType} {")
    if (mutableObjectFastRead) {
        appendLine(sb, 2, "return readFastMutableObjectWithCursor(reader, __reader)")
    } else {
    appendLine(sb, 2, "let __fastReader = __reader.generatedReaderV1()")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    for (field in fields) {
        if (field.isOption) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = None<${field.optionInner}>")
        } else if (let Some(initializer) <- scalarScratchInitializer(field)) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = ${initializer}")
        } else {
            appendLine(sb, 3, "var __value_${field.name}: Option<${field.typeText}> = None<${field.typeText}>")
        }
        appendLine(sb, 3, "var __seen_${field.name} = false")
    }
    appendLine(sb, 3, "__reader.startRawObject()")
    appendLine(sb, 3, "var __first = true")
    var orderedFieldCount: Int64 = 0
    var lastOrderedFieldName = ""
    var hasPostConstructorField = false
    for (field in fields) {
        if (field.writeField) {
            orderedFieldCount++
            lastOrderedFieldName = field.name
            if (field.mutable && constructorParamByName(params, field.name).isNone()) {
                hasPostConstructorField = true
            }
        }
    }
    if (orderedFieldCount > 0) {
        appendLine(sb, 3, "while (true) {")
        var canonicalLabelIndex: Int64 = 0
        for (field in fields) {
            if (field.writeField) {
                appendLine(sb, 4, "if (!__reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                appendFastFieldAssignment(sb, 4, field, field.jsonNameExpr, false)
                appendLine(sb, 4, "__first = false")
            }
            canonicalLabelIndex += 1 + field.aliases.size
        }
        appendLine(sb, 4, "break")
        appendLine(sb, 3, "}")
        if (orderedFieldCount >= 3 && orderedFieldCount == fields.size && hasPostConstructorField) {
            appendLine(sb, 3, "if (__seen_${lastOrderedFieldName} && !__reader.hasRawObjectField(__first)) {")
            appendLine(sb, 4, "__reader.endRawObject()")
            appendFastCanonicalDecodedResult(sb, 4, fields, params, targetType)
            appendLine(sb, 3, "}")
        }
    }
    appendLine(sb, 3, "while (__reader.hasRawObjectField(__first)) {")
    appendLine(sb, 4, "let __nameId = __reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
    appendLine(sb, 4, "match (__nameId) {")
    for (labelIndex in 0..fastLabels.size) {
        let (field, label) = fastLabels[labelIndex]
        appendLine(sb, 5, "case ${labelIndex} =>")
        appendFastFieldAssignment(sb, 6, field, label, true)
    }
    appendLine(sb, 5, "case _ => __reader.skipValue(context.remainingDepth())")
    appendLine(sb, 4, "}")
    appendLine(sb, 4, "__first = false")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "__reader.endRawObject()")
    for (field in fields) {
        if (fieldIsRequired(field, params)) {
            appendLine(sb, 3, "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: ${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption) {
                    args.add("__value_${field.name}")
                } else if (usesScalarScratch(field)) {
                    if (param.hasDefault) {
                        args.add("if (__seen_${field.name}) { __value_${field.name} } else { ${param.defaultExpr} }")
                    } else {
                        args.add("__value_${field.name}")
                    }
                } else if (param.hasDefault) {
                    args.add("if (__seen_${field.name}) { __value_${field.name}.getOrThrow() } else { ${param.defaultExpr} }")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, 3, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
                else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
                else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
            }
        }
        appendLine(sb, 3, "return __result")
    } else {
        appendLine(sb, 3, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
            else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
            else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
        }
        appendLine(sb, 3, "return __result")
    }
    appendLine(sb, 2, if (fastReadContext) {
        "} finally { context.leaveValue() }"
    } else {
        // Keep the generated exception-safe shape valid without paying the
        // semantic enter/leave work for scalar-only objects.
        "} finally { let _ = context }"
    })
    }
    appendLine(sb, 1, "}")
    if (mutableObjectFastRead) {
        appendLine(sb, 1, "private func readFastMutableObjectWithCursor(reader: GeneratedSupportV1Reader, __reader: GeneratedSupportV1ReadCursor): ${targetType} {")
        appendMutableObjectFastRead(sb, fields, params, targetType)
        appendLine(sb, 1, "}")
    }
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    let canProvideCodec = !hasModifier(decl, TokenKind.OPEN) &&
        !hasModifier(decl, TokenKind.ABSTRACT)
    let canProvideCompact = staticCompact && inheritedObjectType.isEmpty()
    let exposedCodecType = if (staticCompact && inheritedObjectType.isEmpty()) {
        "GeneratedCompactCursorWriteCodecV1<${targetType}>"
    } else {
        "JsonCodec<${targetType}>"
    }
    let completeCodecName = "__YJsonCompleteCodec_${name}"
    if (canProvideCodec && !inheritedObjectType.isEmpty()) {
        appendLine(sb, 0, "private class ${completeCodecName}${genericText} <: JsonCodec<${targetType}>${constraints} {")
        appendLine(sb, 1, "private let own: GeneratedObjectCodecV1<${targetType}>")
        appendLine(sb, 1, "init(own: GeneratedObjectCodecV1<${targetType}>) { this.own = own }")
        appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterObject(value)")
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "writer.startObject()")
        appendLine(sb, 3, "generatedObjectCodecV1Of<${inheritedObjectType}>().writeObjectFields(value, writer)")
        appendLine(sb, 3, "own.writeObjectFields(value, writer)")
        appendLine(sb, 3, "writer.endObject()")
        appendLine(sb, 2, "} finally { context.leaveObject() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} { own.read(reader) }")
        appendLine(sb, 0, "}")
    }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "private let __yJsonConcrete_${name} = ${codecName}()")
        if (canProvideCodec && !inheritedObjectType.isEmpty()) {
            appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${completeCodecName}(__yJsonConcrete_${name})")
        } else {
            appendLine(sb, 0, "${visibility}let ${name}Json: ${exposedCodecType} = __yJsonConcrete_${name}")
        }
        if (canProvideCodec) {
            let compactProvider = if (canProvideCompact) {
                " & GeneratedCompactCodecProviderV1<${name}>"
            } else { "" }
            appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> & GeneratedObjectCodecProviderV1<${name}>${compactProvider} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); __yJsonConcrete_${name} }")
            if (canProvideCompact) {
                appendLine(sb, 1, "public static func generatedCompactRawV1(value: ${name}, writer: JsonDirectWriter): Unit { GeneratedSupportV1.enterGeneratedEntry(); __yJsonConcrete_${name}.writeCompactRawWithWriter(value, writer) }")
            }
            appendLine(sb, 0, "}")
            if (canProvideCompact) {
                // Keep the hot explicit-codec call monomorphic at the call site.
                // The generic YJson overload has to resolve a type-constrained
                // static provider through runtime type metadata on every call;
                // this exact-value overload lets Cangjie select the compact
                // codec overload before entering the generic implementation.
                appendLine(sb, 0, "extend YJson {")
                appendLine(sb, 1, "public static func toJson(value: ${name}, codec!: GeneratedCompactCursorWriteCodecV1<${name}>, options!: JsonWriteOptions = JsonWriteOptions.defaults): String {")
                appendLine(sb, 2, "GeneratedSupportV1.enterGeneratedEntry()")
                appendLine(sb, 2, "let writer = YJson.acquireGeneratedCompactStringWriter(options)")
                appendLine(sb, 2, "try {")
                appendLine(sb, 3, "if (writer.tryBeginGeneratedCompactRawValue()) {")
                // The generated public codec is an interface-typed global. On
                // the compact path, dispatch through the concrete codec
                // directly and leave the supplied codec for the semantic
                // fallback below.
                appendLine(sb, 4, "__yJsonConcrete_${name}.writeCompactRawWithWriter(value, writer)")
                appendLine(sb, 4, "return writer.finishGeneratedCompactString()")
                appendLine(sb, 3, "}")
                appendLine(sb, 3, "codec.write(value, writer)")
                appendLine(sb, 3, "writer.finishString()")
                appendLine(sb, 2, "} finally { YJson.releaseGeneratedCompactStringWriter(writer) }")
                appendLine(sb, 1, "}")
                appendLine(sb, 1, "public static func fromJson(text: String, codec!: GeneratedCompactCursorWriteCodecV1<${name}>, options!: JsonReadOptions = JsonReadOptions.defaults): ${name} {")
                appendLine(sb, 2, "GeneratedSupportV1.enterGeneratedEntry()")
                appendLine(sb, 2, "if (GeneratedSupportV1.usesDefaultFastReadOptions(options)) {")
                appendLine(sb, 3, "let reader = JsonFastReader(text)")
                // Match the encode fast path: avoid the interface method-table
                // lookup for the generated global codec on the default reader.
                appendLine(sb, 3, "let result = __yJsonConcrete_${name}.readFast(reader)")
                appendLine(sb, 3, "reader.expectEnd()")
                appendLine(sb, 3, "return result")
                appendLine(sb, 2, "}")
                appendLine(sb, 2, "let reader = GeneratedSupportV1.newSemanticReader(text, options)")
                appendLine(sb, 2, "let result = codec.read(reader)")
                appendLine(sb, 2, "GeneratedSupportV1.finishReader(reader)")
                appendLine(sb, 2, "result")
                appendLine(sb, 1, "}")
                appendLine(sb, 0, "}")
            }
        } else {
            appendLine(sb, 0, "extend ${name} <: GeneratedObjectCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); __yJsonConcrete_${name} }")
            appendLine(sb, 0, "}")
        }
    } else {
        if (canProvideCodec && !inheritedObjectType.isEmpty()) {
            appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { let own = ${codecName}${genericText}(); ${completeCodecName}${genericText}(own) }")
        } else {
            appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): ${exposedCodecType}${constraints} { ${codecName}${genericText}() }")
        }
        if (canProvideCodec) {
            let compactProvider = if (canProvideCompact) {
                " & GeneratedCompactCodecProviderV1<${targetType}>"
            } else { "" }
            appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}> & GeneratedObjectCodecProviderV1<${targetType}>${compactProvider}${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
            if (canProvideCompact) {
                appendLine(sb, 1, "public static func generatedCompactRawV1(value: ${targetType}, writer: JsonDirectWriter): Unit { GeneratedSupportV1.enterGeneratedEntry(); ${codecName}${genericText}().writeCompactRawWithWriter(value, writer) }")
            }
            appendLine(sb, 0, "}")
        } else {
            appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedObjectCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
            appendLine(sb, 0, "}")
        }
    }
    cangjieLex(sb.toString())
}

private func enumWireName(constructor: Constructor): String {
    let names = constructorAnnotationArguments(constructor, "JsonName")
    if (names.size > 1) {
        throw Exception("enum constructor `${constructor.identifier.value}` has multiple @JsonName annotations")
    }
    if (names.isEmpty()) { "\"${constructor.identifier.value}\"" } else { names[0] }
}

private func renderEnumCodec(decl: EnumDecl): Tokens {
    let name = decl.identifier.value
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedEnumConstraints(decl, generics)
    let codecName = "__YJsonCodec_${name}"
    let seenNames = HashSet<String>()
    for (constructor in decl.constructors) {
        let wireName = enumWireName(constructor)
        if (seenNames.contains(wireName)) { throw Exception("duplicate enum JSON name ${wireName}") }
        seenNames.add(wireName)
    }

    let sb = StringBuilder()
    appendLine(sb, 0, "private class ${codecName}${genericText} <: GeneratedCodecV1<${targetType}> & GeneratedCursorReadCodecV1<${targetType}> & GeneratedCursorWriteCodecV1<${targetType}>${constraints} {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        for (index in 0..constructor.typeArguments.size) {
            let typeText = constructor.typeArguments[index].toTokens().toString().trimAscii()
            let codecField = "__yJsonEnumCodec_${constructorName}_${index}"
            appendLine(sb, 1, "private let ${codecField}: JsonCodec<${typeText}> = generatedCodecV1Of<${typeText}>()")
            appendLine(sb, 1, "private let ${codecField}CursorRead: Option<GeneratedCursorReadCodecV1<${typeText}>> = match (${codecField}) { case __cursor: GeneratedCursorReadCodecV1<${typeText}> => Some(__cursor); case _ => None<GeneratedCursorReadCodecV1<${typeText}>> }")
            appendLine(sb, 1, "private let ${codecField}FastRead: Option<GeneratedCodecV1<${typeText}>> = match (${codecField}) { case __fast: GeneratedCodecV1<${typeText}> => Some(__fast); case _ => None<GeneratedCodecV1<${typeText}>> }")
            appendLine(sb, 1, "private let ${codecField}CursorWrite: Option<GeneratedCursorWriteCodecV1<${typeText}>> = match (${codecField}) { case __cursor: GeneratedCursorWriteCodecV1<${typeText}> => Some(__cursor); case _ => None<GeneratedCursorWriteCodecV1<${typeText}>> }")
        }
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "match (value) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        let bindings = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) { bindings.add("__item${index}") }
        let pattern = if (bindings.isEmpty()) {
            "${name}.${constructorName}"
        } else {
            "${name}.${constructorName}(" + joinStrings(bindings, ", ") + ")"
        }
        appendLine(sb, 4, "case ${pattern} =>")
        appendLine(sb, 5, "writer.startArray()")
        appendLine(sb, 5, "writer.writeString(${enumWireName(constructor)})")
        for (index in 0..constructor.typeArguments.size) {
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "try { __yJsonEnumCodec_${constructorName}_${index}.write(__item${index}, writer) } finally { context.popPath() }")
        }
        appendLine(sb, 5, "writer.endArray()")
    }
    appendLine(sb, 3, "}")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    let enumWriteChecks = ArrayList<String>()
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        for (index in 0..constructor.typeArguments.size) {
            enumWriteChecks.add("match (__yJsonEnumCodec_${constructorName}_${index}CursorWrite) { case Some(__cursor) => __cursor.supportsCompactCursorWrite(); case None => false }")
        }
    }
    appendLine(sb, 1, "public func supportsCompactCursorWrite(): Bool { " +
        (if (enumWriteChecks.isEmpty()) { "true" } else { joinStrings(enumWriteChecks, " && ") }) + " }")
    appendLine(sb, 1, "public func writeCompactWithCursor(value: ${targetType}, writer: GeneratedSupportV1Writer, __writer: GeneratedSupportV1WriteCursor): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "__writer.writeRawBeginArray()")
    appendLine(sb, 3, "match (value) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        let bindings = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) { bindings.add("__item${index}") }
        let pattern = if (bindings.isEmpty()) { "${name}.${constructorName}" } else {
            "${name}.${constructorName}(" + joinStrings(bindings, ", ") + ")"
        }
        appendLine(sb, 4, "case ${pattern} =>")
        appendLine(sb, 5, "__writer.writeRawString(${enumWireName(constructor)})")
        for (index in 0..constructor.typeArguments.size) {
            appendLine(sb, 5, "__writer.writeRawByte(b',')")
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "try { __yJsonEnumCodec_${constructorName}_${index}CursorWrite.getOrThrow().writeCompactWithCursor(__item${index}, writer, __writer) } finally { context.popPath() }")
        }
    }
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "__writer.writeRawEndArray()")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "reader.startArray()")
    appendLine(sb, 3, "if (!reader.hasArrayItem()) { throw JsonException(\"Enum array must start with a case name\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "let __caseName = reader.readString()")
    appendLine(sb, 3, "let __result = match (__caseName) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        appendLine(sb, 4, "case ${enumWireName(constructor)} =>")
        let values = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) {
            appendLine(sb, 5, "if (!reader.hasArrayItem()) { throw JsonException(\"Missing enum payload at index ${index}\", code: \"invalid_enum\", path: context.currentPath()) }")
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "let __item${index} = try { __yJsonEnumCodec_${constructorName}_${index}.read(reader) } finally { context.popPath() }")
            values.add("__item${index}")
        }
        appendLine(sb, 5, "${targetType}.${constructorName}" + (if (values.isEmpty()) { "" } else { "(" + joinStrings(values, ", ") + ")" }))
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unknown enum case: \" + __caseName, code: \"unknown_enum_case\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "if (reader.hasArrayItem()) { throw JsonException(\"Too many enum payload values\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "reader.endArray()")
    appendLine(sb, 3, "__result")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func readFast(reader: GeneratedSupportV1Reader): ${targetType} { readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader)) }")
    appendLine(sb, 1, "public func readFastWithCursor(reader: GeneratedSupportV1Reader, __reader: GeneratedSupportV1ReadCursor): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "__reader.startRawArray()")
    appendLine(sb, 3, "if (!__reader.hasRawArrayItem(true)) { throw JsonException(\"Enum array must start with a case name\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "__reader.beforeRawArrayItem(true)")
    appendLine(sb, 3, "let __caseName = __reader.readRawString()")
    appendLine(sb, 3, "let __result = match (__caseName) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        appendLine(sb, 4, "case ${enumWireName(constructor)} =>")
        let values = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) {
            appendLine(sb, 5, "if (!__reader.hasRawArrayItem(false)) { throw JsonException(\"Missing enum payload at index ${index}\", code: \"invalid_enum\", path: context.currentPath()) }")
            appendLine(sb, 5, "__reader.beforeRawArrayItem(false)")
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "let __item${index} = try { GeneratedSupportV1.readWithCursorCached(__yJsonEnumCodec_${constructorName}_${index}CursorRead, __yJsonEnumCodec_${constructorName}_${index}FastRead, __yJsonEnumCodec_${constructorName}_${index}, reader, __reader) } finally { context.popPath() }")
            values.add("__item${index}")
        }
        appendLine(sb, 5, "${targetType}.${constructorName}" + (if (values.isEmpty()) { "" } else { "(" + joinStrings(values, ", ") + ")" }))
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unknown enum case: \" + __caseName, code: \"unknown_enum_case\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "if (__reader.hasRawArrayItem(false)) { throw JsonException(\"Too many enum payload values\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "__reader.endRawArray()")
    appendLine(sb, 3, "__result")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${codecName}()")
        appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
        appendLine(sb, 0, "}")
    }
    cangjieLex(sb.toString())
}

private func renderPolymorphicCodec(
    decl: ClassDecl,
    wrappedSubtypeExpressions: ArrayList<String>,
    wrappedDiscriminatorArguments: ArrayList<String>
): Tokens {
    let name = decl.identifier.value
    let fields = collectFields(decl.body)
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedConstraints(decl, fields, generics)
    let codecName = "__YJsonCodec_${name}"
    let discriminatorArgs = annotationArguments(decl, "JsonPolymorphic")
    discriminatorArgs.add(all: wrappedDiscriminatorArguments)
    let discriminator = if (discriminatorArgs.isEmpty()) { "\"type\"" } else { namedArgumentValue(discriminatorArgs[0]) }
    let subtypes = ArrayList<PolymorphicSubtype>()
    let seenWireNames = HashSet<String>()
    let encodedSubtypes = annotationArguments(decl, "JsonSubtypeMetadata")
    encodedSubtypes.add(all: wrappedSubtypeExpressions)
    for (encoded in encodedSubtypes) {
        let subtype = parseSubtypeExpression(encoded)
        if (seenWireNames.contains(subtype.wireNameExpr)) {
            throw Exception("duplicate polymorphic discriminator ${subtype.wireNameExpr}")
        }
        seenWireNames.add(subtype.wireNameExpr)
        subtypes.add(subtype)
    }
    if (subtypes.isEmpty()) {
        throw Exception("@JsonPolymorphic requires at least one @JsonSubtype[wireName, ConcreteType]")
    }
    for (field in fields) {
        if (field.jsonNameExpr == discriminator) {
            throw Exception("polymorphic discriminator conflicts with JSON field ${discriminator}")
        }
    }

    let sb = StringBuilder()
    appendLine(sb, 0, "private class ${codecName}${genericText} <: GeneratedObjectCodecV1<${targetType}>${constraints} {")
    for (field in fields) {
        appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${fieldCodecInitializer(field)}")
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "context.enterObject(value)")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "match (value) {")
    for (subtype in subtypes) {
        appendLine(sb, 4, "case __subtype: ${subtype.typeText} =>")
        appendLine(sb, 5, "writer.writeName(${discriminator})")
        appendLine(sb, 5, "writer.writeString(${subtype.wireNameExpr})")
        for (field in fields) {
            let codec = fieldCodec(field)
            if (field.isOption && !field.includeNull) {
                appendLine(sb, 5, "if (value.${field.name}.isSome()) {")
                appendLine(sb, 6, "writer.writeName(${field.jsonNameExpr})")
                appendLine(sb, 6, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 6, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
                appendLine(sb, 5, "}")
            } else {
                appendLine(sb, 5, "writer.writeName(${field.jsonNameExpr})")
                appendLine(sb, 5, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 5, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
            }
        }
        appendLine(sb, 5, "generatedObjectCodecV1Of<${subtype.typeText}>().writeObjectFields(__subtype, writer)")
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unregistered runtime subtype for ${name}\", code: \"unknown_runtime_subtype\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, "} finally { context.leaveObject() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeObjectFields(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        let codec = fieldCodec(field)
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 2, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
        }
    }
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    // The subtype codec owns the one GeneratedReadStateV1 container entry for the
    // replayed root object. The polymorphic dispatcher only selects that codec;
    // charging the same object here would make maxDepth=1 reject scalar fields.
    appendLine(sb, 2, "let __replay = GeneratedSupportV1.captureValue(reader, GeneratedSupportV1.readOptions(reader).maxBufferedValueBytes)")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "let __tag = __replay.rootStringField(${discriminator}).getOrThrow({ => JsonException(\"Missing polymorphic discriminator\", code: \"missing_discriminator\", path: context.currentPath()) })")
    appendLine(sb, 3, "match (__tag) {")
    for (subtype in subtypes) {
        appendLine(sb, 4, "case ${subtype.wireNameExpr} =>")
        appendLine(sb, 5, "let __subtypeReader = __replay.openObjectReaderExcluding(${discriminator})")
        appendLine(sb, 5, "let __result: ${targetType} = generatedObjectCodecV1Of<${subtype.typeText}>().read(__subtypeReader)")
        appendLine(sb, 5, "GeneratedSupportV1.finishReader(__subtypeReader)")
        appendLine(sb, 5, "__result")
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unknown polymorphic discriminator: \" + __tag, code: \"unknown_discriminator\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 2, "} finally { __replay.close() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${codecName}()")
        appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> & GeneratedObjectCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}() }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}> & GeneratedObjectCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
        appendLine(sb, 0, "}")
    }
    cangjieLex(sb.toString())
}

public macro JsonCodec(input: Tokens): Tokens {
    var decl = parseDecl(input)
    let wrappedSubtypeExpressions = ArrayList<String>()
    let wrappedDiscriminatorArguments = ArrayList<String>()
    var polymorphic = false
    while (let Some(wrapper) <- (decl as MacroExpandDecl)) {
        let wrapperName = wrapper.identifier.value
        if (wrapperName == "JsonPolymorphic") {
            polymorphic = true
            if (wrapper.macroAttrs.size != 0) {
                addUnique(wrappedDiscriminatorArguments, wrapper.macroAttrs.toString().trimAscii())
            }
        }
        if (wrapperName == "JsonSubtype" || wrapperName == "JsonSubtypeMetadata") {
            if (wrapper.macroAttrs.size != 0) {
                addUnique(wrappedSubtypeExpressions, wrapper.macroAttrs.toString().trimAscii())
            }
        }
        if (hasAnnotation(wrapper, "JsonPolymorphic")) {
            polymorphic = true
            for (argument in annotationArguments(wrapper, "JsonPolymorphic")) {
                addUnique(wrappedDiscriminatorArguments, argument)
            }
        }
        for (argument in annotationArguments(wrapper, "JsonSubtypeMetadata")) {
            addUnique(wrappedSubtypeExpressions, argument)
        }
        decl = wrapper.macroInputDecl
    }
    let generated = match (decl) {
        case classDecl: ClassDecl =>
            if (polymorphic || !wrappedSubtypeExpressions.isEmpty() || hasAnnotation(classDecl, "JsonSubtypeMetadata") || hasAnnotation(classDecl, "JsonPolymorphic")) {
                renderPolymorphicCodec(classDecl, wrappedSubtypeExpressions, wrappedDiscriminatorArguments)
            } else {
                renderCodec(classDecl, classDecl.body, true)
            }
        case structDecl: StructDecl => renderCodec(structDecl, structDecl.body, false)
        case enumDecl: EnumDecl => renderEnumCodec(enumDecl)
        case _ => throw Exception("@JsonCodec supports class, struct, and enum declarations")
    }
    input + Token(TokenKind.NL).toTokens() + generated
}

public macro JsonUsing(attrs: Tokens, input: Tokens): Tokens {
    let expression = Token(TokenKind.STRING_LITERAL, attrs.toString().trimAscii())
    quote(
        @JsonUsingMetadata[$expression]
        $input
    )
}

public macro JsonSubtype(attrs: Tokens, input: Tokens): Tokens {
    let expression = Token(TokenKind.STRING_LITERAL, attrs.toString().trimAscii())
    quote(
        @JsonSubtypeMetadata[$expression]
        $input
    )
}
