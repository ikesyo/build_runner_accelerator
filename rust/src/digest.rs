/// Algorithm-tagged BLAKE3-256 identity for disposable accelerator state.
/// This internal digest is not build_runner's AssetGraph format or a stable API.
pub fn digest_bytes(bytes: &[u8]) -> String {
    let hash = blake3::hash(bytes).to_hex();
    let mut digest = String::with_capacity(3 + hash.len());
    digest.push_str("b3-");
    digest.push_str(hash.as_str());
    digest
}

/// The manifest emitter's worker-source identity is a separate Rust/Dart
/// contract, not an internal cache digest. Keep matching workerSourceDigest
/// in lib/src/manifest/emitter.dart. This is not a security authenticator.
pub(crate) fn worker_source_digest(bytes: &[u8]) -> String {
    fnv1a_64(bytes)
}

pub(crate) fn fnv1a_64(bytes: &[u8]) -> String {
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
        assert_eq!(digest_bytes(b"").len(), 67);
        assert_eq!(
            digest_bytes(b""),
            "b3-af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        );
    }

    #[test]
    fn manifest_identity_still_matches_the_dart_emitter() {
        assert_eq!(super::worker_source_digest(b""), "cbf29ce484222325");
        assert_eq!(super::worker_source_digest(b"hello"), "a430d84680aabd0b");
        assert_eq!(
            super::worker_source_digest("builder:日本語".as_bytes()),
            "a809354f9cbb004e"
        );
    }
}
