//! The fake extractor, written once for every test binary in this directory
//! that needs one.
//!
//! `--extractor` has no default, so the extraction step is the one seam these
//! tests hand a stand-in through: a `/bin/sh` script that takes a module list
//! and writes a partial IR tree, every byte of it copied out of a baked world so
//! that an incrementally merged tree and a from-scratch one stay comparable. A
//! second Rust binary would ship with the product; a real Lean toolchain would
//! mean none of these tests exist.
//!
//! One script and not one per file, because `build.rs` and `incremental.rs`
//! **both** hold a gate that compares what the fake extractor baked against a
//! full generation. While the script existed twice, one copy's IR-generation
//! rule could move while the other stood still and both comparisons would still
//! pass, each against a tree its own script wrote. [`Features`] names what the
//! two flavours differ by, so a new one is added here rather than by forking.
//!
//! This file and not `litedoc4-testutil`, because what the script writes is a
//! format **the extractor owns** — `index.json`'s `schemaVersion`, `generator`,
//! `hashAlgorithm`, `leanVersion` and `dependencyMaps` are
//! `extractor/Extract.lean`'s spelling, and the only program that reads them
//! back is the `litedoc4` binary this directory tests. A `tests/common/mod.rs`
//! reaches exactly the two callers and nothing else; a writer of that format in
//! a crate every crate may depend on would invite a third caller that is not
//! testing this binary at all.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

#[derive(Clone, Copy)]
pub(crate) struct Features {
    /// Accept `--corrupt <Module>` and, after a **successful** extraction, write
    /// bytes the renderer cannot read into that module's IR file. The run then
    /// fails in the renderer, which is the half of the ledger's ordering no
    /// failing extractor can reach: a failing extractor stops the run before the
    /// IR exists.
    pub(crate) corrupt: bool,
    /// Copy `ir/deps/*.json` and inline `ir/deps-index.json` as `index.json`'s
    /// `dependencyMaps`; off, the array is written empty. Inlined rather than
    /// computed because a shell that worked out the byte counts itself would be
    /// a second writer of a format the extractor owns.
    pub(crate) deps: bool,
}

pub(crate) fn write_fake_extractor(path: &Path, features: Features) {
    let mut script = String::new();

    script.push_str(
        r#"#!/bin/sh
# The fake extractor. Both flavours are written by one generator —
# crates/litedoc4/tests/common/mod.rs — so that the IR-generation rule
# crates/litedoc4/tests/{build,incremental}.rs each compare against full
# generation cannot move on one side only.
set -eu
WORLD=""; MODULES=""; IRDIR=""; TIMINGS=""; FAIL=0"#,
    );
    if features.corrupt {
        script.push_str(r#"; CORRUPT="""#);
    }
    script.push_str(
        r#"
while [ $# -gt 0 ]; do
  case "$1" in
    --world) WORLD="$2"; shift 2 ;;
    --modules) MODULES="$2"; shift 2 ;;
    --ir-dir) IRDIR="$2"; shift 2 ;;
    --timings) TIMINGS="$2"; shift 2 ;;
    --fail) FAIL=1; shift ;;
"#,
    );
    if features.corrupt {
        script.push_str("    --corrupt) CORRUPT=\"$2\"; shift 2 ;;\n");
    }
    script.push_str(
        r#"    *) echo "fake extractor: unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODULES" ] && [ -n "$IRDIR" ] && [ -n "$TIMINGS" ] || {
  echo "fake extractor: --modules, --ir-dir and --timings are all required" >&2; exit 2; }
WORK=$(dirname "$TIMINGS")
# `--world` first, and every flag named: `build.rs`'s reader looks for the token
# after `--modules`, and `incremental.rs`'s asserts this order.
echo "--world $WORLD --modules $MODULES --ir-dir $IRDIR --timings $TIMINGS" \
  >> "$WORK/extractor-calls.txt"
[ "$FAIL" = 0 ] || { echo "fake extractor: asked to fail" >&2; exit 3; }
mkdir -p "$IRDIR/modules"
"#,
    );
    if features.deps {
        script.push_str(
            r#"# The dependency slices, when the world has any. Its `deps-index.json` is the
# `dependencyMaps` array verbatim, because a shell that computed the byte counts
# itself would be a second writer of a format the extractor owns.
DEPS=""
if [ -f "$WORLD/ir/deps-index.json" ]; then
  DEPS=$(cat "$WORLD/ir/deps-index.json")
  mkdir -p "$IRDIR/deps"
  cp "$WORLD"/ir/deps/*.json "$IRDIR/deps/"
fi
"#,
        );
    }
    script.push_str(
        r#"ENTRIES="$WORK/.entries"
: > "$ENTRIES"
n=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  cp "$WORLD/ir/modules/$m.json" "$IRDIR/modules/$m.json"
  [ "$n" -eq 0 ] || printf ',' >> "$ENTRIES"
  cat "$WORLD/entries/$m.json" >> "$ENTRIES"
  n=$((n + 1))
done < "$MODULES"
{
"#,
    );
    // The one line of `index.json` the two flavours do not share — and with no
    // `deps-index.json` in the world `$DEPS` is empty, so even here they agree.
    script.push_str(if features.deps {
        "  printf '{\"declarationCount\":0,\"dependencyMaps\":[%s],' \"$DEPS\"\n"
    } else {
        "  printf '{\"declarationCount\":0,\"dependencyMaps\":[],'\n"
    });
    script.push_str(
        r#"  printf '"generator":"fake-extractor","hashAlgorithm":"lean-string-hash-64/hex16",'
  printf '"leanVersion":"4.31.0","moduleCount":%s,"modules":[' "$n"
  cat "$ENTRIES"
  printf '],"schemaVersion":5}'
} > "$IRDIR/index.json"
rm -f "$ENTRIES"
"#,
    );
    if features.corrupt {
        script.push_str(
            r#"# `--corrupt <Module>`: an IR file the renderer cannot read. The extraction
# still succeeds, so the run fails in the renderer, which is the half of the
# ledger's ordering no failing extractor can reach.
[ -z "$CORRUPT" ] || printf 'not json' > "$IRDIR/modules/$CORRUPT.json"
"#,
        );
    }
    script.push_str(
        "printf '{\"targetModules\":%s,\"extractor\":\"fake\"}\\n' \"$n\" > \"$TIMINGS\"\n",
    );

    fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
    fs::write(path, script.as_bytes()).expect("writable");
    let mut perms = fs::metadata(path).expect("the script exists").permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).expect("the script is chmod-able");
}

// These run `/bin/sh` over a two-module world and read what the script wrote:
// the subject is what the script *does*, and asserting on its text would only
// restate the lines above.
//
// `mod common;` compiles this into every binary that declares it, so they run
// once per such binary — deliberately, so that whichever of `build.rs` and
// `incremental.rs` a developer runs on its own checks the shared generator.
//
// Nothing else reads the incremental flavour's `"dependencyMaps":[]`:
// `litedoc4-incr::merge` recomputes the array from the merged module files
// rather than taking the incremental tree's, so a world with a dependency map
// spliced into that array leaves every test in `incremental.rs` green
// (measured 2026-08-23). Hence the bytes each flavour writes are pinned here,
// where a change to one flavour is visible next to the other.
#[cfg(test)]
mod tests {
    use std::process::Output;

    use litedoc4_testutil::TempDirs;
    use litedoc4_testutil::cli::{Cli, code, stderr};

    use super::*;

    const TEMP: TempDirs = TempDirs::prefixed("litedoc4-fake-extractor");

    /// The script is started the way the product starts it: `--extractor
    /// /bin/sh --extractor-arg <script>` becomes `/bin/sh <script> …`.
    const SH: Cli = Cli::at("/bin/sh");

    /// The script copies bytes and counts lines and never parses either file, so
    /// the two modules need only be distinguishable.
    fn write_world(world: &Path) {
        for (module, entry) in [
            ("Pkg", r#"{"module":"Pkg"}"#),
            ("Pkg.B", r#"{"module":"Pkg.B"}"#),
        ] {
            put(
                &world.join(format!("ir/modules/{module}.json")),
                format!("the IR of {module}").as_bytes(),
            );
            put(
                &world.join(format!("entries/{module}.json")),
                entry.as_bytes(),
            );
        }
    }

    fn put(path: &Path, body: &[u8]) {
        fs::create_dir_all(path.parent().expect("a parent")).expect("writable");
        fs::write(path, body).expect("writable");
    }

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
    }

    fn extract(script: &Path, world: &Path, ir: &Path, extra: &[&str]) -> Output {
        let work = ir.parent().expect("a work directory");
        fs::create_dir_all(work).expect("writable");
        let modules = work.join("modules.txt");
        put(&modules, b"Pkg\nPkg.B\n");
        let mut args: Vec<String> = [
            script.display().to_string(),
            "--world".to_owned(),
            world.display().to_string(),
            "--modules".to_owned(),
            modules.display().to_string(),
            "--ir-dir".to_owned(),
            ir.display().to_string(),
            "--timings".to_owned(),
            work.join("timings.json").display().to_string(),
        ]
        .to_vec();
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        SH.run(&args)
    }

    /// The expected bytes are written out rather than derived from the
    /// generator: they are what a merged tree is compared against.
    #[test]
    fn a_world_with_no_dependency_map_gets_the_same_index_from_both_flavours() {
        let temp = TEMP.make("no-deps");
        let world = temp.path().join("world");
        write_world(&world);

        const EXPECTED: &str = concat!(
            r#"{"declarationCount":0,"dependencyMaps":[],"generator":"fake-extractor","#,
            r#""hashAlgorithm":"lean-string-hash-64/hex16","leanVersion":"4.31.0","#,
            r#""moduleCount":2,"modules":[{"module":"Pkg"},{"module":"Pkg.B"}],"#,
            r#""schemaVersion":5}"#,
        );

        for (what, features) in [
            (
                "build",
                Features {
                    corrupt: true,
                    deps: true,
                },
            ),
            (
                "incremental",
                Features {
                    corrupt: false,
                    deps: false,
                },
            ),
        ] {
            let script = temp.path().join(format!("{what}.sh"));
            write_fake_extractor(&script, features);
            let ir = temp.path().join(format!("{what}/ir"));
            let output = extract(&script, &world, &ir, &[]);
            assert_eq!(code(&output), 0, "{what}: {}", stderr(&output));

            assert_eq!(read(&ir.join("index.json")), EXPECTED, "{what}");
            assert_eq!(
                read(&ir.join("modules/Pkg.B.json")),
                "the IR of Pkg.B",
                "{what}: the module file is the world's, copied",
            );
            assert_eq!(
                read(&ir.parent().expect("a work directory").join("timings.json")),
                "{\"targetModules\":2,\"extractor\":\"fake\"}\n",
                "{what}",
            );
        }
    }

    /// Two readers disagree about how to read the line: `incremental.rs`'s
    /// `case_extractor_contract` asserts the order and that `--world` is first,
    /// while `build.rs`'s `Live::extractions` takes the token after `--modules`.
    /// One line has to satisfy both, and this is where that is stated.
    #[test]
    fn the_recorded_call_names_every_flag_with_the_world_first() {
        let temp = TEMP.make("call-line");
        let world = temp.path().join("world");
        write_world(&world);

        for (what, features) in [
            (
                "build",
                Features {
                    corrupt: true,
                    deps: true,
                },
            ),
            (
                "incremental",
                Features {
                    corrupt: false,
                    deps: false,
                },
            ),
        ] {
            let script = temp.path().join(format!("{what}.sh"));
            write_fake_extractor(&script, features);
            let ir = temp.path().join(format!("{what}/ir"));
            let output = extract(&script, &world, &ir, &[]);
            assert_eq!(code(&output), 0, "{what}: {}", stderr(&output));

            let work = ir.parent().expect("a work directory");
            let line = read(&work.join("extractor-calls.txt"));
            let line = line.trim_end();
            assert_eq!(
                line,
                format!(
                    "--world {} --modules {} --ir-dir {} --timings {}",
                    world.display(),
                    work.join("modules.txt").display(),
                    ir.display(),
                    work.join("timings.json").display(),
                ),
                "{what}",
            );
            assert!(line.starts_with("--world "), "{what}: {line}");
            let mut tokens = line.split_whitespace();
            let modules = tokens
                .find(|token| *token == "--modules")
                .and_then(|_| tokens.next())
                .expect("--modules has a value");
            assert_eq!(read(Path::new(modules)).lines().count(), 2, "{what}");
        }
    }

    #[test]
    fn the_dependency_slices_are_carried_only_where_the_feature_is_on() {
        let temp = TEMP.make("deps");
        let world = temp.path().join("world");
        write_world(&world);
        let slice = r#"{"schemaVersion":5,"package":"Dep","declarations":{"Dep.x":"Dep.Home"}}"#;
        put(&world.join("ir/deps/Dep.json"), slice.as_bytes());
        put(
            &world.join("ir/deps-index.json"),
            br#"{"package":"Dep","file":"deps/Dep.json","entries":1,"bytes":72}"#,
        );

        let on = temp.path().join("on.sh");
        write_fake_extractor(
            &on,
            Features {
                corrupt: false,
                deps: true,
            },
        );
        let ir = temp.path().join("on/ir");
        let output = extract(&on, &world, &ir, &[]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert!(
            read(&ir.join("index.json")).starts_with(concat!(
                r#"{"declarationCount":0,"dependencyMaps":"#,
                r#"[{"package":"Dep","file":"deps/Dep.json","entries":1,"bytes":72}],"#,
            )),
            "{}",
            read(&ir.join("index.json")),
        );
        assert_eq!(read(&ir.join("deps/Dep.json")), slice);

        let off = temp.path().join("off.sh");
        write_fake_extractor(
            &off,
            Features {
                corrupt: false,
                deps: false,
            },
        );
        let ir = temp.path().join("off/ir");
        let output = extract(&off, &world, &ir, &[]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert!(
            read(&ir.join("index.json")).contains(r#""dependencyMaps":[],"#),
            "the world's dependency map reached a flavour that did not ask for it: {}",
            read(&ir.join("index.json")),
        );
        assert!(
            !ir.join("deps").exists(),
            "a flavour that does not carry the slices created a directory for them",
        );
    }

    #[test]
    fn corrupt_writes_unreadable_bytes_only_where_the_feature_is_on() {
        let temp = TEMP.make("corrupt");
        let world = temp.path().join("world");
        write_world(&world);

        let on = temp.path().join("on.sh");
        write_fake_extractor(
            &on,
            Features {
                corrupt: true,
                deps: false,
            },
        );
        let ir = temp.path().join("on/ir");
        let output = extract(&on, &world, &ir, &["--corrupt", "Pkg.B"]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert_eq!(read(&ir.join("modules/Pkg.B.json")), "not json");
        assert_eq!(
            read(&ir.join("modules/Pkg.json")),
            "the IR of Pkg",
            "the module that was not named was corrupted too",
        );
        assert!(
            read(&ir.join("index.json")).ends_with(r#""schemaVersion":5}"#),
            "the index was written before the corruption and stays whole",
        );

        let ir = temp.path().join("on-clean/ir");
        let output = extract(&on, &world, &ir, &[]);
        assert_eq!(code(&output), 0, "{}", stderr(&output));
        assert_eq!(read(&ir.join("modules/Pkg.B.json")), "the IR of Pkg.B");

        let off = temp.path().join("off.sh");
        write_fake_extractor(
            &off,
            Features {
                corrupt: false,
                deps: false,
            },
        );
        let ir = temp.path().join("off/ir");
        let output = extract(&off, &world, &ir, &["--corrupt", "Pkg.B"]);
        assert_eq!(code(&output), 2, "{}", stderr(&output));
        assert!(
            stderr(&output).contains("unknown option: --corrupt"),
            "{}",
            stderr(&output),
        );
        assert!(
            !ir.join("modules").exists(),
            "the refusal happened after the tree was made",
        );
    }
}
