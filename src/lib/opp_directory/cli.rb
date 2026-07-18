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
      OptionParser.new.parse!(@argv)
      raise Error, "verify requires one FILE" unless @argv.length == 1

      document = Registration.parse(File.binread(@argv.first))
      Registration.verify!(document)
      @out.puts "valid registration for #{document["subject"]}"
    end
  end
end
