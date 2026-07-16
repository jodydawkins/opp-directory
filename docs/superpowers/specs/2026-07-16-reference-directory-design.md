# OPP Directory Reference Server Design

## Goal

Implement issue #1 as a deliberately small reference server for OPP Directory Specification 0.2. The server resolves OPP subjects to their latest signed Directory Registration. It prioritizes protocol correctness, interoperability, and readability over production scalability.

## Scope

The implementation replaces the uncommitted Rails scaffold in `src/` with a Ruby 3.2+ Sinatra application backed by SQLite. It uses the `opp` gem's generic signing API for canonical Ed25519 verification and subject derivation.

The server stores registrations, not Presence Documents. It does not fetch `document_url`, authenticate users separately, provide a web UI, federate, rate-limit, replicate, or add alternate storage backends.

## HTTP API

All registration routes use the subject as the single path segment.

### `GET /:subject`

Return the exact bytes of the current stored registration with `Content-Type: application/json`. Return `404 Not Found` when no registration exists.

### `HEAD /:subject`

Return `200 OK` when a registration exists and `404 Not Found` otherwise. Never include a response body.

### `PUT /:subject`

Require `Content-Type: application/json`, read the request body, and validate it as a Directory Registration. Return:

- `201 Created` when the subject is registered for the first time.
- `200 OK` when a registration with a higher sequence replaces the current registration.
- `400 Bad Request` for malformed JSON, a non-object body, a path/body subject mismatch, or an invalid registration field.
- `409 Conflict` when the submitted sequence is not greater than the stored sequence.
- `415 Unsupported Media Type` when the request is not JSON.
- `422 Unprocessable Content` when subject derivation or signature verification fails.

Error responses are small JSON objects containing an `error` string. They do not expose exception details.

## Registration Validation

A submitted registration must be a JSON object containing:

- `type`, exactly `open-presence-directory-registration`
- `version`, exactly `0.2`
- `subject`, a string equal to both the route subject and the subject derived from `public_key`
- `public_key`, a valid OPP public key string
- `document_url`, an absolute HTTPS URL with a host
- `sequence`, a non-negative JSON integer
- `issued_at`, an RFC 3339 UTC timestamp ending in `Z`
- `signature.algorithm`, exactly `ed25519`
- `signature.value`, a string accepted by the OPP verifier

Unknown fields are allowed because the specification does not prohibit them and the OPP generic signing API authenticates them. Validation never removes, rewrites, or normalizes fields.

After schema validation, the server derives the subject using `OPP::Subject.derive` and verifies the complete registration using `OPP::Signature.verify!` with the submitted public key.

## Persistence and Data Flow

SQLite contains one `registrations` table:

- `subject TEXT PRIMARY KEY`
- `sequence INTEGER NOT NULL`
- `document TEXT NOT NULL`

The application stores the original HTTP request body in `document`. Retrieval returns that same string without reserializing it.

Publishing uses a single SQLite upsert whose conflict update is conditional on the incoming sequence being greater than the stored sequence. This makes replay protection atomic. If the conditional upsert changes no row, the application returns `409 Conflict`.

The database path comes from `DATABASE_PATH` and defaults to `db/opp-directory.sqlite3`. The application creates the database directory and table on startup.

## Structure

The implementation stays compact:

- `app.rb`: Sinatra routes, validation, and persistence
- `config.ru`: Rack entry point
- `Gemfile` and lockfile: Sinatra, SQLite, OPP, and test dependencies
- `test/app_test.rb`: request-level protocol tests
- `Dockerfile` and `.dockerignore`: container example
- `README.md`: setup, configuration, API examples, and test commands

No ORM, repository abstraction, dependency injection container, background jobs, or framework-specific generator output is included.

## Testing

Minitest and Rack::Test exercise the service through HTTP. Tests generate real Ed25519 key pairs and signatures with the `opp` gem rather than mocking verification.

Coverage includes:

- first publication and exact-byte retrieval
- valid higher-sequence update
- `HEAD` for known and unknown subjects
- unknown `GET`
- malformed JSON and non-object JSON
- wrong content type
- missing or invalid required fields
- path/body subject mismatch
- subject/public-key mismatch
- invalid signature
- insecure or malformed `document_url`
- invalid `issued_at`
- negative or non-integer sequence
- replayed and lower sequence rejection
- preservation and authentication of unknown fields

The full test suite, style check, and container build are the completion checks. The container build may be skipped only when the environment cannot access the image registry, and that limitation must be reported.

## Operational Boundaries

SQLite and a single-process deployment are sufficient for the reference implementation. Production concerns listed as non-goals in issue #1 remain intentionally absent. If deployment requirements later demand multiple application instances, the storage and concurrency design must be revisited rather than hidden behind speculative abstractions now.
