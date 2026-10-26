package yjson_macros_characterization

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@JsonCodec
struct MutableDefaultStruct {
    public var id: Int64 = 3
    public var label: String = "default"

    public init() {}
}

@JsonCodec
struct MutableIgnoredStruct {
    public var visible: Int64 = 7
    @JsonIgnore
    public var secret: Int64 = 9

    public init() {}
}

@JsonCodec
struct MutableIncludedNullStruct {
    @JsonIncludeNull
    public var optional: Option<Int64> = None<Int64>

    public init() {}
}

@JsonCodec
struct MutablePostConstructorStruct {
    public let id: Int64
    public var count: Int64 = 4

    public init(id: Int64) { this.id = id }
}

private func decodeMutableStructPaths<T>(text: String, codec: JsonCodec<T>): Array<T>
    where T <: GeneratedCodecProviderV1<T> {
    [
        YJson.fromJson<T>(text),
        YJson.fromJson(text, codec: codec, options: JsonReadOptions(maxDepth: 32)),
        YJson.fromJson<T>(text.toArray()),
        YJson.fromJson<T>(YJsonByteArrayInputStream(text))
    ]
}

@Test
class MutableStructDecodeTest {
    @TestCase
    func defaultConstructedStructDecodesAcrossReaderPaths(): Unit {
        for (value in decodeMutableStructPaths("{\"id\":12,\"label\":\"read\"}", MutableDefaultStructJson)) {
            @Expect(value.id, 12)
            @Expect(value.label, "read")
            @Expect(YJson.fromJson<MutableDefaultStruct>(YJson.toJson(value)).id, 12)
        }
        for (value in decodeMutableStructPaths("{}", MutableDefaultStructJson)) {
            @Expect(value.id, 3)
            @Expect(value.label, "default")
        }
    }

    @TestCase
    func ignoredStructFieldKeepsItsDefaultAndStaysOutOfOutput(): Unit {
        for (value in decodeMutableStructPaths("{\"visible\":5,\"secret\":99}", MutableIgnoredStructJson)) {
            @Expect(value.visible, 5)
            @Expect(value.secret, 9)
            let encoded = JsonNode.parse(YJson.toJson(value))
            @Expect(encoded["visible"].asInt64(), 5)
            @Expect(encoded.member("secret").isNone(), true)
        }
    }

    @TestCase
    func includeNullStructFieldSupportsNullAndPresentValues(): Unit {
        for (value in decodeMutableStructPaths("{\"optional\":null}", MutableIncludedNullStructJson)) {
            @Expect(value.optional.isNone(), true)
            @Expect(JsonNode.parse(YJson.toJson(value))["optional"].isNull, true)
        }
        for (value in decodeMutableStructPaths("{\"optional\":11}", MutableIncludedNullStructJson)) {
            @Expect(value.optional.getOrThrow(), 11)
            @Expect(JsonNode.parse(YJson.toJson(value))["optional"].asInt64(), 11)
        }
        for (value in decodeMutableStructPaths("{}", MutableIncludedNullStructJson)) {
            @Expect(value.optional.isNone(), true)
        }
    }

    @TestCase
    func parameterizedStructAssignsFieldsOutsideItsConstructor(): Unit {
        for (value in decodeMutableStructPaths("{\"id\":5,\"count\":8}", MutablePostConstructorStructJson)) {
            @Expect(value.id, 5)
            @Expect(value.count, 8)
        }
        for (value in decodeMutableStructPaths("{\"id\":5}", MutablePostConstructorStructJson)) {
            @Expect(value.id, 5)
            @Expect(value.count, 4)
        }
    }
}
