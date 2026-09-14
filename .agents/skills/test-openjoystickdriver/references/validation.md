# Product Validation

Load this reference after defining the observable test contract. Tests call Swift product APIs and observe typed behavior; they never inspect source, scripts, documentation, generated output, or human-readable help text.

## First Proof

| Change | Run first |
| --- | --- |
| Parser, protocol, or HID | Matching `OpenJoystickDriverKitTests` filter, then `./Scripts/ojd test parsers-macos14` |
| Controller record or catalog | Matching Kit test, catalog check, then profile check |
| App CLI, remapping, runtime, or status | Matching `OpenJoystickDriverTests` filter |
| Relay or generator | Matching test, then `./Scripts/ojd check driverkit` |
| Hardware, permission, or installation | Documented diagnostic or manual procedure |

Example filters:

```bash
swift test --filter OpenJoystickDriverKitTests.Protocol.Parsers
swift test --filter OpenJoystickDriverTests.CLI
```

Adjust filters to names that exist in the repository.

## Gates

After focused proof, run applicable commands in this order:

```bash
./Scripts/ojd catalog regenerate --check
./Scripts/ojd check profiles
./Scripts/ojd check schemas
just lint
python3 -m unittest discover -s Tests/RepositoryScripts
./Scripts/ojd check driverkit
swift test
```

Explain omitted gates. For the documented SwiftPM module-cache mismatch only:

```bash
./Scripts/ojd repair swiftpm-module-cache
swift test
```

Before handoff, run `git diff --check`, inspect target membership, and confirm no stale path, generated output, or `Tests/Scripts` fixture was added.

## Blockers

Report the command, working directory, exit status, relevant non-secret output, attribution, attempted recovery, evidence that passed, and remaining risk. Hardware, signing, and permission checks may be unavailable; never replace them with source inspection.
