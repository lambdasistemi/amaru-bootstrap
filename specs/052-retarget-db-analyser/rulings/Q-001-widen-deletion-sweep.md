# Decision 1 Question: Required dependency-sweep scope

The mandatory exact-name sweep found five required live surfaces outside the
original filed fence:

- `nix/bootstrap-producer-image.nix`;
- `test/HeaderExtractorSpec.hs`;
- `test/Spec.hs`;
- `AGENTS.md`;
- `skills/amaru-bootstrap-guide/SKILL.md`.

It also found tracked generated output under `site/**`.

Recommendation: include the five live sources and continue excluding
`site/**`, which the documentation workflow regenerates from sources.
