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

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_owned()).collect()
    }

    /// The message of a refusal that came from the command line.
    ///
    /// Panics on any other variant: everything this module produces is a
    /// `Usage`, and a test that quietly accepted a `Failed` would be checking
    /// that *something* went wrong rather than that the right thing did.
    fn refusal(failure: &Failure) -> String {
        match failure {
            Failure::Usage(message) => message.clone(),
            other => panic!("expected a usage refusal, got {other:?}"),
        }
    }

    #[test]
    fn value_takes_the_argument_after_the_flag_and_consumes_it() {
        let raw = argv(&["--out", "site", "--jobs"]);
        let mut args = Args::new(&raw);
        assert_eq!(args.next().map(String::as_str), Some("--out"));
        assert_eq!(args.value("--out").expect("a value"), "site");
        assert_eq!(args.next().map(String::as_str), Some("--jobs"));
        assert!(args.next().is_none(), "the list is exhausted");
    }

    /// A flag that runs out is refused **by its own name**.
    ///
    /// Thirteen subcommands share this one message, so the name is the only
    /// thing that tells a reader which of their flags was the problem —
    /// "expected a value" would leave them counting arguments.
    #[test]
    fn a_flag_with_nothing_after_it_is_refused_by_name() {
        for flag in ["--out", "--ir", "--extractor-bin"] {
            let raw = argv(&[flag]);
            let mut args = Args::new(&raw);
            args.next();
            let message = match args.value(flag) {
                Ok(value) => panic!("{flag} at the end of the line yielded {value}"),
                Err(failure) => refusal(&failure),
            };
            assert_eq!(message, format!("{flag} needs a value"));
        }
    }

    #[test]
    fn number_parses_the_value_it_took() {
        let raw = argv(&["--jobs", "4"]);
        let mut args = Args::new(&raw);
        args.next();
        assert_eq!(args.number::<usize>("--jobs").expect("a number"), 4);
    }

    /// The refusal quotes **what was given**, which is the half that
    /// `invalid digit found in string` does not have.
    #[test]
    fn number_refuses_by_quoting_what_it_was_given() {
        for raw_value in ["four", "", "4.5", "-1"] {
            let raw = argv(&["--jobs", raw_value]);
            let mut args = Args::new(&raw);
            args.next();
            let message = match args.number::<usize>("--jobs") {
                Ok(value) => panic!("--jobs {raw_value} was accepted as {value}"),
                Err(failure) => refusal(&failure),
            };
            assert_eq!(message, format!("--jobs wants a number, not {raw_value}"));
        }
    }

    /// `number` is `value` plus a parse, so the missing-value refusal has to
    /// survive the composition rather than becoming a parse failure of "".
    #[test]
    fn number_with_nothing_after_it_refuses_the_way_value_does() {
        let raw = argv(&["--jobs"]);
        let mut args = Args::new(&raw);
        args.next();
        let message = match args.number::<usize>("--jobs") {
            Ok(value) => panic!("--jobs at the end of the line yielded {value}"),
            Err(failure) => refusal(&failure),
        };
        assert_eq!(message, "--jobs needs a value");
    }

    #[test]
    fn unknown_names_the_argument_it_did_not_expect() {
        let message = match unknown::<()>("--colour") {
            Ok(()) => panic!("an unknown argument was accepted"),
            Err(failure) => refusal(&failure),
        };
        assert_eq!(message, "unknown argument `--colour`");
    }
}
