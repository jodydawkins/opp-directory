# OPP Directory Registration CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dependency-free CLI that creates, verifies, publishes, and fetches OPP Directory Registrations while making the server and CLI share one protocol implementation.

**Architecture:** Move Registration parsing and validation into `OppDirectory::Registration`, then move the Sinatra server under `OppDirectory::App` and delegate to that module. Add `OppDirectory::CLI`, backed only by Ruby standard-library command, file, URL, and HTTP APIs, plus a thin executable.

**Tech Stack:** Ruby 3.2+, OPP Ruby gem, Sinatra 4, SQLite 3, Minitest, Rack::Test, `OptionParser`, `Net::HTTP`

## Global Constraints

- Add no CLI or HTTP dependency.
- Key files are UTF-8 text containing one encoded key; trim surrounding whitespace.
- Keep the server's routes, statuses, exact-byte storage, and atomic sequence behavior unchanged.
- Preserve unknown authenticated top-level Registration fields; allow only `algorithm` and `value` in `signature`.
- Support absolute HTTP and HTTPS directory URLs; do not follow redirects.
- Return CLI status `0` on success and `1` for every user-facing failure, without a backtrace.
- Keep fetched and published Registration bytes exact.
- Write a failing test and observe its expected failure before every production behavior change.

---

## File Map

- Create `src/lib/opp_directory/registration.rb`: all Registration construction, parsing, validation, signing, and verification.
- Create `src/lib/opp_directory/app.rb`: namespaced Sinatra application and SQLite persistence.
- Create `src/lib/opp_directory/cli.rb`: command parsing, filesystem access, HTTP, output, and exit status.
- Create `src/bin/opp-directory`: executable entry point.
- Create `src/test/registration_test.rb`: protocol-unit tests using real keys and signatures.
- Create `src/test/cli_test.rb`: command tests, including a local TCP HTTP peer.
- Modify `src/test/app_test.rb`: require and exercise `OppDirectory::App` while retaining all existing assertions.
- Modify `src/config.ru`: load the namespaced app.
- Modify `src/Dockerfile`: copy `lib/` and the executable into the image.
- Modify `src/README.md`: document the four CLI commands and key-file format.
- Delete `src/app.rb` only after the namespaced replacement passes all server tests.

---

### Task 1: Shared Registration protocol module

**Files:**
- Create: `src/lib/opp_directory/registration.rb`
- Create: `src/test/registration_test.rb`

**Interfaces:**
- Consumes: `OPP::JSON.parse`, `OPP::Subject.derive`, `OPP::Subject.verify!`, `OPP::Signature.sign`, and `OPP::Signature.verify!`.
- Produces: `OppDirectory::Registration.parse(String) -> Hash`, `create(document_url:, private_key:, public_key:, sequence:, issued_at:) -> Hash`, and `verify!(Hash, expected_subject: nil) -> Hash`.
- Produces: `OppDirectory::Registration::Invalid` for JSON/schema errors and `OppDirectory::Registration::VerificationFailed` for subject/signature failures.

- [ ] **Step 1: Write focused failing tests for construction, parsing, and verification**

Create `src/test/registration_test.rb`:

```ruby
require "json"
require "English"
require "minitest/autorun"
require "opp"
require "time"
require_relative "../lib/opp_directory/registration"

class RegistrationTest < Minitest::Test
  def setup
    @pair = OPP::KeyPair.generate
  end

  def test_create_builds_and_signs_a_valid_registration
    document = OppDirectory::Registration.create(
      document_url: "https://example.com/opp.json",
      private_key: @pair.private_key,
      public_key: @pair.public_key,
      sequence: 7,
      issued_at: Time.iso8601("2026-07-17T12:34:56Z")
    )

    assert_equal "open-presence-directory-registration", document["type"]
    assert_equal "0.2", document["version"]
    assert_equal OPP::Subject.derive(@pair.public_key), document["subject"]
    assert_equal "https://example.com/opp.json", document["document_url"]
    assert_equal 7, document["sequence"]
    assert_equal "2026-07-17T12:34:56Z", document["issued_at"]
    assert_equal document, OppDirectory::Registration.verify!(document)
  end

  def test_parse_rejects_malformed_and_duplicate_json
    assert_raises(OppDirectory::Registration::Invalid) do
      OppDirectory::Registration.parse("{")
    end
    assert_raises(OppDirectory::Registration::Invalid) do
      OppDirectory::Registration.parse('{"type":"first","type":"second"}')
    end
  end

  def test_verify_distinguishes_schema_and_cryptographic_failures
    document = OppDirectory::Registration.create(
      document_url: "https://example.com/opp.json",
      private_key: @pair.private_key,
      public_key: @pair.public_key,
      sequence: 1,
      issued_at: Time.iso8601("2026-07-17T12:34:56Z")
    )

    invalid = document.merge("sequence" => -1)
    assert_raises(OppDirectory::Registration::Invalid) do
      OppDirectory::Registration.verify!(invalid)
    end

    forged = Marshal.load(Marshal.dump(document))
    forged["signature"]["value"] = "A" * 86
    assert_raises(OppDirectory::Registration::VerificationFailed) do
      OppDirectory::Registration.verify!(forged)
    end

    assert_raises(OppDirectory::Registration::Invalid) do
      OppDirectory::Registration.verify!(document, expected_subject: "key:sha256:other")
    end
  end
end
```

- [ ] **Step 2: Run the tests and verify the missing module failure**

Run: `cd src && bundle exec ruby -Itest test/registration_test.rb`

Expected: FAIL with `cannot load such file -- .../lib/opp_directory/registration`.

- [ ] **Step 3: Implement the minimum shared module by extracting the current rules**

Create `src/lib/opp_directory/registration.rb`:

```ruby
require "opp"
require "time"
require "uri"

module OppDirectory
  module Registration
    class Invalid < StandardError; end
    class VerificationFailed < StandardError; end

    REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
    UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

    module_function

    def parse(body)
      OPP::JSON.parse(body)
    rescue OPP::ParseError, OPP::DuplicateMemberError
      raise Invalid, "invalid JSON"
    end

    def create(document_url:, private_key:, public_key:, sequence:, issued_at: Time.now.utc)
      document = {
        "type" => "open-presence-directory-registration",
        "version" => "0.2",
        "subject" => OPP::Subject.derive(public_key),
        "public_key" => public_key,
        "document_url" => document_url,
        "sequence" => sequence,
        "issued_at" => issued_at.utc.iso8601
      }
      OPP::Signature.sign(document, private_key:).tap { |signed| verify!(signed) }
    rescue OPP::Error => error
      raise VerificationFailed, error.message
    end

    def verify!(document, expected_subject: nil)
      raise Invalid, "registration must be an object" unless document.is_a?(Hash)
      missing = REQUIRED_FIELDS.reject { |field| document.key?(field) }
      raise Invalid, "missing field: #{missing.first}" unless missing.empty?
      raise Invalid, "unsupported type" unless document["type"] == "open-presence-directory-registration"
      raise Invalid, "unsupported version" unless document["version"] == "0.2"
      raise Invalid, "subject must be a string" unless document["subject"].is_a?(String)
      raise Invalid, "public_key must be a string" unless document["public_key"].is_a?(String)
      if expected_subject && document["subject"] != expected_subject
        raise Invalid, "subject does not match path"
      end

      begin
        url = URI.parse(document["document_url"].to_s)
      rescue URI::InvalidURIError
        url = nil
      end
      unless url.is_a?(URI::HTTPS) && url.host && url.absolute?
        raise Invalid, "document_url must be an absolute HTTPS URL"
      end

      sequence = document["sequence"]
      unless sequence.is_a?(Integer) && sequence >= 0
        raise Invalid, "sequence must be a non-negative integer"
      end

      issued_at = document["issued_at"]
      unless issued_at.is_a?(String) && UTC_TIMESTAMP.match?(issued_at)
        raise Invalid, "issued_at must be an RFC 3339 UTC timestamp"
      end
      begin
        Time.iso8601(issued_at)
      rescue ArgumentError
        raise Invalid, "issued_at must be an RFC 3339 UTC timestamp"
      end

      signature = document["signature"]
      unless signature.is_a?(Hash) && signature.keys.sort == %w[algorithm value] &&
          signature["algorithm"] == "ed25519" && signature["value"].is_a?(String)
        raise Invalid, "signature must use ed25519"
      end

      begin
        OPP::Subject.verify!(document["subject"], public_key: document["public_key"])
        OPP::Signature.verify!(document, public_key: document["public_key"])
      rescue OPP::Error
        raise VerificationFailed, "subject or signature verification failed"
      end

      document
    end
  end
end
```

- [ ] **Step 4: Run the focused and existing suites**

Run: `cd src && bundle exec ruby -Itest test/registration_test.rb && bundle exec rake`

Expected: 3 Registration tests pass; all 13 existing server tests pass.

- [ ] **Step 5: Commit the shared module**

```bash
git add src/lib/opp_directory/registration.rb src/test/registration_test.rb
git commit -m "Add shared registration protocol module"
```

---

### Task 2: Namespace the server and reuse Registration validation

**Files:**
- Create: `src/lib/opp_directory/app.rb`
- Modify: `src/test/app_test.rb`
- Modify: `src/config.ru`
- Delete: `src/app.rb`

**Interfaces:**
- Consumes: `OppDirectory::Registration.parse` and `verify!` from Task 1.
- Produces: `OppDirectory::App < Sinatra::Base`, including `.database` and the unchanged `GET`, `HEAD`, and `PUT` routes.

- [ ] **Step 1: Change the request test to require the namespaced app**

In `src/test/app_test.rb`, replace the app require, app accessor, and database references:

```ruby
require_relative "../lib/opp_directory/app"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app = OppDirectory::App

  def setup
    OppDirectory::App.database.execute("DELETE FROM registrations")
  end
end
```

Keep every existing helper and test method in the class. Replace the remaining `OppDirectory.database` occurrence in `test_get_and_head_return_a_stored_registration` with `OppDirectory::App.database`.

- [ ] **Step 2: Run the request suite and verify the missing app failure**

Run: `cd src && bundle exec ruby -Itest test/app_test.rb`

Expected: FAIL with `cannot load such file -- .../lib/opp_directory/app`.

- [ ] **Step 3: Move the application under the namespace and delegate validation**

Create `src/lib/opp_directory/app.rb`:

```ruby
require "fileutils"
require "json"
require "sinatra/base"
require "sqlite3"
require_relative "registration"

module OppDirectory
  class App < Sinatra::Base
    class RegistrationError < StandardError
      attr_reader :status

      def initialize(status, message)
        @status = status
        super(message)
      end
    end

    configure do
      set :database_path, ENV.fetch("DATABASE_PATH", "db/opp-directory.sqlite3")
      set :lock, true
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
              sequence TEXT NOT NULL,
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

      def halt_json(status, message)
        halt status, { "Content-Type" => "application/json" }, JSON.generate(error: message)
      end

      def reject!(status, message)
        raise RegistrationError.new(status, message)
      end
    end

    put "/:subject" do
      reject! 415, "content type must be application/json" unless request.media_type == "application/json"
      body = request.body.read
      document = Registration.parse(body)
      Registration.verify!(document, expected_subject: params[:subject])

      created = nil
      self.class.database.transaction(:immediate) do |database|
        created = database.get_first_value(
          "SELECT 1 FROM registrations WHERE subject = ?", document["subject"]
        ).nil?
        database.execute <<~SQL, [document["subject"], document["sequence"].to_s, body]
          INSERT INTO registrations(subject, sequence, document) VALUES (?, ?, ?)
          ON CONFLICT(subject) DO UPDATE SET
            sequence = excluded.sequence,
            document = excluded.document
          WHERE length(excluded.sequence) > length(registrations.sequence)
             OR (length(excluded.sequence) = length(registrations.sequence)
                 AND excluded.sequence > registrations.sequence)
        SQL
        reject! 409, "sequence must be greater than the current sequence" if database.changes.zero?
      end

      status(created ? 201 : 200)
    rescue Registration::Invalid => error
      halt_json 400, error.message
    rescue Registration::VerificationFailed => error
      halt_json 422, error.message
    rescue RegistrationError => error
      halt_json error.status, error.message
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
end
```

Once the new file is complete, delete `src/app.rb`.

- [ ] **Step 4: Update Rack loading and prove server parity**

Replace `src/config.ru` with:

```ruby
require_relative "lib/opp_directory/app"

run OppDirectory::App
```

Run: `cd src && bundle exec ruby -Itest test/app_test.rb && bundle exec rake`

Expected: all 13 server tests and all Registration tests pass.

- [ ] **Step 5: Commit the server refactor**

```bash
git add src/app.rb src/lib/opp_directory/app.rb src/test/app_test.rb src/config.ru
git commit -m "Share registration validation with server"
```

---

### Task 3: Create and verify CLI commands

**Files:**
- Create: `src/lib/opp_directory/cli.rb`
- Create: `src/bin/opp-directory`
- Create: `src/test/cli_test.rb`

**Interfaces:**
- Consumes: `OppDirectory::Registration.create`, `parse`, and `verify!`.
- Produces: `OppDirectory::CLI.run(argv, out: $stdout, err: $stderr) -> Integer`.
- Produces: executable `src/bin/opp-directory` that exits with the returned status.

- [ ] **Step 1: Write failing create and verify command tests**

Create `src/test/cli_test.rb` with this initial content:

```ruby
require "json"
require "minitest/autorun"
require "opp"
require "stringio"
require "tmpdir"
require_relative "../lib/opp_directory/cli"

class CLITest < Minitest::Test
  def setup
    @pair = OPP::KeyPair.generate
    @out = StringIO.new
    @err = StringIO.new
  end

  def run_cli(*arguments)
    OppDirectory::CLI.run(arguments, out: @out, err: @err)
  end

  def test_create_reads_trimmed_keys_and_writes_a_valid_registration
    Dir.mktmpdir do |directory|
      private_key = File.join(directory, "private.key")
      public_key = File.join(directory, "public.key")
      output = File.join(directory, "registration.json")
      File.write(private_key, "  #{@pair.private_key}\n")
      File.write(public_key, "#{@pair.public_key}\n")

      status = run_cli(
        "registration", "create",
        "--document-url", "https://example.com/opp.json",
        "--private-key", private_key,
        "--public-key", public_key,
        "--sequence", "7",
        "--output", output
      )

      document = OppDirectory::Registration.parse(File.binread(output))
      assert_equal 0, status
      assert_equal 7, document["sequence"]
      assert_equal document, OppDirectory::Registration.verify!(document)
      assert_includes @out.string, document["subject"]
      assert_empty @err.string
    end
  end

  def test_verify_reports_valid_and_invalid_registrations
    Dir.mktmpdir do |directory|
      path = File.join(directory, "registration.json")
      document = OppDirectory::Registration.create(
        document_url: "https://example.com/opp.json",
        private_key: @pair.private_key,
        public_key: @pair.public_key,
        sequence: 1
      )
      File.write(path, JSON.pretty_generate(document))

      assert_equal 0, run_cli("registration", "verify", path)
      assert_includes @out.string, "valid"

      document["sequence"] = -1
      File.write(path, JSON.generate(document))
      @out.truncate(0)
      @out.rewind
      assert_equal 1, run_cli("registration", "verify", path)
      assert_match(/sequence/, @err.string)
    end
  end

  def test_usage_errors_return_one_without_a_backtrace
    assert_equal 1, run_cli("registration", "create")
    assert_match(/missing/, @err.string)
    refute_match(/cli\.rb:\d+/, @err.string)
  end

  def test_executable_reports_usage_failure_without_a_backtrace
    executable = File.expand_path("../bin/opp-directory", __dir__)
    output = IO.popen([executable, "registration", "unknown"], err: [:child, :out], &:read)
    assert_equal 1, $CHILD_STATUS.exitstatus
    assert_match(/unknown registration command/, output)
    refute_match(/cli\.rb:\d+/, output)
  end
end
```

- [ ] **Step 2: Run the tests and verify the missing CLI failure**

Run: `cd src && bundle exec ruby -Itest test/cli_test.rb`

Expected: FAIL with `cannot load such file -- .../lib/opp_directory/cli`.

- [ ] **Step 3: Implement command dispatch plus create and verify**

Create `src/lib/opp_directory/cli.rb`:

```ruby
require "json"
require "optparse"
require_relative "registration"

module OppDirectory
  class CLI
    class Error < StandardError; end

    def self.run(argv, out: $stdout, err: $stderr)
      new(argv.dup, out:, err:).run
    end

    def initialize(argv, out:, err:)
      @argv = argv
      @out = out
      @err = err
    end

    def run
      raise Error, "expected 'registration'" unless @argv.shift == "registration"

      case @argv.shift
      when "create" then create
      when "verify" then verify
      else raise Error, "unknown registration command"
      end
      0
    rescue Error, OptionParser::ParseError, Registration::Invalid,
        Registration::VerificationFailed, SystemCallError => error
      @err.puts "error: #{error.message}"
      1
    end

    private

    def create
      options = {}
      parser = OptionParser.new do |value|
        value.on("--document-url URL") { |item| options[:document_url] = item }
        value.on("--private-key FILE") { |item| options[:private_key] = item }
        value.on("--public-key FILE") { |item| options[:public_key] = item }
        value.on("--sequence INTEGER", Integer) { |item| options[:sequence] = item }
        value.on("--output FILE") { |item| options[:output] = item }
      end
      parser.parse!(@argv)
      raise Error, "unexpected argument: #{@argv.first}" unless @argv.empty?
      missing = %i[document_url private_key public_key sequence output].reject { |key| options.key?(key) }
      raise Error, "missing option: --#{missing.first.to_s.tr('_', '-')}" unless missing.empty?

      document = Registration.create(
        document_url: options[:document_url],
        private_key: File.read(options[:private_key]).strip,
        public_key: File.read(options[:public_key]).strip,
        sequence: options[:sequence]
      )
      File.write(options[:output], JSON.pretty_generate(document) + "\n")
      @out.puts "created #{options[:output]} for #{document["subject"]}"
    end

    def verify
      parser = OptionParser.new
      parser.parse!(@argv)
      raise Error, "verify requires one FILE" unless @argv.length == 1

      document = Registration.parse(File.binread(@argv.first))
      Registration.verify!(document)
      @out.puts "valid registration for #{document["subject"]}"
    end

  end
end
```

Create `src/bin/opp-directory`:

```ruby
#!/usr/bin/env ruby

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "opp_directory/cli"

exit OppDirectory::CLI.run(ARGV)
```

Make it executable: `chmod +x src/bin/opp-directory`.

- [ ] **Step 4: Run CLI and complete suites**

Run: `cd src && bundle exec ruby -Itest test/cli_test.rb && bundle exec rake`

Expected: 4 CLI tests pass; all Registration and server tests pass.

- [ ] **Step 5: Commit create and verify**

```bash
git add src/bin/opp-directory src/lib/opp_directory/cli.rb src/test/cli_test.rb
git commit -m "Add registration create and verify commands"
```

---

### Task 4: Publish and fetch CLI commands

**Files:**
- Modify: `src/lib/opp_directory/cli.rb`
- Modify: `src/test/cli_test.rb`

**Interfaces:**
- Consumes: the CLI and Registration interfaces from Tasks 1 and 3.
- Produces: `publish FILE --directory URL` and `fetch SUBJECT --directory URL [--output FILE]` using exact request and response bytes.

- [ ] **Step 1: Add a local HTTP peer and failing publish/fetch tests**

Add these requires and helper to `src/test/cli_test.rb`:

```ruby
require "socket"

def with_http_peer(status: "200 OK", response_body: "{}")
  server = TCPServer.new("127.0.0.1", 0)
  requests = Queue.new
  thread = Thread.new do
    socket = server.accept
    request_line = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = socket.read(headers.fetch("content-length", "0").to_i)
    requests << [request_line, headers, body]
    socket.write(
      "HTTP/1.1 #{status}\r\n" \
      "Content-Length: #{response_body.bytesize}\r\n" \
      "Connection: close\r\n\r\n" \
      "#{response_body}"
    )
    socket.close
  end
  thread.report_on_exception = false

  yield "http://127.0.0.1:#{server.addr[1]}/directory", requests
ensure
  thread&.join(0.1)
  thread&.kill if thread&.alive?
  server&.close
end
```

Add these tests to `CLITest`:

```ruby
def test_publish_verifies_and_puts_original_bytes_to_encoded_subject_path
  Dir.mktmpdir do |directory|
    document = OppDirectory::Registration.create(
      document_url: "https://example.com/opp.json",
      private_key: @pair.private_key,
      public_key: @pair.public_key,
      sequence: 1
    )
    body = JSON.pretty_generate(document) + "\n"
    path = File.join(directory, "registration.json")
    File.binwrite(path, body)

    with_http_peer(status: "201 Created") do |url, requests|
      assert_equal 0, run_cli("registration", "publish", path, "--directory", url)
      request_line, headers, request_body = requests.pop
      assert_equal "PUT /directory/#{document["subject"].gsub(':', '%3A')} HTTP/1.1\r\n", request_line
      assert_equal "application/json", headers["content-type"]
      assert_equal body, request_body
    end
  end
end

def test_fetch_writes_exact_bytes_to_stdout_or_file
  subject = "key:sha256:example"
  body = %({ "subject": "#{subject}" }\n)

  with_http_peer(response_body: body) do |url, requests|
    assert_equal 0, run_cli("registration", "fetch", subject, "--directory", url)
    assert_equal body, @out.string
    assert_match("GET /directory/key%3Asha256%3Aexample HTTP/1.1", requests.pop.first)
  end

  @out.truncate(0)
  @out.rewind
  Dir.mktmpdir do |directory|
    output = File.join(directory, "registration.json")
    with_http_peer(response_body: body) do |url, _requests|
      assert_equal 0, run_cli(
        "registration", "fetch", subject, "--directory", url, "--output", output
      )
    end
    assert_equal body, File.binread(output)
    assert_includes @out.string, output
  end
end

def test_http_failure_returns_one_and_reports_status
  with_http_peer(status: "404 Not Found", response_body: "missing") do |url, _requests|
    assert_equal 1, run_cli(
      "registration", "fetch", "key:sha256:missing", "--directory", url
    )
  end
  assert_match(/404.*missing/, @err.string)
end
```

- [ ] **Step 2: Run the focused tests and verify publish/fetch failures**

Run: `cd src && bundle exec ruby -Itest test/cli_test.rb`

Expected: the three new tests FAIL because `publish` and `fetch` are unknown registration commands.

- [ ] **Step 3: Implement URL building and synchronous HTTP**

Add these standard-library requires to `src/lib/opp_directory/cli.rb`:

```ruby
require "net/http"
require "uri"
```

Add `SocketError` to the `run` rescue list. Add the following two branches to the `case` in `run`:

```ruby
when "publish" then publish
when "fetch" then fetch
```

Then add the command and HTTP helper methods:

```ruby
def publish
  options = parse_directory_options
  raise Error, "publish requires one FILE" unless @argv.length == 1

  body = File.binread(@argv.first)
  document = Registration.parse(body)
  Registration.verify!(document)
  request = Net::HTTP::Put.new(registration_uri(options[:directory], document["subject"]))
  request["Content-Type"] = "application/json"
  request.body = body
  perform(request)
  @out.puts "published registration for #{document["subject"]}"
end

def fetch
  options = parse_directory_options(output: true)
  raise Error, "fetch requires one SUBJECT" unless @argv.length == 1

  request = Net::HTTP::Get.new(registration_uri(options[:directory], @argv.first))
  body = perform(request).body
  if options[:output]
    File.binwrite(options[:output], body)
    @out.puts "fetched registration to #{options[:output]}"
  else
    @out.write(body)
  end
end

def parse_directory_options(output: false)
  options = {}
  parser = OptionParser.new do |value|
    value.on("--directory URL") { |item| options[:directory] = item }
    value.on("--output FILE") { |item| options[:output] = item } if output
  end
  parser.parse!(@argv)
  raise Error, "missing option: --directory" unless options[:directory]
  options
end

def registration_uri(directory, subject)
  uri = URI.parse(directory)
  unless %w[http https].include?(uri.scheme) && uri.host
    raise Error, "directory must be an absolute HTTP or HTTPS URL"
  end
  segment = URI.encode_www_form_component(subject).gsub("+", "%20")
  uri.path = "#{uri.path.sub(%r{/\z}, "")}/#{segment}"
  uri.fragment = nil
  uri
rescue URI::InvalidURIError
  raise Error, "directory must be an absolute HTTP or HTTPS URL"
end

def perform(request)
  uri = request.uri
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end
  return response if response.is_a?(Net::HTTPSuccess)

  detail = response.body.to_s.strip[0, 200]
  suffix = detail.empty? ? "" : ": #{detail}"
  raise Error, "HTTP #{response.code}#{suffix}"
rescue Error
  raise
rescue StandardError => error
  raise Error, "request failed: #{error.message}"
end
```

- [ ] **Step 4: Run focused and complete tests**

Run: `cd src && bundle exec ruby -Itest test/cli_test.rb && bundle exec rake`

Expected: 7 CLI tests pass; all Registration and server tests pass with no warnings or errors.

- [ ] **Step 5: Commit HTTP commands**

```bash
git add src/lib/opp_directory/cli.rb src/test/cli_test.rb
git commit -m "Add registration publish and fetch commands"
```

---

### Task 5: Package and document the CLI

**Files:**
- Modify: `src/Dockerfile`
- Modify: `src/README.md`

**Interfaces:**
- Consumes: `src/bin/opp-directory` and the reorganized library.
- Produces: a container that can load the server and CLI, plus operator-facing command examples.

- [ ] **Step 1: Confirm the executable integration test is green before packaging changes**

Run: `cd src && bundle exec ruby -Itest test/cli_test.rb`

Expected: all 7 CLI tests pass, including direct execution of `bin/opp-directory`.

- [ ] **Step 2: Update the container copy instructions**

Replace the final copy line in `src/Dockerfile`:

```dockerfile
COPY app.rb config.ru ./
```

with:

```dockerfile
COPY config.ru ./
COPY lib ./lib
COPY bin ./bin
```

Keep the existing server `CMD` unchanged.

- [ ] **Step 3: Add concise CLI documentation**

Append this section to `src/README.md` before `## Test`:

````markdown
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
````

- [ ] **Step 4: Run packaging-adjacent checks and commit**

Run:

```bash
cd src
bundle exec ruby -Itest test/cli_test.rb
bundle exec rackup --help >/dev/null
```

Expected: CLI tests pass and Rack loads without a missing-file error.

Commit:

```bash
git add src/Dockerfile src/README.md src/test/cli_test.rb
git commit -m "Package and document registration CLI"
```

---

### Task 6: Final verification

**Files:**
- Verify only; modify a file only to correct a failure attributable to Tasks 1-5.

**Interfaces:**
- Consumes: the complete server and CLI.
- Produces: evidence that issue #3 acceptance criteria and existing server behavior pass together.

- [ ] **Step 1: Run the complete automated suite**

Run: `cd src && bundle exec rake`

Expected: all Registration, CLI, and server tests pass with zero failures and zero errors.

- [ ] **Step 2: Run syntax checks**

Run:

```bash
cd src
bundle exec ruby -cw lib/opp_directory/registration.rb
bundle exec ruby -cw lib/opp_directory/app.rb
bundle exec ruby -cw lib/opp_directory/cli.rb
bundle exec ruby -cw bin/opp-directory
bundle exec ruby -cw test/registration_test.rb
bundle exec ruby -cw test/app_test.rb
bundle exec ruby -cw test/cli_test.rb
```

Expected: every command prints `Syntax OK` and no warnings.

- [ ] **Step 3: Check the diff and repository state**

Run: `git diff --check && git status --short && git log -6 --oneline`

Expected: no whitespace errors; only intentional changes, if any, remain uncommitted; the task commits are visible.

- [ ] **Step 4: Build the image when registry access is available**

Run: `cd src && docker build -t opp-directory .`

Expected: image builds successfully and includes `config.ru`, `lib/`, and `bin/`. If registry access or Docker itself is unavailable, record that limitation rather than changing code.

- [ ] **Step 5: Make a final correction commit only if verification required changes**

```bash
git add src/lib/opp_directory/registration.rb src/lib/opp_directory/app.rb \
  src/lib/opp_directory/cli.rb src/bin/opp-directory src/test/registration_test.rb \
  src/test/app_test.rb src/test/cli_test.rb src/config.ru src/Dockerfile src/README.md
git commit -m "Fix registration CLI verification issues"
```

Skip this commit when Step 1-4 required no code or documentation changes.
