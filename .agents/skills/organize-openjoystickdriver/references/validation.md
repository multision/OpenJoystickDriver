# Topology Validation

Load this checklist after moving or splitting source and tests. From the repository root, run:

```bash
just lint
swift package dump-package
swift package describe --type json
swift test
```

Then:

1. Run `git diff --check`.
2. Confirm every moved source belongs to the intended target and has a matching behavioral-test owner.
3. Search for stale old paths and duplicate Swift basenames.
4. Confirm resources, entitlements, public interfaces, and dependency direction did not change unintentionally.
5. Confirm no generated controller or DriverKit output, compatibility alias, exclusion, baseline, or suppression was added.

Treat every structural warning or error as a blocker. Report the exact command and relevant output; do not weaken a gate.
