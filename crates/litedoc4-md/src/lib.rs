//! CommonMark for docstrings: md4c through FFI, plus doc-gen4's own rendering.
//!
//! doc-gen4 does not use md4c's HTML renderer — it parses to an AST and builds
//! the HTML itself (`DocGen4/Output/DocString.lean`). This crate does the same,
//! so only `md4c.c` and `md4c.h` are vendored.
//!
//! ```
//! use litedoc4_md::{NoLinks, Renderer};
//!
//! let html = Renderer::new("../", &NoLinks).docstring("`Nat.succ` is *fine*");
//! assert_eq!(html, "<p><code>Nat.succ</code> is <em>fine</em></p>");
//! ```

pub mod ast;
mod error;
pub mod escape;
pub mod ffi;
pub mod flags;
pub mod gc;
pub mod html;
pub mod math;
mod parse;

// A `pub use` here means another crate imports the item; everything else stays
// `pub` in its own module and is reached as `litedoc4_md::<module>::<item>`.
// `error` and `parse` are private modules, so for those the re-export is the
// only path there is — `unreachable_pub` says so the moment one is dropped.
pub use error::{Error, Result};
pub use escape::{escape_html, escape_html_into};
pub use html::{LinkResolver, NoLinks, Renderer};
pub use parse::{parse, parse_with_flags};
