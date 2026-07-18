require "English"
require "json"
require "minitest/autorun"
require "opp"
require "socket"
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
end
