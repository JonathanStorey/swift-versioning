import Foundation

extension UUID {
    /// The 128-bit MurmurHash3 (x64, seed 0) of the UTF-8 bytes of `text`.
    /// The bytes are the two 64-bit halves, each little-endian, matching the
    /// reference implementation's output.
    public init(stableHashOf text: String) {
        let c1: UInt64 = 0x87c3_7b91_1142_53d5
        let c2: UInt64 = 0x4cf5_ad43_2745_937f
        var h1: UInt64 = 0
        var h2: UInt64 = 0

        // The tail is zero-padded to a full block, which may be all padding.
        // Mixing a zero word gives zero, so the padding leaves the hash as the
        // reference implementation leaves it.
        let bytes = Array(text.utf8)
        let fullBlocks = bytes.count / 16
        let padded = bytes + repeatElement(0, count: 16 - bytes.count % 16)

        padded.withUnsafeBytes { buffer in
            func word(_ index: Int) -> UInt64 {
                UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
            }
            for block in 0..<fullBlocks {
                h1 ^= (word(2 * block) &* c1).rotatedLeft(by: 31) &* c2
                h1 = (h1.rotatedLeft(by: 27) &+ h2) &* 5 &+ 0x52dc_e729
                h2 ^= (word(2 * block + 1) &* c2).rotatedLeft(by: 33) &* c1
                h2 = (h2.rotatedLeft(by: 31) &+ h1) &* 5 &+ 0x3849_5ab5
            }
            h1 ^= (word(2 * fullBlocks) &* c1).rotatedLeft(by: 31) &* c2
            h2 ^= (word(2 * fullBlocks + 1) &* c2).rotatedLeft(by: 33) &* c1
        }

        let length = UInt64(bytes.count)
        h1 ^= length
        h2 ^= length
        h1 &+= h2
        h2 &+= h1
        h1 = h1.finalMixed
        h2 = h2.finalMixed
        h1 &+= h2
        h2 &+= h1

        var halves = (h1.littleEndian, h2.littleEndian)
        self = withUnsafeBytes(of: &halves) { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}

private extension UInt64 {
    func rotatedLeft(by count: UInt64) -> UInt64 {
        self << count | self >> (64 - count)
    }

    /// MurmurHash3's `fmix64` avalanche step.
    var finalMixed: UInt64 {
        var k = self
        k ^= k >> 33
        k &*= 0xff51_afd7_ed55_8ccd
        k ^= k >> 33
        k &*= 0xc4ce_b9fe_1a85_ec53
        k ^= k >> 33
        return k
    }
}
