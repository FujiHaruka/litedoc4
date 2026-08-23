//! The `litedoc4` binary: dispatch, and nothing else.
//!
//! Everything the subcommands are made of is in the library beside this file
//! (`lib.rs`), so that a test of a command line does not have to start a
//! process to reach it.

use std::process::ExitCode;

use litedoc4::{Failure, USAGE, build, extract, ledger, pipeline, queries, stages, usage, watch};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(Failure::Usage(message)) => {
            eprintln!("litedoc4: {message}\n\n{USAGE}");
            ExitCode::from(2)
        }
        Err(Failure::Failed(message)) => {
            eprintln!("litedoc4: {message}");
            ExitCode::FAILURE
        }
        Err(Failure::Answered(code)) => ExitCode::from(code),
        Err(Failure::Refused { code, message }) => {
            eprintln!("litedoc4: {message}");
            ExitCode::from(code)
        }
    }
}

fn run(args: &[String]) -> Result<(), Failure> {
    match args.first().map(String::as_str) {
        Some("build") => build::build(&args[1..]),
        Some("watch") => watch::watch(&args[1..]),
        Some("incremental") => pipeline::incremental(&args[1..]),
        Some("modules") => pipeline::modules(&args[1..]),
        Some("links") => queries::links(&args[1..]),
        Some("extract") => extract::extract(&args[1..]),
        Some("site") => stages::site(&args[1..]),
        Some("render") => stages::render(&args[1..]),
        Some("global") => stages::global(&args[1..]),
        Some("ledger") => ledger::ledger(&args[1..]),
        Some("ownership") => queries::ownership(&args[1..]),
        Some("merge") => queries::merge(&args[1..]),
        Some("impact") => queries::impact(&args[1..]),
        Some("prune") => queries::prune(&args[1..]),
        Some("--help" | "-h") | None => {
            println!("{USAGE}");
            Ok(())
        }
        Some("--version") => {
            println!("litedoc4 {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some(other) => usage(format!("unknown subcommand `{other}`")),
    }
}
