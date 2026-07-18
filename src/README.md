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

Key files contain one encoded OPP key. Surrounding whitespace is ignored.

```sh
bundle exec bin/opp-directory registration create \
  --document-url https://example.com/.opp/presence.json \
  --private-key private.key \
  --public-key public.key \
  --sequence 1 \
  --output registration.json

bundle exec bin/opp-directory registration verify registration.json

bundle exec bin/opp-directory registration publish registration.json \
  --directory http://localhost:9292

bundle exec bin/opp-directory registration fetch key:sha256:... \
  --directory http://localhost:9292 \
  --output registration.json
```

## Test

```sh
bundle exec rake
```

## Docker

```sh
docker build -t opp-directory .
docker run --rm -p 9292:9292 -v opp-directory-data:/data opp-directory
```
