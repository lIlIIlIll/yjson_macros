macro package yjson_macros

private func compactScalarMethodStem(op: CompactWriteOp): String {
    match (op) {
        case CompactWriteOp.BoolValue => "Bool"
        case CompactWriteOp.Int64Value | CompactWriteOp.Int64Widened |
             CompactWriteOp.OptionalInt64Value => "Int64"
        case CompactWriteOp.UInt64Value | CompactWriteOp.UInt64Widened => "UInt64"
        case CompactWriteOp.Float64Value | CompactWriteOp.Float64Widened => "Float64"
        case CompactWriteOp.StringValue | CompactWriteOp.OptionalStringValue => "String"
        case _ => ""
    }
}

private func compactScalarValue(op: CompactWriteOp, value: String): String {
    match (op) {
        case CompactWriteOp.Int64Widened => "Int64(${value})"
        case CompactWriteOp.UInt64Widened => "UInt64(${value})"
        case CompactWriteOp.Float64Widened => "Float64(${value})"
        case _ => value
    }
}

private func compactScalarEntryCall(
    plan: FieldWritePlan,
    value: String,
    first: String,
    receiver: String,
    knownNameSuffix: String
): String {
    let stem = compactScalarMethodStem(plan.compactOp)
    let renderedValue = compactScalarValue(plan.compactOp, value)
    let nameKind = if (plan.usesKnownName) { "KnownName" } else { "Name" }
    let suffix = if (plan.usesKnownName) { knownNameSuffix } else { "" }
    "${first} = ${receiver}.writeRawObjectEntry${nameKind}${stem}${suffix}(" +
        "${first}, ${plan.field.jsonNameExpr}, ${renderedValue})"
}

private func compactOptionalScalarField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    receiver: String,
    knownNameSuffix: String
): String {
    let someWrite = compactScalarEntryCall(
        plan, "__rawItem", first, receiver, knownNameSuffix)
    if (!plan.field.includeNull) {
        return "if (let Some(__rawItem) <- ${value}) { ${someWrite} }"
    }
    let nameKind = if (plan.usesKnownName) { "KnownName" } else { "Name" }
    "match (${value}) { case Some(__rawItem) => ${someWrite}; " +
        "case None => ${first} = ${receiver}.writeRawObjectEntry${nameKind}(" +
        "${first}, ${plan.field.jsonNameExpr}); writer.writeRawNull() }"
}

internal func renderCompactCursorScalarField(
    plan: FieldWritePlan,
    value: String,
    first: String
): String {
    if (!plan.hasScalarOp()) { return "" }
    match (plan.compactOp) {
        case CompactWriteOp.OptionalInt64Value | CompactWriteOp.OptionalStringValue =>
            compactOptionalScalarField(plan, value, first, "__writer", "")
        case _ => compactScalarEntryCall(plan, value, first, "__writer", "")
    }
}

internal func renderCompactDirectScalarField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    scalarBatch: Bool
): String {
    if (!plan.hasScalarOp()) { return "" }
    match (plan.compactOp) {
        case CompactWriteOp.OptionalInt64Value | CompactWriteOp.OptionalStringValue =>
            return compactOptionalScalarField(plan, value, first, "writer", "Buffer")
        case _ => ()
    }

    if (scalarBatch && plan.usesKnownName) {
        let renderedValue = compactScalarValue(plan.compactOp, value)
        let method = match (plan.compactOp) {
            case CompactWriteOp.StringValue =>
                "writer.writeRawObjectEntryKnownNameStringFast"
            case CompactWriteOp.BoolValue =>
                "__buffer.writeObjectEntryNameBoolNoEscapeFast"
            case CompactWriteOp.Int64Value | CompactWriteOp.Int64Widened =>
                "__buffer.writeObjectEntryNameInt64NoEscapeFast"
            case CompactWriteOp.UInt64Value | CompactWriteOp.UInt64Widened =>
                "__buffer.writeObjectEntryNameUInt64NoEscapeFast"
            case CompactWriteOp.Float64Value | CompactWriteOp.Float64Widened =>
                "__buffer.writeObjectEntryNameFloat64NoEscapeFast"
            case _ => ""
        }
        return "${first} = ${method}(${first}, ${plan.field.jsonNameExpr}, ${renderedValue})"
    }

    compactScalarEntryCall(plan, value, first, "writer", "Buffer")
}

private func compactContainerMethodStem(op: CompactWriteOp): String {
    match (op) {
        case CompactWriteOp.Int64Array => "Int64Array"
        case CompactWriteOp.Float64Array => "Float64Array"
        case CompactWriteOp.StringArray => "StringArray"
        case CompactWriteOp.Int64Map => "Int64Map"
        case CompactWriteOp.StringMap => "StringMap"
        case CompactWriteOp.Int64ArrayMap => "Int64ArrayMap"
        case _ => ""
    }
}

private func compactContainerTryWrite(op: CompactWriteOp): String {
    match (op) {
        case CompactWriteOp.Int64Array => "jsonTryWriteCompactInt64Array"
        case CompactWriteOp.Float64Array => "jsonTryWriteCompactFloat64Array"
        case CompactWriteOp.StringArray => "jsonTryWriteCompactStringArray"
        case CompactWriteOp.Int64ArrayList => "jsonTryWriteCompactInt64ArrayList"
        case CompactWriteOp.StringArrayList => "jsonTryWriteCompactStringArrayList"
        case CompactWriteOp.Int64Map => "jsonTryWriteCompactInt64Map"
        case CompactWriteOp.StringMap => "jsonTryWriteCompactStringMap"
        case CompactWriteOp.Int64ArrayMap => "jsonTryWriteCompactInt64ArrayMap"
        case _ => ""
    }
}

private func compactContainerKnownNameSuffix(op: CompactWriteOp): String {
    match (op) {
        case CompactWriteOp.StringArray => ""
        case _ => "Buffer"
    }
}

private func primitiveCompactValueWrite(
    op: PrimitiveCompactWriteOp,
    receiver: String,
    value: String
): String {
    match (op) {
        case PrimitiveCompactWriteOp.BoolValue =>
            "GeneratedSupportV1.writeRawBool(${receiver}, ${value})"
        case PrimitiveCompactWriteOp.SignedInteger =>
            "GeneratedSupportV1.writeRawInt64(${receiver}, Int64(${value}))"
        case PrimitiveCompactWriteOp.UnsignedInteger =>
            "GeneratedSupportV1.writeRawUInt64(${receiver}, UInt64(${value}))"
        case PrimitiveCompactWriteOp.FloatValue =>
            "GeneratedSupportV1.writeRawFloat64(${receiver}, Float64(${value}))"
        case PrimitiveCompactWriteOp.StringValue =>
            "GeneratedSupportV1.writeRawString(${receiver}, ${value})"
        case _ => ""
    }
}

private func renderPrimitiveCompactSequenceValue(
    plan: FieldWritePlan,
    receiver: String,
    value: String,
    stem: String
): String {
    let index = "__rawIndex_${stem}"
    let itemWrite = primitiveCompactValueWrite(
        plan.primitiveOp, receiver, "${value}[${index}]")
    if (itemWrite.isEmpty()) { return "" }
    "${receiver}.writeRawBeginArray(); " +
        "for (${index} in 0..${value}.size) { " +
        "if (${index} > 0) { ${receiver}.writeRawByte(b',') }; " +
        "${itemWrite} }; ${receiver}.writeRawEndArray()"
}

private func compactContainerEntryPrefix(
    plan: FieldWritePlan,
    first: String,
    receiver: String
): String {
    let nameKind = if (plan.usesKnownName) { "KnownName" } else { "Name" }
    "${first} = ${receiver}.writeRawObjectEntry${nameKind}(" +
        "${first}, ${plan.field.jsonNameExpr}); "
}

internal func compactRawCodecName(field: CodecField): String {
    "__yJsonCompactRaw_${field.name}"
}

internal func compactRawCursorCodecName(field: CodecField): String {
    "__yJsonCompactRawCursor_${field.name}"
}

private func renderCompactCodecField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    entryReceiver: String,
    cursor: String
): String {
    let prefix = compactContainerEntryPrefix(plan, first, entryReceiver)
    let write = prefix +
        "match (${compactRawCursorCodecName(plan.field)}) { " +
        "case Some(__rawCursor) => __rawCursor.writeCompactWithCursor(" +
        "${value}, writer, ${cursor}); " +
        "case None => match (${compactRawCodecName(plan.field)}) { " +
        "case Some(__raw) => __raw.writeCompactRaw(${value}, writer); " +
        "case None => throw JsonException(\"Compact raw codec is unavailable\") } }"
    if (plan.field.isOption && !plan.field.includeNull) {
        "if (${value}.isSome()) { ${write} }"
    } else {
        write
    }
}

internal func renderCompactCursorCodecField(
    plan: FieldWritePlan,
    value: String,
    first: String
): String {
    renderCompactCodecField(plan, value, first, "__writer", "__writer")
}

internal func renderCompactDirectCodecField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    cursor: String
): String {
    renderCompactCodecField(plan, value, first, "writer", cursor)
}

internal func renderCompactDirectConcreteField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    concreteType: String
): String {
    compactContainerEntryPrefix(plan, first, "writer") +
        "__yJsonConcrete_${concreteType}.writeCompactRawWithWriter(${value}, writer)"
}

private func renderPrimitiveCompactContainerField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    receiver: String
): String {
    let prefix = compactContainerEntryPrefix(plan, first, receiver)
    match (plan.compactOp) {
        case CompactWriteOp.PrimitiveSequence =>
            let body = renderPrimitiveCompactSequenceValue(
                plan, receiver, value, plan.field.name)
            if (body.isEmpty()) { "" } else { prefix + body }
        case CompactWriteOp.PrimitiveMap =>
            let item = "__rawMapItem_${plan.field.name}"
            let itemWrite = primitiveCompactValueWrite(plan.primitiveOp, receiver, item)
            if (itemWrite.isEmpty()) {
                ""
            } else {
                let mapFirst = "__rawMapFirst_${plan.field.name}"
                let mapName = "__rawMapName_${plan.field.name}"
                prefix + "${receiver}.writeRawBeginObject(); " +
                    "var ${mapFirst} = true; " +
                    "for ((${mapName}, ${item}) in ${value}) { " +
                    "${mapFirst} = ${receiver}.writeRawObjectEntryName(" +
                    "${mapFirst}, ${mapName}); ${itemWrite} }; " +
                    "${receiver}.writeRawEndObject()"
            }
        case CompactWriteOp.PrimitiveSequenceMap =>
            let items = "__rawMapItems_${plan.field.name}"
            let sequenceWrite = renderPrimitiveCompactSequenceValue(
                plan, receiver, items, "map_${plan.field.name}")
            if (sequenceWrite.isEmpty()) {
                ""
            } else {
                let mapFirst = "__rawMapFirst_${plan.field.name}"
                let mapName = "__rawMapName_${plan.field.name}"
                prefix + "${receiver}.writeRawBeginObject(); " +
                    "var ${mapFirst} = true; " +
                    "for ((${mapName}, ${items}) in ${value}) { " +
                    "${mapFirst} = ${receiver}.writeRawObjectEntryName(" +
                    "${mapFirst}, ${mapName}); ${sequenceWrite} }; " +
                    "${receiver}.writeRawEndObject()"
            }
        case _ => ""
    }
}

private func renderCompactContainerField(
    plan: FieldWritePlan,
    value: String,
    first: String,
    receiver: String,
    directWriter: Bool
): String {
    let tryWrite = compactContainerTryWrite(plan.compactOp)
    if (tryWrite.isEmpty()) {
        return renderPrimitiveCompactContainerField(plan, value, first, receiver)
    }

    let methodStem = compactContainerMethodStem(plan.compactOp)
    if (plan.usesKnownName && !methodStem.isEmpty()) {
        let suffix = if (directWriter) {
            compactContainerKnownNameSuffix(plan.compactOp)
        } else {
            ""
        }
        return "${first} = ${receiver}.writeRawObjectEntryKnownName${methodStem}${suffix}(" +
            "${first}, ${plan.field.jsonNameExpr}, ${value})"
    }

    let nameKind = if (plan.usesKnownName) { "KnownName" } else { "Name" }
    "${first} = ${receiver}.writeRawObjectEntry${nameKind}(" +
        "${first}, ${plan.field.jsonNameExpr}); " +
        "if (!${tryWrite}(writer, ${value})) { " +
        "throw JsonException(\"Compact raw codec is unavailable\") }"
}

internal func renderCompactCursorContainerField(
    plan: FieldWritePlan,
    value: String,
    first: String
): String {
    renderCompactContainerField(plan, value, first, "__writer", false)
}

internal func renderCompactDirectContainerField(
    plan: FieldWritePlan,
    value: String,
    first: String
): String {
    renderCompactContainerField(plan, value, first, "writer", true)
}
