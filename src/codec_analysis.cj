macro package yjson_macros

import std.ast.*
import std.collection.*

internal func hasModifier(decl: Decl, kind: TokenKind): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.keyword.kind == kind) { return true }
    }
    false
}

internal func hasAnnotation(decl: Decl, name: String): Bool {
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) { return true }
    }
    false
}

internal func annotationArguments(decl: Decl, name: String): ArrayList<String> {
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

internal func constructorAnnotationArguments(
    constructor: Constructor,
    name: String
): ArrayList<String> {
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

internal func optionInner(typeNode: TypeNode): Option<String> {
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
            return try {
                fieldHasMarker(parseDecl(macroDecl.macroInputs), field, name)
            } catch (_) {
                false
            }
        case _ => false
    }
}

private func collectFieldArguments(
    wrapper: Decl,
    field: Decl,
    name: String
): ArrayList<String> {
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

internal func namedArgumentValue(value: String): String {
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
    if (foundColon) {
        result.toString().trimAscii()
    } else {
        retainedExpression(value)
    }
}

internal func addUnique(values: ArrayList<String>, value: String): Unit {
    for (existing in values) {
        if (existing == value) { return }
    }
    values.add(value)
}

internal func parseSubtypeExpression(expression: String): PolymorphicSubtype {
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
                if (depth == 0 && !foundComma) {
                    foundComma = true
                    continue
                }
            case _ => ()
        }
        if (foundComma) { right.append(token) } else { left.append(token) }
    }
    let wireName = left.toString().trimAscii()
    let typeText = right.toString().trimAscii()
    if (!foundComma || wireName.isEmpty() || typeText.isEmpty()) {
        throw Exception(
            "@JsonSubtype expects a wire name and concrete type, " +
            "for example @JsonSubtype[\"dog\", Dog]")
    }
    PolymorphicSubtype(wireName, typeText)
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

internal func collectFields(body: Body): ArrayList<CodecField> {
    let result = ArrayList<CodecField>()
    let seenJsonNames = HashSet<String>()
    for (member in body.decls) {
        let decl = unwrapField(member)
        if (let Some(field) <- (decl as VarDecl)) {
            if (hasModifier(field, TokenKind.STATIC) ||
                fieldHasMarker(member, field, "JsonIgnore")) {
                continue
            }
            let isPublic = hasModifier(field, TokenKind.PUBLIC)
            let isPrivate = hasModifier(field, TokenKind.PRIVATE)
            if (isPrivate || !isPublic) {
                continue
            }
            let typeNode = try { field.declType } catch (_: ASTException) {
                throw Exception("@JsonCodec requires an explicit type for `${field.identifier.value}`")
            }
            let names = collectFieldArguments(member, field, "JsonName")
            let jsonExpr = if (names.isEmpty()) {
                "\"${field.identifier.value}\""
            } else {
                names[0]
            }
            if (seenJsonNames.contains(jsonExpr)) {
                throw Exception("duplicate JSON name ${jsonExpr}")
            }
            seenJsonNames.add(jsonExpr)
            let aliases = collectFieldArguments(member, field, "JsonAlias")
            for (alias in aliases) {
                if (seenJsonNames.contains(alias)) {
                    throw Exception("duplicate JSON name or alias ${alias}")
                }
                seenJsonNames.add(alias)
            }
            let fieldTypeText = typeNode.toTokens().toString().trimAscii()
            let astInner = optionInner(typeNode)
            let inner = if (astInner.isSome()) {
                astInner
            } else {
                optionInnerText(fieldTypeText)
            }
            let customCodecs = collectFieldArguments(member, field, "JsonUsing")
            for (encoded in collectFieldArguments(member, field, "JsonUsingMetadata")) {
                customCodecs.add(retainedExpression(encoded))
            }
            if (customCodecs.size > 1) {
                throw Exception(
                    "@JsonUsing accepts exactly one codec expression for `${field.identifier.value}`")
            }
            result.add(CodecField(
                CodecFieldDeclaration(
                    field.identifier.value,
                    fieldTypeText,
                    field.keyword.kind == TokenKind.VAR,
                    hasInitializer(field)
                ),
                JsonFieldPolicy(
                    jsonExpr,
                    aliases,
                    inner.isSome(),
                    inner.getOrDefault({ => "" }),
                    fieldHasMarker(member, field, "JsonIncludeNull"),
                    if (customCodecs.isEmpty()) { "" } else { customCodecs[0] }
                )
            ))
        }
    }
    result
}

internal func constructorParams(body: Body): ArrayList<CodecConstructorParam> {
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

internal func genericNames(decl: Decl): ArrayList<String> {
    let result = ArrayList<String>()
    try {
        let generic = decl.genericParam
        for (token in generic.parameters) {
            if (token.kind == TokenKind.IDENTIFIER) { result.add(token.value) }
        }
    } catch (_: ASTException) {}
    result
}

internal func analyzePolymorphicCodec(
    decl: ClassDecl,
    wrappedSubtypeExpressions: ArrayList<String>,
    wrappedDiscriminatorArguments: ArrayList<String>
): PolymorphicCodecModel {
    let name = decl.identifier.value
    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    let fields = collectFields(decl.body)
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedConstraints(decl, fields, generics)
    let codecName = "__YJsonCodec_${name}"
    let discriminatorArgs = annotationArguments(decl, "JsonPolymorphic")
    discriminatorArgs.add(all: wrappedDiscriminatorArguments)
    let discriminator = if (discriminatorArgs.isEmpty()) {
        "\"type\""
    } else {
        namedArgumentValue(discriminatorArgs[0])
    }

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

    PolymorphicCodecModel(
        visibility,
        name,
        fields,
        generics,
        genericText,
        targetType,
        constraints,
        codecName,
        "${name}Json",
        discriminator,
        subtypes
    )
}
