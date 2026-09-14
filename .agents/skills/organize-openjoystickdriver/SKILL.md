---
name: organize-openjoystickdriver
description: >-
  Move, split, rename, or review OpenJoystickDriver Swift source and matching
  test ownership. Not for behavior-only fixes or generated output.
---

# Organize Source And Tests

Give each capability one discoverable source owner and one matching behavioral-test owner without changing package boundaries unnecessarily.

## Procedure

1. Read `AGENTS.md`, `Package.swift`, and `docs/development/source-topology.md`.
2. Load [topology](references/topology.md) to identify the current source owner, test owner, target, resources, and dependencies.
3. Compare leaving the code in place, moving it within its current target, and creating a new target. Choose the smallest structure with an independent lifecycle or dependency boundary.
4. Move cohesive source and behavior tests together. Preserve unique Swift basenames, resources, visibility, and dependency direction.
5. Delete old paths. Do not add aliases, forwarding files, tombstones, exclusions, baselines, or suppressions.
6. Update topology documentation and path literals in the same change.
7. Load [topology validation](references/validation.md) and run every applicable command.

## Boundaries

- Do not move generated controller records, schemas, entitlements, or generated DriverKit output.
- Keep existing SwiftPM targets unless an independently justified boundary requires a package change.
- Route behavior-only work to `$maintain-openjoystickdriver` and test-contract work to `$test-openjoystickdriver`.

## Completion

Report the ownership map, rejected alternatives, moved source/test pairs, target and dependency evidence, checks, stale-path result, and rollback boundary.
