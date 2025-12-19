# frozen_string_literal: true

source "https://rubygems.org"

ruby "3.4.7"

# Specify your gem's dependencies in herd.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "bcrypt_pbkdf", "~> 1.1"
gem "csv"
gem "diff-lcs"
gem "ed25519", "~> 1.4"
gem "erb"
gem "json"
gem "net-ssh", "~> 7.3"
gem "rsync"

group :development, :test do
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.21",  require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rake",        require: false
  gem "rubocop-rspec",       require: false
end

group :development do
  gem "yard", "~> 0.9"
end
