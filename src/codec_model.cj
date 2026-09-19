macro package yjson_macros

import std.ast.*
import std.collection.*

internal class CodecFieldDeclaration {
    let name: String
    let typeText: String
    let mutable: Bool
    let hasDefault: Bool

    init(name: String, typeText: String, mutable: Bool, hasDefault: Bool) {
        this.name = name
        this.typeText = typeText
        this.mutable = mutable
        this.hasDefault = hasDefault
    }
}

internal class JsonFieldPolicy {
    let jsonNameExpr: String
    let aliases: ArrayList<String>
    let isOption: Bool
    let optionInner: String
    let includeNull: Bool
    let codecExpr: String
    let writeField: Bool

    init(
        jsonNameExpr: String,
        aliases: ArrayList<String>,
        isOption: Bool,
        optionInner: String,
        includeNull: Bool,
        codecExpr: String,
        writeField!: Bool = true
    ) {
        this.jsonNameExpr = jsonNameExpr
        this.aliases = aliases
        this.isOption = isOption
        this.optionInner = optionInner
        this.includeNull = includeNull
        this.codecExpr = codecExpr
        this.writeField = writeField
    }
}

internal class CodecField {
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
    let capabilities: FieldCapabilities

    init(declaration: CodecFieldDeclaration, policy: JsonFieldPolicy) {
        name = declaration.name
        typeText = declaration.typeText
        mutable = declaration.mutable
        hasDefault = declaration.hasDefault
        jsonNameExpr = policy.jsonNameExpr
        aliases = policy.aliases
        isOption = policy.isOption
        optionInner = policy.optionInner
        includeNull = policy.includeNull
        codecExpr = policy.codecExpr
        writeField = policy.writeField
        capabilities = FieldCapabilities(
            declaration.typeText,
            !policy.codecExpr.isEmpty(),
            policy.isOption
        )
    }
}

internal class CodecConstructorParam {
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

internal class PolymorphicSubtype {
    let wireNameExpr: String
    let typeText: String

    init(wireNameExpr: String, typeText: String) {
        this.wireNameExpr = wireNameExpr
        this.typeText = typeText
    }
}

internal class PolymorphicCodecModel {
    let visibility: String
    let name: String
    let fields: ArrayList<CodecField>
    let genericNames: ArrayList<String>
    let genericText: String
    let targetType: String
    let constraints: String
    let codecName: String
    let codecProviderName: String
    let discriminator: String
    let subtypes: ArrayList<PolymorphicSubtype>

    init(
        visibility: String,
        name: String,
        fields: ArrayList<CodecField>,
        genericNames: ArrayList<String>,
        genericText: String,
        targetType: String,
        constraints: String,
        codecName: String,
        codecProviderName: String,
        discriminator: String,
        subtypes: ArrayList<PolymorphicSubtype>
    ) {
        this.visibility = visibility
        this.name = name
        this.fields = fields
        this.genericNames = genericNames
        this.genericText = genericText
        this.targetType = targetType
        this.constraints = constraints
        this.codecName = codecName
        this.codecProviderName = codecProviderName
        this.discriminator = discriminator
        this.subtypes = subtypes
    }
}

internal class ObjectCodecModel {
    let declaration: Decl
    let name: String
    let fields: ArrayList<CodecField>
    let constructorParams: ArrayList<CodecConstructorParam>
    let genericNames: ArrayList<String>
    let genericText: String
    let targetType: String
    let constraints: String
    let codecName: String
    let inheritedObjectType: String
    let isClass: Bool
    let staticCompact: Bool
    let readPlans = ArrayList<FieldReadPlan>()
    let fastLabels = ArrayList<(FieldReadPlan, String)>()
    let fastLabelBytes = ArrayList<String>()

    init(
        declaration: Decl,
        name: String,
        fields: ArrayList<CodecField>,
        constructorParams: ArrayList<CodecConstructorParam>,
        genericNames: ArrayList<String>,
        genericText: String,
        targetType: String,
        constraints: String,
        codecName: String,
        inheritedObjectType: String,
        isClass: Bool,
        staticCompact: Bool
    ) {
        this.declaration = declaration
        this.name = name
        this.fields = fields
        this.constructorParams = constructorParams
        this.genericNames = genericNames
        this.genericText = genericText
        this.targetType = targetType
        this.constraints = constraints
        this.codecName = codecName
        this.inheritedObjectType = inheritedObjectType
        this.isClass = isClass
        this.staticCompact = staticCompact
        for (field in fields) {
            let readPlan = FieldReadPlan(field)
            readPlans.add(readPlan)
            fastLabels.add((readPlan, field.jsonNameExpr))
            fastLabelBytes.add("(${field.jsonNameExpr}).rawData()")
            for (alias in field.aliases) {
                fastLabels.add((readPlan, alias))
                fastLabelBytes.add("(${alias}).rawData()")
            }
        }
    }
}
