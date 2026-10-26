@JsonCodec
class DocRecord {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) { this.id = id; this.name = name }
}

@JsonCodec
class DocCustomCodec {
    @JsonUsing[JsonCodecs.array(JsonCodecs.int64)]
    public let values: Array<Int64>
    public init(values: Array<Int64>) { this.values = values }
}

@JsonCodec
@JsonSubtype["dog", DocDog]
@JsonPolymorphic[discriminator: "kind"]
open class DocAnimal {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}

@JsonCodec
class DocDog <: DocAnimal {
    public let bark: String
    public init(id: Int64, bark: String) { super(id); this.bark = bark }
}
