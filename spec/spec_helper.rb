# frozen_string_literal: true

require "herd"

# ssh_story.rb isn't loaded here: requiring net/ssh/test patches net-ssh for every
# connection in the process, so only the specs that script a socket require it.
Dir[File.join(__dir__, "support", "**", "*.rb")].reject { |file| file.end_with?("ssh_story.rb") }
                                                .each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
