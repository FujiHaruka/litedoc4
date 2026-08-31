/-
`litedoc4 watch`'s file server: **the bytes that were built, and nothing else**.

**No live-reload script is injected.** A snippet appended to every page would make
the previewed page and the shipped page two different files, and the difference is
invisible exactly when it matters — a selector that only matches because of the
injected node, a script error the injected script swallowed. `watch` prints a line
per rebuild instead; the reload is a keystroke. What the server owes the reader is
that the keystroke works: `Cache-Control: no-store` on every response, because a
200 the browser served out of its own cache is "local build does not refresh after
code change" with the fix already applied.

**A taken port is an error with a name**, not a reason to try the next one: an
address that moves between runs leaves the tab the reader already has open
pointing at nothing, and nothing says so.

**Loopback only.** `127.0.0.1`, not `0.0.0.0`: this serves a half-finished
documentation site out of somebody's working tree, and binding every interface
publishes it to whatever network the machine is on without anybody having asked.
-/
import Std.Async.TCP
import Std.Net.Addr
import Litedoc4.Bytes
import Litedoc4.Fs

open System
open Std Std.Net Std.Async

namespace Litedoc4.Httpd

/-- **Not 8899**, where `tools/check-site-browser.ts` drives puppeteer and
sometimes leaks the listener; not 3000 / 8000 / 8080 / 5173 / 4173 either, where
every other development server in a working tree already is. The first thing a
default port must do is be free. -/
def defaultPort : UInt16 := 8484

/-- A request line plus headers; the body is never read, because no method here
has one. -/
def maxHeadBytes : Nat := 8 * 1024

def backlog : UInt32 := 128

private partial def lossyFrom (bs : ByteArray) (i : Nat) (acc : String) : String :=
  if i ≥ bs.size then acc
  else match bs.utf8DecodeChar? i with
    | some c => lossyFrom bs (i + c.utf8Size) (acc.push c)
    | none => lossyFrom bs (i + 1) (acc.push (Char.ofNat 0xFFFD))

def lossy (bs : ByteArray) : String :=
  match String.fromUTF8? bs with
  | some s => s
  | none => lossyFrom bs 0 ""

def hexValue (b : UInt8) : Option Nat :=
  let n := b.toNat
  if n ≥ 48 && n ≤ 57 then some (n - 48)
  else if n ≥ 97 && n ≤ 102 then some (n - 87)
  else if n ≥ 65 && n ≤ 70 then some (n - 55)
  else none

/-- One path segment with its `%XX` escapes resolved, or `none` when an escape is
malformed.

Bytes, not characters: a percent escape names a byte, and a UTF-8 name arrives as
several of them. -/
def decode (segment : String) : Option String := Id.run do
  if !segment.any (· == '%') then return some segment
  let raw := segment.toUTF8
  let mut bytes := ByteArray.emptyWithCapacity raw.size
  let mut i := 0
  while i < raw.size do
    if raw[i]! == 37 then
      if i + 2 ≥ raw.size then return none
      let some hi := hexValue raw[i + 1]! | return none
      let some lo := hexValue raw[i + 2]! | return none
      bytes := bytes.push (UInt8.ofNat (hi * 16 + lo))
      i := i + 3
    else
      bytes := bytes.push raw[i]!
      i := i + 1
  return some (lossy bytes)

inductive Route where
  | file (path : FilePath)
  /-- Nothing there: 404. -/
  | missing
  /-- Malformed: 400. -/
  | bad (why : String)
  /-- Well formed and pointing out of the tree: 403. -/
  | outside (why : String)

/-- **Decoded first, checked second**, which is the order that matters: `%2e%2e`
is `..` and `%2f` is `/`, so a check that ran before the decoding would pass both.
Everything that survives is a single component with no separator in it, so the
join in `route` cannot leave the tree. -/
def segments (target : String) : Except Route (Array String) := Id.run do
  -- A fragment never reaches a server, but a hand-written request can carry one.
  let path := ((((target.splitOn "?").headD "").splitOn "#").headD "")
  if !path.startsWith "/" then
    return .error (.bad "a request target has to be an absolute path (this server answers \
      `GET /x.html`, not an absolute URL and not a proxy request)")
  let mut out : Array String := #[]
  for raw in path.splitOn "/" do
    let some decoded := decode raw
      | return .error (.bad "a % escape in the path is not two hex digits")
    if decoded == "" || decoded == "." then
      continue
    if decoded == ".." then
      return .error (.outside "`..` is not resolved here: this server answers out of one \
        directory and a path that climbs above it has no answer")
    if decoded.any (fun c => c == '/' || c == '\\' || c == (Char.ofNat 0)) then
      return .error (.outside "an escaped path separator is not a file name: `%2f`, `%5c` and \
        a NUL are refused rather than joined")
    out := out.push decoded
  return .ok out

/-- Two layers, because they fail differently. `segments` never lets a `..` become
part of a path at all; the containment check below catches what that cannot see —
a symlink *inside* the site pointing out of it, where every component is innocent
and the resolved file is somebody's private key. A generated site holds no
symlinks, which is the argument for leaving the second check out and exactly why
it is in: the site is a directory a person can put anything in. -/
def route (root : FilePath) (target : String) : IO Route := do
  let segs ← match segments target with
    | .error r => return r
    | .ok segs => pure segs
  let mut path := root
  for segment in segs do
    path := path / segment
  if ← path.isDir then
    path := path / "index.html"
  match ← (IO.FS.realPath root).toBaseIO, ← (IO.FS.realPath path).toBaseIO with
  | .ok realRoot, .ok resolved =>
    if !isInside realRoot resolved then
      return .outside "that path resolves outside the site directory, so it is not this \
        server's to serve"
  | _, _ => pure ()
  if ← isRegularFile path then return .file path else return .missing

/-- The site itself is HTML, CSS, one script, JSON and one SVG; the rest of the
list is what a person drops into a site directory. Anything unrecognised is served
as bytes rather than guessed at. -/
def contentType (path : FilePath) : String :=
  -- Lowercased because APFS is case-insensitive by default, so the extension the
  -- file has and the extension a comparison sees are two questions.
  let name := (path.fileName.getD "").toLower
  let extension := match (name.splitOn ".").getLast? with
    | some tail => if tail == name then "" else tail
    | none => ""
  match extension with
  | "html" | "htm" => "text/html; charset=utf-8"
  | "css" => "text/css; charset=utf-8"
  | "js" | "mjs" => "text/javascript; charset=utf-8"
  | "json" | "map" => "application/json; charset=utf-8"
  | "svg" => "image/svg+xml"
  | "png" => "image/png"
  | "jpg" | "jpeg" => "image/jpeg"
  | "gif" => "image/gif"
  | "ico" => "image/x-icon"
  | "woff2" => "font/woff2"
  | "woff" => "font/woff"
  | "txt" | "md" => "text/plain; charset=utf-8"
  | "xml" => "application/xml"
  | _ => "application/octet-stream"

structure Response where
  status : Nat
  reason : String
  kind : String
  body : ByteArray

def Response.text (status : Nat) (reason body : String) : Response :=
  { status, reason, kind := "text/plain; charset=utf-8", body := (body ++ "\n").toUTF8 }

/-- The site's own `404.html` when it has one, so that a wrong URL looks the way
it will look once the site is published. -/
def notFound (root : FilePath) (target : String) : IO Response := do
  match ← (IO.FS.readBinFile (root / "404.html")).toBaseIO with
  | .ok bytes => return { status := 404, reason := "Not Found"
                          kind := "text/html; charset=utf-8", body := bytes }
  | .error _ => return Response.text 404 "Not Found" s!"no such file: {target}"

def respond (root : FilePath) (target : String) : IO Response := do
  if !(← root.isDir) then
    -- The first build has not finished, or it failed. Said, not hung on: an empty
    -- page with no explanation is the browser's version of a hang.
    return Response.text 503 "Service Unavailable" "the site has not been generated yet — the \
      first build is still running, or it stopped. The window running `litedoc4 watch` says which"
  match ← route root target with
  | .file path =>
    match ← (IO.FS.readBinFile path).toBaseIO with
    | .ok bytes => return { status := 200, reason := "OK", kind := contentType path, body := bytes }
    | .error e => return Response.text 500 "Internal Server Error" s!"{path}: {e}"
  | .missing => notFound root target
  | .bad why => return Response.text 400 "Bad Request" why
  | .outside why => return Response.text 403 "Forbidden" why

/-- `Content-Length` is the file's length on a `HEAD` too — that is what the header
means — and `Connection: close` because there is no keep-alive: one request per
connection is what makes the read below bounded. -/
def wire (r : Response) (withBody : Bool) : ByteArray :=
  let head := s!"HTTP/1.1 {r.status} {r.reason}\r\nContent-Type: {r.kind}\r\nContent-Length: \
    {r.body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
  if withBody then head.toUTF8 ++ r.body else head.toUTF8

private def blankLineAt (bs : ByteArray) : Bool := Id.run do
  let mut i := 0
  while i + 1 < bs.size do
    if bs[i]! == 10 then
      if bs[i + 1]! == 10 then return true
      if i + 2 < bs.size && bs[i + 1]! == 13 && bs[i + 2]! == 10 then return true
    i := i + 1
  return false

private def dropTrailingCR (s : String) : String :=
  if s.endsWith "\r" then byteSub s 0 (s.utf8ByteSize - 1) else s

private def firstLine (bs : ByteArray) : Option String :=
  ((lossy bs).splitOn "\n").map dropTrailingCR |>.find? (!·.isEmpty)

/-- The request line, with the rest of the head read and discarded. Bounded, so
that a connection which never sends a blank line is answered rather than waited
on — nothing here may look like a hang. -/
private partial def readHead (c : TCP.Socket.Client) (acc : ByteArray) :
    Async (Option String) := do
  let line := firstLine acc
  -- The blank line only ends the head once a request line has been seen: a client
  -- that opens with a bare CRLF would otherwise be answered 400 for a request it
  -- has not sent yet.
  if (line.isSome && blankLineAt acc) || acc.size ≥ maxHeadBytes then return line
  match ← c.recv? 4096 with
  | none => return line
  | some chunk => readHead c (acc ++ chunk)

def answer (root : FilePath) (c : TCP.Socket.Client) : Async Unit := do
  let response ← match ← readHead c ByteArray.empty with
    | none => pure (Response.text 400 "Bad Request" "no request line", true)
    | some line =>
      let parts := line.splitOn " "
      let method := parts.headD ""
      let target := (parts.drop 1).headD ""
      if method == "GET" then pure (← respond root target, true)
      else if method == "HEAD" then pure (← respond root target, false)
      else pure (Response.text 405 "Method Not Allowed" "this server reads a directory of \
        files; GET and HEAD are all it can do", true)
  c.send (wire response.1 response.2)
  c.shutdown

private partial def acceptLoop (server : TCP.Socket.Server) (root : FilePath) : Async Unit := do
  let client? ← try
      -- One task per connection. A browser opens several at once for one page
      -- (the HTML, the CSS, the script), and an accept loop that answered them
      -- one after another makes each of them wait for the one before it — which
      -- on a 34 MB site reads as the server being slow.
      pure (some (← server.accept))
    catch e =>
      IO.eprintln s!"watch   http: cannot accept a connection: {e}"
      pure none
  if let some client := client? then
    let _ ← MonadAsync.async (t := AsyncTask) (do
      try
        answer root client
      catch e =>
        -- A client that went away mid-response is ordinary (a reload cancels the
        -- one in flight), so this is a note and never a failure of the run.
        IO.eprintln s!"watch   http: {e}")
  acceptLoop server root

/-- A listening socket that is already answering, or the refusal for a port
somebody else has.

**The accept loop is started here and not by the caller**, which is where this
differs from `crates/litedoc4/src/httpd.rs`: in Lean a socket that has only been
`bind`+`listen`ed does not hold the port — two servers that both stop there do not
conflict, and the second one to issue `accept` wins it (measured 2026-08-31 →
`benchmarks/results/purelean-async-tcp-2026-08-31.txt` §4). Splitting this in two
so that the caller may print a banner in between would put that window between the
check and the claim it licenses. What would falsify it: a libuv that binds
eagerly, which is what the same section measured it does not do. -/
def bind (port : UInt16) (root : FilePath) : IO (Except String TCP.Socket.Server) := do
  let server ← TCP.Socket.Server.mk
  let address : SocketAddress := .v4 { addr := IPv4Addr.ofParts 127 0 0 1, port }
  -- `listen`, not `bind`, is what says the port is taken: `bind` never throws, and
  -- `accept` on a socket whose `listen` failed does not throw either — so a naive
  -- reading of `bind` alone reports success and serves nothing.
  match ← (do server.bind address; server.listen backlog).toBaseIO with
  | .error e =>
    return .error s!"127.0.0.1:{port}: {e}. The port is refused rather than moved to the next \
      free one — an address that changes between runs leaves the browser tab you already have \
      open pointing at nothing. Pass --port <n>, or find what is holding it with `lsof -nP \
      -iTCP:{port} -sTCP:LISTEN`"
  | .ok () =>
    -- Detached on purpose: it has no exit condition, and the process ending is
    -- what closes the listener.
    let _ ← (acceptLoop server root).toIO
    return .ok server

end Litedoc4.Httpd
