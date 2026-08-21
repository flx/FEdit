# (preview-tables) repro — GFM table renders as one run-on paragraph

Reported 2026-08-21. Screenshot: `plans/preview-tables-repro.png`.

## Source (paste into a `.md` file, open in FEdit, look at the preview column)

```
| skill #100 | skill #99     |   skill #98 | skill #75 | skill #50 |
| ---------- | ------------- | ----------- | --------- | --------- |
| gama radar | 99luftbaloons | pickpocket  | railgun   |cheeky     |
|shoot gases | float away &  | steal a     | explosion | cheeky    |
|that KILL   | ESCAPE!!!     | ROLE!!!     | EXPLODE   | ALL items in |
|taggers!!!  |               |             | the map!!!| all roles!!! |
|20,000$     |   17,500$     |  10,000$    |  16,450$       17,450$ |
```

Note the source is *itself* imperfect GFM — the last row has 4 pipes where the
header has 6 (`16,450$` and `17,450$` share a cell), and several rows have
ragged cell counts. A fix must degrade gracefully on ragged rows rather than
require well-formed input.

## Observed

Every line is emitted as one wrapped paragraph, rows space-joined:

> | skill #100 | skill #99 | skill #98 | skill #75 | skill #50 | | ---------- |
> ------------- | ----------- | --------- | --------- | | gama radar |
> 99luftbaloons | pickpocket | railgun |cheeky | |shoot gases | float away & …

Even the source's line structure is gone.

## Root cause (read off HEAD, not inferred)

`MarkdownBlock` has no `.table` case, so a `|…|` row is classified by
`MarkdownBlockParser.parse`'s steps 1–7 as none of fence / blank / heading /
rule / blockquote / list item, and falls through to step 8, paragraph
continuation, which appends it to the paragraph accumulator
(`Preview/MarkdownRenderer.swift:183-190`); the accumulator is flushed with
`joined(separator: " ")`. The `| --- | --- |` delimiter row is not a horizontal
rule either — `isRule` sees a leading `|` — so nothing breaks the block, and
the whole table plus any adjacent prose collapses into a single paragraph.

## Expected

The table renders as a table (aligned columns, header row distinguishable).
SPEC §8.2 currently lists tables under "Not in v1", so the fix reverses that
non-goal and must edit §8.2.
