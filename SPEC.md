# Open Presence Protocol Directory Specification (OPP Directory)

Version: 0.1 (Draft)

## Status

This document defines the behavior of an Open Presence Protocol (OPP) Directory.

An OPP Directory provides a decentralized mechanism for discovering the current location of an OPP Presence Document.

This specification is intended to complement the core Open Presence Protocol specification and does not redefine identity, signing, or presence documents.

---

# Conventions

The key words “MUST,” “MUST NOT,” “SHOULD,” “SHOULD NOT,” and “MAY” in this document are to be interpreted as described in BCP 14, RFC 2119, and RFC 8174 when, and only when, they appear in all capitals.

---

# 1. Introduction

The Open Presence Protocol allows an identity to publish a signed Presence Document describing where that identity is present online.

While the core OPP specification defines the structure and verification of that document, it intentionally does not define how clients discover it.

This specification defines that discovery mechanism.

An OPP Directory stores registrations that associate an OPP identity with the current location of its signed Presence Document.

Applications query an OPP Directory to resolve an identity into a Presence Document.

---

# 2. Goals

An OPP Directory SHALL:

- Allow an identity to register the location of its Presence Document.
- Allow clients to resolve an identity into the current Presence Document location.
- Verify that only the identity owner may update a registration.
- Operate independently of any particular social platform.
- Be simple to implement.

---

# 3. Non-Goals

An OPP Directory is NOT:

- A social network.
- A content hosting service.
- A messaging platform.
- A search engine.
- A user profile database.

Directories resolve identities.

They do not host or index user-generated content.

---

# 4. Terminology

## Identity

A cryptographic identity defined by the core OPP specification.

## Presence Document

A signed document published by an identity owner describing where that identity may be found.

## Registration

A signed declaration associating an Identity with the current location of its Presence Document.

## Resolution

The process of discovering the current Registration for an Identity.

---

# 5. Registration

Each Registration SHALL contain:

- identity
- document_url
- sequence
- issued_at
- signature

The signature MUST cover the complete registration payload.

A Registration SHALL only be accepted if:

- the signature is valid
- the sequence number is greater than the currently stored registration
- the registration conforms to this specification

Older registrations MUST NOT replace newer registrations.

---

# 6. Resolution

Given an Identity, an OPP Directory SHALL return the most recent valid Registration.

Clients SHALL retrieve the Presence Document using the returned document_url.

Clients SHALL verify the Presence Document according to the core OPP specification.

Directories are discovery mechanisms.

Presence Documents remain the authoritative source of presence information.

---

# 7. Hosting

An OPP Directory MAY store Registration records.

An OPP Directory SHOULD NOT store Presence Documents.

Presence Documents remain under the control of the identity owner.

---

# 8. Security Considerations

Directories MUST verify signatures before accepting registrations.

Directories MUST reject replay attacks by refusing registrations whose sequence number is less than or equal to the currently stored value.

Directories SHOULD require HTTPS for all registration and resolution endpoints.

Directories SHOULD implement rate limiting.

Directories SHOULD validate submitted document URLs.

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

The Open Presence Protocol follows a simple design philosophy:

Identity proves ownership.

Presence Documents describe presence.

Directories provide discovery.

Each component has a single responsibility.

Together they create an open, decentralized system for discovering online presence without requiring a central authority.