# OPP Directory Registration CLI Design

## Goal

Implement issue #3 by adding a command-line interface for creating, verifying, publishing, and fetching OPP Directory Registrations. The server and CLI will share one registration implementation so schema and cryptographic behavior cannot drift.

The implementation remains a small Ruby application. It uses the standard library for command parsing, HTTP, URLs, and files; no CLI or HTTP gem is added.

## Scope

The CLI exposes these commands:

- `opp-directory registration create`
- `opp-directory registration verify`
- `opp-directory registration publish`
- `opp-directory registration fetch`

Key files are UTF-8 text files containing one OPP encoded key. Leading and trailing whitespace is ignored.

The CLI does not generate keys, publish Presence Documents, discover directories, follow redirects, federate directories, or add authentication beyond Registration signatures.

## Structure

The implementation uses the structure proposed by issue #3:

- `bin/opp-directory`: executable entry point
- `lib/opp_directory/registration.rb`: Registration construction, parsing, schema validation, subject verification, signing, and signature verification
- `lib/opp_directory/cli.rb`: command parsing, files, HTTP, user output, and exit status
- `lib/opp_directory/app.rb`: Sinatra routes and persistence
- `test/registration_test.rb`: shared protocol behavior
- `test/cli_test.rb`: command behavior
- `test/app_test.rb`: existing server request behavior

`OppDirectory` becomes a module. The Sinatra application becomes `OppDirectory::App`. `config.ru`, tests, and Docker packaging will load the new paths.

## Shared Registration Logic

`OppDirectory::Registration` is the only component that knows the Directory Registration schema. It provides operations to:

- parse JSON with `OPP::JSON`, including duplicate-member rejection
- construct the fixed 0.2 Registration fields
- derive the subject from the public key
- sign a Registration with `OPP::Signature`
- validate required fields and field formats
- verify subject ownership and the Ed25519 signature

Construction accepts `document_url`, `private_key`, `public_key`, `sequence`, and an `issued_at` time. It produces a signed hash with:

- `type: open-presence-directory-registration`
- `version: 0.2`
- the derived `subject`
- the supplied public key and document URL
- the supplied non-negative sequence
- `issued_at` formatted as RFC 3339 UTC with a `Z` suffix
- an Ed25519 signature

Validation preserves the existing server rules exactly, including unknown authenticated top-level fields and the restriction that `signature` contain only `algorithm` and `value`. Shared exceptions distinguish malformed/schema-invalid registrations from failed subject or signature verification so the server can preserve its current `400` and `422` responses.

The module performs no HTTP, command parsing, file access, persistence, or user-facing output.

## CLI Commands

The CLI uses Ruby's `OptionParser`. Commands are explicit; unknown commands, missing arguments, and invalid options show a short error and relevant usage text on stderr.

### `registration create`

Required options:

- `--document-url URL`
- `--private-key FILE`
- `--public-key FILE`
- `--sequence INTEGER`
- `--output FILE`

The command reads and trims both key files, constructs and signs a Registration, and writes pretty-printed JSON followed by a newline. The output file is replaced if it already exists. On success it reports the output path and derived subject.

### `registration verify FILE`

The command reads and parses the file, validates the complete Registration schema, verifies subject ownership, and verifies the signature. On success it reports that the Registration is valid and includes its subject.

### `registration publish FILE --directory URL`

The command reads the Registration without changing its bytes, parses and verifies it locally, percent-encodes its subject as one URL path segment, and sends the original bytes with `PUT` and `Content-Type: application/json`.

The directory must be an absolute HTTP or HTTPS URL with a host. HTTP remains supported for local development, matching the issue example. A directory URL may include a base path; the subject is appended beneath that path.

Any `2xx` response is success. Redirects are not followed. Other responses fail with the HTTP status and, when present, a short response body.

### `registration fetch SUBJECT --directory URL [--output FILE]`

The command percent-encodes the supplied subject as one path segment and sends `GET` to the directory. Any `2xx` response is success. Redirects are not followed.

With `--output`, the exact response bytes replace the named file and the CLI reports the path. Without `--output`, the exact response bytes are written to stdout with no surrounding status text so the output remains valid Registration JSON.

## Exit Status and Errors

Successful commands return exit status `0`. All usage, validation, verification, filesystem, URL, network, and non-2xx HTTP failures return exit status `1` and write a concise message to stderr without a backtrace.

Success messages go to stdout except for `fetch` without `--output`, where stdout is reserved for the fetched document. The executable does not expose internal exception details.

## Server Integration

The server retains its current routes, response statuses, exact-byte storage, atomic sequence comparison, and SQLite behavior. `PUT /:subject` parses and validates through `OppDirectory::Registration`, passing the route subject as the expected subject. The route maps shared validation failures to the same HTTP responses used today.

This refactor changes code ownership, not the server protocol.

## Testing

Implementation follows test-driven development: each new behavior is first expressed as a failing test and observed failing for the expected reason.

Registration tests use real OPP key pairs and signatures. They cover construction, parsing, schema rules, subject derivation, valid signatures, invalid signatures, duplicate JSON members, and invalid field values.

CLI tests invoke the CLI with argument arrays and captured standard streams. They use temporary files for keys and documents. HTTP commands communicate with a small local test server so request methods, paths, headers, original bytes, responses, and failure statuses are exercised without external network access.

Existing request tests continue to exercise the Sinatra application. They are updated only as needed for the namespace and file move, and all current assertions must continue to pass.

Completion checks are:

- the complete Minitest suite
- Ruby syntax checks for application, library, executable, and test files
- `git diff --check`
- a Docker build when registry access is available

## Operational Boundaries

The CLI is intentionally synchronous and handles one command per process. It has no configuration file, plugin system, retry policy, redirect policy, custom transport abstraction, or alternate output formats. Those features should be added only if a concrete interoperability or operational need appears.
