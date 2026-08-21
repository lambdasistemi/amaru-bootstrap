# Data model

Artifact ceiling: 60 lines.

| ID | Value | Source | Validation |
|---|---|---|---|
| D-088-FULL | Full Amaru revision | `inputs.amaru.rev` / `amaruRev` | Exactly 40 lowercase hexadecimal characters. |
| D-088-SHORT | Short Amaru revision | D-088-FULL | Exactly the first eight characters of D-088-FULL. |
| D-088-DIRTY | Source dirty state | Deterministic packaging declaration | Always false for the immutable fetched source. |
| D-088-VERSION | Observable version output | Built `amaru --version` surface | Contains D-088-SHORT and contains no dirty marker. |

## Relationships

- D-088-FULL is the sole identity authority.
- D-088-SHORT is a pure projection of D-088-FULL.
- D-088-DIRTY describes the immutable fetched input, not the surrounding
  bootstrap repository.
- D-088-VERSION is the permanent observation proving those values reached the
  executable.
