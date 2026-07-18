require "json"
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
