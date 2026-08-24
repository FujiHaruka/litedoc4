//! The digest the frozen fixtures record artifacts by.
//!
//! **This is an instrument, not an oracle, and forking it again would buy
//! nothing** 【実測 2026-08-23】. No product code computes an FNV hash, so this
//! is not a second spelling of anything the tree ships. The independent side of
//! every comparison is the prototype that wrote the digest literals in
//! `litedoc4-{incr,global}/tests/data/*-expected.json`; it left HEAD with tag
//! `experiments-frozen` and only its output survives. For those comparisons to
//! mean anything both sides must run *the same* function, so a per-caller copy
//! would add no independence and one more thing able to drift.

/// FNV-1a 64 of `bytes`, as sixteen lower-case hex digits.
///
/// A staleness check, not a security property.
///
/// The width is fixed at sixteen — the fixtures store the digest as text, and a
/// hash with a leading zero byte spelled `{hash:x}` would be fourteen
/// characters that no recorded value ever equals.
///
/// ```
/// // The published FNV-1a 64 vector for the empty input is the offset basis.
/// assert_eq!(litedoc4_testutil::hash::fnv1a64(b""), "cbf29ce484222325");
/// assert_eq!(litedoc4_testutil::hash::fnv1a64(b"a"), "af63dc4c8601ec8c");
/// ```
pub fn fnv1a64(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The standard vectors, and deliberately not a digest read back out of a
    /// fixture: every value in `tests/data/*-expected.json` is over a corpus
    /// tree that is not in this repository, so quoting one would only assert
    /// that this function equals itself.
    #[test]
    fn the_published_vectors() {
        assert_eq!(fnv1a64(b""), "cbf29ce484222325");
        assert_eq!(fnv1a64(b"a"), "af63dc4c8601ec8c");
        assert_eq!(fnv1a64(b"foobar"), "85944171f73967e8");
    }

    #[test]
    fn the_digest_is_zero_padded_to_sixteen_digits() {
        assert_eq!(fnv1a64(b"oqda"), "0000c5b4674b4b6e");
        assert_eq!(fnv1a64(b"oqda").len(), 16);
    }

    #[test]
    fn the_input_is_bytes_and_not_text() {
        assert_eq!(fnv1a64(&[0xff, 0xff, 0xff]), "f998341be47bae14");
        assert_ne!(fnv1a64(b"ab"), fnv1a64(b"ba"));
    }
}
