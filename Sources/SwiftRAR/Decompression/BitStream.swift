import Foundation

/// MSB-first bit reader over a `Data` buffer.
///
/// RAR3 packs its compressed streams bit-by-bit, with the most significant
/// bit of each byte transmitted first. `BitStream` exposes the three
/// primitives the Huffman + LZSS decoders need:
///
///   * `peekBits(_:)` — look at the next `n` bits without consuming them.
///   * `readBits(_:)` — peek + advance in one call.
///   * `advance(_:)` — drop `n` bits (for the common Huffman idiom of
///     "peek 15, then advance by the decoded code length").
///
/// The reader is intentionally cheap: bits are accumulated into a 64-bit
/// register lazily, so the hot path is a shift + mask. When the source
/// data is exhausted the reader yields zero bits — RAR3 streams are
/// self-terminating via an explicit end-of-block symbol, so a clean tail
/// is the expected behaviour for well-formed input. Callers can inspect
/// `isExhausted` for a hard "no more real bits available" signal.
struct BitStream {
    /// Backing byte buffer.
    private let data: Data
    /// Byte index of the next byte to pull into the bit register.
    private var byteCursor: Int
    /// 64-bit shift register holding pending bits, MSB-aligned.
    private var register: UInt64 = 0
    /// Number of valid bits currently held in `register` (0...64).
    private var bitsAvailable: Int = 0

    /// Construct a bit reader positioned at the start of `data`.
    init(_ data: Data) {
        self.data = data
        // Data's startIndex is not always zero — preserve the underlying
        // slice's base so callers can pass a `subdata` directly.
        self.byteCursor = data.startIndex
    }

    /// Total number of bytes in the underlying buffer (useful for assertions
    /// in tests).
    var byteCount: Int { data.count }

    /// `true` once both the source buffer and the internal register are
    /// drained. Returning bits while exhausted yields zero.
    var isExhausted: Bool {
        return bitsAvailable == 0 && byteCursor >= data.endIndex
    }

    /// Number of *bytes* of original input consumed (rounded down). RAR3
    /// payloads are byte-aligned externally — this is the value to use when
    /// reporting position to the surrounding stream layer.
    var byteOffset: Int {
        return byteCursor - data.startIndex - (bitsAvailable / 8)
    }

    /// Peek at the next `count` bits as an unsigned integer.
    ///
    /// - Parameter count: Number of bits to peek, in `0...32`.
    /// - Returns: A `UInt32` whose low `count` bits are the next bits in
    ///   the stream, with the first bit transmitted occupying the most
    ///   significant position of those `count` bits.
    @inline(__always)
    mutating func peekBits(_ count: Int) -> UInt32 {
        precondition(count >= 0 && count <= 32, "BitStream.peekBits: count out of range")
        if count == 0 { return 0 }
        fill(needBits: count)
        // Top `bitsAvailable` bits of `register` are MSB-aligned. Shift
        // the wanted bits down to the bottom of a UInt32.
        let shift = 64 - count
        // If the register holds fewer than `count` real bits (end of
        // stream), the missing low-order positions are zero — which is
        // exactly the behaviour callers expect from a malformed/truncated
        // tail.
        return UInt32(truncatingIfNeeded: register >> shift)
    }

    /// Discard the next `count` bits.
    @inline(__always)
    mutating func advance(_ count: Int) {
        precondition(count >= 0 && count <= 64, "BitStream.advance: count out of range")
        var remaining = count
        while remaining > 0 {
            if bitsAvailable == 0 {
                // Try to load more; if there's nothing left, we still
                // "advance" logically — subsequent peeks will return zero.
                if !loadByte() { return }
            }
            let take = min(remaining, bitsAvailable)
            register <<= take
            bitsAvailable -= take
            remaining -= take
        }
    }

    /// Read and consume the next `count` bits.
    @inline(__always)
    mutating func readBits(_ count: Int) -> UInt32 {
        let value = peekBits(count)
        advance(count)
        return value
    }

    /// Align the cursor to the next whole byte. RAR3 main blocks are not
    /// generally byte-aligned (the decoder leaves them mid-byte), but a
    /// couple of corner cases — e.g. the optional VM filter spec — assume
    /// alignment. Included for completeness.
    mutating func alignToByte() {
        let extra = bitsAvailable % 8
        if extra != 0 {
            advance(extra)
        }
    }

    // MARK: - Internals

    /// Ensure at least `needBits` bits are present in the register, pulling
    /// fresh bytes from the buffer until either the requirement is met or
    /// the buffer is drained.
    @inline(__always)
    private mutating func fill(needBits: Int) {
        while bitsAvailable < needBits {
            if !loadByte() { break }
        }
    }

    /// Pull one byte from the buffer into the bit register at the
    /// MSB-aligned position immediately below the existing bits.
    /// Returns `false` when the buffer is exhausted.
    @inline(__always)
    private mutating func loadByte() -> Bool {
        guard byteCursor < data.endIndex else { return false }
        let byte = data[byteCursor]
        byteCursor += 1
        // Insert the new byte's bits below the existing ones. The register
        // is MSB-aligned: existing bits occupy the top `bitsAvailable`
        // positions, new bits drop into the next 8 positions below.
        let shift = 64 - bitsAvailable - 8
        if shift >= 0 {
            register |= UInt64(byte) << shift
        } else {
            // The register is already too full to hold another byte.
            // RAR3 never asks for more than 32 bits at once, and we top
            // up before each peek, so this branch is defensive.
            return false
        }
        bitsAvailable += 8
        return true
    }
}
