/// A small deterministic digest for the standalone PoC graph.
///
/// This is deliberately not presented as build_runner's graph digest format.
/// The compatibility digest can be added behind this interface once the
/// pinned build_runner version is selected for the fork-based comparison.
pub fn digest_bytes(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::digest_bytes;

    #[test]
    fn digest_is_deterministic_and_content_sensitive() {
        assert_eq!(digest_bytes(b"hello"), digest_bytes(b"hello"));
        assert_ne!(digest_bytes(b"hello"), digest_bytes(b"hello!"));
    }
}
