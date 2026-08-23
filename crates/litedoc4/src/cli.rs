//! The one command-line parser, so that thirteen of them are not thirteen
//! answers to the same question.
//!
//! Every subcommand had its own copy of the same skeleton — a `while let` over
//! the arguments, a `value` closure that took the next one or refused by name,
//! a `--help` arm, and an `unknown argument` arm. The closure was byte for byte
//! identical in all thirteen; the `--help` arm was not, and had already drifted
//! into three spellings.
//!
//! **What this does not take over is the `match`.** Each subcommand's arms are
//! its interface — including the refusals it words itself, which are part of
//! the product's output — so they stay where they are. What moves here is only
//! the mechanism they all shared.
//!
//! ```ignore
//! let mut args = Args::new(argv);
//! while let Some(arg) = args.next() {
//!     match arg.as_str() {
//!         "--out" => out = Some(args.value("--out")?.into()),
//!         "--jobs" => jobs = args.number("--jobs")?,
//!         "--help" | "-h" => return cli::help(),
//!         other => return cli::unknown(other),
//!     }
//! }
//! ```

use std::str::FromStr;

use crate::{Failure, USAGE, usage};

/// The argument list, and the one way to take a flag's value off it.
pub(crate) struct Args<'a> {
    rest: std::slice::Iter<'a, String>,
}

impl<'a> Args<'a> {
    pub(crate) fn new(args: &'a [String]) -> Self {
        Self { rest: args.iter() }
    }

    /// The next argument, or `None` at the end.
    ///
    /// **Not an `Iterator` impl.** `for arg in args` would borrow the whole
    /// struct for the loop, and every caller needs [`Args::value`] *inside* it.
    /// (`clippy::should_implement_trait` does not fire on this — the method is
    /// not public — so there is nothing to `#[expect]`.)
    pub(crate) fn next(&mut self) -> Option<&'a String> {
        self.rest.next()
    }

    /// The value belonging to `flag`, or a refusal naming it.
    ///
    /// The refusal is by name because the alternative — "expected a value" —
    /// leaves the reader to count arguments to find out which flag ran out.
    pub(crate) fn value(&mut self, flag: &str) -> Result<String, Failure> {
        match self.rest.next() {
            Some(value) => Ok(value.clone()),
            None => usage(format!("{flag} needs a value")),
        }
    }

    /// The value belonging to `flag`, parsed.
    ///
    /// **The refusal quotes what was given**: `--jobs wants a number, not four`
    /// says which of the two words on the command line was the problem, where
    /// "invalid digit found in string" does not.
    pub(crate) fn number<T: FromStr>(&mut self, flag: &str) -> Result<T, Failure> {
        let raw = self.value(flag)?;
        raw.parse()
            .map_err(|_| Failure::Usage(format!("{flag} wants a number, not {raw}")))
    }
}

/// What every subcommand's `--help` arm does.
///
/// Eleven of the fourteen subcommands answer it this way. The other three do
/// not, and both differences are on purpose: [`crate::build`] returns
/// `Err(Failure::Answered(0))` because its `Ok` means "run", and
/// [`crate::watch`] scans for it before the parse. Their reasons are written
/// where they are.
pub(crate) fn help() -> Result<(), Failure> {
    println!("{USAGE}");
    Ok(())
}

/// What every subcommand's last `match` arm does.
pub(crate) fn unknown<T>(arg: &str) -> Result<T, Failure> {
    usage(format!("unknown argument `{arg}`"))
}
