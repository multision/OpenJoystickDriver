# Machine-Readable Contracts

`Resources/Schemas/` is the sole registry for OpenJoystickDriver-authored JSON.
Its Draft 2020-12 schemas are resolved locally; runtime code never fetches them.

## Live Contracts

- `controller.schema.json`: generated runtime controller records.
- `controller-override.schema.json`: authored additions and factual patches.
- `report.schema.json`: the CloudEvents 1.0 support-report envelope and payload.

Each artifact class has one current, unversioned contract. OJD-owned property
names use lowerCamelCase, including `vendorID`, `profileID`, `startupPackets`,
`keepAlive`, and `postHandshakeSettleMs`. JSON Schema keywords, CloudEvents
context attributes, external API fields, and dynamic map keys retain their
standards' or sources' spelling. Do not recase values: enums,
protocol identifiers, hashes, URLs, or user text.

Change a schema atomically with every producer, consumer, authored input,
generated output, and test. Do not add versioned schemas, aliases, migrations,
upcasters, fallback readers, crosswalks, or dual writers. Git history preserves
obsolete contracts.

## Boundaries

Controller records contain only facts consumed at runtime. Keep:

1. parser-specific encoding and subsystem quirks in `protocol.quirks`;
2. exact host writes and transport facts in `startupPackets`, `keepAlive`, and
   USB overrides; and
3. packet-mapped controls in parser events.

Do not add provenance, confidence, verification, review state, test plans, or
per-controller schemas. Pin source revisions in `ControllerSources.lock.json`.
Record accepted hardware observations in the stable pages under `docs/testing/`.
Support reports contain observed diagnostic state only.

CloudEvents owns `specversion`, `id`, `source`, `type`, `time`,
`datacontenttype`, and `dataschema`; OJD owns the typed `data` payload. Do not
invent another report shape without a live producer and consumer.

## Validation

```bash
./Scripts/ojd catalog regenerate --check
./Scripts/ojd check profiles
./Scripts/ojd check schemas
git diff --check
```

`check schemas` validates all schemas, every generated controller record, every
override, OJD-owned Swift `CodingKeys`, and one live support report. Generate an
intentional catalog change only through:

```bash
./Scripts/ojd catalog regenerate --write
```
