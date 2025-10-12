# frozen_string_literal: true

require "tempfile"

RSpec.describe Herd::Recipe do
  describe ".load" do
    context "with dependent tasks" do
      let(:runner) { instance_double(Herd::Runner, hosts: Array.new(2) { instance_double(Herd::Host) }) }

      let(:recipe) do
        build_recipe(<<~RUBY)
          task :first do
          end

          task :second, depends_on: :first do
          end
        RUBY
      end

      let(:report) { instance_double(Herd::Report) }
      let(:execution_result) do
        instance_double(
          Herd::ExecutionResult,
          success?: true,
          stdout: "",
          stderr: "",
          commands: [],
          exception: nil,
          started_at: Time.now,
          finished_at: Time.now,
          duration: 0.0
        )
      end
      let(:progress) do
        instance_double(
          Herd::ProgressReporter,
          reset: nil,
          task_started: nil,
          task_completed: nil,
          finish: nil
        )
      end

      before do
        allow(runner).to receive(:exec).and_return([execution_result])
        allow(report).to receive(:add)
        recipe.run(runner, report: report, progress: progress)
      end

      it "executes tasks sequentially" do
        expect(runner).to have_received(:exec).twice
      end

      it "records each task in the report" do
        expect(report).to have_received(:add).twice
      end
    end

    context "with missing dependency" do
      let(:recipe) do
        build_recipe(<<~RUBY)
          task :second, depends_on: :missing do
          end
        RUBY
      end
      let(:runner) { instance_double(Herd::Runner, hosts: []) }

      it "raises an error" do
        expect { recipe.run(runner) }.to raise_error(ArgumentError, /Unknown dependency/)
      end
    end
  end
end

def build_recipe(contents)
  Tempfile.create("recipe.rb") do |file|
    file.write(contents)
    file.flush
    file.close
    return Herd::Recipe.load(file.path)
  end
end
