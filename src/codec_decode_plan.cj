macro package yjson_macros

import std.collection.*

private func semanticReadTemplate(field: CodecField): String {
    if (field.capabilities.usesCustomCodec) { return "" }
    let reader = "__YJSON_FIELD_READER__"
    let primitiveRead = match (field.capabilities.typeShape.primitive) {
        case PrimitiveFieldKind.BoolValue => "${reader}.readBool()"
        case PrimitiveFieldKind.Int64Value => "${reader}.readInt64()"
        case PrimitiveFieldKind.UInt64Value => "${reader}.readUInt64()"
        case PrimitiveFieldKind.Float64Value => "${reader}.readFloat64()"
        case PrimitiveFieldKind.StringValue => "${reader}.readString()"
        case PrimitiveFieldKind.BigIntValue => "${reader}.readBigInt()"
        case PrimitiveFieldKind.DecimalValue => "${reader}.readDecimal()"
        case _ => ""
    }
    if (!primitiveRead.isEmpty()) { return primitiveRead }
    match (field.capabilities.typeShape.normalized) {
        case "ArrayList<String>" => "__yJsonReadStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadStringOption(${reader})"
        case "Option<Int64>" => "__yJsonReadInt64Option(${reader})"
        case _ => ""
    }
}

private func directFastReadTemplate(field: CodecField): String {
    if (field.capabilities.usesCustomCodec) { return "" }
    let reader = "__YJSON_FIELD_READER__"
    let primitiveRead = match (field.capabilities.typeShape.primitive) {
        case PrimitiveFieldKind.BoolValue => "${reader}.readRawBool()"
        case PrimitiveFieldKind.Int64Value => "${reader}.readRawInt64()"
        case PrimitiveFieldKind.Int32Value => "${reader}.readRawInt32()"
        case PrimitiveFieldKind.Int16Value => "${reader}.readRawInt16()"
        case PrimitiveFieldKind.Int8Value => "${reader}.readRawInt8()"
        case PrimitiveFieldKind.UInt64Value => "${reader}.readRawUInt64()"
        case PrimitiveFieldKind.UInt32Value => "${reader}.readRawUInt32()"
        case PrimitiveFieldKind.UInt16Value => "${reader}.readRawUInt16()"
        case PrimitiveFieldKind.UInt8Value => "${reader}.readRawUInt8()"
        case PrimitiveFieldKind.StringValue => "${reader}.readRawString()"
        case PrimitiveFieldKind.DecimalValue => "jsonFastReadDecimal(${reader})"
        case PrimitiveFieldKind.Float64Value => "jsonFastReadFloat64(${reader})"
        case PrimitiveFieldKind.Float32Value => "jsonFastReadFloat32(${reader})"
        case PrimitiveFieldKind.Float16Value => "jsonFastReadFloat16(${reader})"
        case _ => ""
    }
    if (!primitiveRead.isEmpty()) { return primitiveRead }
    match (field.capabilities.typeShape.normalized) {
        case "ArrayList<String>" => "__yJsonReadFastStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadFastInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadFastStringOption(${reader})"
        case "Option<Int64>" => "__yJsonReadFastInt64Option(${reader})"
        case "ArrayList<BigInt>" => "__yJsonReadFastArrayListBigInt(${reader})"
        case "HashMap<String,BigInt>" => "__yJsonReadFastHashMapStringBigInt(${reader})"
        case "ArrayList<Decimal>" => "__yJsonReadFastArrayListDecimal(${reader})"
        case "HashMap<String,Decimal>" => "__yJsonReadFastHashMapStringDecimal(${reader})"
        case _ => ""
    }
}

private func cursorFastReadTemplate(field: CodecField, directFastTemplate: String): String {
    if (field.capabilities.usesCustomCodec) { return "" }
    let primitiveRead = match (field.capabilities.typeShape.primitive) {
        case PrimitiveFieldKind.BoolValue => "__reader.readRawBool()"
        case PrimitiveFieldKind.Int64Value => "__reader.readRawInt64()"
        case PrimitiveFieldKind.Int32Value => "__reader.readRawInt32()"
        case PrimitiveFieldKind.Int16Value => "__reader.readRawInt16()"
        case PrimitiveFieldKind.Int8Value => "__reader.readRawInt8()"
        case PrimitiveFieldKind.UInt64Value => "__reader.readRawUInt64()"
        case PrimitiveFieldKind.UInt32Value => "__reader.readRawUInt32()"
        case PrimitiveFieldKind.UInt16Value => "__reader.readRawUInt16()"
        case PrimitiveFieldKind.UInt8Value => "__reader.readRawUInt8()"
        case PrimitiveFieldKind.StringValue => "__reader.readRawString()"
        case PrimitiveFieldKind.Float64Value => "__reader.readRawFloat64()"
        case PrimitiveFieldKind.Float32Value => "__reader.readRawFloat32()"
        case PrimitiveFieldKind.Float16Value => "__reader.readRawFloat16()"
        case _ => ""
    }
    if (!primitiveRead.isEmpty()) { return primitiveRead }
    match (field.capabilities.typeShape.normalized) {
        case "Array<Int64>" => "__reader.readRawInt64Array()"
        case "Array<String>" => "__reader.readRawStringArray()"
        case "HashMap<String,Int64>" => "__reader.readRawInt64Map()"
        case "HashMap<String,String>" => "__reader.readRawStringMap()"
        case "HashMap<String,Array<Int64>>" => "__reader.readRawInt64ArrayMap()"
        case "Option<Int64>" =>
            "if (__reader.tryReadRawNull()) { None<Int64> } else { Some(__reader.readRawInt64()) }"
        case "Option<String>" =>
            "if (__reader.tryReadRawNull()) { None<String> } else { Some(__reader.readRawString()) }"
        case _ => directFastTemplate
    }
}

internal func fieldSpecializedOperationNeedsContext(field: CodecField): Bool {
    let normalized = field.capabilities.typeShape.normalized
    normalized == "ArrayList<String>" || normalized == "HashMap<String,Int64>" ||
        normalized == "HashMap<String,String>" || normalized == "HashMap<String,Array<Int64>>" ||
        normalized == "Option<String>" || normalized == "ArrayList<BigInt>" ||
        normalized == "HashMap<String,BigInt>" || normalized == "ArrayList<Decimal>" ||
        normalized == "HashMap<String,Decimal>"
}

internal class FieldReadPlan {
    let field: CodecField
    private let semanticTemplate: String
    private let directFastTemplate: String
    private let cursorFastTemplate: String
    let semanticNeedsContext: Bool
    let directFastNeedsContext: Bool
    let cursorFastNeedsContext: Bool
    let needsDirectFastCodec: Bool
    let needsCursorFastCodec: Bool

    init(field: CodecField) {
        this.field = field
        semanticTemplate = semanticReadTemplate(field)
        directFastTemplate = directFastReadTemplate(field)
        cursorFastTemplate = cursorFastReadTemplate(field, directFastTemplate)
        let specializedNeedsContext = fieldSpecializedOperationNeedsContext(field)
        semanticNeedsContext = semanticTemplate.isEmpty() || specializedNeedsContext
        directFastNeedsContext = directFastTemplate.isEmpty() || specializedNeedsContext
        cursorFastNeedsContext = cursorFastTemplate.isEmpty() || specializedNeedsContext
        needsDirectFastCodec = directFastTemplate.isEmpty()
        needsCursorFastCodec = cursorFastTemplate.isEmpty()
    }

    func semanticRead(reader: String): String {
        semanticTemplate.replace("__YJSON_FIELD_READER__", reader)
    }

    func directFastRead(reader: String): String {
        directFastTemplate.replace("__YJSON_FIELD_READER__", reader)
    }

    func cursorFastRead(): String {
        cursorFastTemplate.replace("__YJSON_FIELD_READER__", "reader")
    }

    func hasDirectSemanticRead(): Bool { !semanticTemplate.isEmpty() }
    func hasDirectFastRead(): Bool { !directFastTemplate.isEmpty() }
}

internal class CanonicalFieldOrderPlan {
    let fieldCount: Int64
    let lastFieldName: String
    let hasPostConstructorField: Bool

    init(
        fieldCount: Int64,
        lastFieldName: String,
        hasPostConstructorField: Bool
    ) {
        this.fieldCount = fieldCount
        this.lastFieldName = lastFieldName
        this.hasPostConstructorField = hasPostConstructorField
    }
}

internal func fieldByName(
    fields: ArrayList<CodecField>,
    name: String
): Option<CodecField> {
    for (field in fields) {
        if (field.name == name) { return Some(field) }
    }
    None<CodecField>
}

internal func constructorParamByName(
    params: ArrayList<CodecConstructorParam>,
    name: String
): Option<CodecConstructorParam> {
    for (param in params) {
        if (param.name == name) { return Some(param) }
    }
    None<CodecConstructorParam>
}

internal func fieldIsRequired(
    field: CodecField,
    params: ArrayList<CodecConstructorParam>
): Bool {
    if (field.isOption) { return false }
    if (let Some(param) <- constructorParamByName(params, field.name)) {
        return !param.hasDefault
    }
    !field.hasDefault
}

internal func appendRequiredFieldChecks(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>
): Unit {
    for (field in fields) {
        if (fieldIsRequired(field, params)) {
            appendLine(
                sb,
                level,
                "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: " +
                    "${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
}

internal func appendDecodeScratchDeclarations(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>
): Unit {
    for (field in fields) {
        if (field.isOption) {
            appendLine(
                sb,
                level,
                "var __value_${field.name}: ${field.typeText} = " +
                    "None<${field.optionInner}>")
        } else if (let Some(initializer) <- scalarScratchInitializer(field)) {
            appendLine(
                sb,
                level,
                "var __value_${field.name}: ${field.typeText} = ${initializer}")
        } else {
            appendLine(
                sb,
                level,
                "var __value_${field.name}: Option<${field.typeText}> = " +
                    "None<${field.typeText}>")
        }
        appendLine(sb, level, "var __seen_${field.name} = false")
    }
}

internal func canonicalFieldOrderPlan(
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>
): CanonicalFieldOrderPlan {
    var fieldCount: Int64 = 0
    var lastFieldName = ""
    var hasPostConstructorField = false
    for (field in fields) {
        if (!field.writeField) { continue }
        fieldCount++
        lastFieldName = field.name
        if (field.mutable && constructorParamByName(params, field.name).isNone()) {
            hasPostConstructorField = true
        }
    }
    CanonicalFieldOrderPlan(fieldCount, lastFieldName, hasPostConstructorField)
}

private func decodedConstructorArgument(
    param: CodecConstructorParam,
    fields: ArrayList<CodecField>,
    allFieldsSeen: Bool
): String {
    if (let Some(field) <- fieldByName(fields, param.name)) {
        if (field.isOption) { return "__value_${field.name}" }
        if (usesScalarScratch(field)) {
            if (param.hasDefault && !allFieldsSeen) {
                return "if (__seen_${field.name}) { __value_${field.name} } " +
                    "else { ${param.defaultExpr} }"
            }
            return "__value_${field.name}"
        }
        if (param.hasDefault && !allFieldsSeen) {
            return "if (__seen_${field.name}) { __value_${field.name}.getOrThrow() } " +
                "else { ${param.defaultExpr} }"
        }
        return "__value_${field.name}.getOrThrow()"
    }
    if (param.hasDefault) { return param.defaultExpr }
    throw Exception("constructor parameter `${param.name}` has no JSON property")
}

private func appendPostConstructorAssignments(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>,
    allFieldsSeen: Bool
): Unit {
    for (field in fields) {
        if (constructorParamByName(params, field.name).isSome()) { continue }
        if (!field.mutable) {
            if (params.isEmpty()) {
                throw Exception("immutable field `${field.name}` requires a constructor parameter")
            }
            continue
        }
        if (field.isOption || usesScalarScratch(field)) {
            if (field.isOption || allFieldsSeen) {
                appendLine(sb, level, "__result.${field.name} = __value_${field.name}")
            } else {
                appendLine(
                    sb,
                    level,
                    "if (__seen_${field.name}) { " +
                        "__result.${field.name} = __value_${field.name} }")
            }
        } else if (allFieldsSeen) {
            appendLine(
                sb,
                level,
                "__result.${field.name} = __value_${field.name}.getOrThrow()")
        } else {
            appendLine(
                sb,
                level,
                "if (__seen_${field.name}) { " +
                    "__result.${field.name} = __value_${field.name}.getOrThrow() }")
        }
    }
}

internal func appendDecodedResult(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>,
    targetType: String,
    allFieldsSeen: Bool
): Unit {
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            args.add(decodedConstructorArgument(param, fields, allFieldsSeen))
        }
        appendLine(sb, level, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        appendPostConstructorAssignments(sb, level, fields, params, allFieldsSeen)
        appendLine(sb, level, "return __result")
        return
    }

    appendLine(sb, level, "let __result = ${targetType}()")
    appendPostConstructorAssignments(sb, level, fields, params, allFieldsSeen)
    appendLine(sb, level, "return __result")
}
