require "English"
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
