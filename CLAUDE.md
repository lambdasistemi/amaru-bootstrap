# amaru-bootstrap

Agent guidance for this repository lives in [AGENTS.md](AGENTS.md).
Start there; it covers what the repo is, the working commands, the
constitution gate, and the skills under `skills/`.

Claude-specific notes only below this line.

- Read [`.specify/memory/constitution.md`](.specify/memory/constitution.md)
  before design decisions — it gates them.
- Every ticket runs through speckit: `speckit-specify` ->
  `speckit-plan` -> `speckit-tasks` -> `speckit-implement`. No
  implementation without a spec on disk. `plan.md` <= 200 lines; push
  detail into `research.md`, `data-model.md`, `contracts/`,
  `quickstart.md`, and compact a Status block back into `plan.md`
  after each implement phase.
- One worktree per branch; the main checkout stays on `main`.
