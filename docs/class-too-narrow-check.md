# Class-too-narrow claims check

This note records what the class-too-narrow refuse-hook can see, and what it cannot.
`bin/fm-class-too-narrow-check.sh`'s header owns the claims JSON fields, the rule ids, structural exit 2, exact-count regression flags, and residual coverage.
Do not copy that contract here.

## What it catches

A new class claims file must state a property in `shape`, name two or more instances in different clothes, and fail when a slash-command or ISO date in that named shape is missing from an instance.
The 2026-08-22 historical instance named progress-lost-on-session-end as `/stow` reset-safe and shipped as https://github.com/guanchengh-lgtm/firstmate/pull/29.
That ship stays.
This check is so the next class is not named that way.

## What it does not catch

- English "broader than" cannot be 100%.
- The check sees a slash-command or ISO date binder in `shape` (or `named_as` / `class_id` / `class`) that an instance does not share.
- It cannot see a class whose instance strings stay inside the named clothes while the true mechanism is still broader.
- It cannot judge paraphrase.
- Claims files that predate this check remain as they shipped, including the PR 29 stow-open-lock claims used as the derived historical fixture.

Regression coverage lives in `tests/fm-class-too-narrow-check.test.sh`.
The claims file is [`verification/class-too-narrow-check-claims.json`](verification/class-too-narrow-check-claims.json).
