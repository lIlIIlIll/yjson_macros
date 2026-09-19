macro package yjson_macros

import std.ast.*
import std.collection.*

internal func joinStrings(values: ArrayList<String>, separator: String): String {
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

internal func renderedConstraints(decl: Decl, fields: ArrayList<CodecField>, generics: ArrayList<String>): String {
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


// A non-generic user model emitted by @JsonCodec owns a private concrete
// codec global with the same source-level name.  Keep this deliberately
// narrow: container/builtin/custom-codec fields must continue through their
// cached protocol codec because no generated concrete global is guaranteed
// for them.
private func simpleGeneratedTypeName(
    field: CodecField,
    genericNames: ArrayList<String>
): String {
    field.capabilities.generatedConcreteType(genericNames)
}

private func fieldCodec(field: CodecField): String {
    cachedFieldCodecName(field)
}

private func fieldCodecInitializer(field: CodecField): String {
    if (field.codecExpr.isEmpty()) { defaultFieldCodec(field.typeText) } else { "(${field.codecExpr})" }
}

private func directScalarWrite(field: CodecField, value: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    let primitiveWrite = match (field.capabilities.typeShape.primitive) {
        case PrimitiveFieldKind.BoolValue => "writer.writeBool(${value})"
        case PrimitiveFieldKind.Int64Value => "writer.writeInt64(${value})"
        case PrimitiveFieldKind.Int32Value | PrimitiveFieldKind.Int16Value |
             PrimitiveFieldKind.Int8Value => "writer.writeInt64(Int64(${value}))"
        case PrimitiveFieldKind.UInt64Value => "writer.writeUInt64(${value})"
        case PrimitiveFieldKind.UInt32Value | PrimitiveFieldKind.UInt16Value |
             PrimitiveFieldKind.UInt8Value => "writer.writeUInt64(UInt64(${value}))"
        case PrimitiveFieldKind.Float64Value => "writer.writeFloat64(${value})"
        case PrimitiveFieldKind.Float32Value | PrimitiveFieldKind.Float16Value =>
            "writer.writeFloat64(Float64(${value}))"
        case PrimitiveFieldKind.StringValue => "writer.writeString(${value})"
        case _ => ""
    }
    if (!primitiveWrite.isEmpty()) { return primitiveWrite }
    match (field.capabilities.typeShape.normalized) {
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

private func compactRawSpecializedFieldWrite(
    field: CodecField,
    value: String,
    first: String
): String {
    let plan = FieldWritePlan(field)
    let scalar = renderCompactCursorScalarField(plan, value, first)
    if (!scalar.isEmpty()) { return scalar }
    let container = renderCompactCursorContainerField(plan, value, first)
    if (!container.isEmpty()) { return container }
    ""
}

private func compactRawFieldWrite(field: CodecField, value: String, first: String): String {
    let specialized = compactRawSpecializedFieldWrite(field, value, first)
    if (!specialized.isEmpty()) { return specialized }
    renderCompactCursorCodecField(FieldWritePlan(field), value, first)
}

private func compactRawConcreteFieldWrite(
    field: CodecField,
    value: String,
    first: String,
    genericNames: ArrayList<String>
): String {
    let plan = FieldWritePlan(field)
    let scalar = renderCompactDirectScalarField(plan, value, first, false)
    if (!scalar.isEmpty()) {
        return scalar
    }
    let container = renderCompactDirectContainerField(plan, value, first)
    if (!container.isEmpty()) {
        return container
    }
    if (!field.codecExpr.isEmpty() || field.isOption) {
        return renderCompactDirectCodecField(plan, value, first, "__writer")
    }
    let concreteType = simpleGeneratedTypeName(field, genericNames)
    if (!concreteType.isEmpty()) {
        return renderCompactDirectConcreteField(plan, value, first, concreteType)
    }
    renderCompactDirectCodecField(
        plan, value, first, "GeneratedSupportV1.writeCursor(writer)")
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

private func compactRawFieldNeedsContext(
    field: CodecField,
    genericNames: ArrayList<String>
): Bool {
    !field.codecExpr.isEmpty() || field.isOption ||
        !simpleGeneratedTypeName(field, genericNames).isEmpty()
}


// Compile-time reserve terms cover value shapes with local deterministic
// bounds. Runtime-sized values remain as a short dynamic term list, while
// non-literal names use the general exact-expression fallback.
private func generatedBufferReserveTerm(field: CodecField, value: String): String {
    if (!field.writeField || !field.codecExpr.isEmpty() || field.isOption) { return "" }
    let name = "(${field.jsonNameExpr}).size"
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${name} + 8"
        case "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" => "${name} + 24"
        case "Float16" | "Float32" | "Float64" => "${name} + 44"
        // General fallback retains the runtime value-length term when a
        // field name cannot be folded above.
        case "String" => "${name} + ${value}.size + 8"
        case _ => ""
    }
}

// Fold static field names and fixed-width bounds at macro expansion time.
// String values remain the only runtime terms for the common literal-name
// shape; non-literal names retain the general exact expression below.
private func generatedBufferReserveHint(fields: ArrayList<CodecField>, valuePrefix: String): String {
    var fixedReserve: Int64 = 2
    let dynamicTerms = ArrayList<String>()
    var canFold = true
    for (field in fields) {
        if (!field.writeField) { continue }
        if (!field.codecExpr.isEmpty() || field.isOption ||
            field.jsonNameExpr != "\"${field.name}\"") {
            canFold = false
            continue
        }
        let nameSize = field.name.size
        match (field.typeText.replace(" ", "")) {
            case "Bool" => fixedReserve += nameSize + 8
            case "Int8" | "Int16" | "Int32" | "Int64" |
                 "UInt8" | "UInt16" | "UInt32" | "UInt64" =>
                fixedReserve += nameSize + 24
            case "Float16" | "Float32" | "Float64" =>
                fixedReserve += nameSize + 44
            case "String" =>
                fixedReserve += nameSize + 8
                dynamicTerms.add("${valuePrefix}.${field.name}.size")
            case _ => canFold = false
        }
    }
    if (canFold) {
        if (dynamicTerms.isEmpty()) { return "${fixedReserve}" }
        return "${fixedReserve} + " + joinStrings(dynamicTerms, " + ")
    }
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
        if (field.jsonNameExpr != "\"${field.name}\"") { return false }
        if (!FieldWritePlan(field).supportsScalarBatch()) { return false }
    }
    hasField
}


internal func scalarScratchInitializer(field: CodecField): Option<String> {
    field.capabilities.scalarScratchInitializer()
}

internal func usesScalarScratch(field: CodecField): Bool {
    scalarScratchInitializer(field).isSome()
}

internal func genericDecl(generics: ArrayList<String>): String {
    if (generics.isEmpty()) { return "" }
    "<" + joinStrings(generics, ", ") + ">"
}

internal func appendLine(sb: StringBuilder, level: Int64, value: String): Unit {
    for (_ in 0..level) { sb.append("    ") }
    sb.append(value)
    sb.append(r'\n')
}

private func appendPreparedFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    plan: FieldReadPlan,
    label: String,
    checkDuplicate: Bool,
    needsContext: Bool,
    readValue: String
): Unit {
    let field = plan.field
    let assignValue = "__value_${field.name} = " +
        (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
    if (checkDuplicate) {
        appendLine(sb, level, "if (__seen_${field.name}) { context.pushField(${label}); try { throw JsonException(\"Duplicate JSON field\", code: \"duplicate_key\", path: context.currentPath()) } finally { context.popPath() } }")
    }
    if (needsContext) {
        appendLine(sb, level, "context.pushField(${label})")
        appendLine(sb, level, "try { ${assignValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, level, assignValue)
    }
    appendLine(sb, level, "__seen_${field.name} = true")
}

private func appendFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    plan: FieldReadPlan,
    label: String,
    checkDuplicate: Bool
): Unit {
    let field = plan.field
    let codec = fieldCodec(field)
    let directRead = plan.cursorFastRead()
    let readValue = if (directRead.isEmpty()) {
        "GeneratedSupportV1.readWithCursorCached(${cachedCursorFastFieldCodecName(field)}, " +
            "${cachedFastFieldCodecName(field)}, ${codec}, reader, __reader)"
    } else {
        directRead
    }
    appendPreparedFieldAssignment(
        sb, level, plan, label, checkDuplicate, plan.cursorFastNeedsContext, readValue)
}

private func directFastReadNeedsContext(readPlans: ArrayList<FieldReadPlan>): Bool {
    for (plan in readPlans) {
        if (plan.field.writeField && plan.directFastNeedsContext) { return true }
    }
    false
}

private func cursorFastReadNeedsContext(readPlans: ArrayList<FieldReadPlan>): Bool {
    for (plan in readPlans) {
        if (plan.field.writeField && plan.cursorFastNeedsContext) { return true }
    }
    false
}

private func appendDirectFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    plan: FieldReadPlan,
    label: String,
    checkDuplicate: Bool,
    fastReaderName: String
): Unit {
    let field = plan.field
    let codec = fieldCodec(field)
    let directRead = plan.directFastRead(fastReaderName)
    let readValue = if (directRead.isEmpty()) {
        "GeneratedSupportV1.readWithCached(${cachedFastFieldCodecName(field)}, ${codec}, reader)"
    } else {
        directRead
    }
    appendPreparedFieldAssignment(
        sb, level, plan, label, checkDuplicate, plan.directFastNeedsContext, readValue)
}

// A default-constructed mutable class can be populated in place while the
// fast reader walks its object fields.  This avoids one Option allocation per
// non-scalar field and the final temporary-to-object copy, while retaining
// the generic name dispatcher for reordered/unknown input.
private func canUseMutableObjectFastRead(
    readPlans: ArrayList<FieldReadPlan>,
    params: ArrayList<CodecConstructorParam>,
    genericNames: ArrayList<String>
): Bool {
    if (!params.isEmpty()) { return false }
    var hasField = false
    for (plan in readPlans) {
        let field = plan.field
        if (!field.writeField) { continue }
        hasField = true
        if (!field.mutable || field.isOption || !field.codecExpr.isEmpty()) {
            return false
        }
        if (plan.needsCursorFastCodec &&
            simpleGeneratedTypeName(field, genericNames).isEmpty()) {
            return false
        }
    }
    hasField
}

private func appendMutableObjectFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    plan: FieldReadPlan,
    label: String,
    checkDuplicate: Bool,
    genericNames: ArrayList<String>
): Unit {
    let field = plan.field
    let directRead = plan.cursorFastRead()
    let concreteType = simpleGeneratedTypeName(field, genericNames)
    let readValue = if (!concreteType.isEmpty()) {
        "__yJsonConcrete_${concreteType}.readFastWithCursor(reader, __reader)"
    } else {
        directRead
    }
    if (checkDuplicate) {
        appendLine(sb, level, "if (__seen_${field.name}) { context.pushField(${label}); try { throw JsonException(\"Duplicate JSON field\", code: \"duplicate_key\", path: context.currentPath()) } finally { context.popPath() } }")
    }
    if (plan.cursorFastNeedsContext) {
        appendLine(sb, level, "context.pushField(${label})")
        appendLine(sb, level, "try { __result.${field.name} = ${readValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, level, "__result.${field.name} = ${readValue}")
    }
    appendLine(sb, level, "__seen_${field.name} = true")
}

private func appendMutableObjectFastRead(
    sb: StringBuilder,
    model: ObjectCodecModel
): Unit {
    let fields = model.fields
    let readPlans = model.readPlans
    let params = model.constructorParams
    let targetType = model.targetType
    let genericNames = model.genericNames
    let fastReadContext = cursorFastReadNeedsContext(readPlans)
    appendLine(sb, 2, "let __fastReader = __reader.generatedReaderV1()")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "let __result = ${targetType}()")
    for (plan in readPlans) {
        let field = plan.field
        if (field.writeField) {
            appendLine(sb, 3, "var __seen_${field.name} = false")
        }
    }
    appendLine(sb, 3, "__reader.startRawObject()")
    appendLine(sb, 3, "var __first = true")
    var orderedFieldCount: Int64 = 0
    var lastOrderedFieldName = ""
    for (plan in readPlans) {
        let field = plan.field
        if (field.writeField) {
            orderedFieldCount++
            lastOrderedFieldName = field.name
        }
    }
    if (orderedFieldCount > 0) {
        appendLine(sb, 3, "while (true) {")
        var canonicalLabelIndex: Int64 = 0
        for (plan in readPlans) {
            let field = plan.field
            if (field.writeField) {
                appendLine(sb, 4, "if (!__reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                appendMutableObjectFastFieldAssignment(
                    sb, 4, plan, field.jsonNameExpr, false, genericNames)
                appendLine(sb, 4, "__first = false")
            }
            canonicalLabelIndex += 1 + field.aliases.size
        }
        appendLine(sb, 4, "break")
        appendLine(sb, 3, "}")
        // A complete declaration-order prefix can return without entering the
        // policy-aware dispatcher; any trailing token still takes the fallback.
        if (orderedFieldCount == fields.size) {
            appendLine(sb, 3, "if (__seen_${lastOrderedFieldName} && !__reader.hasRawObjectField(__first)) {")
            appendLine(sb, 4, "__reader.endRawObject()")
            appendLine(sb, 4, "return __result")
            appendLine(sb, 3, "}")
        }
    }

    appendLine(sb, 3, "while (__reader.hasRawObjectField(__first)) {")
    appendLine(sb, 4, "let __nameId = __reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
    appendLine(sb, 4, "match (__nameId) {")
    var labelIndex: Int64 = 0
    for (plan in readPlans) {
        let field = plan.field
        if (!field.writeField) { continue }
        appendLine(sb, 5, "case ${labelIndex} =>")
        appendMutableObjectFastFieldAssignment(
            sb, 6, plan, field.jsonNameExpr, true, genericNames)
        labelIndex += 1
        for (alias in field.aliases) {
            appendLine(sb, 5, "case ${labelIndex} =>")
            appendMutableObjectFastFieldAssignment(
                sb, 6, plan, alias, true, genericNames)
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

private func appendDirectFastObjectRead(
    sb: StringBuilder,
    model: ObjectCodecModel,
    fastReaderName: String,
    contextExpression: String
): Unit {
    let fields = model.fields
    let readPlans = model.readPlans
    let params = model.constructorParams
    let targetType = model.targetType
    let fastLabels = model.fastLabels
    let fastReadContext = directFastReadNeedsContext(readPlans)
    if (fastReaderName == "__fastReader") {
        appendLine(sb, 2, "let __fastReader = GeneratedSupportV1.readFastReader(reader)")
    }
    appendLine(sb, 2, "let context = ${contextExpression}")
    if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendDecodeScratchDeclarations(sb, 3, fields)
    appendLine(sb, 3, "reader.startRawObject()")
    appendLine(sb, 3, "var __first = true")
    let fieldOrder = canonicalFieldOrderPlan(fields, params)
    if (fieldOrder.fieldCount > 0) {
        appendLine(sb, 3, "while (true) {")
        var canonicalLabelIndex: Int64 = 0
        for (plan in readPlans) {
            let field = plan.field
            if (field.writeField) {
                appendLine(sb, 4, "if (!reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                appendDirectFastFieldAssignment(sb, 4, plan, field.jsonNameExpr, false, fastReaderName)
                appendLine(sb, 4, "__first = false")
            }
            canonicalLabelIndex += 1 + field.aliases.size
        }
        appendLine(sb, 4, "break")
        appendLine(sb, 3, "}")
        if (fieldOrder.fieldCount >= 3 && fieldOrder.fieldCount == fields.size &&
            fieldOrder.hasPostConstructorField) {
            appendLine(sb, 3, "if (__seen_${fieldOrder.lastFieldName} && !reader.hasRawObjectField(__first)) {")
            appendLine(sb, 4, "reader.endRawObject()")
            appendDecodedResult(sb, 4, fields, params, targetType, true)
            appendLine(sb, 3, "}")
        }
    }
    appendLine(sb, 3, "while (reader.hasRawObjectField(__first)) {")
    appendLine(sb, 4, "let __nameId = reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
    appendLine(sb, 4, "match (__nameId) {")
    for (labelIndex in 0..fastLabels.size) {
        let (plan, label) = fastLabels[labelIndex]
        appendLine(sb, 5, "case ${labelIndex} =>")
        appendDirectFastFieldAssignment(sb, 6, plan, label, true, fastReaderName)
    }
    appendLine(sb, 5, "case _ => reader.skipRawWithDepth(context.remainingDepth())")
    appendLine(sb, 4, "}")
    appendLine(sb, 4, "__first = false")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "reader.endRawObject()")
    appendRequiredFieldChecks(sb, 3, fields, params)
    appendDecodedResult(sb, 3, fields, params, targetType, false)
    appendLine(sb, 2, if (fastReadContext) {
        "} finally { context.leaveValue() }"
    } else {
        "} finally { let _ = context }"
    })
}

private func appendObjectReadMethods(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let fields = model.fields
    let readPlans = model.readPlans
    let params = model.constructorParams
    let targetType = model.targetType
    let fastLabels = model.fastLabels
    let generics = model.genericNames
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendDecodeScratchDeclarations(sb, 3, fields)
    appendLine(sb, 3, "reader.startObject()")
    appendLine(sb, 3, "while (reader.hasObjectField()) {")
    appendLine(sb, 4, "let __name = reader.readName()")
    appendLine(sb, 4, "match (__name) {")
    for (plan in readPlans) {
        let field = plan.field
        let codec = fieldCodec(field)
        let directRead = plan.semanticRead("reader")
        let readValue = if (directRead.isEmpty()) { "${codec}.read(reader)" } else { directRead }
        let labels = ArrayList<String>()
        labels.add(field.jsonNameExpr)
        labels.add(all: field.aliases)
        appendLine(sb, 5, "case " + joinStrings(labels, " | ") + " =>")
        appendLine(sb, 6, "if (__seen_${field.name} && GeneratedSupportV1.readOptions(reader).rejectsDuplicateKeys()) { throw JsonException(\"Duplicate JSON field: \" + __name, code: \"duplicate_key\", path: context.currentPath()) }")
        let assignValue = "__value_${field.name} = " +
            (if (field.isOption || usesScalarScratch(field)) {
                readValue
            } else {
                "Some(${readValue})"
            })
        if (plan.semanticNeedsContext) {
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
    appendRequiredFieldChecks(sb, 3, fields, params)
    appendDecodedResult(sb, 3, fields, params, targetType, false)
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")

    let fastReadContext = cursorFastReadNeedsContext(readPlans)
    let mutableObjectFastRead = canUseMutableObjectFastRead(readPlans, params, generics)
    appendLine(sb, 1, "public func readFast(reader: GeneratedSupportV1Reader): ${targetType} {")
    appendLine(sb, 2, "readFastWithCursor(reader, GeneratedSupportV1.readCursor(reader))")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func readFastDirect(reader: JsonFastReader): ${targetType} {")
    appendDirectFastObjectRead(
        sb, model, "reader", "reader.generatedReadStateV1()")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func readFastWithCursor(reader: GeneratedSupportV1Reader, __reader: GeneratedSupportV1ReadCursor): ${targetType} {")
    if (mutableObjectFastRead) {
        appendLine(sb, 2, "return readFastMutableObjectWithCursor(reader, __reader)")
    } else {
        appendLine(sb, 2, "let __fastReader = __reader.generatedReaderV1()")
        appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
        if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
        appendLine(sb, 2, "try {")
        appendDecodeScratchDeclarations(sb, 3, fields)
        appendLine(sb, 3, "__reader.startRawObject()")
        appendLine(sb, 3, "var __first = true")
        let fieldOrder = canonicalFieldOrderPlan(fields, params)
        if (fieldOrder.fieldCount > 0) {
            appendLine(sb, 3, "while (true) {")
            var canonicalLabelIndex: Int64 = 0
            for (plan in readPlans) {
                let field = plan.field
                if (field.writeField) {
                    appendLine(sb, 4, "if (!__reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                    appendFastFieldAssignment(sb, 4, plan, field.jsonNameExpr, false)
                    appendLine(sb, 4, "__first = false")
                }
                canonicalLabelIndex += 1 + field.aliases.size
            }
            appendLine(sb, 4, "break")
            appendLine(sb, 3, "}")
            if (fieldOrder.fieldCount >= 3 && fieldOrder.fieldCount == fields.size &&
                fieldOrder.hasPostConstructorField) {
                appendLine(sb, 3, "if (__seen_${fieldOrder.lastFieldName} && !__reader.hasRawObjectField(__first)) {")
                appendLine(sb, 4, "__reader.endRawObject()")
                appendDecodedResult(sb, 4, fields, params, targetType, true)
                appendLine(sb, 3, "}")
            }
        }
        appendLine(sb, 3, "while (__reader.hasRawObjectField(__first)) {")
        appendLine(sb, 4, "let __nameId = __reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
        appendLine(sb, 4, "match (__nameId) {")
        for (labelIndex in 0..fastLabels.size) {
            let (plan, label) = fastLabels[labelIndex]
            appendLine(sb, 5, "case ${labelIndex} =>")
            appendFastFieldAssignment(sb, 6, plan, label, true)
        }
        appendLine(sb, 5, "case _ => __reader.skipValue(context.remainingDepth())")
        appendLine(sb, 4, "}")
        appendLine(sb, 4, "__first = false")
        appendLine(sb, 3, "}")
        appendLine(sb, 3, "__reader.endRawObject()")
        appendRequiredFieldChecks(sb, 3, fields, params)
        appendDecodedResult(sb, 3, fields, params, targetType, false)
        appendLine(sb, 2, if (fastReadContext) {
            "} finally { context.leaveValue() }"
        } else {
            "} finally { let _ = context }"
        })
    }
    appendLine(sb, 1, "}")
    if (mutableObjectFastRead) {
        appendLine(sb, 1, "private func readFastMutableObjectWithCursor(reader: GeneratedSupportV1Reader, __reader: GeneratedSupportV1ReadCursor): ${targetType} {")
        appendMutableObjectFastRead(sb, model)
        appendLine(sb, 1, "}")
    }
}

private func appendObjectFieldWrite(
    sb: StringBuilder,
    field: CodecField,
    directWrite: String,
    writeValue: String
): Unit {
    if (field.isOption && !field.includeNull) {
        appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
        appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
        appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
        appendLine(sb, 3, "try { ${writeValue} } finally { context.popPath() }")
        appendLine(sb, 2, "}")
        return
    }
    appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
    if (directWrite.isEmpty() || fieldSpecializedOperationNeedsContext(field)) {
        appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
        appendLine(sb, 2, "try { ${writeValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, 2, writeValue)
    }
}

private func analyzeObjectCodec(decl: Decl, body: Body, isClass: Bool): ObjectCodecModel {
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
                            CodecFieldDeclaration(
                                param.name,
                                param.typeText,
                                false,
                                param.hasDefault
                            ),
                            JsonFieldPolicy(
                                "\"${param.name}\"",
                                ArrayList<String>(),
                                inner.isSome(),
                                inner.getOrDefault({ => "" }),
                                false,
                                "",
                                writeField: false
                            )
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
    ObjectCodecModel(decl, name, fields, params, generics, genericText, targetType,
        constraints, codecName, inheritedObjectType, isClass, supportsStaticCompactRawWrite(fields))
}

private func appendObjectCodecPrelude(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let targetType = model.targetType
    let codecName = model.codecName
    let genericText = model.genericText
    let constraints = model.constraints
    let staticCompact = model.staticCompact
    let fastLabelBytes = model.fastLabelBytes
    let directInterface = if (staticCompact) {
        "GeneratedCompactCursorWriteCodecV1<${targetType}> & " +
            "GeneratedCompactArrayListElementCodecV1<${targetType}>"
    } else {
        "GeneratedDirectWriteCodecV1<${targetType}> & " +
            "GeneratedCursorWriteCodecV1<${targetType}>"
    }
    let codecInterfaces = "GeneratedObjectCodecV1<${targetType}> & " +
        "GeneratedCodecV1<${targetType}> & GeneratedDirectFastReadCodecV1<${targetType}> & " +
        "GeneratedCursorReadCodecV1<${targetType}> & " +
        directInterface
    appendLine(sb, 0, "private class ${codecName}${genericText} <: ${codecInterfaces}${constraints} {")
    for (plan in model.readPlans) {
        let field = plan.field
        let fullyDirect = !directScalarWrite(field, "__value").isEmpty() &&
            plan.hasDirectSemanticRead() && plan.hasDirectFastRead()
        if (!fullyDirect) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${fieldCodecInitializer(field)}")
            let needsDirectFastCodec = plan.needsDirectFastCodec
            let needsCursorFastCodec = plan.needsCursorFastCodec
            if (needsDirectFastCodec || needsCursorFastCodec) {
                appendLine(sb, 1, "private let ${cachedFastFieldCodecName(field)}: Option<GeneratedCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __fast: GeneratedCodecV1<${field.typeText}> => Some(__fast); case _ => None<GeneratedCodecV1<${field.typeText}>> }")
            }
            if (needsCursorFastCodec) {
                appendLine(sb, 1, "private let ${cachedCursorFastFieldCodecName(field)}: Option<GeneratedCursorReadCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __fast: GeneratedCursorReadCodecV1<${field.typeText}> => Some(__fast); case _ => None<GeneratedCursorReadCodecV1<${field.typeText}>> }")
            }
            if (compactRawSpecializedFieldWrite(field, "__value", "__first").isEmpty() &&
                directScalarWrite(field, "__value").isEmpty()) {
                appendLine(sb, 1, "private let ${compactRawCodecName(field)}: Option<GeneratedCompactWriteCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __raw: GeneratedCompactWriteCodecV1<${field.typeText}> => Some(__raw); case _ => None<GeneratedCompactWriteCodecV1<${field.typeText}>> }")
                appendLine(sb, 1, "private let ${compactRawCursorCodecName(field)}: Option<GeneratedCursorWriteCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __rawCursor: GeneratedCursorWriteCodecV1<${field.typeText}> => Some(__rawCursor); case _ => None<GeneratedCursorWriteCodecV1<${field.typeText}>> }")
            }
        }
    }
    appendLine(sb, 1, "private let __yJsonFastFieldNames: Array<Array<Byte>> = unsafe { [" +
        joinStrings(fastLabelBytes, ", ") + "] }")
}

private func appendObjectSemanticWriteMethods(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let fields = model.fields
    let targetType = model.targetType
    let isClass = model.isClass
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
        appendObjectFieldWrite(sb, field, directWrite, writeValue)
    }
    appendLine(sb, 1, "}")
}

private func appendObjectDirectWriteMethods(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let fields = model.fields
    let targetType = model.targetType
    let isClass = model.isClass
    let staticCompact = model.staticCompact
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
        appendObjectFieldWrite(sb, field, directWrite, writeValue)
    }
    appendLine(sb, 1, "}")
}

private func appendObjectCompactCursorWriteMethods(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let fields = model.fields
    let targetType = model.targetType
    let generics = model.genericNames
    let rawChecks = ArrayList<String>()
    for (field in fields) {
        if (!field.writeField) { continue }
        if (compactRawSpecializedFieldWrite(field, "__value", "__first").isEmpty() &&
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
        if (compactRawFieldNeedsContext(field, generics)) {
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
}

private func appendObjectCompactWriterMethod(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let fields = model.fields
    let targetType = model.targetType
    let generics = model.genericNames
    // Every generated object must account for its own write depth. Field-level
    // context checks only decide path tracking around nested field writes.
    var compactHasDirectField = false
    for (field in fields) {
        if (field.writeField && !compactRawSpecializedFieldWrite(field, "__value", "__first").isEmpty()) {
            compactHasDirectField = true
            break
        }
    }
    var compactNeedsWriterCursor = false
    for (field in fields) {
        if (!field.writeField) { continue }
        if (FieldWritePlan(field).needsCachedDirectCursor()) {
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
            // Large generated objects otherwise grow the direct buffer in
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
    appendLine(sb, 2, "writer.writeRawBeginObject()")
    appendLine(sb, 2, "var __first = true")
    for (field in fields) {
        if (!field.writeField) {
            continue
        }
        let scalarRawWrite = renderCompactDirectScalarField(
            FieldWritePlan(field), "value.${field.name}", "__first", scalarBufferBatch)
        let rawWrite = if (scalarRawWrite.isEmpty()) {
            compactRawConcreteFieldWrite(
                field, "value.${field.name}", "__first", generics)
        } else {
            scalarRawWrite
        }
        if (compactRawFieldNeedsContext(field, generics)) {
            appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 2, "try { ${rawWrite} } finally { context.popPath() }")
        } else {
            appendLine(sb, 2, rawWrite)
        }
    }
    appendLine(sb, 3, "writer.writeRawEndObject()")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
}

private func appendObjectCompactArrayListWriteMethod(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let targetType = model.targetType
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

private func renderCodec(decl: Decl, body: Body, isClass: Bool): Tokens {
    let model = analyzeObjectCodec(decl, body, isClass)
    let sb = StringBuilder()
    appendObjectCodecPrelude(sb, model)
    appendObjectSemanticWriteMethods(sb, model)
    appendObjectDirectWriteMethods(sb, model)
    appendObjectCompactCursorWriteMethods(sb, model)
    if (model.staticCompact) {
        appendObjectCompactWriterMethod(sb, model)
        appendObjectCompactArrayListWriteMethod(sb, model)
    }
    appendObjectReadMethods(sb, model)
    appendLine(sb, 0, "}")
    appendObjectProviders(sb, model)
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

private func renderPolymorphicCodec(model: PolymorphicCodecModel): Tokens {
    let visibility = model.visibility
    let name = model.name
    let fields = model.fields
    let generics = model.genericNames
    let genericText = model.genericText
    let targetType = model.targetType
    let constraints = model.constraints
    let codecName = model.codecName
    let codecProviderName = model.codecProviderName
    let discriminator = model.discriminator
    let subtypes = model.subtypes

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

    if (generics.isEmpty()) {
        appendLine(sb, 0, "${visibility}let ${codecProviderName}: JsonCodec<${name}> = ${codecName}()")
        appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> & GeneratedObjectCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecProviderName} }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}() }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${codecProviderName}${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}> & GeneratedObjectCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecProviderName}${genericText}() }")
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
                renderPolymorphicCodec(analyzePolymorphicCodec(
                    classDecl, wrappedSubtypeExpressions, wrappedDiscriminatorArguments))
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
