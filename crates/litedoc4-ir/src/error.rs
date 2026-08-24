use std::fmt;
use std::io;
use std::path::PathBuf;

/// A variant that is about a file carries its path: a build reads 436 files,
/// and an error that does not say which one costs a bisection.
#[derive(Debug)]
pub enum Error {
    Io {
        path: PathBuf,
        source: io::Error,
    },
    Json {
        path: PathBuf,
        source: serde_json::Error,
    },
    Schema {
        what: String,
        found: u32,
        required: u32,
    },
    Ablated {
        ablations: Vec<String>,
    },
    ModuleMismatch {
        path: PathBuf,
        expected: String,
        found: String,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => write!(f, "reading {}: {source}", path.display()),
            Self::Json { path, source } => write!(f, "parsing {}: {source}", path.display()),
            Self::Schema {
                what,
                found,
                required,
            } => write!(
                f,
                "{what} is schema {found}; this reader needs schema {required} or newer \
                 (re-extract with --tagged-code)"
            ),
            Self::Ablated { ablations } => write!(
                f,
                "this IR was written with ablations [{}] and is incomplete on purpose; \
                 it is for the stopwatch only",
                ablations.join(", ")
            ),
            Self::ModuleMismatch {
                path,
                expected,
                found,
            } => write!(
                f,
                "{} declares module {found}, but the index files it under {expected}",
                path.display()
            ),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Json { source, .. } => Some(source),
            _ => None,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
