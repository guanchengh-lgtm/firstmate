Role: verifier
# Definition of done
Delivery contract: mode=no-mistakes
The verifier works on branch `fm/evidence-verifier-brief`.
The first command in the worktree is `git checkout fm/evidence-verifier-brief`.
If Git says another worktree has this branch checked out, report a Firstmate handoff defect.
Append `blocked: task branch fm/evidence-verifier-brief is checked out in worktree <path>` and stop; never ask the captain.
The fresh verifier drives no-mistakes by responding to its gates, not by implementing fixes.
It follows the guidance no-mistakes itself provides for the mechanics: `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, it makes `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; it retains direct requirements instead of substituting a diff summary, and excludes generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Carry verbatim into `--intent`: Manufactured breakage (required): for every test file this branch adds or changes, break the code under test on one line (flip a value, delete a branch), run that test, observe it fail, restore the line, confirm `git status --porcelain` is empty, run it again green. Record each as a `tested` entry that starts with `breakage: <test-file> subject <file:line> selector <sel> red <artifact>`. After every restore, confirm porcelain is empty before the next breakage and record the final clean state as the last `breakage:` entry. A changed test with no red observation is a blocking pipeline finding, not an ask-user finding. The firstmate hook in touch 3 is advisory.
Mutation runs inside the test-step pipeline worktree, never in the verifier tree.
The verifier does not hand-edit, commit, or fix findings while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never the verifier's to answer: escalate to firstmate and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), the verifier appends `done: PR {url} checks green` and stops.

# Task
Validate the stopped builder worktree handoff.

# Rules
1. Never push to the default branch. Never merge a PR.
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state}: {one short line}" >> '/Users/AI/.no-mistakes/worktrees/edb446952c22/01M18ZCADT4Y1FS47J1HE4WR0C/tests/.brief-evidence-home/state/evidence-verifier-brief.status'`
   States: working, needs-decision, blocked, paused, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   A mid-task `working:` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined `done:` gate under Definition of done.
   Use `paused: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
5. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append `needs-decision [key=<decision-slug>]: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [key=<decision-slug>]: {how it cleared}` yourself as you resume.
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.
