macro package yjson_macros

import std.ast.*
import std.collection.*
import std.convert.Parsable

private enum JsonLiteralKind {
    Null | Boolean | String | Number | Interpolation | Array | Object
}

private class JsonLiteralBinding {
    let name: String
    let expression: String
    let keyBinding: Bool

    init(name: String, expression: String, keyBinding: Bool) {
        this.name = name
        this.expression = expression
        this.keyBinding = keyBinding
    }
}

private class JsonLiteralField {
    let keyExpression: String
    let staticKey: Bool
    let staticIdentity: String
    let value: JsonLiteralNode

    init(
        keyExpression: String,
        staticKey: Bool,
        staticIdentity: String,
        value: JsonLiteralNode
    ) {
        this.keyExpression = keyExpression
        this.staticKey = staticKey
        this.staticIdentity = staticIdentity
        this.value = value
    }
}

private class JsonLiteralNode {
    let kind: JsonLiteralKind
    let text: String
    let items: ArrayList<JsonLiteralNode>
    let fields: ArrayList<JsonLiteralField>

    init(
        kind: JsonLiteralKind,
        text!: String = "",
        items!: ArrayList<JsonLiteralNode> = ArrayList<JsonLiteralNode>(),
        fields!: ArrayList<JsonLiteralField> = ArrayList<JsonLiteralField>()
    ) {
        this.kind = kind
        this.text = text
        this.items = items
        this.fields = fields
    }
}

private class JsonLiteralDocument {
    let root: JsonLiteralNode
    let bindings: ArrayList<JsonLiteralBinding>

    init(root: JsonLiteralNode, bindings: ArrayList<JsonLiteralBinding>) {
        this.root = root
        this.bindings = bindings
    }
}

private func jsonLiteralHexValue(value: Rune): UInt32 {
    let code = UInt32(value)
    if (value >= r'0' && value <= r'9') { return code - UInt32(r'0') }
    if (value >= r'a' && value <= r'f') { return code - UInt32(r'a') + 10u32 }
    code - UInt32(r'A') + 10u32
}

// Token.value retains the source escape spelling. Decode it only for static
// duplicate-key detection; the original token is emitted into the caller.
private func jsonLiteralStaticStringValue(value: String): String {
    let runes = value.toRuneArray()
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < runes.size) {
        let current = runes[index]
        index++
        if (current != r'\\') {
            builder.append(current)
            continue
        }
        let escaped = runes[index]
        index++
        match (escaped) {
            case r'0' => builder.append(r'\0')
            case r'\\' => builder.append(r'\\')
            case r'b' => builder.append(r'\b')
            case r'f' => builder.append(r'\f')
            case r'n' => builder.append(r'\n')
            case r'r' => builder.append(r'\r')
            case r't' => builder.append(r'\t')
            case r'v' => builder.append(r'\v')
            case r'\'' => builder.append(r'\'')
            case r'"' => builder.append(r'"')
            case r'u' =>
                index++ // '{'
                var codePoint = 0u32
                while (runes[index] != r'}') {
                    codePoint = codePoint * 16u32 + jsonLiteralHexValue(runes[index])
                    index++
                }
                index++ // '}'
                builder.append(Rune(codePoint))
            case _ => builder.append(escaped)
        }
    }
    builder.toString()
}

private func isJsonDigit(value: Rune): Bool {
    value >= r'0' && value <= r'9'
}

private func isStrictJsonNumber(text: String): Bool {
    let values = text.toRuneArray()
    var index: Int64 = 0
    if (index < values.size && values[index] == r'-') { index++ }
    if (index >= values.size) { return false }
    if (values[index] == r'0') {
        index++
        if (index < values.size && isJsonDigit(values[index])) { return false }
    } else {
        if (values[index] < r'1' || values[index] > r'9') { return false }
        index++
        while (index < values.size && isJsonDigit(values[index])) { index++ }
    }
    if (index < values.size && values[index] == r'.') {
        index++
        if (index >= values.size || !isJsonDigit(values[index])) { return false }
        while (index < values.size && isJsonDigit(values[index])) { index++ }
    }
    if (index < values.size && (values[index] == r'e' || values[index] == r'E')) {
        index++
        if (index < values.size && (values[index] == r'+' || values[index] == r'-')) { index++ }
        if (index >= values.size || !isJsonDigit(values[index])) { return false }
        while (index < values.size && isJsonDigit(values[index])) { index++ }
    }
    index == values.size
}

private class JsonLiteralParser {
    private let tokens: Tokens
    private var index: Int64 = 0
    private var bindingIndex: Int64 = 0
    private let bindings = ArrayList<JsonLiteralBinding>()

    init(tokens: Tokens) {
        this.tokens = tokens
    }

    func parse(): JsonLiteralDocument {
        let root = parseValue()
        skipTrivia()
        if (index != tokens.size) {
            fail("unexpected token '${tokens[index].toTokens().toString()}' after the root value")
        }
        JsonLiteralDocument(root, bindings)
    }

    private func fail(message: String): Nothing {
        throw Exception("JSON literal syntax error: ${message}")
    }

    private func skipTrivia(): Unit {
        while (index < tokens.size) {
            match (tokens[index].kind) {
                case TokenKind.NL | TokenKind.COMMENT => index++
                case _ => return
            }
        }
    }

    private func at(kind: TokenKind): Bool {
        skipTrivia()
        index < tokens.size && tokens[index].kind == kind
    }

    private func take(kind: TokenKind, expected: String): Token {
        skipTrivia()
        if (index >= tokens.size || tokens[index].kind != kind) { fail("expected ${expected}") }
        let result = tokens[index]
        index++
        result
    }

    private func parseValue(): JsonLiteralNode {
        skipTrivia()
        if (index >= tokens.size) { fail("expected a value") }
        let token = tokens[index]
        match (token.kind) {
            case TokenKind.LCURL => parseObject()
            case TokenKind.LSQUARE => parseArray()
            case TokenKind.STRING_LITERAL =>
                let source = token.toTokens().toString().trimAscii()
                if (!source.startsWith("\"")) { fail("only double-quoted strings are supported") }
                index++
                JsonLiteralNode(JsonLiteralKind.String, text: source)
            case TokenKind.BOOL_LITERAL =>
                index++
                JsonLiteralNode(JsonLiteralKind.Boolean, text: token.value)
            case TokenKind.INTEGER_LITERAL | TokenKind.FLOAT_LITERAL => parseNumber(false)
            case TokenKind.SUB => parseNumber(true)
            case TokenKind.DOLLAR =>
                let binding = parseInterpolation(false)
                JsonLiteralNode(JsonLiteralKind.Interpolation, text: binding.name)
            case TokenKind.IDENTIFIER =>
                if (token.value != "null") { fail("unsupported identifier '${token.value}'") }
                index++
                JsonLiteralNode(JsonLiteralKind.Null)
            case _ => fail("expected an object, array, string, number, boolean, null, or $() interpolation")
        }
    }

    private func parseNumber(negative: Bool): JsonLiteralNode {
        let builder = StringBuilder()
        if (negative) {
            let _ = take(TokenKind.SUB, "a minus sign")
            builder.append("-")
        }
        skipTrivia()
        if (index >= tokens.size) { fail("expected digits after '-'") }
        let token = tokens[index]
        if (token.kind != TokenKind.INTEGER_LITERAL && token.kind != TokenKind.FLOAT_LITERAL) {
            fail("expected a JSON number")
        }
        index++
        builder.append(token.value)
        let text = builder.toString()
        if (!isStrictJsonNumber(text)) { fail("'${text}' is not a strict JSON number") }
        JsonLiteralNode(JsonLiteralKind.Number, text: text)
    }

    private func parseArray(): JsonLiteralNode {
        let _ = take(TokenKind.LSQUARE, "'['")
        let items = ArrayList<JsonLiteralNode>()
        if (at(TokenKind.RSQUARE)) {
            let _ = take(TokenKind.RSQUARE, "']'")
            return JsonLiteralNode(JsonLiteralKind.Array, items: items)
        }
        while (true) {
            items.add(parseValue())
            if (at(TokenKind.RSQUARE)) {
                let _ = take(TokenKind.RSQUARE, "']'")
                break
            }
            let _ = take(TokenKind.COMMA, "',' or ']'")
            if (at(TokenKind.RSQUARE)) {
                let _ = take(TokenKind.RSQUARE, "']'")
                break
            }
        }
        JsonLiteralNode(JsonLiteralKind.Array, items: items)
    }

    private func parseObject(): JsonLiteralNode {
        let _ = take(TokenKind.LCURL, "'{'")
        let fields = ArrayList<JsonLiteralField>()
        let staticKeys = ArrayList<String>()
        if (at(TokenKind.RCURL)) {
            let _ = take(TokenKind.RCURL, "'}'")
            return JsonLiteralNode(JsonLiteralKind.Object, fields: fields)
        }
        while (true) {
            skipTrivia()
            if (index >= tokens.size) { fail("expected an object key") }
            var keyExpression = ""
            var staticKey = false
            var staticIdentity = ""
            if (tokens[index].kind == TokenKind.STRING_LITERAL) {
                let token = tokens[index]
                keyExpression = token.toTokens().toString().trimAscii()
                if (!keyExpression.startsWith("\"")) {
                    fail("object keys must use double-quoted strings or $()")
                }
                staticKey = true
                staticIdentity = jsonLiteralStaticStringValue(token.value)
                for (existing in staticKeys) {
                    if (existing == staticIdentity) { fail("duplicate static object key ${keyExpression}") }
                }
                staticKeys.add(staticIdentity)
                index++
            } else if (tokens[index].kind == TokenKind.DOLLAR) {
                let binding = parseInterpolation(true)
                keyExpression = binding.name
            } else {
                fail("object keys must use double-quoted strings or $()")
            }
            let _ = take(TokenKind.COLON, "':' after an object key")
            fields.add(JsonLiteralField(keyExpression, staticKey, staticIdentity, parseValue()))
            if (at(TokenKind.RCURL)) {
                let _ = take(TokenKind.RCURL, "'}'")
                break
            }
            let _ = take(TokenKind.COMMA, "',' or '}'")
            if (at(TokenKind.RCURL)) {
                let _ = take(TokenKind.RCURL, "'}'")
                break
            }
        }
        JsonLiteralNode(JsonLiteralKind.Object, fields: fields)
    }

    private func parseInterpolation(keyBinding: Bool): JsonLiteralBinding {
        let _ = take(TokenKind.DOLLAR, "'$'")
        let _ = take(TokenKind.LPAREN, "'(' after '$'")
        let expressionTokens = Tokens()
        var depth: Int64 = 1
        while (index < tokens.size) {
            let token = tokens[index]
            index++
            if (token.kind == TokenKind.LPAREN) {
                depth++
                expressionTokens.append(token)
                continue
            }
            if (token.kind == TokenKind.RPAREN) {
                depth--
                if (depth == 0) { break }
                expressionTokens.append(token)
                continue
            }
            expressionTokens.append(token)
        }
        if (depth != 0) { fail("unterminated $() interpolation") }
        let expression = expressionTokens.toString().trimAscii()
        if (expression.isEmpty()) { fail("$() interpolation cannot be empty") }
        let name = "__yjson_literal_binding_${bindingIndex}"
        bindingIndex++
        let binding = JsonLiteralBinding(name, expression, keyBinding)
        bindings.add(binding)
        binding
    }
}

private func jsonLiteralAppendLine(builder: StringBuilder, level: Int64, value: String): Unit {
    for (_ in 0..level) { builder.append("    ") }
    builder.append(value)
    builder.append("\n")
}

private class JsonLiteralRenderer {
    private var localIndex: Int64 = 0

    private func localName(prefix: String): String {
        let result = "__yjson_literal_${prefix}_${localIndex}"
        localIndex++
        result
    }

    func render(document: JsonLiteralDocument): Tokens {
        let builder = StringBuilder()
        jsonLiteralAppendLine(builder, 0, "({ =>")
        for (binding in document.bindings) {
            let typeText = if (binding.keyBinding) { ": String" } else { "" }
            jsonLiteralAppendLine(builder, 1,
                "let ${binding.name}${typeText} = (${binding.expression})")
        }
        jsonLiteralAppendLine(builder, 1, renderNode(document.root))
        jsonLiteralAppendLine(builder, 0, "})()")
        cangjieLex(builder.toString())
    }

    private func objectNeedsSlots(node: JsonLiteralNode): Bool {
        for (field in node.fields) {
            if (!field.staticKey) { return true }
        }
        false
    }

    private func renderObjectSlots(node: JsonLiteralNode, builder: StringBuilder, level: Int64): String {
        if (!objectNeedsSlots(node)) { return "" }
        let slots = localName("slots")
        jsonLiteralAppendLine(builder, level, "let ${slots} = YJsonHashMap<String, Int64>()")
        for (index in 0..node.fields.size) {
            jsonLiteralAppendLine(builder, level,
                "${slots}[${node.fields[index].keyExpression}] = ${index}")
        }
        slots
    }

    private func renderNode(node: JsonLiteralNode): String {
        match (node.kind) {
            case JsonLiteralKind.Null => "JsonNode.nullValue"
            case JsonLiteralKind.Boolean => "JsonNode.boolean(${node.text})"
            case JsonLiteralKind.String => "JsonNode.string(${node.text})"
            case JsonLiteralKind.Number => renderNumber(node.text)
            case JsonLiteralKind.Interpolation => "GeneratedSupportV1.nodeValue(${node.text})"
            case JsonLiteralKind.Array => renderArray(node)
            case JsonLiteralKind.Object => renderObject(node)
        }
    }

    private func renderNumber(text: String): String {
        if (!text.contains(".") && !text.contains("e") && !text.contains("E")) {
            try {
                let _ = Int64.parse(text)
                return "JsonNode.int64(${text})"
            } catch (_) {}
        }
        "JsonNode.number(\"${text}\")"
    }

    private func renderArray(node: JsonLiteralNode): String {
        let arrayName = localName("array")
        let builder = StringBuilder()
        jsonLiteralAppendLine(builder, 0, "({ =>")
        jsonLiteralAppendLine(builder, 1, "let ${arrayName} = JsonNode.array()")
        for (item in node.items) {
            jsonLiteralAppendLine(builder, 1,
                "let _ = ${arrayName}.add(${renderNode(item)})")
        }
        jsonLiteralAppendLine(builder, 1, arrayName)
        jsonLiteralAppendLine(builder, 0, "})()")
        builder.toString().trimAscii()
    }

    private func renderObject(node: JsonLiteralNode): String {
        let objectName = localName("object")
        let builder = StringBuilder()
        jsonLiteralAppendLine(builder, 0, "({ =>")
        jsonLiteralAppendLine(builder, 1, "let ${objectName} = JsonNode.object()")
        let slots = renderObjectSlots(node, builder, 1)
        for (index in 0..node.fields.size) {
            let field = node.fields[index]
            if (!slots.isEmpty()) {
                jsonLiteralAppendLine(builder, 1,
                    "if (${slots}[${field.keyExpression}] == ${index}) {")
            }
            let level = if (slots.isEmpty()) { 1 } else { 2 }
            jsonLiteralAppendLine(builder, level,
                "let _ = ${objectName}.put(${field.keyExpression}, ${renderNode(field.value)})")
            if (!slots.isEmpty()) { jsonLiteralAppendLine(builder, 1, "}") }
        }
        jsonLiteralAppendLine(builder, 1, objectName)
        jsonLiteralAppendLine(builder, 0, "})()")
        builder.toString().trimAscii()
    }
}

private func parseJsonLiteral(input: Tokens): JsonLiteralDocument {
    JsonLiteralParser(input).parse()
}

/// Builds a mutable JsonNode tree from JSON-like literal syntax. Runtime values
/// and dynamic String keys use $(). Every interpolation is evaluated once from
/// left to right; dynamic object-key collisions use LastWins.
public macro Json(input: Tokens): Tokens {
    JsonLiteralRenderer().render(parseJsonLiteral(input))
}

/// Explicit alias for callers migrating from the former literal macro name.
public macro JsonValue(input: Tokens): Tokens {
    JsonLiteralRenderer().render(parseJsonLiteral(input))
}
