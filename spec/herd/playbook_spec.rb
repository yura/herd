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

    context "when :only does not match any defined stage" do
      it "prints a message naming the missing stage and does not touch the runner" do
        expect(runner).not_to receive(:exec)
        expect do
          playbook.run(only: :missing_stage, from: nil, except: nil) { some_stage }
        end.to output(/no stage named 'missing_stage' — nothing to run/).to_stdout
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
end
