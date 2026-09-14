# AGENTS.md

macOS userspace gamepad driver. Ground claims in source, tests, schemas, or recorded hardware evidence.

Read `CONTRIBUTING.md`, `docs/README.md`, `LOCALIZATION.md`, `docs/AGENTS.md`, `Resources/Schemas/AGENTS.md`.

Do not edit generated records under `Sources/OpenJoystickDriverKit/Resources/Controllers/` or `.build/driverkit/generated/`. Catalog write: `./Scripts/ojd catalog regenerate --write`. DriverKit: `./Scripts/ojd driverkit generate`. No SVGs or secrets. Confirm destructive writes and publication.

```bash
./Scripts/ojd catalog regenerate --check
./Scripts/ojd check profiles
./Scripts/ojd check schemas
ruff format --check Scripts Tests/RepositoryScripts
ruff check Scripts Tests/RepositoryScripts
pyright
find Scripts -type f \( -name '*.sh' -o -name ojd \) -print0 | xargs -0 shellcheck --external-sources --source-path=SCRIPTDIR
swift-format lint --recursive --strict Package.swift Sources Tests
swiftlint lint --no-cache --strict
./Scripts/ojd check driverkit
swift test
```

Parser/protocol: `./Scripts/ojd test parsers-macos14`. Cache: `./Scripts/ojd repair swiftpm-module-cache`.
