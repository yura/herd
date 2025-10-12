# TODO

- [x] Load session commands automatically from `lib/herd/session/commands`.
- [x] Extract existing `Session` command helpers (e.g., `add_authorized_key`) into the commands directory.
- [x] Ensure new command loading approach is covered by specs.
- [ ] Add explicit `logger` dependency to address net-ssh warning on Ruby 3.4.2.
- [ ] Document new command-extension flow with YARD annotations.

# Log

- Initialized planning file and seeded initial task list.
- Updated project configuration to target Ruby 3.4.2 (Gemfile, gemspec, .ruby-version, lockfile).
- Synced RuboCop config with Ruby 3.4.2 and confirmed clean lint run.
- Moved development dependencies from gemspec to Gemfile; bundle, lint, and tests still pass (with net-ssh logger warning).
- Fixed `Session#method_missing` to avoid extra spaces when building commands; specs now green.
- Implemented automatic session command loading via prepended modules, moved authorized key helpers, added YARD dependency, and expanded specs accordingly.

# Notes

- Keep command implementations in English and back them with tests.
