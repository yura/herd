# frozen_string_literal: true

RSpec.describe Herd::Playbook do
  let(:playbook) { described_class.new(runner) }
  let(:runner) { Herd::Runner.new([host]) }
  let(:host) { instance_double(Herd::Host) }

  describe "#run" do
    context "when the block defines no stages" do
      it "prints a message and does not touch the runner" do
        expect(runner).not_to receive(:exec)
        expect { playbook.run(only: nil, from: nil, except: nil) {} }
          .to output(/no stages defined — nothing to run/).to_stdout
      end
    end

    context "when only, from or except name a stage that isn't declared" do
      it "raises before touching the runner, checking against all declared stages" do
        expect(runner).not_to receive(:exec)

        [{ only: :missing }, { from: :typo }, { except: [:typo] }, { only: :a, from: :b }].each do |opts|
          expect { playbook.run(**opts) { a } }.to raise_error(ArgumentError, /no stage named/)
        end
      end
    end

    context "when a stage is given as a block" do
      it "runs the block in the session instead of calling a method of that name" do
        fake_session = Class.new do
          attr_reader :ran

          def info(*); end
          def apt_update = (@ran ||= []) << :apt_update
          def packages = raise("the method named like the stage must not run")
        end.new
        allow(host).to receive(:exec) { |_command, &block| fake_session.instance_exec(&block) }

        playbook.run(only: :packages) do
          packages { apt_update }
          other { raise "not selected" }
        end

        expect(fake_session.ran).to eq([:apt_update])
      end
    end

    context "when :except filters out every defined stage" do
      it "prints a message and does not touch the runner" do
        expect(runner).not_to receive(:exec)
        expect do
          playbook.run(only: nil, from: nil, except: [:some_stage]) { some_stage }
        end.to output(/all stages skipped.*nothing to run/).to_stdout
      end
    end

    context "when at least one stage is runnable" do
      it "executes only the runnable stages on the runner" do
        fake_session = Class.new do
          attr_reader :ran

          def info(*); end

          def some_stage(*)
            @ran = true
          end

          def excluded_stage(*)
            raise "should not run"
          end
        end.new

        allow(host).to receive(:exec) { |_command, &block| fake_session.instance_exec(&block) }

        playbook.run(only: nil, from: nil, except: [:excluded_stage]) do
          some_stage
          excluded_stage
        end

        expect(fake_session.ran).to be true
      end
    end
  end

  describe ".parse_argv" do
    it "reads a stage, --from and repeated --except" do
      expect(described_class.parse_argv(%w[deploy --except a --except b]))
        .to eq(only: :deploy, from: nil, except: %i[a b])
      expect(described_class.parse_argv(%w[--from b])).to eq(only: nil, from: :b, except: nil)
    end

    it "refuses an option without its value, an unknown option and a second stage" do
      [%w[--from], %w[--except], %w[--from --except a], %w[--frm a], %w[a b]].each do |argv|
        expect { described_class.parse_argv(argv) }.to raise_error(ArgumentError, /usage/)
      end
    end
  end
end
