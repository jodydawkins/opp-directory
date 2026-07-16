# Open Presence Protocol Directory (OPP Directory)

The Open Presence Protocol Directory is the reference implementation and specification for resolving Open Presence Protocol (OPP) identities.

An OPP Directory allows applications to discover the current location of an identity's signed OPP Presence Document.

It serves a role similar to DNS on the Internet: given an identity, it tells clients where to find the authoritative record.

## Relationship to OPP

The Open Presence Protocol ecosystem is composed of independent components with distinct responsibilities.

| Component | Responsibility |
|-----------|----------------|
| OPP | Defines identities, presence documents, signing, and verification |
| OPP Directory | Resolves identities into Presence Documents |

The Directory specification intentionally does not redefine identity or cryptography. Those are defined by the core OPP specification.

## Philosophy

OPP Directory follows a simple principle:

> Directories provide discovery. Presence Documents provide truth.

A directory helps clients locate an identity's current Presence Document.

The Presence Document itself remains the authoritative statement of that identity's online presence.

This separation keeps the protocol decentralized and allows individuals to retain control of their own presence information.

## Goals

The project has four primary goals:

- Provide an open, vendor-neutral directory for OPP identities.
- Allow identity owners to update the location of their Presence Documents.
- Allow applications to resolve identities into Presence Documents.
- Remain simple enough that anyone can operate an OPP Directory.

## Repository Contents

| File | Purpose |
|------|---------|
| `SPEC.md` | OPP Directory protocol specification |
| `README.md` | Project overview |
| `src/` | Reference server implementation |

## Current Status

This project is in active development.

The protocol specification is being developed alongside the reference implementation.

Early versions should be considered experimental and may change as the protocol evolves.

## Reference Implementation

The Sinatra/SQLite reference server lives in [`src/`](src/). See [`src/README.md`](src/README.md) for quick-start, API, test, and Docker instructions.

## License

See [LICENSE](LICENSE)
