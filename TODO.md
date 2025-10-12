# TODO

- [x] Load session commands automatically from `lib/herd/session/commands`.
- [x] Extract existing `Session` command helpers (e.g., `add_authorized_key`) into the commands directory.
- [x] Ensure new command loading approach is covered by specs.
- [x] Add explicit `logger` dependency to address net-ssh warning on Ruby 3.4.2.
- [x] Add explicit `csv` dependency to silence Ruby 3.4 warning.
- [ ] Document new command-extension flow with YARD annotations.
- [x] Wire recipe loader/CLI to execute CSV-defined hosts sequentially per dependencies.
- [x] Extend CLI host parsing with per-row user/private key/timeout overrides.

# Log

- Initialized planning file and seeded initial task list.
- Updated project configuration to target Ruby 3.4.2 (Gemfile, gemspec, .ruby-version, lockfile).
- Synced RuboCop config with Ruby 3.4.2 and confirmed clean lint run.
- Moved development dependencies from gemspec to Gemfile; bundle, lint, and tests still pass (with net-ssh logger warning).
- Fixed `Session#method_missing` to avoid extra spaces when building commands; specs now green.
- Implemented automatic session command loading via prepended modules, moved authorized key helpers, added YARD dependency, and expanded specs accordingly.
- Added recipe loader with dependency ordering, CLI entrypoint, and CSV-host execution workflow with specs.
- Expanded CLI host parsing to support user overrides, per-host timeouts, and private key configuration.
- Added explicit runtime dependencies on csv/logger to silence Ruby 3.4 warnings.
- Added reporting pipeline with execution transcripts, task timing, and CLI summary output.
- Refined CLI runner/hosts loader split, added progress output with alias/identity, and ensured execution results expose stdout/stderr for printing.

# Notes

- Keep command implementations in English and back them with tests.
