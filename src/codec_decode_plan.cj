macro package yjson_macros

import std.collection.*

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
