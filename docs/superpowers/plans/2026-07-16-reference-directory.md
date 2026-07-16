# OPP Directory Reference Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Rails scaffold with a complete Sinatra/SQLite reference server that publishes and resolves signed OPP Directory Registration 0.2 documents.

**Architecture:** A single `Sinatra::Base` application owns the three HTTP routes, registration validation, and a small SQLite connection. Valid registrations are stored as their original JSON bytes, and a conditional SQLite upsert enforces monotonic sequences atomically. Request-level Minitest coverage uses real `opp` key pairs and signatures.

**Tech Stack:** Ruby 3.2+, Sinatra 4.2, SQLite 3 via `sqlite3`, `opp` pinned from `jodydawkins/opp-ruby`, Rack::Test, Minitest, Docker.

## Global Constraints

- Follow `SPEC.md` version `0.2`; store Directory Registrations, never Presence Documents.
- Accept only `type: open-presence-directory-registration`, `version: 0.2`, Ed25519 signatures, absolute HTTPS document URLs, non-negative integer sequences, and RFC 3339 UTC `issued_at` values ending in `Z`.
- Preserve and return the original request body byte-for-byte.
- Allow unknown fields and authenticate them as part of the signed payload.
- Add no ORM, service/repository layer, alternate backend, authentication, UI, federation, rate limiting, replication, or production scaling machinery.
- Keep all implementation files under `src/`; keep the protocol documents at repository root.

## File Map

- Replace: `src/` — remove the uncommitted Rails application and nested Git metadata.
- Create: `src/Gemfile` — minimal runtime and test dependencies.
- Create: `src/Rakefile` — default Minitest task.
- Create: `src/app.rb` — app, validation, routes, and SQLite persistence.
- Create: `src/config.ru` — Rack entry point.
- Create: `src/test/app_test.rb` — complete request-level suite.
- Create: `src/README.md` — quick start, configuration, and API examples.
- Create: `src/Dockerfile` and `src/.dockerignore` — example container.
- Modify: `README.md` — link the reference server quick start.

---

### Task 1: Minimal Sinatra App and Read Routes

**Files:**
- Replace: `src/`
- Create: `src/Gemfile`
- Create: `src/Rakefile`
- Create: `src/test/app_test.rb`
- Create: `src/app.rb`
- Create: `src/config.ru`

**Interfaces:**
- Produces: `OppDirectory.database -> SQLite3::Database`
- Produces: `GET /:subject` and `HEAD /:subject`
- Produces: SQLite table `registrations(subject TEXT PRIMARY KEY, sequence INTEGER NOT NULL, document TEXT NOT NULL)`

- [ ] **Step 1: Replace the uncommitted Rails scaffold with the minimal test skeleton**

Remove `src/` (including its nested `.git`) and create `src/test/`. Create `src/Gemfile`:

```ruby
source "https://rubygems.org"

gem "opp", github: "jodydawkins/opp-ruby", ref: "b69cf26bf07e8ee3b0b54cb79cd0f453f2101073"
gem "puma", "~> 7.0"
gem "rackup", "~> 2.2"
gem "sinatra", "~> 4.2"
gem "sqlite3", "~> 2.7"

group :test do
  gem "minitest", "~> 5.25"
  gem "rack-test", "~> 2.2"
end
```

Run `bundle install` in `src/` to generate `Gemfile.lock`.

Create `src/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task default: :test
```

- [ ] **Step 2: Write failing read-route tests**

Create `src/test/app_test.rb`:

```ruby
ENV["RACK_ENV"] = "test"
ENV["DATABASE_PATH"] = ":memory:"

require "json"
require "minitest/autorun"
require "rack/test"
require_relative "../app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app = OppDirectory

  def setup
    OppDirectory.database.execute("DELETE FROM registrations")
  end

  def path(subject)
    "/#{Rack::Utils.escape_path(subject)}"
  end

  def test_unknown_subject_is_not_found
    get path("key:sha256:missing")
    assert_equal 404, last_response.status

    head path("key:sha256:missing")
    assert_equal 404, last_response.status
    assert_empty last_response.body
  end

  def test_get_and_head_return_a_stored_registration
    body = %({ "subject": "key:sha256:known" }\n)
    OppDirectory.database.execute(
      "INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)",
      ["key:sha256:known", 1, body]
    )

    get path("key:sha256:known")
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.media_type
    assert_equal body, last_response.body

    head path("key:sha256:known")
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end
end
```

- [ ] **Step 3: Run the test and verify RED**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: FAIL with `LoadError` for `../app`.

- [ ] **Step 4: Implement the smallest database and read routes**

Create `src/app.rb`:

```ruby
require "fileutils"
require "json"
require "sinatra/base"
require "sqlite3"

class OppDirectory < Sinatra::Base
  configure do
    set :database_path, ENV.fetch("DATABASE_PATH", "db/opp-directory.sqlite3")
    set :show_exceptions, false
  end

  def self.database
    @database ||= begin
      path = settings.database_path
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      SQLite3::Database.new(path).tap do |database|
        database.execute <<~SQL
          CREATE TABLE IF NOT EXISTS registrations (
            subject TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL,
            document TEXT NOT NULL
          )
        SQL
      end
    end
  end

  helpers do
    def registration(subject)
      self.class.database.get_first_value(
        "SELECT document FROM registrations WHERE subject = ?", subject
      )
    end
  end

  get "/:subject" do
    document = registration(params[:subject]) or halt 404
    content_type :json
    document
  end

  head "/:subject" do
    halt 404 unless registration(params[:subject])
    200
  end
end
```

Create `src/config.ru`:

```ruby
require_relative "app"

run OppDirectory
```

- [ ] **Step 5: Run tests and commit**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: `2 runs, 10 assertions, 0 failures, 0 errors`.

Run: `git add src && git commit -m "Add minimal directory read API"`

---

### Task 2: Signed Registration Publication

**Files:**
- Modify: `src/test/app_test.rb`
- Modify: `src/app.rb`

**Interfaces:**
- Consumes: `OppDirectory.database`
- Produces: `PUT /:subject` for the first valid signed registration
- Produces: test helpers `pair`, `unsigned_registration`, `signed_registration`, and `put_registration`

- [ ] **Step 1: Add a failing valid-publication test and signing helpers**

Add `require "opp"` and `require "time"` to `src/test/app_test.rb`, then add inside `AppTest`:

```ruby
  def pair
    @pair ||= OPP::KeyPair.generate
  end

  def unsigned_registration(sequence: 1, **overrides)
    {
      "type" => "open-presence-directory-registration",
      "version" => "0.2",
      "subject" => OPP::Subject.derive(pair.public_key),
      "public_key" => pair.public_key,
      "document_url" => "https://example.com/opp.json",
      "sequence" => sequence,
      "issued_at" => "2026-07-16T12:00:00Z"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def signed_registration(sequence: 1, **overrides)
    OPP::Signature.sign(
      unsigned_registration(sequence:, **overrides),
      private_key: pair.private_key
    )
  end

  def put_registration(document, subject: document["subject"], content_type: "application/json")
    body = JSON.generate(document)
    put path(subject), body, "CONTENT_TYPE" => content_type
    body
  end

  def test_publishes_and_returns_exact_signed_registration
    document = signed_registration
    body = JSON.pretty_generate(document) + "\n"

    put path(document["subject"]), body, "CONTENT_TYPE" => "application/json"
    assert_equal 201, last_response.status

    get path(document["subject"])
    assert_equal body, last_response.body
  end
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb -n test_publishes_and_returns_exact_signed_registration`

Expected: FAIL because `PUT` returns `404`.

- [ ] **Step 3: Implement minimal valid publication**

Add these requires to `src/app.rb`:

```ruby
require "opp"
require "time"
require "uri"
```

Add inside `helpers`:

```ruby
    def parse_registration
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      halt_json 400, "invalid JSON"
    end

    def halt_json(status, message)
      halt status, { "Content-Type" => "application/json" }, JSON.generate(error: message)
    end
```

Add the route before the read routes:

```ruby
  put "/:subject" do
    halt_json 415, "content type must be application/json" unless request.media_type == "application/json"

    body = request.body.rewind && request.body.read
    document = JSON.parse(body)
    halt_json 400, "registration must be an object" unless document.is_a?(Hash)
    halt_json 400, "subject does not match path" unless document["subject"] == params[:subject]

    OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
    OPP::Signature.verify!(document, public_key: document["public_key"])

    self.class.database.execute(
      "INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)",
      [document["subject"], document["sequence"], body]
    )
    status 201
  rescue JSON::ParserError
    halt_json 400, "invalid JSON"
  rescue OPP::Error
    halt_json 422, "subject or signature verification failed"
  end
```

- [ ] **Step 4: Run tests and commit**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: `3 runs, 13 assertions, 0 failures, 0 errors`.

Run: `git add src/app.rb src/test/app_test.rb && git commit -m "Accept signed directory registrations"`

---

### Task 3: Complete Validation and Replay Protection

**Files:**
- Modify: `src/test/app_test.rb`
- Modify: `src/app.rb`

**Interfaces:**
- Produces: `OppDirectory::RegistrationError` with HTTP status and public message
- Produces: `validate_registration!(document, path_subject)`
- Produces: conditional upsert returning `201`, `200`, or `409`

- [ ] **Step 1: Add failing update, replay, extension, and request-error tests**

Add these tests to `src/test/app_test.rb`:

```ruby
  def test_higher_sequence_updates_the_exact_stored_document
    first = signed_registration(sequence: 1)
    put_registration(first)
    second = signed_registration(sequence: 2, document_url: "https://example.com/new.json")
    body = JSON.pretty_generate(second) + "\n"

    put path(second["subject"]), body, "CONTENT_TYPE" => "application/json"
    assert_equal 200, last_response.status
    get path(second["subject"])
    assert_equal body, last_response.body
  end

  def test_equal_and_lower_sequences_are_rejected_without_replacing_document
    current = signed_registration(sequence: 2)
    original = put_registration(current)

    [2, 1].each do |sequence|
      put_registration(signed_registration(sequence:))
      assert_equal 409, last_response.status
    end

    get path(current["subject"])
    assert_equal original, last_response.body
  end

  def test_unknown_fields_are_preserved_and_authenticated
    document = signed_registration(extension: { "enabled" => true })
    body = put_registration(document)
    assert_equal 201, last_response.status
    get path(document["subject"])
    assert_equal body, last_response.body

    document["extension"]["enabled"] = false
    put_registration(document)
    assert_equal 422, last_response.status
  end

  def test_rejects_wrong_content_type_malformed_json_and_non_object_json
    put path("key:sha256:any"), "{}", "CONTENT_TYPE" => "text/plain"
    assert_equal 415, last_response.status

    put path("key:sha256:any"), "{", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status

    put path("key:sha256:any"), "[]", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
  end

  def test_rejects_path_subject_public_key_and_signature_mismatches
    document = signed_registration
    put_registration(document, subject: "key:sha256:different")
    assert_equal 400, last_response.status

    other_pair = OPP::KeyPair.generate
    mismatched = signed_registration(public_key: other_pair.public_key)
    put_registration(mismatched)
    assert_equal 422, last_response.status

    document["signature"]["value"] = "A" * 86
    put_registration(document)
    assert_equal 422, last_response.status
  end
```

Add the table-driven schema test:

```ruby
  def test_rejects_invalid_registration_fields
    invalid_documents = [
      unsigned_registration.tap { |value| value.delete("type") },
      unsigned_registration(type: "wrong"),
      unsigned_registration(version: "0.1"),
      unsigned_registration(document_url: "http://example.com/opp.json"),
      unsigned_registration(document_url: "not a url"),
      unsigned_registration(sequence: -1),
      unsigned_registration(sequence: 1.5),
      unsigned_registration(issued_at: "2026-07-16T12:00:00+00:00")
    ]

    invalid_documents.each do |unsigned|
      document = OPP::Signature.sign(unsigned, private_key: pair.private_key)
      put_registration(document)
      assert_equal 400, last_response.status, unsigned.inspect
    end

    document = signed_registration
    document["signature"]["algorithm"] = "rsa"
    put_registration(document)
    assert_equal 400, last_response.status
  end
```

- [ ] **Step 2: Run new tests and verify RED**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: failures for updates (`SQLite3::ConstraintException`), stale sequences, schema validation, and mutated extensions.

- [ ] **Step 3: Add explicit registration errors and complete validation**

Add inside `OppDirectory` before `configure`:

```ruby
  class RegistrationError < StandardError
    attr_reader :status

    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
  UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/
```

Add inside `helpers`:

```ruby
    def reject!(status, message)
      raise RegistrationError.new(status, message)
    end

    def validate_registration!(document, path_subject)
      reject! 400, "registration must be an object" unless document.is_a?(Hash)
      missing = REQUIRED_FIELDS.reject { |field| document.key?(field) }
      reject! 400, "missing field: #{missing.first}" unless missing.empty?
      reject! 400, "unsupported type" unless document["type"] == "open-presence-directory-registration"
      reject! 400, "unsupported version" unless document["version"] == "0.2"
      reject! 400, "subject must be a string" unless document["subject"].is_a?(String)
      reject! 400, "public_key must be a string" unless document["public_key"].is_a?(String)
      reject! 400, "subject does not match path" unless document["subject"] == path_subject

      begin
        url = URI.parse(document["document_url"].to_s)
      rescue URI::InvalidURIError
        url = nil
      end
      reject! 400, "document_url must be an absolute HTTPS URL" unless url.is_a?(URI::HTTPS) && url.host && url.absolute?
      reject! 400, "sequence must be a non-negative integer" unless document["sequence"].is_a?(Integer) && document["sequence"] >= 0
      reject! 400, "issued_at must be an RFC 3339 UTC timestamp" unless document["issued_at"].is_a?(String) && UTC_TIMESTAMP.match?(document["issued_at"])
      begin
        Time.iso8601(document["issued_at"])
      rescue ArgumentError
        reject! 400, "issued_at must be an RFC 3339 UTC timestamp"
      end

      signature = document["signature"]
      reject! 400, "signature must use ed25519" unless signature.is_a?(Hash) && signature["algorithm"] == "ed25519" && signature["value"].is_a?(String)

      begin
        OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
        OPP::Signature.verify!(document, public_key: document["public_key"])
      rescue OPP::Error
        reject! 422, "subject or signature verification failed"
      end
    end
```

- [ ] **Step 4: Replace the PUT route with validation and a conditional upsert**

Replace the Task 2 `put` route with:

```ruby
  put "/:subject" do
    reject! 415, "content type must be application/json" unless request.media_type == "application/json"
    body = request.body.read
    document = JSON.parse(body)
    validate_registration!(document, params[:subject])

    created = nil
    self.class.database.transaction(:immediate) do |database|
      created = database.get_first_value(
        "SELECT 1 FROM registrations WHERE subject = ?", document["subject"]
      ).nil?
      database.execute <<~SQL, [document["subject"], document["sequence"], body]
        INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)
        ON CONFLICT(subject) DO UPDATE SET
          sequence = excluded.sequence,
          document = excluded.document
        WHERE excluded.sequence > registrations.sequence
      SQL
      reject! 409, "sequence must be greater than the current sequence" if database.changes.zero?
    end

    status(created ? 201 : 200)
  rescue JSON::ParserError
    halt_json 400, "invalid JSON"
  rescue RegistrationError => error
    halt_json error.status, error.message
  end
```

Remove the now-unused `parse_registration` helper and the Task 2 `rescue OPP::Error` clause.

- [ ] **Step 5: Run complete tests, syntax checks, and commit**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: all tests pass with `0 failures, 0 errors`.

Run: `cd src && bundle exec ruby -cw app.rb && bundle exec ruby -cw test/app_test.rb`

Expected: `Syntax OK` for both files with no warnings.

Run: `git add src/app.rb src/test/app_test.rb && git commit -m "Validate registrations and reject replays"`

---

### Task 4: Quick Start and Container Example

**Files:**
- Create: `src/README.md`
- Create: `src/Dockerfile`
- Create: `src/.dockerignore`
- Modify: `README.md`

**Interfaces:**
- Documents: `DATABASE_PATH`, port `9292`, three HTTP routes, test command
- Produces: container listening on `0.0.0.0:9292` with `/data` SQLite persistence

- [ ] **Step 1: Write the operational documentation**

Replace `src/README.md` with concise sections containing these exact commands and facts:

````markdown
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
````

Append this section to root `README.md`:

```markdown
## Reference Implementation

The Sinatra/SQLite reference server lives in [`src/`](src/). See [`src/README.md`](src/README.md) for quick-start, API, test, and Docker instructions.
```

- [ ] **Step 2: Add the example container**

Create `src/Dockerfile`:

```dockerfile
FROM ruby:3.4-alpine

RUN apk add --no-cache build-base git sqlite-dev
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set without test && bundle install
COPY app.rb config.ru ./

ENV DATABASE_PATH=/data/opp-directory.sqlite3
VOLUME /data
EXPOSE 9292

CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "9292"]
```

Create `src/.dockerignore`:

```text
.bundle
db/*.sqlite3*
test
```

- [ ] **Step 3: Verify all acceptance criteria**

Run: `cd src && bundle exec rake`

Expected: all request tests pass with `0 failures, 0 errors`.

Run: `cd src && bundle exec ruby -cw app.rb && bundle exec ruby -cw test/app_test.rb`

Expected: `Syntax OK` twice with no warnings.

Run: `cd src && docker build -t opp-directory .`

Expected: image builds successfully. If registry access is unavailable, record that limitation and do not claim the container build passed.

Run: `git diff --check`

Expected: no output and exit status `0`.

- [ ] **Step 4: Commit documentation and container files**

Run: `git add README.md src/README.md src/Dockerfile src/.dockerignore src/Gemfile.lock && git commit -m "Document and package the reference server"`

---

### Task 5: Final End-to-End Verification

**Files:**
- Verify only; modify files solely to correct failures found by the checks.

**Interfaces:**
- Confirms every issue #1 acceptance criterion and every approved design requirement.

- [ ] **Step 1: Run fresh verification**

Run:

```sh
cd src
bundle exec rake
bundle exec ruby -cw app.rb
bundle exec ruby -cw test/app_test.rb
cd ..
git diff --check
git status --short
```

Expected: all tests pass, both syntax checks print `Syntax OK`, `git diff --check` is silent, and status contains no unintended files.

- [ ] **Step 2: Re-read requirements against the implementation**

Confirm explicitly:

- valid first and higher-sequence registrations publish successfully;
- exact submitted bytes are retrieved;
- `HEAD` reports existence without a body;
- unknown subjects return `404`;
- invalid JSON/media type/schema/subject/signature return the designed status;
- equal and lower sequences return `409` without replacement;
- configuration, Dockerfile, and quick-start instructions exist;
- no Rails, PostgreSQL, UI, auth, federation, replication, or scaling code remains.

- [ ] **Step 3: Commit only if verification required a correction**

If a correction was necessary, rerun Step 1, then run:

```sh
git add README.md src
git commit -m "Fix reference server verification findings"
```

If no correction was necessary, create no empty commit.
