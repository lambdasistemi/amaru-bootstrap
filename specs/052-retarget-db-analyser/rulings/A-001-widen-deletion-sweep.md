# Decision 1 Answer: Scope widening approved

The epic owner approved all five required live surfaces:

- `nix/bootstrap-producer-image.nix`;
- `test/HeaderExtractorSpec.hs`;
- `test/Spec.hs`;
- `AGENTS.md`;
- `skills/amaru-bootstrap-guide/SKILL.md`.

Changes in `AGENTS.md` and the repository guide are limited to
`header-extractor` references. Generated `site/**` remains excluded because
deployment builds from MkDocs sources; its stale committed output will be
tracked separately.

The original forbidden fence remains unchanged: historical `specs/00*`,
`docs/history/**`, the constitution, the Amaru pin, and other worktrees.
