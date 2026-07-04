# frozen_string_literal: true

RSpec.describe Herd::Commands::Apt do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  let(:sources_path) { "/etc/apt/sources.list.d/example.list" }
  let(:sources_line) { "deb [signed-by=/usr/share/keyrings/example.gpg] https://example.com/apt stable main" }
  let(:keyring_path) { "/usr/share/keyrings/example.gpg" }
  let(:keyring_url)  { "https://example.com/key.gpg" }

  before do
    allow(session).to receive(:apt_update)
    allow(session).to receive(:expect_file_content_equals)
  end

  describe "#apt_add_repo" do
    context "when the key doesn't exist yet" do
      before do
        allow(session).to receive(:file_exists?).with(keyring_path).and_return(false)
        allow(session).to receive(:sudo)
      end

      it "fetches the key as-is by default" do
        session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url)
        expect(session).to have_received(:sudo).with("curl -fsSL -o #{keyring_path} #{keyring_url}")
      end

      it "dearmors the key when dearmor: true" do
        session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url, dearmor: true)
        expect(session).to have_received(:sudo).with(%(bash -c 'curl -fsSL #{keyring_url} | gpg --dearmor > #{keyring_path}'))
      end

      it "writes the sources file and refreshes apt" do
        session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url)
        expect(session).to have_received(:expect_file_content_equals).with(sources_path, "#{sources_line}\n")
        expect(session).to have_received(:apt_update)
      end

      context "with a fingerprint" do
        let(:fingerprint) { "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" }

        it "raises and does not touch the sources file if the fetched key doesn't match" do
          allow(session).to receive(:run).and_return("pub:-:4096:1:some other key\n")

          expect do
            session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url,
                                                               fingerprint: fingerprint)
          end.to raise_error(Herd::CommandError, /does not match expected fingerprint/)

          expect(session).not_to have_received(:expect_file_content_equals)
        end

        it "proceeds if the fetched key matches" do
          allow(session).to receive(:run).and_return("fpr:::::::::#{fingerprint}:\n")

          session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url,
                                                             fingerprint: fingerprint)

          expect(session).to have_received(:expect_file_content_equals)
        end
      end
    end

    context "when a key already exists and matches the fingerprint" do
      let(:fingerprint) { "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" }

      before do
        allow(session).to receive(:file_exists?).with(keyring_path).and_return(true)
        allow(session).to receive(:run).and_return("fpr:::::::::#{fingerprint}:\n")
        allow(session).to receive(:sudo)
      end

      it "does not re-fetch the key" do
        session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url,
                                                           fingerprint: fingerprint)

        expect(session).not_to have_received(:sudo)
        expect(session).to have_received(:expect_file_content_equals)
      end
    end

    context "when an existing key no longer matches the fingerprint" do
      let(:fingerprint) { "573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" }

      it "re-fetches and re-verifies the key" do
        allow(session).to receive(:file_exists?).with(keyring_path).and_return(true)
        allow(session).to receive(:run).and_return("stale key\n", "fpr:::::::::#{fingerprint}:\n")
        allow(session).to receive(:sudo)

        session.apt_add_repo(sources_path, sources_line, keyring_path: keyring_path, keyring_url: keyring_url,
                                                           fingerprint: fingerprint)

        expect(session).to have_received(:sudo).with("curl -fsSL -o #{keyring_path} #{keyring_url}")
        expect(session).to have_received(:expect_file_content_equals)
      end
    end
  end
end
