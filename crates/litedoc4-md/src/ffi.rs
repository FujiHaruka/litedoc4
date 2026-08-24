//! Derived from md4c (MIT, Copyright (c) 2016-2024 Martin Mitáš); the licence
//! is at `vendor/md4c/LICENSE.md`. See this repository's NOTICE.
//!
//! The md4c C ABI, transcribed from `vendor/md4c/md4c.h` (md4c 0.5.2).
//!
//! Written by hand rather than generated because the header is pinned by
//! `vendor/md4c/PROVENANCE.md` and will not move on its own; what makes that
//! safe is that `tests/abi.rs` compares every size, alignment, field offset and
//! enumerator below against the values the C compiler computes from the same
//! header (`csrc/layout_probe.c`). A layout that merely happens to link is the
//! failure mode this crate is most exposed to, so it is checked rather than
//! reasoned about.
//!
//! Two deliberate deviations from a literal transcription, both for safety:
//!
//! - The callbacks take the enum arguments as [`c_int`] rather than as the
//!   Rust enums. C may hand us any `int`; materialising a Rust enum from an
//!   out-of-range value is undefined behaviour, so conversion goes through
//!   [`MdBlockType::from_raw`] and friends, which return `None` instead.
//! - [`MdAttribute::substr_types`] is `*const c_int`, not `*const MdTextType`,
//!   for the same reason: the values are read and converted, never transmuted.
//!
//! A block or span type's detail struct is `Md{Block,Span}<Type>Detail`, except
//! that `Th` and `Td` share [`MdBlockTdDetail`].

use std::ffi::{c_char, c_int, c_uint, c_void};

/// The header's character type when `MD4C_USE_UTF16` is not defined, which is
/// the only configuration we build.
pub type MdChar = c_char;
pub type MdSize = c_uint;
pub type MdOffset = c_uint;

/// The C enums are `int`-sized in every ABI we target; this is what makes the
/// `#[repr(i32)]` below not merely a hope.
const _: () = assert!(size_of::<c_int>() == 4);

macro_rules! c_enum {
    (
        $(#[$meta:meta])*
        $name:ident { $( $(#[$vmeta:meta])* $variant:ident = $value:expr, )* }
    ) => {
        $(#[$meta])*
        #[repr(i32)]
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum $name {
            $( $(#[$vmeta])* $variant = $value, )*
        }

        impl $name {
            /// `None` if `raw` names no enumerator of the vendored header.
            #[must_use]
            pub fn from_raw(raw: c_int) -> Option<Self> {
                match raw {
                    $( $value => Some(Self::$variant), )*
                    _ => None,
                }
            }
        }
    };
}

c_enum! {
    MdBlockType {
        Doc = 0,
        Quote = 1,
        Ul = 2,
        Ol = 3,
        Li = 4,
        Hr = 5,
        H = 6,
        Code = 7,
        /// Never produced under [`crate::flags::MD_FLAG_NOHTML`].
        Html = 8,
        P = 9,
        Table = 10,
        Thead = 11,
        Tbody = 12,
        Tr = 13,
        Th = 14,
        Td = 15,
    }
}

c_enum! {
    MdSpanType {
        Em = 0,
        Strong = 1,
        A = 2,
        Img = 3,
        Code = 4,
        /// Needs `MD_FLAG_STRIKETHROUGH`.
        Del = 5,
        /// `$...$`; needs `MD_FLAG_LATEXMATHSPANS`.
        LatexMath = 6,
        /// `$$...$$`; needs `MD_FLAG_LATEXMATHSPANS`.
        LatexMathDisplay = 7,
        /// Needs `MD_FLAG_WIKILINKS`.
        Wikilink = 8,
        /// Needs `MD_FLAG_UNDERLINE`.
        U = 9,
    }
}

c_enum! {
    MdTextType {
        Normal = 0,
        /// A NUL in the input. md4c passes an empty string with size 1.
        NullChar = 1,
        Br = 2,
        SoftBr = 3,
        /// Verbatim: md4c keeps no table of entity names.
        Entity = 4,
        Code = 5,
        Html = 6,
        LatexMath = 7,
    }
}

c_enum! {
    /// Only reachable through table cells, whose alignment this crate's AST
    /// does not carry (neither does MD4Lean's, so neither does doc-gen4's).
    MdAlign {
        Default = 0,
        Left = 1,
        Center = 2,
        Right = 3,
    }
}

/// A string that may be cut into runs of different text types, used for link
/// destinations, titles and code-fence info strings.
///
/// The invariants the header states, which the reader in `crate::parse` relies
/// on: `substr_offsets[0] == 0`, the offsets array has one more entry than the
/// types array, and its last entry equals `size`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdAttribute {
    /// Not NUL-terminated; `size` is authoritative.
    pub text: *const MdChar,
    /// Bytes.
    pub size: MdSize,
    /// One `MD_TEXTTYPE` per run.
    pub substr_types: *const c_int,
    pub substr_offsets: *const MdOffset,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockUlDetail {
    pub is_tight: c_int,
    /// The bullet character in the source: `-`, `+` or `*`.
    pub mark: MdChar,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockOlDetail {
    pub start: c_uint,
    pub is_tight: c_int,
    /// `.` or `)`.
    pub mark_delimiter: MdChar,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockLiDetail {
    /// Non-zero only under `MD_FLAG_TASKLISTS`.
    pub is_task: c_int,
    /// `x`, `X` or a space when `is_task`; undefined otherwise.
    pub task_mark: MdChar,
    /// Offset of the character between `[` and `]` when `is_task`.
    pub task_mark_offset: MdOffset,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockHDetail {
    /// 1 through 6.
    pub level: c_uint,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockCodeDetail {
    /// Everything after the opening fence.
    pub info: MdAttribute,
    /// The first word of `info`.
    pub lang: MdAttribute,
    /// Zero for an indented code block.
    pub fence_char: MdChar,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockTableDetail {
    pub col_count: c_uint,
    /// Currently always 1.
    pub head_row_count: c_uint,
    pub body_row_count: c_uint,
}

/// Shared by `MD_BLOCK_TH` and `MD_BLOCK_TD`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdBlockTdDetail {
    /// An `MD_ALIGN`.
    pub align: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdSpanADetail {
    pub href: MdAttribute,
    /// Empty when absent.
    pub title: MdAttribute,
    /// Non-zero for `<...>` and permissive autolinks.
    pub is_autolink: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdSpanImgDetail {
    pub src: MdAttribute,
    /// Empty when absent.
    pub title: MdAttribute,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MdSpanWikilinkDetail {
    pub target: MdAttribute,
}

pub type MdBlockCallback =
    unsafe extern "C" fn(ty: c_int, detail: *mut c_void, userdata: *mut c_void) -> c_int;
pub type MdSpanCallback =
    unsafe extern "C" fn(ty: c_int, detail: *mut c_void, userdata: *mut c_void) -> c_int;
pub type MdTextCallback = unsafe extern "C" fn(
    ty: c_int,
    text: *const MdChar,
    size: MdSize,
    userdata: *mut c_void,
) -> c_int;
pub type MdDebugLogCallback = unsafe extern "C" fn(msg: *const c_char, userdata: *mut c_void);

/// The callback table md4c drives the caller through.
///
/// The nullable members are `Option<fn>`, which has the same layout as the
/// function pointer itself with `None` as the null pointer, so this stays a
/// literal transcription.
#[repr(C)]
pub struct MdParser {
    /// Reserved; must be zero.
    pub abi_version: c_uint,
    /// A bitmask of `MD_FLAG_*`.
    pub flags: c_uint,
    pub enter_block: Option<MdBlockCallback>,
    pub leave_block: Option<MdBlockCallback>,
    pub enter_span: Option<MdSpanCallback>,
    pub leave_span: Option<MdSpanCallback>,
    /// Text inside the innermost open block or span.
    pub text: Option<MdTextCallback>,
    pub debug_log: Option<MdDebugLogCallback>,
    /// Reserved; must be `None`.
    pub syntax: Option<unsafe extern "C" fn()>,
}

unsafe extern "C" {
    /// Returns zero on success, `-1` on a runtime error, or whatever value a
    /// callback returned to abort.
    pub fn md_parse(
        text: *const MdChar,
        size: MdSize,
        parser: *const MdParser,
        userdata: *mut c_void,
    ) -> c_int;
}
