macro package yjson_macros

internal enum CompactWriteOp {
    Unsupported |
    BoolValue |
    Int64Value | Int64Widened |
    UInt64Value | UInt64Widened |
    Float64Value | Float64Widened |
    StringValue |
    OptionalInt64Value | OptionalStringValue |
    Int64Array | Float64Array | StringArray |
    Int64ArrayList | StringArrayList |
    Int64Map | StringMap | Int64ArrayMap |
    PrimitiveSequence | PrimitiveMap | PrimitiveSequenceMap
}

internal enum PrimitiveCompactWriteOp {
    Unsupported |
    BoolValue | SignedInteger | UnsignedInteger | FloatValue | StringValue
}

private func primitiveCompactWriteOp(typeText: String): PrimitiveCompactWriteOp {
    match (typeText) {
        case "Bool" => PrimitiveCompactWriteOp.BoolValue
        case "Int8" | "Int16" | "Int32" | "Int64" =>
            PrimitiveCompactWriteOp.SignedInteger
        case "UInt8" | "UInt16" | "UInt32" | "UInt64" =>
            PrimitiveCompactWriteOp.UnsignedInteger
        case "Float16" | "Float32" | "Float64" =>
            PrimitiveCompactWriteOp.FloatValue
        case "String" => PrimitiveCompactWriteOp.StringValue
        case _ => PrimitiveCompactWriteOp.Unsupported
    }
}

private func compactSequenceInnerType(typeText: String): String {
    if (typeText.startsWith("Array<") && typeText.endsWith(">")) {
        return typeText[6..typeText.size - 1]
    }
    if (typeText.startsWith("ArrayList<") && typeText.endsWith(">")) {
        return typeText[10..typeText.size - 1]
    }
    ""
}

private func classifyPrimitiveContainer(
    normalized: String
): (CompactWriteOp, PrimitiveCompactWriteOp) {
    let innerType = compactSequenceInnerType(normalized)
    if (!innerType.isEmpty()) {
        let itemOp = primitiveCompactWriteOp(innerType)
        match (itemOp) {
            case PrimitiveCompactWriteOp.Unsupported => ()
            case _ => return (CompactWriteOp.PrimitiveSequence, itemOp)
        }
    }

    let mapPrefix = "HashMap<String,"
    if (!normalized.startsWith(mapPrefix) || !normalized.endsWith(">")) {
        return (CompactWriteOp.Unsupported, PrimitiveCompactWriteOp.Unsupported)
    }
    let mapValueType = normalized[mapPrefix.size..normalized.size - 1]
    let mapItemOp = primitiveCompactWriteOp(mapValueType)
    match (mapItemOp) {
        case PrimitiveCompactWriteOp.Unsupported => ()
        case _ => return (CompactWriteOp.PrimitiveMap, mapItemOp)
    }

    let mapInnerType = compactSequenceInnerType(mapValueType)
    let nestedItemOp = primitiveCompactWriteOp(mapInnerType)
    match (nestedItemOp) {
        case PrimitiveCompactWriteOp.Unsupported =>
            (CompactWriteOp.Unsupported, PrimitiveCompactWriteOp.Unsupported)
        case _ => (CompactWriteOp.PrimitiveSequenceMap, nestedItemOp)
    }
}

private func classifyCompactWrite(
    normalized: String
): (CompactWriteOp, PrimitiveCompactWriteOp) {
    let exactOp = match (normalized) {
        case "Bool" => CompactWriteOp.BoolValue
        case "Int64" => CompactWriteOp.Int64Value
        case "Int32" | "Int16" | "Int8" => CompactWriteOp.Int64Widened
        case "UInt64" => CompactWriteOp.UInt64Value
        case "UInt32" | "UInt16" | "UInt8" => CompactWriteOp.UInt64Widened
        case "Float64" => CompactWriteOp.Float64Value
        case "Float32" | "Float16" => CompactWriteOp.Float64Widened
        case "String" => CompactWriteOp.StringValue
        case "Option<Int64>" => CompactWriteOp.OptionalInt64Value
        case "Option<String>" => CompactWriteOp.OptionalStringValue
        case "Array<Int64>" => CompactWriteOp.Int64Array
        case "Array<Float64>" => CompactWriteOp.Float64Array
        case "Array<String>" => CompactWriteOp.StringArray
        case "ArrayList<Int64>" => CompactWriteOp.Int64ArrayList
        case "ArrayList<String>" => CompactWriteOp.StringArrayList
        case "HashMap<String,Int64>" => CompactWriteOp.Int64Map
        case "HashMap<String,String>" => CompactWriteOp.StringMap
        case "HashMap<String,Array<Int64>>" => CompactWriteOp.Int64ArrayMap
        case _ => CompactWriteOp.Unsupported
    }
    match (exactOp) {
        case CompactWriteOp.Unsupported => classifyPrimitiveContainer(normalized)
        case _ => (exactOp, PrimitiveCompactWriteOp.Unsupported)
    }
}

internal class FieldWritePlan {
    let field: CodecField
    let compactOp: CompactWriteOp
    let primitiveOp: PrimitiveCompactWriteOp
    let usesKnownName: Bool

    init(field: CodecField) {
        this.field = field
        usesKnownName = field.jsonNameExpr == "\"${field.name}\""
        if (!field.codecExpr.isEmpty()) {
            compactOp = CompactWriteOp.Unsupported
            primitiveOp = PrimitiveCompactWriteOp.Unsupported
        } else {
            let (resolvedOp, resolvedPrimitiveOp) = classifyCompactWrite(
                field.capabilities.typeShape.normalized)
            compactOp = resolvedOp
            primitiveOp = resolvedPrimitiveOp
        }
    }

    func hasScalarOp(): Bool {
        match (compactOp) {
            case CompactWriteOp.BoolValue |
                 CompactWriteOp.Int64Value | CompactWriteOp.Int64Widened |
                 CompactWriteOp.UInt64Value | CompactWriteOp.UInt64Widened |
                 CompactWriteOp.Float64Value | CompactWriteOp.Float64Widened |
                 CompactWriteOp.StringValue |
                 CompactWriteOp.OptionalInt64Value |
                 CompactWriteOp.OptionalStringValue => true
            case _ => false
        }
    }

    func hasCompactOp(): Bool {
        match (compactOp) {
            case CompactWriteOp.Unsupported => false
            case _ => true
        }
    }

    func needsCachedDirectCursor(): Bool {
        !hasCompactOp() && (!field.codecExpr.isEmpty() || field.isOption)
    }

    func supportsScalarBatch(): Bool {
        match (compactOp) {
            case CompactWriteOp.BoolValue |
                 CompactWriteOp.Int64Value | CompactWriteOp.Int64Widened |
                 CompactWriteOp.UInt64Value | CompactWriteOp.UInt64Widened |
                 CompactWriteOp.Float64Value | CompactWriteOp.Float64Widened |
                 CompactWriteOp.StringValue => true
            case _ => false
        }
    }

}
