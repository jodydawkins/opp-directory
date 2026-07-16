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
end
