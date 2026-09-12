# Record link proposal

Source commit: 3207da391e841cb3655a25e97512855b23407996
Tool: 20ec6ba53bd21070652e30d3ebeac81ff5fac192bf202d07bbf23a83937f8145
Scanned: 14

## Classification

- eligible: 9
- already-linked: 2
- owner-exempt: 0
- generated: 1
- raw: 1
- active-writer: 1
- needs-review: 0

## Proposed edits

### decisions/cyc-a.md
authored tree decisions/
Related: supersedes: none; cites: [[decisions/cyc-b.md]]; relates: none

### decisions/cyc-b.md
authored tree decisions/
Related: supersedes: none; cites: [[decisions/cyc-a.md]]; relates: none

### decisions/latin1.md
authored tree decisions/
Related: supersedes: none; cites: none; relates: none

### decisions/missing.md
authored tree decisions/
Related: supersedes: none; cites: none; relates: none

### decisions/new.md
authored tree decisions/
Related: supersedes: [[decisions/old.md]]; cites: [[decisions/old.md]]; relates: none

### decisions/old.md
authored tree decisions/
Related: supersedes: none; cites: none; relates: none

### task-a/brief.md
authored brief.md
Related: supersedes: none; cites: [[decisions/new.md]], [[decisions/old.md]]; relates: [[task-a/report.md]]

### task-a/report.md
authored report.md
Related: supersedes: none; cites: [[task-a/brief.md]]; relates: [[task-a/brief.md]]

### task-self/report.md
authored report.md
Related: supersedes: none; cites: none; relates: none

## Questions

- decisions/badfooter.md:3: malformed existing Related footer
- decisions/cyc-a.md:3: supersession cycle
- decisions/cyc-b.md:3: supersession cycle
- decisions/missing.md:3: missing target
- task-self/report.md:3: self-target

## Unresolved

[{"line":3,"path":"decisions/missing.md","reason":"missing target","text":"See decisions/nowhere.md.","token":"decisions/nowhere.md"}]

## Ambiguous ids

None.

## Excluded

[{"classification":"raw","path":"raw/dump.md","reason":"byte-preserved or generated-adjacent path"},{"classification":"active-writer","path":"task-w/report.md","reason":"live status working"},{"classification":"generated","path":"wiki/gen.md","reason":"under wiki/"}]

## Existing footers

[{"canonical":false,"line":"Related: cites=foo","path":"decisions/badfooter.md"},{"canonical":true,"line":"Related: supersedes: none; cites: none; relates: none","path":"decisions/linked.md"}]

## Unknown metadata

None.

## Partial replacements

None.

## Cycles

[["decisions/cyc-a.md","decisions/cyc-b.md","decisions/cyc-a.md"]]

## Path shadows

None.

## Slug collisions

[{"paths":["task-a/report.md","task-self/report.md","task-w/report.md"],"slug":"report"}]
