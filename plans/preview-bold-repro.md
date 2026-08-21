# (preview-bold-spans) repro — `**…**` sometimes isn't bold, and the wrong run is

Reported 2026-08-21 with a screenshot. Two independent root causes, both
probe-confirmed against HEAD by compiling `MarkdownRenderer.swift` +
`Theme.swift` with a driver that prints the block and inline trees.

---

## Cause 1 (the reported example) — a bold span wrapped across source lines inside a list item

### Source

```
- [ ] (snapshot-solve-merge) **[hi · TRIGGERED — do not schedule until it
  fires]** The structural half of `(solve-blocks-main-actor)` (shipped
  2026-08-21). Direction: snapshot-solve-merge, not a finer lock.
```

### Expected

`[hi · TRIGGERED — do not schedule until it fires]` is bold; the rest is plain.

### Observed

`**[hi · TRIGGERED — do not schedule until it` renders plain **with the `**`
visible as literal text**, and everything *after* `fires]**` renders bold —
i.e. the delimiters pair with the wrong run.

### Probe output (HEAD)

```
listItem(line 0, marker "•") text="[ ] (snapshot-solve-merge) **[hi · TRIGGERED — do not schedule until it"
  -> text("[ ] (snapshot-solve-merge) **[hi · TRIGGERED — do not schedule until it")
paragraph(line 1) text="  fires]** The structural half of `(solve-blocks-main-actor)` (shipped   2026-08-21). …"
  -> text("  fires]** The structural half of "), code("(solve-blocks-main-actor)"), text(" (shipped   2026-08-21). …")
```

### Root cause

`MarkdownBlockParser.parse` has **no list-item continuation**. A wrapped list
item's second line matches none of steps 1–7 and falls to step 8, paragraph
continuation (`Preview/MarkdownRenderer.swift:183-190`), so it starts a **new
block**. The `**…**` span is therefore split across two blocks, and the inline
parser — which runs per block — sees an unpaired `**` in each: the opener half
emits literally, and the orphaned closing `**` becomes an *opener* that pairs
with the next `**` further down the document, bolding the wrong run (exactly
what the screenshot shows).

Controls prove the diagnosis — both of these render correctly today:

```
control: same bold on ONE line in a list item
  -> text("[ ] (snapshot-solve-merge) "), BOLD[text("[hi · TRIGGERED — do not schedule until it fires]")], text(" The rest.")

control: same wrap inside a PLAIN paragraph (paragraph lines merge with a space)
  -> text("Some prose "), BOLD[text("[hi · TRIGGERED — do not schedule until it fires]")], text(" and the rest.")
```

So the defect is specific to *list items*, whose continuation lines break out
into a paragraph instead of merging into the item.

Cosmetic side effects of the same gap, visible in the probe output: the
continuation line keeps its leading indent (`"  fires]**"`), and joining a
continuation that already ends in a space yields a double space
(`"(shipped   2026-08-21"`).

---

## Cause 2 (independent) — one stray `*` earlier in a block re-pairs every asterisk after it

The inline parser commits to the **nearest** closing delimiter with no
backtracking and no CommonMark left/right-flanking delimiter-run rule
(`MarkdownInlineParser.parseNodes`, precedence code → link → bold → italic).
So a single unpaired `*` anywhere earlier in the same block — multiplication, a
footnote marker, a glob — captures the first `*` of a later `**` as its italic
closer and desynchronizes everything downstream.

Probe output (HEAD):

```
IN : 2 * 3 and **bold** here
OUT: text("2 "), italic[text(" 3 and ")], italic[text("bold")], text("* here")     ← "bold" is ITALIC, stray "*" left

IN : see footnote * and **bold**
OUT: text("see footnote "), italic[text(" and ")], italic[text("bold")], text("*")

IN : 5 * 4 = 20, 6 * 7 = 42, **bold**
OUT: text("5 "), italic[text(" 4 = 20, 6 ")], text(" 7 = 42, "), BOLD[text("bold")]  ← even count re-syncs by luck

IN : a ** b and **bold** c
OUT: text("a "), BOLD[text(" b and ")], text("bold** c")                            ← wrong run bold
```

Because paragraph lines merge, the stray `*` need not be on the same *line* —
only in the same block:

```
Rate is 5 * 4 per unit
and the result is **very important**.
  -> text("Rate is 5 "), italic[text(" 4 per unit and the result is ")], italic[text("very important")], text("*.")
```

These cases are all correct-by-construction under the parser's documented
"nearest closer, no backtracking" rule — the rule itself is what disagrees with
every real Markdown renderer, so the fix is a design change, not a patch.

### Working baseline (must not regress)

```
IN : **bold** alone        -> BOLD[text("bold")], text(" alone")
IN : **a * b** tail        -> BOLD[text("a * b")], text(" tail")
IN : *italic* and **bold** -> italic[text("italic")], text(" and "), BOLD[text("bold")]
```

Also unchanged-by-design and out of scope here: a link title is stored verbatim
and never inline-parsed, so `[**bold** link](url)` shows literal asterisks; and
`**bold**` inside a heading is invisible because the heading face is already
bold (`headingStyle` sets `boldFont` to the heading font).

---

## Reproducing the probes

```
swiftc FEdit/Preview/MarkdownRenderer.swift FEdit/Editor/Theme.swift <driver>.swift -o /tmp/probe && /tmp/probe
```

where `<driver>.swift` is a `main.swift` printing
`MarkdownBlockParser.parse` / `MarkdownInlineParser.parse` trees (same
compile line as `scripts/MarkdownRendererTests`).
