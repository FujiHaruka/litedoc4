/-! A memory snapshot taken by a child process while this one waits, so the numbers belong to a
known point of the run. Inert unless `HYBRID_SNAPSHOT` names the script. -/

def snap (label : String) : IO Unit := do
  let some script ← IO.getEnv "HYBRID_SNAPSHOT" | return
  let pid ← IO.Process.getPID
  let t0 ← IO.monoMsNow
  let out ← IO.Process.output { cmd := script, args := #[toString pid, label] }
  let t1 ← IO.monoMsNow
  IO.eprintln s!"snapshot {label}: paused {t1 - t0} ms (exit {out.exitCode})"
