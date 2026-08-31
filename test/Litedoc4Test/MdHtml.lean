/- `crates/litedoc4-md/src/html.rs::entities_are_passed_through_raw`. -/
import Litedoc4.Md.Html
import Litedoc4Test.Basis

namespace Litedoc4Test
open Litedoc4

def render (md : String) : String :=
  (docstring "" { root := "../", links := noLinks } md).run' 0

/-- md4c reports anything entity-shaped as an entity and the renderer writes it
out untouched, so `&notanentity;` survives with its `&`; a bare `&` is not
entity-shaped, goes through the text path, and is escaped.

A `#guard` cannot ask this. `Md.events` is `opaque` with an `@[extern]` body, so
elaboration-time evaluation has no `litedoc4_md_events` to call — the C is
linked into the executable and nothing else. What would falsify it: a
`precompileModules` on the library, which would put the symbol in the
interpreter and cost every consumer a shared library. -/
def entitiesArePassedThroughRaw : Invariant where
  name := "an entity keeps its & and a bare & is escaped"
  check := return first [
    eq (render "&amp; &notanentity;\n") "<p>&amp; &notanentity;</p>",
    eq (render "a & b\n") "<p>a &amp; b</p>"]

end Litedoc4Test
