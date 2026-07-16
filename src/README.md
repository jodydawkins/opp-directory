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

## Test

```sh
bundle exec rake
```

## Docker

```sh
docker build -t opp-directory .
docker run --rm -p 9292:9292 -v opp-directory-data:/data opp-directory
```
