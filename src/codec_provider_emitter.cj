macro package yjson_macros

import std.ast.*
import std.collection.*

internal func appendObjectProviders(sb: StringBuilder, model: ObjectCodecModel): Unit {
    let decl = model.declaration
    let name = model.name
    let generics = model.genericNames
    let genericText = model.genericText
    let targetType = model.targetType
    let constraints = model.constraints
    let codecName = model.codecName
    let inheritedObjectType = model.inheritedObjectType
    let staticCompact = model.staticCompact
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
                appendLine(sb, 0, "extend YJson {")
                appendLine(sb, 1, "public static func toJson(value: ${name}, codec!: GeneratedCompactCursorWriteCodecV1<${name}>, options!: JsonWriteOptions = JsonWriteOptions.defaults): String {")
                appendLine(sb, 2, "GeneratedSupportV1.enterGeneratedEntry()")
                appendLine(sb, 2, "let writer = YJson.acquireGeneratedCompactStringWriter(options)")
                appendLine(sb, 2, "try {")
                appendLine(sb, 3, "if (writer.tryBeginGeneratedCompactRawValue()) {")
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
        return
    }

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
