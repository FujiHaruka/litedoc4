//! Build the site's `app.js` from the TypeScript in `web/`.
//!
//! What this crate compiles in comes from `web/src` and nowhere else: the
//! output lands in cargo's `OUT_DIR`, so `include_str!` cannot pick up a
//! version behind its sources. The cost is that node is a build dependency of
//! this crate, paid by whoever builds from source.
//!
//! There is deliberately no fallback to a checked-in bundle *here*. Two ways of
//! answering "where does app.js come from" is the shape where only one of them
//! ever gets fixed. The committed bundles under `assets/` are not that second
//! way: the Lean half cannot `include_str!`, so it reads them through
//! `tools/gen-assets.py`, and the last stage of `tools/assets-gate.sh` is what
//! holds them to what these sources build.

use std::env;
use std::path::Path;
use std::process::Command;

fn main() {
    // A directory is walked recursively, so this covers every module under it.
    for input in [
        "../../web/src",
        "../../web/package.json",
        "../../web/package-lock.json",
        "../../web/tsconfig.json",
        "../../web/vite.config.ts",
        "../../web/vite.boot.config.ts",
    ] {
        println!("cargo:rerun-if-changed={input}");
    }

    let out_dir = env::var("OUT_DIR").expect("cargo sets OUT_DIR");

    // `npm ci` rather than `npm install`: the lockfile is the version everything
    // downstream was tested against, and a build is not the place to resolve a
    // new one.
    if !Path::new("web/node_modules").exists() {
        npm(&["ci", "--no-audit", "--no-fund"], &out_dir);
    }
    npm(&["run", "build"], &out_dir);

    for name in ["app.js", "theme-boot.js"] {
        let bundle = Path::new(&out_dir).join(name);
        assert!(
            bundle.exists(),
            "vite reported success but wrote no {}. \
             `web/vite.config.ts` and `web/vite.boot.config.ts` decide the \
             names; they and this file have to agree.",
            bundle.display(),
        );
    }
}

/// Output is captured and only shown on failure: a build script's stdout is
/// cargo's directive channel, and npm's progress lines are not directives.
fn npm(args: &[&str], out_dir: &str) {
    let shown = args.join(" ");
    // `npm.cmd` on Windows, because `Command` there is `CreateProcessW`, which
    // appends `.exe` and nothing else: the extensionless `npm` shipped next to
    // it is a shell script, so the plain name is "program not found" even with
    // node on PATH (measured 2026-08-30). The panic below then names the one
    // cause that is not it.
    let result = Command::new(if cfg!(windows) { "npm.cmd" } else { "npm" })
        .args(args)
        .current_dir("../../web")
        // `web/vite.config.ts` reads this; absent it writes to `web/dist`
        // instead, so a hand-run `npm run build` never contends for this file.
        .env("LITEDOC4_ASSET_OUT_DIR", out_dir)
        .output();

    let output = match result {
        Ok(output) => output,
        Err(e) => panic!(
            "could not run `npm {shown}` in web: {e}\n\
             \n\
             This crate builds the site's app.js from TypeScript, so node is \
             required to build it from source. The version this tree is \
             pinned to is in mise.toml; \
             `mise install` puts it on PATH.",
        ),
    };

    assert!(
        output.status.success(),
        "`npm {shown}` failed in web ({})\n\
         \n\
         --- stdout ---\n{}\n--- stderr ---\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}
