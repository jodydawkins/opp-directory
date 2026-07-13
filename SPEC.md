# Open Presence Protocol Directory Specification (OPP Directory)

**Version:** 0.2 (Draft)

## Status

This document defines the behavior of an Open Presence Protocol (OPP) Directory.

An OPP Directory provides an open mechanism for discovering the current location of an OPP Presence Document. Multiple OPP Directories may be operated independently.

This specification complements the core Open Presence Protocol (OPP) specification and does not redefine subjects, presence documents, signing, or verification.

---

# Conventions

The key words **"MUST," "MUST NOT," "SHOULD," "SHOULD NOT,"** and **"MAY"** in this document are to be interpreted as described in BCP 14 (RFC 2119 and RFC 8174) when, and only when, they appear in all capitals.

---

# 1. Introduction

The Open Presence Protocol allows a cryptographic subject to publish a signed Presence Document describing where that subject may be found online.

While the core OPP specification defines the structure and verification of that document, it intentionally does not define how clients discover it.

This specification defines that discovery mechanism.

An OPP Directory stores Registrations that associate an OPP Subject with the current location of its signed Presence Document.

Applications query an OPP Directory to resolve a Subject into a Presence Document.

---

# 2. Goals

An OPP Directory MUST:

- Allow a subject to register the location of its Presence Document.
- Allow clients to resolve a subject into the current Presence Document location.
- Verify that only the owner of a subject may update its Registration.
- Operate independently of any particular platform.
- Be simple to implement.

---

# 3. Non-Goals

An OPP Directory is NOT:

- A social network.
- A content hosting service.
- A messaging platform.
- A search engine.
- A user profile database.

Directories resolve Subjects.

They do not host or index user-generated content.

---

# 4. Terminology

## Subject

The stable identifier derived from the public key controlling an OPP Presence Document, as defined by the core OPP specification.

## Presence Document

A signed document published by a subject describing where that subject may be found.

## Registration

A signed declaration associating a Subject with the current location of its Presence Document.

## Resolution

The process of discovering the current Registration for a Subject.

---

# 5. Registration

Each Registration MUST contain the following members:

- `type`
- `version`
- `subject`
- `public_key`
- `document_url`
- `sequence`
- `issued_at`
- `signature`

Example:

```json
{
  "type": "open-presence-directory-registration",
  "version": "0.2",
  "subject": "key:sha256:abc123...",
  "public_key": "base64url-public-key",
  "document_url": "https://example.com/opp.json",
  "sequence": 1,
  "issued_at": "2026-07-13T05:00:00Z",
  "signature": {
    "algorithm": "ed25519",
    "value": "base64url-signature"
  }
}
```

The `document_url` MUST be an absolute HTTPS URL.

The `sequence` member MUST be a non-negative integer.

The `issued_at` member MUST be an RFC 3339 UTC timestamp using the `Z` suffix.

The signature authenticates every member of the Registration except the top-level `signature` member.

Registrations MUST be serialized, signed, and encoded using the procedure defined in Section 7 of the core OPP specification.

A Registration MUST only be accepted if:

- the `subject` matches the supplied `public_key`
- the `signature` is valid
- the Registration conforms to this specification
- the `sequence` value is greater than the `sequence` value of the currently stored Registration for the same Subject

A Registration whose `sequence` value is less than or equal to the currently stored Registration for the same Subject MUST be rejected.

---

# 6. Resolution

Given a Subject, an OPP Directory MUST return the most recent valid Registration.

Clients MUST retrieve the Presence Document using the returned `document_url`.

Clients MUST verify the retrieved Presence Document according to the core OPP specification.

Directories provide discovery.

Presence Documents remain the authoritative source of presence information.

---

# 7. Hosting

An OPP Directory MAY store Registration records.

An OPP Directory SHOULD NOT store Presence Documents.

Presence Documents remain under the control of the subject.

---

# 8. Security Considerations

Directories MUST verify Registration signatures before accepting updates.

Directories MUST reject replay attacks by enforcing monotonically increasing sequence numbers for each Subject.

Directories SHOULD require HTTPS for all registration and resolution endpoints.

Directories SHOULD implement rate limiting.

Directories SHOULD validate submitted `document_url` values.

Directories SHOULD reject malformed or unsupported Registration versions.

---

# 9. API

This specification intentionally does not define an HTTP API.

HTTP is expected to be the first reference implementation.

Future specifications MAY define standard APIs for registration and resolution.

---

# 10. Future Work

Future versions of this specification may define:

- federation between directories
- synchronization protocols
- discovery of directory servers
- caching behavior
- replication
- high availability
- alternate transport protocols

These topics are intentionally outside the scope of this version.

---

# Design Philosophy

The Open Presence Protocol ecosystem follows a simple design philosophy:

- Subjects prove ownership.
- Presence Documents describe presence.
- Directories provide discovery.

Each component has a single responsibility.

Together they create an open, decentralized ecosystem for discovering online presence without requiring a central authority.