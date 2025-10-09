# TODO

## Change Log
- 2025-10-09: Set up TODO.md to track Herd evolution; captured reporting requirements (including exception metadata) and high-level goals addressing Ansible pain points.

## TODO
- [x] Core: keep persistent SSH sessions per host and reuse them during task execution.
- [x] Core: design a task graph with explicit dependencies and skip downstream tasks after failures.
- [x] Reporting: implement `RunReport` capturing start/success/fail, stdout/stderr, timing, exception class/message/backtrace, and task context.
- [x] Reporting: add a structured console summary plus export (e.g., JSON) for later inspection.
- [x] Persistence: define a `StateStore` interface plus in-memory adapter for task caching.
- [x] Persistence: build SQLite `StateStore` backend (via `sequel`) for durable caching.
- [x] Persistence: honor a `--force` flag to invalidate cached task results per host/task signature.
- [ ] DSL: sketch a Ruby DSL for declaring hosts, tasks, and dependency graphs (support reusable modules).
- [ ] Research: evaluate the concurrency model (thread pool vs async) once persistent sessions land.
- [ ] Meta: at each session start, reread `TODO.md` and append progress notes to the Dev Log before exiting.
- [ ] Meta: practice TDD — write comprehensive tests for each change before implementing functionality.

## Dev Log
- 2025-10-09: Logged Ansible pain points (per-task SSH reconnects, weak reporting, missing dependencies, no state) as targets for Herd.
- 2025-10-09: Agreed failure reporting must include exception class, message, full backtrace, and task metadata.
- 2025-10-09: Installed Ruby 3.2.8 via rbenv, aligned bundler 2.6.6, ran `bundle install`, and confirmed `bundle exec rspec` is green.
- 2025-10-09: Wrote specs for `Herd::RunReport`, implemented lifecycle tracking with exception metadata, and kept the suite green under TDD (`bundle exec rspec`).
- 2025-10-09: Extended `Runner#exec` to emit `RunReport` events for success/failure across hosts and covered new behavior with specs.
- 2025-10-09: Shifted `Host`/`Session` to persistent SSH connections with reconnection on failure, plus new specs for lifecycle management.
- 2025-10-09: Added `ExecutionResult` plumbing so runner reports real stdout/stderr buffers and sessions keep last result (with error capture).
- 2025-10-09: Implemented `RunReport` summaries and JSON export with aggregation specs.
- 2025-10-09: Introduced dependency-aware `TaskGraph` with skip propagation and reporting hooks.
- 2025-10-09: Sketched `StateStore` interface with in-memory adapter, including force fetch semantics and invalidation tests.
- 2025-10-09: Implemented SQLite-backed `StateStore` via Sequel with persistence specs and shared adapter tests.
- 2025-10-09: Wired TaskGraph caching/signatures and added configuration hooks for state storage.
- 2025-10-09: Added CLI options for state store selection/path and documented caching workflow in README.

## Next Session Prep
- Finalize CLI entry points/flags for enabling persistent cache and selecting adapter/path.
- Document TaskGraph caching behavior (signature params, cache hit reporting) and provide usage examples.
- Explore DSL integration for task parameters to feed signature builder.
