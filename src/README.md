# OPP Directory Reference Server

Minimal Sinatra/SQLite implementation of OPP Directory Specification 0.2.

## Run locally

Requires Ruby 3.2+, a C compiler, Git, and SQLite development headers.

```sh
bundle install
bundle exec rackup --host 0.0.0.0 --port 9292
```

Registrations are stored in `db/opp-directory.sqlite3`. Override the path with `DATABASE_PATH`.

## API

- `PUT /:subject` publishes a signed Directory Registration JSON document.
- `GET /:subject` returns the latest registration exactly as submitted.
- `HEAD /:subject` checks whether the subject exists.

The request `Content-Type` for `PUT` must be `application/json`. Subjects in URLs must be percent-encoded.

## Registration CLI

Run the repository-local `opp-directory` binary from this directory after installing the bundle:

```sh
bundle install
bundle exec bin/opp-directory registration COMMAND
```

Key files contain one encoded OPP key. Surrounding whitespace is ignored. The CLI exits with status `0` on success and status `1` on errors, which are written to stderr.

### Create a Registration

Create and sign a Registration from an existing OPP key pair:

```sh
bundle exec bin/opp-directory registration create \
  --document-url https://example.com/.opp/presence.json \
  --private-key private.key \
  --public-key public.key \
  --sequence 1 \
  --output registration.json
```

The command derives the subject from the public key, adds the current UTC timestamp, signs the Registration, and writes formatted JSON to `registration.json`. An existing output file is replaced.

### Verify a Registration

```sh
bundle exec bin/opp-directory registration verify registration.json
```

Verification checks the Registration schema, subject/public-key relationship, and Ed25519 signature.

### Publish a Registration

Start a Directory server, then publish the exact bytes from a verified Registration file:

```sh
bundle exec bin/opp-directory registration publish registration.json \
  --directory http://localhost:9292
```

The Directory URL may use HTTP or HTTPS. HTTP is intended for local development.

### Fetch a Registration

Fetch by subject and print the exact Registration bytes to stdout:

```sh
bundle exec bin/opp-directory registration fetch key:sha256:... \
  --directory http://localhost:9292
```

Use `--output` to write the response to a file instead:

```sh
bundle exec bin/opp-directory registration fetch key:sha256:... \
  --directory http://localhost:9292 \
  --output registration.json
```

Before printing or writing anything, the command verifies the returned Registration and confirms that its subject matches the requested subject. The response bytes are preserved exactly.

## Test

```sh
bundle exec rake
```

## Docker

```sh
docker build -t opp-directory .
docker run --rm -p 9292:9292 -v opp-directory-data:/data opp-directory
```
