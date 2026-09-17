macro package yjson_macros

import std.collection.*

internal enum PrimitiveFieldKind {
    Other |
    BoolValue |
    Int8Value | Int16Value | Int32Value | Int64Value |
    UInt8Value | UInt16Value | UInt32Value | UInt64Value |
    Float16Value | Float32Value | Float64Value |
    StringValue | RuneValue | BigIntValue | DecimalValue
}

internal class FieldTypeShape {
    let sourceText: String
    let normalized: String
    let primitive: PrimitiveFieldKind
    let generatedBuiltin: Bool

    init(sourceText: String) {
        this.sourceText = sourceText
        normalized = sourceText.replace(" ", "")
        primitive = match (normalized) {
            case "Bool" => PrimitiveFieldKind.BoolValue
            case "Int8" => PrimitiveFieldKind.Int8Value
            case "Int16" => PrimitiveFieldKind.Int16Value
            case "Int32" => PrimitiveFieldKind.Int32Value
            case "Int64" => PrimitiveFieldKind.Int64Value
            case "UInt8" => PrimitiveFieldKind.UInt8Value
            case "UInt16" => PrimitiveFieldKind.UInt16Value
            case "UInt32" => PrimitiveFieldKind.UInt32Value
            case "UInt64" => PrimitiveFieldKind.UInt64Value
            case "Float16" => PrimitiveFieldKind.Float16Value
            case "Float32" => PrimitiveFieldKind.Float32Value
            case "Float64" => PrimitiveFieldKind.Float64Value
            case "String" => PrimitiveFieldKind.StringValue
            case "Rune" => PrimitiveFieldKind.RuneValue
            case "BigInt" => PrimitiveFieldKind.BigIntValue
            case "Decimal" => PrimitiveFieldKind.DecimalValue
            case _ => PrimitiveFieldKind.Other
        }
        generatedBuiltin = match (normalized) {
            case "Bool" | "Int8" | "Int16" | "Int32" | "Int64" |
                 "UInt8" | "UInt16" | "UInt32" | "UInt64" |
                 "Float16" | "Float32" | "Float64" | "Rune" | "String" |
                 "BigInt" | "Decimal" | "DateTime" | "Duration" |
                 "JsonNode" | "JsonValue" | "JsonValueView" => true
            case _ => false
        }
    }
}

internal class FieldCapabilities {
    let typeShape: FieldTypeShape
    let usesCustomCodec: Bool
    let isOption: Bool

    init(typeText: String, usesCustomCodec: Bool, isOption: Bool) {
        typeShape = FieldTypeShape(typeText)
        this.usesCustomCodec = usesCustomCodec
        this.isOption = isOption
    }

    func generatedConcreteType(genericNames: ArrayList<String>): String {
        if (isOption || usesCustomCodec || typeShape.generatedBuiltin) { return "" }
        let normalized = typeShape.normalized
        for (genericName in genericNames) {
            if (normalized == genericName) { return "" }
        }
        if (normalized.contains("<") || normalized.contains(">") ||
            normalized.contains(".")) {
            return ""
        }
        normalized
    }

    func scalarScratchInitializer(): Option<String> {
        if (isOption || usesCustomCodec) { return None<String> }
        match (typeShape.primitive) {
            case PrimitiveFieldKind.BoolValue => Some("false")
            case PrimitiveFieldKind.Int8Value | PrimitiveFieldKind.Int16Value |
                 PrimitiveFieldKind.Int32Value | PrimitiveFieldKind.Int64Value |
                 PrimitiveFieldKind.UInt8Value | PrimitiveFieldKind.UInt16Value |
                 PrimitiveFieldKind.UInt32Value | PrimitiveFieldKind.UInt64Value |
                 PrimitiveFieldKind.Float16Value | PrimitiveFieldKind.Float32Value |
                 PrimitiveFieldKind.Float64Value => Some("${typeShape.normalized}(0)")
            case _ => None<String>
        }
    }
}
