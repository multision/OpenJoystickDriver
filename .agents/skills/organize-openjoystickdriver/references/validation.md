# Topology validation

From the repository root, inspect the SwiftPM model and run standard tools
directly:

```sh
just lint
swift package describe --type json
```

For a topology change, run the full `$architecture-enforce` audit with no
exclusions, thresholds, baselines, or suppressions, then run focused product
tests and the applicable gates from `$test-openjoystickdriver`.

Before handoff, inspect `git diff --check`, target membership, duplicate Swift
basenames, stale old paths, generated output, and the ownership map. Every
architecture warning or error is blocking; report pre-existing blockers with
the exact command and evidence instead of weakening the audit.
