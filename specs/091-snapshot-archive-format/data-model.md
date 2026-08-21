# Data model

Artifact ceiling: 60 lines.

## D-091-SNAPSHOT-ARTIFACT

One filesystem entry produced for one requested snapshot target.

| Field | Source | Validation |
|---|---|---|
| slot | entry basename | One or more decimal digits. |
| hash | entry basename | One or more lowercase hexadecimal digits. |
| form | filesystem type and suffix | Directory with no suffix, or regular file ending `.tar.zst`. |

An entry is recognized only when all fields validate. Era-history sidecars and
other files are not snapshot artifacts.

## D-091-SNAPSHOT-SET

The recognized D-091-SNAPSHOT-ARTIFACT entries under one network snapshot
root. It is valid for producer continuation only when its cardinality is at
least three.

## D-091-HOSTED-RECEIPT

Evidence binding a repository, branch, exact head SHA, upstream Amaru SHA,
workflow run, and required check conclusions. Stock and candidate receipts are
distinct; neither substitutes for the other.
