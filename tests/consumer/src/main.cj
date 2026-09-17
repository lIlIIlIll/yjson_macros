package yjson_macros_characterization

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@JsonCodec
class CharacterizedRecord {
    @JsonName["record_id"]
    @JsonAlias["legacy_id"]
    public let id: Int64

    @JsonIncludeNull
    public let nickname: Option<String>

    public var active: Bool = false

    public init(id: Int64, nickname: Option<String>) {
        this.id = id
        this.nickname = nickname
    }
}

@JsonCodec
struct CharacterizedPoint {
    public let x: Int64
    public let y: Int64

    public init(x: Int64, y: Int64) {
        this.x = x
        this.y = y
    }
}

@JsonCodec
class CharacterizedBox<T> {
    public let value: T

    public init(value: T) {
        this.value = value
    }
}

@JsonCodec
class CharacterizedCustomCodec {
    @JsonUsing[JsonCodecs.array(JsonCodecs.int64)]
    public let values: Array<Int64>

    public init(values: Array<Int64>) {
        this.values = values
    }
}

@JsonCodec
enum CharacterizedEvent {
    Ready | Renamed(String, Int64)
}

@JsonCodec
@JsonSubtype["dog", CharacterizedDog]
@JsonSubtype["cat", CharacterizedCat]
@JsonPolymorphic[discriminator: "kind"]
open class CharacterizedAnimal {
    public let id: Int64

    public init(id: Int64) {
        this.id = id
    }
}

@JsonCodec
class CharacterizedDog <: CharacterizedAnimal {
    public let bark: String

    public init(id: Int64, bark: String) {
        super(id)
        this.bark = bark
    }
}

@JsonCodec
class CharacterizedCat <: CharacterizedAnimal {
    public let lives: Int64

    public init(id: Int64, lives: Int64) {
        super(id)
        this.lives = lives
    }
}

private func expectJsonError(code: String, action: () -> Unit): Unit {
    try {
        action()
        @Fail("expected JsonException with code ${code}")
    } catch (error: JsonException) {
        @Expect(error.code, code)
    }
}

@Test
class JsonCodecCharacterizationTest {
    @TestCase
    func objectRoundTripsAcrossPublicEntryPoints(): Unit {
        let encoded = YJson.toJson(CharacterizedRecord(7, None))
        @Expect(encoded, "{\"record_id\":7,\"nickname\":null,\"active\":false}")

        let semantic = YJson.fromJson<CharacterizedRecord>(encoded)
        let explicit = YJson.fromJson(encoded, codec: CharacterizedRecordJson)
        let bytes = YJson.fromJson(unsafe { encoded.rawData() }, codec: CharacterizedRecordJson)

        @Expect(semantic.id, 7)
        @Expect(explicit.id, 7)
        @Expect(bytes.id, 7)
        @Expect(semantic.nickname.isNone(), true)
        @Expect(semantic.active, false)
    }

    @TestCase
    func aliasesDefaultsAndReaderErrorsRemainStable(): Unit {
        let decoded = YJson.fromJson<CharacterizedRecord>(
            "{\"legacy_id\":8,\"nickname\":\"Ada\"}")
        @Expect(decoded.id, 8)
        @Expect(decoded.nickname.getOrThrow(), "Ada")
        @Expect(decoded.active, false)

        expectJsonError("duplicate_key", { =>
            let _ = YJson.fromJson<CharacterizedRecord>(
                "{\"record_id\":1,\"record_id\":2,\"nickname\":null}")
        })
        expectJsonError("unknown_field", { =>
            let _ = YJson.fromJson(
                "{\"record_id\":1,\"nickname\":null,\"extra\":true}",
                codec: CharacterizedRecordJson,
                options: JsonReadOptions(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)
            )
        })
    }

    @TestCase
    func structGenericAndCustomCodecShapesRoundTrip(): Unit {
        let point = YJson.fromJson<CharacterizedPoint>(
            YJson.toJson(CharacterizedPoint(3, 4)))
        @Expect(point.x, 3)
        @Expect(point.y, 4)

        let box = YJson.fromJson<CharacterizedBox<String>>(
            YJson.toJson(CharacterizedBox<String>("value")))
        @Expect(box.value, "value")

        let custom = YJson.fromJson<CharacterizedCustomCodec>(
            YJson.toJson(CharacterizedCustomCodec([1, 2, 3])))
        @Expect(custom.values.size, 3)
        @Expect(custom.values[2], 3)
    }

    @TestCase
    func enumAndPolymorphicShapesRoundTrip(): Unit {
        match (YJson.fromJson<CharacterizedEvent>(
            YJson.toJson(CharacterizedEvent.Renamed("Ada", 9)))) {
            case CharacterizedEvent.Renamed(name, revision) =>
                @Expect(name, "Ada")
                @Expect(revision, 9)
            case _ => @Fail("associated enum constructor was not preserved")
        }

        let animal: CharacterizedAnimal = CharacterizedDog(41, "loud")
        let encoded = YJson.toJson(animal)
        @Expect(encoded, "{\"kind\":\"dog\",\"id\":41,\"bark\":\"loud\"}")
        match (YJson.fromJson<CharacterizedAnimal>(encoded)) {
            case dog: CharacterizedDog =>
                @Expect(dog.id, 41)
                @Expect(dog.bark, "loud")
            case _ => @Fail("runtime subtype was not preserved")
        }
    }

    @TestCase
    func literalMacrosPreserveOrderingAndInterpolation(): Unit {
        let dynamicKey = "user"
        let literal = @Json({
            "a": 1,
            $(dynamicKey): $(CharacterizedRecord(9, Some("Lin"))),
            "nested": [true, null, -3, 1.5],
        })
        @Expect(
            literal.toJson(),
            "{\"a\":1,\"user\":{\"record_id\":9,\"nickname\":\"Lin\",\"active\":false},\"nested\":[true,null,-3,1.5]}"
        )

        let alias = @JsonValue({"ok": true})
        @Expect(alias.asObject().get("ok").getOrThrow().asBool(), true)
    }
}

main(): Unit {}
