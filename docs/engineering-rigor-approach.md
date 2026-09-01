# Approach: an `engineering-rigor` skill and task playbooks for firstmate

Design record for the decision to borrow pstack's authoring-level rigor into firstmate.
Kept as the durable trace of the adopted approach, not as an operating contract.
The operating contract lives in the skill itself (`.agents/skills/engineering-rigor/SKILL.md`); this document explains why that skill exists and how it was scoped.

## 1. Why

firstmate validates the OUTPUT of a crewmate's work (the no-mistakes pipeline runs review, test, lint, docs) but says almost nothing about HOW a crewmate should think and write while producing it.
That authoring layer is currently delegated implicitly to the harness.
pstack (Cursor plugin, MIT, by poteto/Lauren Tan) fills exactly that gap with a set of harness-agnostic engineering principles and task-type recipes.
We adopt the part of pstack that is least redundant with firstmate and most valuable: the authoring rigor.
We do NOT adopt its orchestration, delivery, or parallelism layers, which duplicate firstmate's fleet model, nor its Cursor-locked packaging and multi-model routing.

## 2. What we take, and how

Per the analysis, two things are worth borrowing, and neither ports verbatim.

### 2a. The ~24 `principle-*` skills -> one consolidated `engineering-rigor` skill

pstack ships each principle as its own loadable SKILL.md.
firstmate's skill discipline (see `firstmate-coding-guidelines`: trigger hygiene, one-owner rule, AGENTS.md size discipline) argues against importing 24 separate skills.
We CONSOLIDATE the principles into a single agent-only reference skill, `engineering-rigor`, that a ship crewmate loads before writing non-trivial code.
Content is DISTILLED (not copied verbatim): each principle becomes a short, harness-agnostic entry (the rule, when it applies, the pattern, the boundary), stripped of Cursor frontmatter fields and de-referenced from pstack-internal skill names.

Principles distilled (grouped as pstack groups them), keeping only what is genuinely harness-agnostic:

- Core: laziness protocol (bias to deletion / smallest change), foundational thinking (types and data shape first), redesign from first principles, subtract before you add, minimize reader load, outcome-oriented execution, build the lever (the tool that proves it is the artifact).
- Architecture: model the domain (encode state in a structure, not scattered conditionals), boundary discipline (guards at edges, pure core), type-system discipline (make illegal states unrepresentable, parse at boundaries), make operations idempotent, migrate callers then delete legacy APIs, separate before serializing shared state.
- Verification and craft: prove it works with runtime evidence (not assertion), guard the context window, fix root causes, sequence verifiable units, encode lessons in structure, exhaust the design space (competing prototypes for novel decisions).

Deliberately dropped or reframed because firstmate already owns them at a higher layer or they are Cursor-specific:

- `never-block-on-the-human` is reframed, not imported: firstmate already owns autonomy through `yolo` and `ask-user-authority`, so the crewmate defers to firstmate's approval model (reversible work proceeds; merges, irreversible actions, and security-sensitive choices stay with the captain).
- Anything referencing Cursor built-ins, `cursor-team-kit`, graphite, `/loop`, or Cursor subagents.

Attribution: the skill credits pstack (MIT, https://github.com/cursor/plugins/tree/main/pstack) as the source of the distilled principles.

### 2b. The craft skills (architect, blast-radius, interrogate) -> re-expressed on firstmate primitives

These depend on Cursor mechanics (native multi-model, Cursor subagents), so the IDEA ports and the implementation does not.

- `architect` (settle caller usage, types, and module shape before writing across a boundary) is folded into `engineering-rigor` as a "design the boundary first" principle entry; no separate machinery.
- `blast-radius` (prove-by-running what a change can break) is folded in as a verification rule (prove with runtime evidence, not assertion, and get each safety fact as far down the evidence ladder as is cheap).
- `interrogate` (multi-model adversarial diff review) is a genuinely new capability.
  It is re-expressed natively LATER as an optional firstmate move: firstmate spawns review crewmates on different harnesses (via `quota-array-dispatch`) to attack a diff, or an extra adversarial review pass inside no-mistakes.
  Scoped as a follow-up, not part of this first skill.

## 3. What a "playbook" is, and how it materializes here

In pstack a playbook is a deterministic, ordered step-recipe for one TYPE of task (bug-fix, perf, refactor, feature, forensics, prototype-to-settle-a-fork).
`poteto-mode` matches a request to a playbook, copies its steps in, and wires the other skills at each step, all inside one self-orchestrating agent.

In firstmate the equivalent lives at the crewmate authoring layer, never at the fleet layer.
firstmate already has playbook-shaped things without the name: the task lifecycle (`AGENTS.md` section 7), and `diagnostic-reasoning` (the de-facto bug playbook).

### Chosen structure: playbooks live inside the `engineering-rigor` skill

The approach considered three homes for the playbooks: a separate companion skill, sections inside `engineering-rigor`, or brief templates injected by `bin/fm-brief.sh`.
We put them as a "Task-type playbooks" section INSIDE `engineering-rigor`, for three reasons consistent with `firstmate-coding-guidelines`.

- Consolidation over proliferation: the principles and the playbooks are one body of knowledge loaded at the same moment (a ship crewmate, before writing non-trivial code), so one skill means one load, one classification entry, and one trigger.
- One owner: each playbook step cites the principle entries in the same file, so the recipe and the principles it leans on cannot drift apart across files.
- Simplest robust path: per-type `fm-brief.sh` template variants would add script surface and its own tests while duplicating the recipe text; a skill the crewmate loads and matches to its task type is the direct path, and the brief only needs to point at it.

Each playbook is an ordered step recipe that cites the principle entries at the right moments (name the data shape, design the boundary, subtract first, prove with runtime evidence, regression test).

### Playbooks in the first wave

Kept small and non-redundant with what firstmate already owns.

- bug-fix: reuse the existing `diagnostic-reasoning` skill; `engineering-rigor` adds only a thin pointer (reproduce end to end first, root-cause, prove before and after, turn the repro into a regression test), it does not duplicate the procedure.
- feature: name the data shape first, design the boundary, smallest change, prove it, test.
- refactor: behavior-preserving; pin the contract; subtract before adding; migrate callers then delete; prove no behavior change.
- perf: baseline first, one change at a time against the baseline, prove the win.
- Later (optional): prototype-to-settle-a-fork, forensics, visual-parity.

## 4. Trigger and wiring

A skill nothing loads is dead weight (`firstmate-coding-guidelines`, trigger hygiene), so the load trigger is wired deterministically rather than left to memory.
`bin/fm-brief.sh` adds one line to every ship brief instructing the crewmate to load `engineering-rigor` before writing non-trivial code and to follow the matching task-type playbook.
`AGENTS.md` section 11 (crewmate briefs) carries the one-line pointer to that behavior; `AGENTS.md` section 13 lists the skill in the agent-only reference catalog with its precise trigger.

## 5. Delivery and constraints

- This is firstmate shared tracked material (`.agents/skills/`, `docs/`, `bin/`), so it ships through firstmate's own no-mistakes pipeline and PR path, with the captain owning the merge (`AGENTS.md` section 1).
- The crewmate MUST load `firstmate-coding-guidelines` before editing.
- Every new SKILL.md must be classified in the documentation-audience inventory (`docs/documentation-audiences.json`, enforced by `bin/fm-doc-audience-check.sh` and `tests/fm-documentation-audiences.test.sh`) or CI stays red; the skill is classified `agent-runtime` and this design record `maintainer-architecture`.
- The brief change is covered by an added assertion in `tests/fm-brief.test.sh`.
- Scope discipline: consolidate, do not import 24 skills; re-express craft skills, do not copy Cursor mechanics; keep the first playbook wave to bug-fix, feature, refactor, and perf.

## 6. Out of scope (explicitly not adopted)

Cursor plugin packaging and `/add-plugin`; Cursor multi-model panel routing (firstmate has `crew-dispatch` and `quota-array-dispatch`); graphite stacked PRs (firstmate is one PR per task); Cursor subagent orchestration and the `swarm`/`arena`/`orchestrate`/`autopilot` fleet skills (firstmate owns the fleet); the multi-model `interrogate` capability (a later follow-up per section 2b); the benny Slack-issue automation.
