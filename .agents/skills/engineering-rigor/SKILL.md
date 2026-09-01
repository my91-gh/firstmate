---
name: engineering-rigor
description: >-
  Agent-only authoring rigor for ship crewmates writing non-trivial code.
  Load before writing non-trivial code, then follow the matching task-type playbook (feature, refactor, perf; bug-fix defers to diagnostic-reasoning).
  Owns the distilled engineering principles (rule, when it applies, pattern, boundary) and the first-wave task-type step recipes.
user-invocable: false
metadata:
  internal: true
---

# engineering-rigor

Load this before writing non-trivial code, then follow the matching task-type playbook below.
It is the single owner of firstmate's authoring-level engineering rigor: how a crewmate should think and write while producing a change, distinct from the no-mistakes pipeline, which validates the output afterward.

The principles are distilled from pstack (MIT, https://github.com/cursor/plugins/tree/main/pstack, by Lauren Tan).
They are re-expressed here as short harness-agnostic entries, not copied verbatim, and de-referenced from pstack-internal skill and tool names.

How to use it.
Read the principles once so they are in working memory.
Match the task to a playbook in "Task-type playbooks" and follow its ordered steps, which cite the principles by name at each step.
A principle citation must trace to a real choice it changed; citing one you did not act on is noise.

## Principles

Each entry names the rule, when it applies, the pattern, and the boundary that stops it from being applied blindly.

### Core

**Laziness protocol.**
When: refactoring, sizing a diff, or tempted to add abstractions, layers, or signal threading.
Pattern: bias to deletion and the smallest change that solves the problem; keep a flat call hierarchy (if answering a question needs tracing more than about three files or layers, flatten it); consolidate a repeated decision behind one source of truth; question new threading through types, schemas, or pipelines and look for a more direct path.
Boundary: simplest that solves the real problem, not simplest that skips required behavior; a rich interface that hides substantial work is not a deep call chain.

**Foundational thinking.**
When: before writing logic, choosing core types, or sequencing scaffold against feature work.
Pattern: get the data shape right first, because the right shape makes downstream code obvious and a late data-structure change is a rewrite; define core types early and trace every access pattern; do scaffold that every later phase benefits from first (shared types, test infrastructure, CI); ask what concurrent actors share before sharing state.
Boundary: DRY the structure, not every line; three similar statements still beat a premature abstraction; subtract dead weight before laying new foundations.

**Redesign from first principles.**
When: integrating a new requirement into an existing design.
Pattern: redesign as if the requirement had been there on day one instead of bolting it on; read all affected files, ask what you would build from scratch with this requirement known, and propagate the change through every reference (types, docs, rationale); think holistically, deliver incrementally.
Boundary: this preserves option value when a requirement is genuinely foundational; a local addition that does not reshape the design does not need a redesign.

**Subtract before you add.**
When: sequencing an addition, refactor, or rewrite.
Pattern: remove complexity first, then build on the simpler base; sequence removal before construction; delete dead weight, redundant validators, speculative guards, and empty stub references before introducing the new shape.
Boundary: design for observed usage, not speculative edge cases; do not delete behavior the spec still requires.

**Minimize reader load.**
When: reviewing or shaping code that is hard to trace.
Pattern: track two axes, the layers to trace between a question and its answer, and the hidden or mutable state a reader must hold; collapse one-caller wrappers and pass-through layers; shrink state scope (prefer pure functions over mutation, locals over fields, fields over module state, module state over globals); name an invariant once at the boundary, not in every consumer.
Boundary: before adding a layer or a piece of state, it must reduce reader load elsewhere by at least as much; a new reader should answer "where does X come from?" and "what can change X?" quickly.

**Outcome-oriented execution.**
When: a planned rewrite or migration with explicit phase boundaries.
Pattern: optimize for the verifiable end state, not smooth intermediate states propped up by throwaway compatibility code; converge on the target architecture and prove correctness at explicit verification boundaries.
Boundary: intermediate breakage is acceptable only when planned, scoped, and reversible; always run full verification before declaring done.

**Build the lever.**
When: any non-trivial edit, migration, analysis, or check.
Pattern: build the tool that does or proves the work (a codemod, script, generator, or a reusable check) instead of doing it by hand, because the tool reruns for free and is one artifact a reviewer can rerun to confirm the work; do the first unit by hand to learn the recipe, then build the smallest lever that does the rest and make it safe to rerun.
Boundary: the bar is triviality, not repetition; skip the lever only for a couple of obvious edits; build the smallest script that does the job, never a framework.

### Architecture

**Model the domain.**
When: writing stateful logic, or code that branches a lot or repeats a shape assumption across files.
Pattern: encode the domain in a structure (a state machine over scattered booleans, a typed model over loose parameters, a map or registry or discriminated union over branching spread across files, a reducer over ad hoc mutations, a module organized around one body of domain knowledge rather than load-validate-transform-save phases).
Boundary: do not force an abstraction; boring local code stays when it is already clear and unlikely to grow; be skeptical of indirection that removes no branches, no duplicated rules, and no invalid states.

**Boundary discipline.**
When: wiring validation, error handling, or framework adapters.
Pattern: validate, narrow, and handle errors at system boundaries (CLI args, config files, external APIs, network, wire formats); trust internal typed data without re-validation; keep business logic in pure functions the shell just calls; expose domain concepts across a boundary, not the boundary's private representation.
Boundary: if data is not crossing a boundary right now, added validation is redundant; keep general-purpose mechanism inside and special-purpose policy at the edge.

**Type-system discipline.**
When: designing types or a signature in any statically typed language.
Pattern: make illegal states unrepresentable (model variants as sum types, not a bag of optional fields that admits contradictory combinations); build a type up from the values you want rather than carving a looser type with runtime checks; brand semantic primitives so two IDs of different meaning are not interchangeable; parse external data into typed models at the boundary; do not lie to the checker with casts or unsafe coercions; make matches exhaustive so a new variant is a compile error; derive types from an authoritative schema instead of hand-rolling a parallel copy.
Boundary: strengthen a type only where partiality actually appears; prefer total functions; extra precision that prevents no failure costs reuse and buys no safety.

**Make operations idempotent.**
When: designing commands, lifecycle steps, or loops that run amid crashes, restarts, and retries.
Pattern: design every state-mutating operation to converge to the same end state regardless of how many times it runs or where a prior run crashed; scan for existing state and adopt or reconcile it; compare by content, not creation order; use PID-based stale-lock detection.
Boundary: if the outcome depends on what partial state a prior run left behind, the operation needs a reconciliation step before it is safe to retry.

**Migrate callers then delete legacy APIs.**
When: introducing a new internal API while old callers still exist.
Pattern: inventory callers, migrate them, and delete the old API in the same refactor wave; update tests to assert the new contract and delete tests that only protected pre-refactor internals.
Boundary: applies when no external user depends on backward compatibility and the project can absorb coordinated breaking changes; treat a temporary adapter as exceptional and time-boxed, not default architecture.

**Separate before serializing shared state.**
When: concurrent actors might write the same file, branch, key, or object.
Pattern: first ask whether they truly need one shared mutable object; if not, give each actor its own owned file, key, branch, or directory and merge only at the read or reporting boundary; only when one shared write target is a real invariant, serialize access structurally (a lockfile, sequential phases, a single-writer owner, atomic compare-and-swap).
Boundary: instructions and conventions ("take turns") are not concurrency control; treat "we need a lock" as a design smell to check, not the default answer.

### Verification and craft

**Prove it works.**
When: after any task, before declaring done; and when reviewing what a change could break beyond its own diff.
Pattern: verify against the real artifact by running the actual path end to end, not a proxy, a self-report, or "it compiles"; check process liveness and real values directly, not through derived state; when verifying delegated work, inspect the actual diff and runtime behavior, not the delegate's summary; script the check when you can so a reviewer can rerun it.
Boundary (blast radius): for a change whose safety rests on one fact ("this only drops already-dead entries"), find that fact and get it as far down the evidence ladder as is cheap: asserted, pointed at a `file:line`, shown the bad case cannot reach, run against the real code, reproduced in the running system; any safety fact you cannot push to "run it" cheaply, mark unproven rather than rounding up.

**Fix root causes.**
When: debugging.
Pattern: reproduce first (if you cannot reproduce it you cannot verify the fix), ask why until you reach the cause, and fix it there; grep for the same pattern and fix every instance, not just the reported one; when stuck, instrument and read the real error instead of guessing; when something fails only after a restart, suspect stale persistent state before code.
Boundary: resist adding a nil check or guard that only silences a symptom; if a workaround needs a paragraph-long comment to justify it, the code is wrong.

**Sequence work into verifiable units.**
When: multi-step work (sweeps, migrations, runs of similar edits) and how you stack commits.
Pattern: order work as small units that each end in a check, and verify each before starting the next rather than batching edits and verifying once at the end; rebase onto clean trunk first so each check measures against the real baseline; order the delivery so the sequence proves itself (the failing test first, then the fix, so a reviewer sees the problem and the proof).
Boundary: a break caught at the unit that caused it is cheap; a break caught after a batch is buried on top of a broken base.

**Guard the context window.**
When: context is filling with large outputs, long files, repeated reads, or fan-out planning.
Pattern: route verbose outputs and large documents to a subagent and keep summaries, not raw payloads, in the main thread; do not read what you will not use; keep frequently used templates and references inline where they are needed on every invocation; cap files and scope per phase.
Boundary: context spent inside a session cannot be reclaimed, so every token that enters should earn its place.

**Encode lessons in structure.**
When: you catch yourself writing the same instruction a second time, or notice a recurring correction.
Pattern: encode the rule as the strongest available mechanism (an unrepresentable state, then a lint or banned API that fails CI, then a canonical helper, then a runtime check) instead of more prose, and delete the instruction once the mechanism enforces it.
Boundary: reserve prose for rules that genuinely require judgment, and then make the instruction prominent with an example of the failure mode; do not paper over a structural fix with a note.

**Exhaust the design space.**
When: a novel interaction or architectural decision with no precedent in the codebase.
Pattern: build two or three structurally distinct prototypes or sketches and compare them side by side before committing; a second flavor of the first shape does not count.
Boundary: does not apply to mechanical implementation with an established pattern, a bug fix or refactor with a clear target, or a decision where constraints already dictate one viable approach.

**Design the boundary first (architect).**
When: code that crosses a function, module, or service boundary, where jumping straight to code would lock in the wrong shape.
Pattern: before writing bodies, ground yourself in every system the change touches, write the caller's intended usage first, then sketch the types, signatures, and module map it implies; treat the sketch as the contract and fill in against it; when a requirement the sketch did not anticipate appears, surface whether the sketch was wrong rather than bolting the fix on.
Boundary: skip for genuinely greenfield work with no surrounding system to integrate; when implementation keeps producing the same shape of workaround, the sketch is wrong, so re-ground and redesign rather than patching it.

**Defer approval to firstmate (autonomy).**
When: tempted to stop and ask "should I do X?" on reversible work.
Pattern: firstmate, not the crewmate, owns the approval model through `yolo` and `ask-user-authority`; do the reversible work, make a reasonable decision, and report the result and rationale so firstmate and the captain can course-correct after the fact.
Boundary: this does not expand the crewmate's authority; a merge, an irreversible action, a security-sensitive choice, or a product or contract expansion is escalated through the brief's status protocol (append `needs-decision:` and stop), never decided by the crewmate.

## Task-type playbooks

Match the task to one playbook and follow its ordered steps.
Each step names the principles it applies.
If a step genuinely does not apply, note why rather than dropping it silently.
The playbook governs how you build; the brief's delivery contract (no-mistakes, direct-PR, or local-only) governs how the result ships.

### bug-fix

Do not duplicate the bug procedure here.
Load and follow the `diagnostic-reasoning` skill, which owns end-user-aligned reproduction, causal separation, and disconfirming evidence.
`engineering-rigor` adds only this framing: reproduce end to end first (**fix root causes**), trace to the root instead of guarding the symptom (**fix root causes**), fix the pattern across every instance, prove the behavior before and after on the real artifact (**prove it works**), and turn the reproduction into a regression test delivered failing-then-fixed (**sequence work into verifiable units**).

### feature

New or changed behavior, built from a named data shape.

1. Ground the affected subsystem: read what the feature touches before designing (**foundational thinking**).
2. Name the data shape first, and choose its organizing structure (a state machine, a typed model, a table or registry) before writing logic (**foundational thinking**, **model the domain**).
3. Design the boundary the feature crosses before filling in bodies: write the caller's intended usage, then the types and signatures it implies (**design the boundary first**).
4. Build the smallest change that delivers the behavior; subtract dead weight first and resist speculative layers or validators (**subtract before you add**, **laziness protocol**).
5. Keep guards at the boundary and the new logic pure and internally typed (**boundary discipline**, **type-system discipline**).
6. Prove it on the matching surface by running the actual feature path end to end, not "it compiles"; a wrong-surface or inconclusive check is not a pass (**prove it works**).
7. Add tests for the behavior and the edge cases the types cannot already exclude, and deliver in small ordered commits that each stay green (**sequence work into verifiable units**).

### refactor

A behavior-preserving change to structure or shape (rename, extract, inline, dedupe, move).
If the cleanup reveals a missing feature or a real bug, split it out and route it to the feature or bug-fix playbook; a refactor that smuggles in a behavior change loses its safety net.

1. Pin the behavior contract first: write a characterization test, snapshot, or equivalence harness that captures current behavior before any structure moves (**prove it works**). Type check and lint are not a pin.
2. Name the structure the code is missing, so the reshape deletes branches or invalid states rather than adding indirection (**model the domain**).
3. Name the target shape: what the module layout, types, and call graph would be if built today, and design across any boundary the move crosses (**redesign from first principles**, **foundational thinking**, **design the boundary first**).
4. Subtract before you add: delete dead weight, collapse one-caller wrappers, drop redundant validators and orphan references before introducing the new shape; ship the smallest change that reaches the target (**subtract before you add**, **laziness protocol**).
5. Move in small behavior-preserving steps that each keep the pin green; for API reshapes, migrate every caller and delete the old API in the same wave, with no compatibility shim (**migrate callers then delete legacy APIs**, **sequence work into verifiable units**).
6. Prove behavior is unchanged on the real artifact, ideally with an equivalence check that diffs old against new output; own that verification yourself rather than trusting a delegate's summary (**prove it works**).
7. Confirm the change earns its place: fewer layers to trace, less hidden state, fewer indirections without a second consumer; if the diff does not lower reader load, revert it (**minimize reader load**).

### perf

A measured slowness to trace and improve against a baseline.
Tie every change to a measurement; do not read source instead of measuring.

1. Capture a baseline measurement of the real slow path before changing anything; without it there is no win to prove (**prove it works**).
2. Ground hypotheses in the baseline: find where the cost actually is instead of claiming a ceiling from reading code (**foundational thinking**, **fix root causes**). The cheapest win is often deleting work that nobody consumes, which the profiler shows as slow but never shows as deletable.
3. Make one change at a time and re-measure against the baseline after each; if the change crosses a boundary, design that boundary first (**sequence work into verifiable units**, **design the boundary first**).
4. Compare the artifacts and prove the win with the numbers; an inconclusive or wrong-surface measurement is not a pass (**prove it works**).
5. Keep the change the smallest one that captures the measured win, and cite the baseline number, the post-change number, and the delta (**laziness protocol**, **minimize reader load**).

## Maintaining this file

This skill is the single owner of firstmate's authoring rigor and its first-wave task-type playbooks.
Keep the principle entries short (rule, when, pattern, boundary) and harness-agnostic; the durable design rationale lives in `docs/engineering-rigor-approach.md`, not here.
Add a new playbook only when a task type recurs and is not already owned elsewhere (bug diagnosis stays in `diagnostic-reasoning`).
Prefer rewriting or pruning existing entries over appending new ones, and keep each playbook step citing the principle it applies.
