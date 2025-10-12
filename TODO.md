# TODO

- [ ] Load session commands automatically from `lib/herd/session/commands`.
- [ ] Extract existing `Session` command helpers (e.g., `add_authorized_key`) into the commands directory.
- [ ] Ensure new command loading approach is covered by specs.
- [ ] Add explicit `logger` dependency to address net-ssh warning on Ruby 3.4.2.

# Log

- Initialized planning file and seeded initial task list.
- Updated project configuration to target Ruby 3.4.2 (Gemfile, gemspec, .ruby-version, lockfile).
- Synced RuboCop config with Ruby 3.4.2 and confirmed clean lint run.
- Moved development dependencies from gemspec to Gemfile; bundle, lint, and tests still pass (with net-ssh logger warning).
- Fixed `Session#method_missing` to avoid extra spaces when building commands; specs now green.

# Notes

- Keep command implementations in English and back them with tests.
