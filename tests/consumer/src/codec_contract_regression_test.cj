package yjson_macros_characterization

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@JsonCodec
class ContractStringMap {
    public let entries: HashMap<String, String>
    public init(entries: HashMap<String, String>) { this.entries = entries }
}

@JsonCodec
class ContractItem {
    public let value: Int64
    public init(value: Int64) { this.value = value }
}

@JsonCodec
class ContractStrings {
    public let a: String
    public let b: String
    public init(a: String, b: String) { this.a = a; this.b = b }
}

@JsonCodec
class ContractSplitRecord {
    // CharacterizedRecord is declared in characterization_test.cj.
    public var record: CharacterizedRecord = CharacterizedRecord(0, None<String>)
    public init() {}
}

@JsonCodec
class ContractTagged <: ToString {
    public let id: Int64
    public init(id: Int64) { this.id = id }
    public func toString(): String { id.toString() }
}

@Test
class GeneratedCodecContractRegressionTest {
    @TestCase
    func stringMapFieldsApplyDecodedDuplicateKeyPolicy(): Unit {
        let text = "{\"entries\":{\"x\":\"first\",\"\\u0078\":\"last\"}}"
        let error = @AssertThrows[JsonException](
            YJson.fromJson(text, codec: ContractStringMapJson))
        @Expect(error.code, "duplicate_key")
        let accepted = YJson.fromJson(text, codec: ContractStringMapJson,
            options: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins))
        @Expect(accepted.entries["x"], "last")
    }

    @TestCase
    func collectionElementUnknownFieldsKeepDuplicateChecks(): Unit {
        let codec = JsonCodecs.array(ContractItemJson)
        let text = "[{\"value\":1,\"unknown\":{\"k\":2,\"\\u006b\":3}}]"
        let error = @AssertThrows[JsonException](YJson.fromJson(text, codec: codec))
        @Expect(error.code, "duplicate_key")
        @Expect(YJson.fromJson(text, codec: codec,
            options: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins))[0].value, 1)
    }

    @TestCase
    func escapedFieldExpansionDoesNotConsumeTheFollowingFieldBudget(): Unit {
        let a = String.fromUtf8(Array<Byte>(40, repeat: 1))
        let b = String.fromUtf8(Array<Byte>(200, repeat: b'x'))
        let text = YJson.toJson(ContractStrings(a, b), codec: ContractStringsJson)
        let decoded = JsonNode.parse(text)
        @Expect(decoded["a"].asString(), a)
        @Expect(decoded["b"].asString(), b)
    }

    @TestCase
    func mutableHolderUsesAnotherFilesGeneratedProvider(): Unit {
        let input = "{\"record\":{\"record_id\":7,\"nickname\":null,\"active\":true}}"
        let value = YJson.fromJson<ContractSplitRecord>(input)
        @Expect(value.record.id, 7)
        @Expect(value.record.nickname.isNone())
        @Expect(value.record.active)
        @Expect(YJson.toJson(value), input)
    }

    @TestCase
    func interfaceOnlyModelHasNoInheritedObjectFields(): Unit {
        let text = YJson.toJson(ContractTagged(8))
        @Expect(text, "{\"id\":8}")
        @Expect(YJson.fromJson<ContractTagged>(text).id, 8)
    }

    @TestCase
    func concreteStringReaderEnforcesTheDefaultBufferedValueLimit(): Unit {
        let text = String.fromUtf8(Array<Byte>(
            JsonReadOptions.defaults.maxBufferedValueBytes, repeat: b'x'))
        let error = @AssertThrows[JsonException](YJson.fromJson(
            "{\"a\":\"" + text + "\",\"b\":\"\"}", codec: ContractStringsJson))
        @Expect(error.code, "buffered_value_too_large")
    }
}
