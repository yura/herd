# TODO

## Change Log
- 2025-10-09: Set up TODO.md to track Herd evolution; captured reporting requirements (including exception metadata) and high-level goals addressing Ansible pain points.

## TODO
- [ ] Core: keep persistent SSH sessions per host and reuse them during task execution.
- [ ] Core: design a task graph with explicit dependencies and skip downstream tasks after failures.
- [ ] Reporting: implement `RunReport` capturing start/success/fail, stdout/stderr, timing, exception class/message/backtrace, and task context.
- [ ] Reporting: add a structured console summary plus export (e.g., JSON) for later inspection.
- [ ] Persistence: define a `StateStore` interface and default SQLite backend (via `sequel`) for task caching.
- [ ] Persistence: honor a `--force` flag to invalidate cached task results per host/task signature.
- [ ] DSL: sketch a Ruby DSL for declaring hosts, tasks, and dependency graphs (support reusable modules).
- [ ] Research: evaluate the concurrency model (thread pool vs async) once persistent sessions land.
- [ ] Meta: at each session start, reread `TODO.md` and append progress notes to the Dev Log before exiting.
- [ ] Meta: practice TDD — write comprehensive tests for each change before implementing functionality.

## Dev Log
- 2025-10-09: Logged Ansible pain points (per-task SSH reconnects, weak reporting, missing dependencies, no state) as targets for Herd.
- 2025-10-09: Agreed failure reporting must include exception class, message, full backtrace, and task metadata.
- 2025-10-09: Installed Ruby 3.2.8 via rbenv, aligned bundler 2.6.6, ran `bundle install`, and confirmed `bundle exec rspec` is green.
- 2025-10-09: Wrote specs for `Herd::RunReport`, implemented lifecycle tracking with exception metadata, and kept the suite green under TDD (`bundle exec rspec`).

## Next Session Prep
- Draft the `RunReport` API (events, serialization hooks, failure enrichment).
- Plan a `Herd::Host`/`Session` refactor to separate connection lifecycle from command execution.
