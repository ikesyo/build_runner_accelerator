/// Deterministic FNV-1a identity for disposable accelerator state.
/// This internal digest is not build_runner's AssetGraph format or a stable API.
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
