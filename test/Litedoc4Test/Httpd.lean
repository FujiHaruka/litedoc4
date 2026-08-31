/- `crates/litedoc4/src/httpd.rs`: `litedoc4 watch`'s file server, reduced to the
two questions that are not about a socket — which file a request target names,
and what to call its bytes.

The refusals (`..` in every spelling, an escaped separator, a symlink out of the
site, a site that is not there yet) are reachable with one `curl` against
`litedoc4 watch` and belong to a refusal gate; `a_real_request_gets_the_file`
is `tools/watch-gate.sh` step 5/5. What is left is here.

The routing needs a directory to answer at all — "a directory is its index" is a
question for a file system — so it is the run-time half. It binds no port: the
decision this makes is about a path, and taking a port to ask it would make two
copies of the test executable fight over one address. -/
import Litedoc4.Httpd
import Litedoc4Test.IncrFixture

namespace Litedoc4Test
open Litedoc4 System

/-- The site itself is HTML, CSS, one script, JSON and one SVG. Anything else is
served as bytes rather than guessed at, and the extension is lower-cased first
because APFS is case-insensitive by default — the extension a file has and the
extension a comparison sees are two questions. A name with no dot in it has no
extension rather than being its own. -/
def theContentTypeFollowsTheExtensionAndFallsBackToBytes : Bool :=
  Httpd.contentType "a/b.html" == "text/html; charset=utf-8"
    && Httpd.contentType "a/b.HTML" == "text/html; charset=utf-8"
    && Httpd.contentType "style.css" == "text/css; charset=utf-8"
    && Httpd.contentType "declarations/name-map.json" == "application/json; charset=utf-8"
    && Httpd.contentType "favicon.svg" == "image/svg+xml"
    && Httpd.contentType "LICENSE" == "application/octet-stream"

#guard theContentTypeFollowsTheExtensionAndFallsBackToBytes

def describeRoute (root : FilePath) : Httpd.Route → String
  | .file path =>
    let text := path.toString
    let prefix_ := root.toString ++ "/"
    if text.startsWith prefix_ then "file " ++ (text.drop prefix_.length) else "file " ++ text
  | .missing => "missing"
  | .bad _ => "bad"
  | .outside _ => "outside"

/-- Every answer this gives for a site that really exists, and the two that are
not refusals: a directory is its `index.html` whether or not the target ends in a
slash, a file is itself, and **a target nothing is there for is `missing`, not an
error** — a 404 and a 400 are different things to tell a browser.

The query is not part of the file name: the site's own script appends one to
break a cache, so a server that took `style.css?v=2` as a name would 404 the
stylesheet on every page load after a rebuild. -/
def aDirectoryIsItsIndexAFileIsItselfAndNothingThereIsMissing : Invariant where
  name := "route answers index.html for a directory, the file for a file, and missing for a \
    target nothing is there for"
  check := do
    let work ← incrWorkDir "httpd-route"
    let site := work / "site"
    IO.FS.createDirAll (site / "Pkg")
    for (path, body) in [("index.html", "<h1>index</h1>"), ("404.html", "<h1>not found</h1>"),
        ("style.css", "body{}"), ("Pkg/Basic.html", "<h1>Pkg.Basic</h1>"),
        ("Pkg/index.html", "<h1>Pkg</h1>")] do
      IO.FS.writeFile (site / path) body
    let mut answers : Array String := #[]
    for target in ["/", "/Pkg/", "/Pkg", "/Pkg/Basic.html", "/style.css?v=2",
        "/Pkg/Other.html", "/nope/"] do
      answers := answers.push (describeRoute site (← Httpd.route site target))
    removeDir work
    return eq answers.toList
      ["file index.html", "file Pkg/index.html", "file Pkg/index.html", "file Pkg/Basic.html",
       "file style.css", "missing", "missing"]

end Litedoc4Test
