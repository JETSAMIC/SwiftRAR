/// The fields of a FILE_HEAD (0x74) or NEWSUB_HEAD (0x7A) block
/// (Reference §3.6, §3.7). Both block types share this layout.
struct ClassicFileHeader {

    /// FILE_HEAD flag bits (Reference §3.6).
    enum Flag {
        static let splitBefore: UInt16 = 0x0001
        static let splitAfter: UInt16 = 0x0002
        static let encrypted: UInt16 = 0x0004
        static let embeddedComment: UInt16 = 0x0008
        static let solid: UInt16 = 0x0010
        static let dictionaryMask: UInt16 = 0x00E0
        static let large: UInt16 = 0x0100
        static let unicodeName: UInt16 = 0x0200
        static let salt: UInt16 = 0x0400
        static let extendedTime: UInt16 = 0x1000
    }

    /// Size of the fields every FILE_HEAD has, counted from HEAD_CRC.
    static let fixedSize = 32

    let flags: UInt16
    let packedSize: UInt64
    let unpackedSize: UInt64
    let hostOS: UInt8
    let fileCRC: UInt32
    let dosTime: UInt32
    let unpackVersion: UInt8
    let method: UInt8
    let attributes: UInt32
    let nameField: [UInt8]
    /// Offset just past FILE_NAME within the header bytes.
    let nameEnd: Int
    let extendedTime: ExtendedTime?

    /// Parse the header bytes of one block (starting at HEAD_CRC, exactly
    /// HEAD_SIZE long).
    ///
    /// - Throws: ``RARError/malformedHeader`` when a field does not fit in
    ///   HEAD_SIZE.
    init(header: [UInt8], flags: UInt16) throws {
        var reader = FieldReader(header, position: 7)
        let packedLow = try reader.uint32()
        let unpackedLow = try reader.uint32()
        hostOS = try reader.uint8()
        fileCRC = try reader.uint32()
        dosTime = try reader.uint32()
        unpackVersion = try reader.uint8()
        method = try reader.uint8()
        let nameLength = Int(try reader.uint16())
        attributes = try reader.uint32()

        var packedHigh: UInt32 = 0
        var unpackedHigh: UInt32 = 0
        if flags & Flag.large != 0 {
            packedHigh = try reader.uint32()
            unpackedHigh = try reader.uint32()
        }
        packedSize = UInt64(packedHigh) << 32 | UInt64(packedLow)
        unpackedSize = UInt64(unpackedHigh) << 32 | UInt64(unpackedLow)

        nameField = try reader.bytes(nameLength)
        nameEnd = reader.position

        if flags & Flag.salt != 0 {
            try reader.skip(8)
        }
        extendedTime = flags & Flag.extendedTime != 0 ? try ExtendedTime.parse(&reader) : nil
        self.flags = flags
    }

    var isDirectory: Bool { flags & Flag.dictionaryMask == Flag.dictionaryMask }
    var isEncrypted: Bool { flags & Flag.encrypted != 0 }
    var isSolid: Bool { flags & Flag.solid != 0 }
    var isSplit: Bool { flags & (Flag.splitBefore | Flag.splitAfter) != 0 }
}
