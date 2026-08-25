//! `MD_FLAG_*` and `MD_DIALECT_*`, transcribed from `vendor/md4c/md4c.h`.
//!
//! `tests/abi.rs` checks the values against the C compiler's own view of that
//! header: a flag that quietly drifted would change what the parser accepts
//! without changing anything that fails to build.

pub const MD_FLAG_COLLAPSEWHITESPACE: u32 = 0x0001;
/// Accept `###header` with no space after the hashes.
pub const MD_FLAG_PERMISSIVEATXHEADERS: u32 = 0x0002;
pub const MD_FLAG_PERMISSIVEURLAUTOLINKS: u32 = 0x0004;
pub const MD_FLAG_PERMISSIVEEMAILAUTOLINKS: u32 = 0x0008;
pub const MD_FLAG_NOINDENTEDCODEBLOCKS: u32 = 0x0010;
pub const MD_FLAG_NOHTMLBLOCKS: u32 = 0x0020;
pub const MD_FLAG_NOHTMLSPANS: u32 = 0x0040;
pub const MD_FLAG_TABLES: u32 = 0x0100;
pub const MD_FLAG_STRIKETHROUGH: u32 = 0x0200;
/// Autolink `www.`-prefixed hosts, which carry no scheme.
pub const MD_FLAG_PERMISSIVEWWWAUTOLINKS: u32 = 0x0400;
pub const MD_FLAG_TASKLISTS: u32 = 0x0800;
pub const MD_FLAG_LATEXMATHSPANS: u32 = 0x1000;
pub const MD_FLAG_WIKILINKS: u32 = 0x2000;
/// Also stops `_` from marking emphasis.
pub const MD_FLAG_UNDERLINE: u32 = 0x4000;
/// Every soft break becomes a hard break.
pub const MD_FLAG_HARD_SOFT_BREAKS: u32 = 0x8000;

pub const MD_FLAG_PERMISSIVEAUTOLINKS: u32 = MD_FLAG_PERMISSIVEEMAILAUTOLINKS
    | MD_FLAG_PERMISSIVEURLAUTOLINKS
    | MD_FLAG_PERMISSIVEWWWAUTOLINKS;
pub const MD_FLAG_NOHTML: u32 = MD_FLAG_NOHTMLBLOCKS | MD_FLAG_NOHTMLSPANS;

pub const MD_DIALECT_COMMONMARK: u32 = 0;
/// GitHub Flavored Markdown, as far as md4c implements it.
pub const MD_DIALECT_GITHUB: u32 =
    MD_FLAG_PERMISSIVEAUTOLINKS | MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS;

/// The flags doc-gen4 parses docstrings with (measured): `DocGen4/Output/DocString.lean`
/// builds `MD_DIALECT_GITHUB ||| MD_FLAG_LATEXMATHSPANS ||| MD_FLAG_NOHTML`.
///
/// This is why the parser is vendored rather than reimplemented: the oracle
/// compares against doc-gen4's own output, so the dialect has to be that one
/// and not a close relative of it.
pub const DOCSTRING_FLAGS: u32 = MD_DIALECT_GITHUB | MD_FLAG_LATEXMATHSPANS | MD_FLAG_NOHTML;
