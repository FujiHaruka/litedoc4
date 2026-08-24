use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// md4c's offsets are 32-bit: this is the parser's limit, not this crate's.
    InputTooLarge { bytes: usize },
    /// `md_parse` returned non-zero (e.g. `-1` for a failed allocation).
    Md4c { code: i32 },
    /// md4c's callbacks hand out slices of the input, which was a `&str`, so
    /// this cannot happen unless the parser or this binding is wrong.
    NotUtf8,
    /// md4c produced something MD4Lean's ADT has no constructor for.
    ///
    /// Only reachable by parsing with flags doc-gen4 does not use: inline raw
    /// HTML puts text directly in a paragraph where `MD4Lean.Text` allows only
    /// its own constructors. MD4Lean does not report this — it puts a bare
    /// `String` there and dies later — so refusing is the difference, not a
    /// shared behaviour.
    Unrepresentable(&'static str),
    /// The callback sequence did not fit the shape the builder relies on.
    /// Every case is a bug here or a change in md4c, never bad input.
    Malformed(&'static str),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge { bytes } => {
                write!(f, "{bytes} bytes is past md4c's 32-bit MD_SIZE limit")
            }
            Self::Md4c { code } => write!(f, "md_parse failed with {code}"),
            Self::NotUtf8 => f.write_str("md4c produced a fragment that is not UTF-8"),
            Self::Unrepresentable(what) => write!(f, "no MD4Lean constructor for {what}"),
            Self::Malformed(what) => write!(f, "unexpected callback sequence: {what}"),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
