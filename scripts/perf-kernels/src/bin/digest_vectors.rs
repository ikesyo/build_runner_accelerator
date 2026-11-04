//! Compare output with default SIMD dispatch and forced portable BLAKE3 features.
#[allow(dead_code)]
#[path = "../../../../rust/src/digest.rs"]
mod production_digest;

fn main() {
    for len in [
        0,
        1,
        16,
        128,
        1023,
        1024,
        1025,
        4096,
        65536,
        4 * 1024 * 1024,
    ] {
        let bytes: Vec<_> = (0..len)
            .map(|i: usize| (i.wrapping_mul(73) ^ (i >> 3)) as u8)
            .collect();
        let mut b3 = blake3::Hasher::new();
        let mut xx = xxhash_rust::xxh3::Xxh3::new();
        let mut crc = 0;
        for chunk in bytes.chunks(8192) {
            b3.update(chunk);
            xx.update(chunk);
            crc = crc32c::crc32c_append(crc, chunk);
        }
        assert_eq!(b3.finalize(), blake3::hash(&bytes));
        assert_eq!(xx.digest128(), xxhash_rust::xxh3::xxh3_128(&bytes));
        assert_eq!(crc, crc32c::crc32c(&bytes));
        println!("{len},{}", production_digest::digest_bytes(&bytes));
    }
}
