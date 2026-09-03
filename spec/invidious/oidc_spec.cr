require "../spec_helper"

Spectator.describe Invidious::OIDC do
  describe "code_challenge_for" do
    it "matches the test vector in RFC 7636 appendix B" do
      # The one part of PKCE that can be checked against an authority instead
      # of against itself. Getting it wrong is not a visible bug: the provider
      # answers every token exchange with an opaque `invalid_grant`.
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

      expect(Invidious::OIDC.code_challenge_for(verifier))
        .to eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    end

    it "returns base64url without padding" do
      # Padding, '+' or '/' in a challenge are rejected by providers, and
      # `Base64.urlsafe_encode` pads by default.
      challenge = Invidious::OIDC.code_challenge_for(Invidious::OIDC.generate_code_verifier)

      expect(challenge.matches?(/\A[A-Za-z0-9_-]+\z/)).to be_true
    end
  end

  describe "generate_code_verifier" do
    it "stays inside the length RFC 7636 allows" do
      verifier = Invidious::OIDC.generate_code_verifier

      expect(verifier.size).to be >= 43
      expect(verifier.size).to be <= 128
    end

    it "does not hand out the same verifier twice" do
      expect(Invidious::OIDC.generate_code_verifier)
        .to_not eq(Invidious::OIDC.generate_code_verifier)
    end
  end
end
