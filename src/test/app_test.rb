ENV["RACK_ENV"] = "test"
ENV["DATABASE_PATH"] = ":memory:"

require "json"
require "minitest/autorun"
require "opp"
require "rack/test"
require "time"
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

  def test_publishes_and_returns_exact_signed_registration
    document = signed_registration
    body = JSON.pretty_generate(document) + "\n"

    put path(document["subject"]), body, "CONTENT_TYPE" => "application/json"
    assert_equal 201, last_response.status

    get path(document["subject"])
    assert_equal body, last_response.body
  end

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
    put path("key:sha256:any"), String.new("{}"), "CONTENT_TYPE" => "text/plain"
    assert_equal 415, last_response.status

    put path("key:sha256:any"), String.new("{"), "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status

    put path("key:sha256:any"), String.new("[]"), "CONTENT_TYPE" => "application/json"
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
end
