require "json"
require "net/http"
require "optparse"
require "uri"
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
      when "publish" then publish
      when "fetch" then fetch
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

      subject = @argv.first
      request = Net::HTTP::Get.new(registration_uri(options[:directory], subject))
      body = perform(request).body
      document = Registration.parse(body)
      Registration.verify!(document, expected_subject: subject)
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
  end
end
