/-!
Derived from MD4Lean's `wrapper/wrapper.c` (MIT, Copyright (c) 2024 Jz Pan)
by way of `crates/litedoc4-md/src/parse.rs`, and changed; see this repository's
NOTICE and `docs/provenance.md`.

# Markdown, straight from the vendored md4c

`csrc/md_events.c` runs md4c and writes its callback stream into one buffer;
this file rebuilds the tree from those bytes. Together they replace the
`MD4Lean` dependency, and the C they run is `vendor/md4c/md4c.c`, byte for byte
the file `crates/litedoc4-md/vendor/md4c/` already holds.

WHY NOT MD4LEAN, WHICH DOES THIS ALREADY
  Not speed and not correctness — it works. Four things it brings that this does
  not: it has no releases, so the pin is a commit on `main`; it carries a
  `lean-toolchain` of `v4.29.0-rc1`, which Lake silently ignores from below and
  **rewrites the consumer's from above**; it turns on Lean's `experimental.module`;
  and it needs `precompileModules`. Vendoring the same C costs one file of glue
  and leaves litedoc4 with **zero** external git dependencies for Markdown.
  What it does **not** buy is freedom from a C compiler: md4c needs the
  machine's `cc` either way, because Lean's bundled clang ships no libc headers
  (measured — see `lakefile.lean`). What would falsify the choice: if MD4Lean
  tags releases and drops the experimental flag, the glue below is the thing to
  delete.

The tree shape is not a free choice. `crates/litedoc4-md/src/parse.rs` builds
the same tree from the same callbacks, and its output is the reference these
pages have to reproduce, so this is a transcription of that builder and its
decisions are cited to it rather than re-argued.
-/

namespace Md

/-! ## Flags -/

def MD_FLAG_PERMISSIVEURLAUTOLINKS : UInt32 := 0x0004
def MD_FLAG_PERMISSIVEEMAILAUTOLINKS : UInt32 := 0x0008
def MD_FLAG_NOHTMLBLOCKS : UInt32 := 0x0020
def MD_FLAG_NOHTMLSPANS : UInt32 := 0x0040
def MD_FLAG_TABLES : UInt32 := 0x0100
def MD_FLAG_STRIKETHROUGH : UInt32 := 0x0200
def MD_FLAG_PERMISSIVEWWWAUTOLINKS : UInt32 := 0x0400
def MD_FLAG_TASKLISTS : UInt32 := 0x0800
def MD_FLAG_LATEXMATHSPANS : UInt32 := 0x1000

def MD_FLAG_NOHTML : UInt32 := MD_FLAG_NOHTMLBLOCKS ||| MD_FLAG_NOHTMLSPANS

def MD_DIALECT_GITHUB : UInt32 :=
  MD_FLAG_PERMISSIVEURLAUTOLINKS ||| MD_FLAG_PERMISSIVEEMAILAUTOLINKS |||
  MD_FLAG_PERMISSIVEWWWAUTOLINKS ||| MD_FLAG_TABLES ||| MD_FLAG_STRIKETHROUGH |||
  MD_FLAG_TASKLISTS

/-! ## The tree -/

inductive AttrText where
  | normal : String → AttrText
  | entity : String → AttrText
  | nullchar : AttrText
deriving Inhabited, Repr, BEq

inductive Text where
  | normal : String → Text
  | nullchar
  | br : String → Text
  | softbr : String → Text
  | entity : String → Text
  | em : Array Text → Text
  | strong : Array Text → Text
  | u : Array Text → Text
  | a (href title : Array AttrText) (isAuto : Bool) : Array Text → Text
  | img (src title : Array AttrText) (alt : Array Text) : Text
  | code : Array String → Text
  | del : Array Text → Text
  | latexMath : Array String → Text
  | latexMathDisplay : Array String → Text
  | wikiLink (target : Array AttrText) : Array Text → Text
deriving Inhabited, Repr, BEq

structure Li (α) where
  li ::
  isTask : Bool := false
  taskChar : Option Char := none
  taskMarkOffset : Option USize := none
  contents : Array α
deriving Inhabited, Repr, BEq

inductive Block where
  | p : Array Text → Block
  | ul (tight : Bool) (mark : Char) : Array (Li Block) → Block
  | ol (tight : Bool) (start : Nat) (mark : Char) : Array (Li Block) → Block
  | hr
  | header : Nat → Array Text → Block
  | code (info lang : Array AttrText) (fenceChar : Option Char) : Array String → Block
  | html : Array String → Block
  | blockquote : Array Block → Block
  | table (head : Array (Array Text)) (body : Array (Array (Array Text))) : Block
deriving Inhabited, Repr, BEq

structure Document where
  blocks : Array Block
deriving Inhabited, Repr, BEq

/-! ## The event stream -/

/-- md4c's callbacks, flattened. An empty result means md4c refused the input:
a parse that succeeds always emits the document's own enter and leave. The
format is documented in `csrc/md_events.c`, which is the only writer. -/
@[extern "litedoc4_md_events"]
opaque events (input : @& String) (flags : UInt32) : ByteArray

private structure Cursor where
  data : ByteArray
  pos : Nat

private def fail (msg : String) : Except String α := .error msg

/-- The reader is written against `Except` rather than a partial function so
that a truncated stream is a message and not a panic; every read checks its own
bound because the buffer crosses an FFI boundary. -/
private def readU8 (c : Cursor) : Except String (UInt8 × Cursor) :=
  if c.pos < c.data.size then
    .ok (c.data.get! c.pos, { c with pos := c.pos + 1 })
  else fail "the event stream ended inside an event"

private def readU32 (c : Cursor) : Except String (UInt32 × Cursor) := do
  if c.pos + 4 > c.data.size then
    fail "the event stream ended inside a number"
  else
    let b0 := (c.data.get! c.pos).toUInt32
    let b1 := (c.data.get! (c.pos + 1)).toUInt32
    let b2 := (c.data.get! (c.pos + 2)).toUInt32
    let b3 := (c.data.get! (c.pos + 3)).toUInt32
    .ok (b0 ||| (b1 <<< 8) ||| (b2 <<< 16) ||| (b3 <<< 24), { c with pos := c.pos + 4 })

private def readStr (c : Cursor) : Except String (String × Cursor) := do
  let (len, c) ← readU32 c
  let len := len.toNat
  if c.pos + len > c.data.size then
    fail "the event stream ended inside a string"
  else
    match String.fromUTF8? (c.data.extract c.pos (c.pos + len)) with
    | some s => .ok (s, { c with pos := c.pos + len })
    | none => fail "md4c handed back bytes that are not UTF-8"

/-- md4c's marks and delimiters are ASCII by construction, so the byte is the
character. The C side takes the byte rather than the sign for the reason
`mark_char` in the Rust half gives. -/
private def markChar (b : UInt8) : Char :=
  Char.ofNat b.toNat

private def readAttrs :
    Nat → Array AttrText → Cursor → Except String (Array AttrText × Cursor)
  | 0, acc, c => .ok (acc, c)
  | n + 1, acc, c => do
    let (ty, c) ← readU8 c
    let (s, c) ← readStr c
    match ty with
    | 0 => readAttrs n (acc.push (.normal s)) c
    | 4 => readAttrs n (acc.push (.entity s)) c
    | 1 => readAttrs n (acc.push .nullchar) c
    | _ => fail "an attribute held a text type md4c does not put there"

private def readAttr (c : Cursor) : Except String (Array AttrText × Cursor) := do
  let (count, c) ← readU32 c
  readAttrs count.toNat #[] c

/-! ## The builder

A transcription of `Builder` in `crates/litedoc4-md/src/parse.rs`. -/

private inductive Tag where
  | block
  | text
  | li
  /-- A paragraph this builder opened, not md4c. -/
  | implicitP
deriving BEq, Inhabited

private inductive Detail where
  | none
  | ul (tight : Bool) (mark : Char)
  | ol (start : Nat) (tight : Bool) (mark : Char)
  | h (level : Nat)
deriving Inhabited

private inductive Node where
  | block : Block → Node
  | text : Text → Node
  /-- Verbatim content: `MD_TEXT_CODE` / `MD_TEXT_HTML` / `MD_TEXT_LATEXMATH`. -/
  | str : String → Node
  | li : Li Block → Node
  | cell : Array Text → Node
  | row : Array (Array Text) → Node
  | body : Array (Array (Array Text)) → Node
deriving Inhabited

private structure Frame where
  items : Array Node := #[]
  detail : Detail := .none
  tag : Tag := .block
deriving Inhabited

private structure Builder where
  /-- Always non-empty: index 0 is the root, whose tag is `block` so the
  implicit-paragraph test has something defined to read. -/
  stack : Array Frame := #[{}]
  document : Option (Array Block) := none

private def intoTexts (items : Array Node) : Except String (Array Text) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .text t => .ok (acc.push t)
    | .str _ => fail "inline raw HTML (parse with MD_FLAG_NOHTMLSPANS, as doc-gen4 does)"
    | _ => fail "a non-text node turned up where inline text was expected"

private def intoBlocks (items : Array Node) : Except String (Array Block) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .block b => .ok (acc.push b)
    | _ => fail "a non-block node turned up where a block was expected"

/-- A NUL inside verbatim content becomes U+FFFD rather than the type confusion
MD4Lean produces. -/
private def intoStrings (items : Array Node) : Except String (Array String) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .str s => .ok (acc.push s)
    | .text .nullchar => .ok (acc.push "\uFFFD")
    | _ => fail "a non-verbatim node turned up inside verbatim content"

private def intoLis (items : Array Node) : Except String (Array (Li Block)) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .li l => .ok (acc.push l)
    | _ => fail "a list held something that is not an item"

private def intoCells (items : Array Node) : Except String (Array (Array Text)) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .cell c => .ok (acc.push c)
    | _ => fail "a table row held something that is not a cell"

private def intoRows (items : Array Node) : Except String (Array (Array (Array Text))) :=
  items.foldlM (init := #[]) fun acc node =>
    match node with
    | .row r => .ok (acc.push r)
    | _ => fail "a table section held something that is not a row"

private def topTag (b : Builder) : Tag :=
  match b.stack.back? with
  | some f => f.tag
  | none => .block

private def pushFrame (b : Builder) (detail : Detail) (tag : Tag) : Builder :=
  { b with stack := b.stack.push { detail, tag } }

private def popFrame (b : Builder) : Except String (Array Node × Detail × Builder) :=
  if b.stack.size ≥ 2 then
    match b.stack.back? with
    | some f => .ok (f.items, f.detail, { b with stack := b.stack.pop })
    | none => fail "left more nodes than were entered"
  else fail "left more nodes than were entered"

private def save (b : Builder) (node : Node) : Except String Builder :=
  match b.stack.back? with
  | some f =>
    .ok { b with stack := b.stack.set! (b.stack.size - 1) { f with items := f.items.push node } }
  | none => fail "no open node to attach to"

/-- Checked before the pop, not after: asking afterwards means the builder has
already been changed by the time the answer is no. -/
private def closeImplicitP (b : Builder) : Except String Builder := do
  if b.stack.size < 2 || (b.stack[b.stack.size - 2]!).tag != Tag.li then
    fail "an implicit paragraph was not directly inside a list item"
  else
    let (items, _, b) ← popFrame b
    save b (.block (.p (← intoTexts items)))

private def openImplicitPIfInLi (b : Builder) : Builder :=
  if topTag b == Tag.li then pushFrame b .none .implicitP else b

/-! ## Driving the stream -/

private def onEnterBlock (b : Builder) (ty : UInt8) (c : Cursor) :
    Except String (Builder × Cursor) := do
  -- A block that is a sibling of text under a list item closes the paragraph
  -- that text opened.
  let b ← if topTag b == Tag.implicitP then closeImplicitP b else .ok b
  match ty with
  | 2 =>
    let (tight, c) ← readU8 c
    let (mark, c) ← readU8 c
    return (pushFrame b (.ul (tight != 0) (markChar mark)) .block, c)
  | 3 =>
    let (start, c) ← readU32 c
    let (tight, c) ← readU8 c
    let (mark, c) ← readU8 c
    return (pushFrame b (.ol start.toNat (tight != 0) (markChar mark)) .block, c)
  | 6 =>
    let (level, c) ← readU32 c
    return (pushFrame b (.h level.toNat) .block, c)
  | 4 => return (pushFrame b .none .li, c)
  | _ => return (pushFrame b .none .block, c)

private def onLeaveBlock (b : Builder) (ty : UInt8) (c : Cursor) :
    Except String (Builder × Cursor) := do
  match ty with
  | 0 =>
    let (items, _, b) ← popFrame b
    return ({ b with document := some (← intoBlocks items) }, c)
  | 2 =>
    let (items, detail, b) ← popFrame b
    let .ul tight mark := detail | fail "a list closed without its enter detail"
    return (← save b (.block (.ul tight mark (← intoLis items))), c)
  | 3 =>
    let (items, detail, b) ← popFrame b
    let .ol start tight mark := detail | fail "a list closed without its enter detail"
    return (← save b (.block (.ol tight start mark (← intoLis items))), c)
  | 4 =>
    -- Unlike UL / OL / H, the item's own detail is the one handed to `leave`.
    let (isTask, c) ← readU8 c
    let (taskMark, c) ← readU8 c
    let (taskOffset, c) ← readU32 c
    let b ← if topTag b != Tag.li then closeImplicitP b else .ok b
    let (items, _, b) ← popFrame b
    let isTask := isTask != 0
    let li : Li Block := {
      isTask
      taskChar := if isTask then some (markChar taskMark) else none
      taskMarkOffset := if isTask then some taskOffset.toUSize else none
      contents := ← intoBlocks items
    }
    return (← save b (.li li), c)
  | 5 =>
    let (items, _, b) ← popFrame b
    if !items.isEmpty then fail "a thematic break had children"
    else return (← save b (.block .hr), c)
  | 6 =>
    let (items, detail, b) ← popFrame b
    let .h level := detail | fail "a heading closed without its enter detail"
    return (← save b (.block (.header level (← intoTexts items))), c)
  | 7 =>
    let (info, c) ← readAttr c
    let (lang, c) ← readAttr c
    let (fence, c) ← readU8 c
    let (items, _, b) ← popFrame b
    let fenceChar := if fence != 0 then some (markChar fence) else none
    return (← save b (.block (.code info lang fenceChar (← intoStrings items))), c)
  | 8 =>
    let (items, _, b) ← popFrame b
    return (← save b (.block (.html (← intoStrings items))), c)
  | 9 =>
    let (items, _, b) ← popFrame b
    return (← save b (.block (.p (← intoTexts items))), c)
  | 1 =>
    let (items, _, b) ← popFrame b
    return (← save b (.block (.blockquote (← intoBlocks items))), c)
  | 10 =>
    let (items, _, b) ← popFrame b
    let (head, body) ← items.foldlM (init := (#[], #[])) fun (head, body) item =>
      match item with
      | .row r => .ok (r, body)
      | .body rows => .ok (head, rows)
      | _ => fail "a table held something that is not a header row or a body"
    return (← save b (.block (.table head body)), c)
  | 11 =>
    -- md4c documents exactly one header row, so the extra nesting is dropped.
    let (items, _, b) ← popFrame b
    let rows ← intoRows items
    if rows.size != 1 then fail "a table header was not one row"
    else return (← save b (.row rows[0]!), c)
  | 12 =>
    let (items, _, b) ← popFrame b
    return (← save b (.body (← intoRows items)), c)
  | 13 =>
    let (items, _, b) ← popFrame b
    return (← save b (.row (← intoCells items)), c)
  | 14 | 15 =>
    let (items, _, b) ← popFrame b
    return (← save b (.cell (← intoTexts items)), c)
  | _ => fail "md4c reported an unknown block type"

private def onLeaveSpan (b : Builder) (ty : UInt8) (c : Cursor) :
    Except String (Builder × Cursor) := do
  match ty with
  | 0 | 1 | 9 | 5 =>
    let (items, _, b) ← popFrame b
    let texts ← intoTexts items
    let t := match ty with
      | 0 => Text.em texts
      | 1 => Text.strong texts
      | 9 => Text.u texts
      | _ => Text.del texts
    return (← save b (.text t), c)
  | 4 | 6 | 7 =>
    let (items, _, b) ← popFrame b
    let parts ← intoStrings items
    let t := match ty with
      | 4 => Text.code parts
      | 6 => Text.latexMath parts
      | _ => Text.latexMathDisplay parts
    return (← save b (.text t), c)
  | 2 =>
    let (href, c) ← readAttr c
    let (title, c) ← readAttr c
    let (isAuto, c) ← readU8 c
    let (items, _, b) ← popFrame b
    return (← save b (.text (.a href title (isAuto != 0) (← intoTexts items))), c)
  | 3 =>
    let (src, c) ← readAttr c
    let (title, c) ← readAttr c
    let (items, _, b) ← popFrame b
    return (← save b (.text (.img src title (← intoTexts items))), c)
  | 8 =>
    let (target, c) ← readAttr c
    let (items, _, b) ← popFrame b
    return (← save b (.text (.wikiLink target (← intoTexts items))), c)
  | _ => fail "md4c reported an unknown span type"

private def onText (b : Builder) (ty : UInt8) (c : Cursor) :
    Except String (Builder × Cursor) := do
  let (s, c) ← readStr c
  let b := openImplicitPIfInLi b
  let node : Node ← match ty with
    | 0 => .ok (.text (.normal s))
    -- The payload of a null character is a single NUL byte, which carries
    -- nothing; MD4Lean drops it too.
    | 1 => .ok (.text .nullchar)
    | 2 => .ok (.text (.br s))
    | 3 => .ok (.text (.softbr s))
    | 4 => .ok (.text (.entity s))
    -- These three are uniquely determined by the block or span they sit in, so
    -- no constructor is spent on them.
    | 5 | 6 | 7 => .ok (.str s)
    | _ => fail "md4c reported an unknown text type"
  return (← save b node, c)

private partial def drive (c : Cursor) : Except String (Array Block) := do
  let mut cur := c
  let mut b : Builder := {}
  while cur.pos < cur.data.size do
    let (tag, c') ← readU8 cur
    let (ty, c') ← readU8 c'
    let (b', c') ← match tag with
      | 0x01 => onEnterBlock b ty c'
      | 0x02 => onLeaveBlock b ty c'
      | 0x03 => .ok (pushFrame (openImplicitPIfInLi b) .none .text, c')
      | 0x04 => onLeaveSpan b ty c'
      | 0x05 => onText b ty c'
      | _ => fail "the event stream held a tag nothing writes"
    b := b'
    cur := c'
  match b.document with
  | some blocks => return blocks
  | none => fail "the stream ended without closing the document"

/-- Parse `input`, or `none` if md4c refused it or the tree cannot be
represented. The `Except` message is dropped here only because the caller
matches MD4Lean's `Option`; `driveE` keeps it for a test that wants it. -/
def parse (input : @& String) (flags : UInt32 := 0) : Option Document :=
  let bytes := events input flags
  if bytes.isEmpty then none
  else match drive { data := bytes, pos := 0 } with
    | .ok blocks => some { blocks }
    | .error _ => none

/-- The same parse, keeping the reason it failed. -/
def parse? (input : @& String) (flags : UInt32 := 0) : Except String Document :=
  let bytes := events input flags
  if bytes.isEmpty then .error "md4c refused the input"
  else do return { blocks := ← drive { data := bytes, pos := 0 } }

end Md
