# frozen_string_literal: true

# What gpg and curl really do with keys is in spec/system/apt_spec.rb.
RSpec.describe Herd::Commands::Apt do
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }
  let(:fpr) { "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" }
  let(:other) { "1111222233334444555566667777888899990000" }

  describe "fingerprints in gpg --with-colons output" do
    def primary(colons) = session.send(:apt_primary_fingerprints, colons)

    it "takes the fpr record right after pub, upcased" do
      expect(primary("pub:-:255:22:AAAA:1:::::scESC:\nfpr:::::::::#{fpr.downcase}:\n")).to eq([fpr])
    end

    it "ignores subkeys and a user ID that contains the expected fingerprint" do
      colons = <<~COLONS
        pub:-:255:22:BBBB:1:::::scESC:
        fpr:::::::::#{other}:
        uid:-::::1::HASH::fpr:::::::::#{fpr}: <evil@example.com>::::::::::0:
        sub:-:255:18:CCCC:1::::::e:
        fpr:::::::::#{fpr}:
      COLONS

      expect(primary(colons)).to eq([other])
    end

    it "lists every primary key of a multi-key keyring" do
      colons = "pub:-:1:1:A:1:\nfpr:::::::::#{fpr}:\npub:-:1:1:B:1:\nfpr:::::::::#{other}:\n"

      expect(primary(colons)).to eq([other, fpr].sort)
    end
  end

  describe "#apt_add_repo" do
    it "refuses an empty or malformed fingerprint before touching the host" do
      allow(session).to receive(:run_result)

      [[], "", "ABCD", "zz" * 20, [fpr, "nope"]].each do |bad|
        expect do
          session.apt_add_repo("/etc/apt/sources.list.d/x.list", "deb x", keyring_path: "/k", keyring_url: "https://x",
                                                                          fingerprint: bad)
        end.to raise_error(ArgumentError)
      end
      expect(session).not_to have_received(:run_result)
    end

    it "accepts fingerprints with spaces and in lower case" do
      expect(session.send(:apt_expected_fingerprints,
                          "573b fd6b 3d8f bc64 1079  a6ab abf5 bd82 7bd9 bf62")).to eq([fpr])
    end
  end
end
