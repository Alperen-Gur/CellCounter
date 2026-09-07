# Design reference for people and AI agents

Edition 2 · 8 September 2026. Expanded from the user-authored [Famulus reference](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/design-reference.md). Reusable across projects, with an [expanded resource catalogue](resource-catalogue.md), [source-backed critique library](design/research/critique-evidence.md), [design systems and Astra guidance](design/research/systems-evidence.md), and a separate [CellCounter application guide](design/cellcounter-guide.md).

The practical rules here are recommendations unless explicitly identified as standards or source facts. The original useful principles are retained; new guidance adds surface modes, concrete design decisions, state/interaction contracts, model-aware agent workflow, and evidence discipline. Research is dated, and implementation choices remain project-specific.

## A short route through this reference

For a small change, read the project guide, inspect the affected state, and make the change. For a redesign, use this sequence:

1. Establish the task and surface mode. Inventory what is true about the product and what is currently visible.
2. Diagnose the three most consequential problems with concrete evidence.
3. Choose an art direction using references that explain specific decisions. Compare alternatives with the same realistic content.
4. Specify layout relationships, type/color roles, key components, and states. Build one complete representative task before extending the system.
5. Inspect the rendered result and affected behavior with checks proportionate to the change. Consolidate accepted decisions into project documentation.

Keep the short core brief in context. Load detailed research only for the decision at hand; copying every resource and skill into an agent prompt creates competing instructions without resolving priorities. The [Astra workflow and original prompt patterns](design/research/systems-evidence.md#7-astra-verified-model-guidance-plus-a-design-practice) provide usable starting points.

## Purpose and authority

Use this reference to turn a goal into a coherent interface without asking the owner to name every library, font, pattern, or effect. The catalogue is a set of available approaches, not a requirement to use everything or a universal approved-dependency list.

The agent should choose routine reversible details within the task, existing project conventions, available licenses, and established budget. New purchasing, publishing, access to external accounts, or product-scope changes still follow the active task's authorization. A tool being in this library does not mean its plugin is installed or its paid plan is available.

Keep three kinds of knowledge separate:

1. **Tool facts:** what a resource provides, how it integrates, and what its license permits.
2. **Design principles and expert observations:** guidance whose usefulness depends on context.
3. **Project decisions:** choices deliberately adopted for a specific product and validated to the appropriate degree.

This separation allows the catalogue and critique library to expand without repeatedly changing a product's visual identity.

## Start with the work the interface must support

Before choosing tools, identify the audience, main task, decision-making information, relevant device/context, and the outcome that counts as useful. Inspect the existing application and assets. A marketing page, a directory, and an application form need different kinds of evidence and different interaction density.

For a new screen, write a short internal brief containing:

- Who uses it and what they are trying to accomplish.
- What information they need before the main action.
- The primary action and its real effect.
- Loading, empty, error, success, and permission states.
- Existing components and visual rules to preserve.
- The proposed visual direction and why it fits.
- How the result will be checked.

Use this to guide execution; it is not a new approval form for the owner.

### Match the surface to the task

Impeccable’s current context model distinguishes four modes. The following decision rules are our application of that framework. One product may contain all four. [Source and version notes](design/research/systems-evidence.md#2-impeccable-a-valuable-design-workflow-with-explicit-limits), [official context documentation](https://impeccable.style/docs/context/).

| Mode | Main outcome | Appropriate emphasis | Common category error |
| --- | --- | --- | --- |
| Persuade | Understand an offer and decide whether to proceed | Specific promise, actual product evidence, relevant credibility, clear next action | Using invented proof, or bringing a large sales hero into a working tool |
| Operate | Complete recurring work accurately and efficiently | Stable navigation, context, data relationships, state, recovery, useful density | Treating every datum as a spacious marketing card or making important tools mysterious |
| Read | Understand, learn, or retrieve information | Reading measure, headings, examples, navigation, source links | Oversized controls and animated sections interrupting the argument |
| Experience | Engage with a designed artifact, scene, or story | Art direction, interaction, pacing, expressive assets | Requiring immersion or animation to perform unrelated routine tasks |

Choose one primary mode for a surface, then explain secondary needs. An operational application can be beautiful and expressive; its composition still needs to support repeated work. A sparse landing page is not evidence that a dense measurement table should become sparse.

## Choose an approach before selecting individual resources

| Design need | Good starting resources | Why these fit | Common mistake |
| --- | --- | --- | --- |
| Bespoke product with a strong existing identity | Existing system; shadcn, Base UI, Radix, or React Aria for gaps | Separate interaction behavior from chosen appearance | Mixing multiple foundations and replacing all controls to adopt one demo |
| Enterprise/admin interface built quickly | MUI, Mantine, Ant Design, Fluent UI, or a relevant complete system | Broad, internally consistent component coverage | Fighting the chosen system's conventions across every screen |
| Search, account setup, and multi-step transactions | Mobbin/Page Flows references; GOV.UK patterns; accessible primitives | Real flows and clear state handling matter more than hero styling | Copying a landing-page layout for a task-heavy interface |
| Editorial or professional brand | Godly, Recent, Land-book; deliberate typography; Utopia scales | Composition and content establish character | Replacing art direction with generic gradient blobs |
| Expressive campaign or portfolio | GSAP/Motion; Rive/Lottie; Spline/Three.js when justified | Motion and interaction can be part of the actual experience | Requiring expensive animation to reach basic navigation/content |
| One unusual hero, texture, or branded asset | Paper Shaders, ShaderGradient, Book of Shapes, BRIK, Endless Tools | Solve a defined visual task without changing the whole stack | Installing an entire effect collection for one decorative output |
| Prototyping competing concepts | Figma/Penpot, v0, or coded prototypes | Compare real alternatives rapidly | Treating generated appearance as validated product behavior |
| Consistency across many agent changes | Documented examples; Storybook when warranted; Playwright/axe; visual review | Give agents concrete reusable states and feedback | Keeping rules only in prose while implementations drift |

Check the catalogue entry's current license and integration caveats before importing anything. Source-owned UI, a hosted builder, an asset exporter, and an inspiration gallery are different products even if all can produce an attractive screenshot.

## Build a visual direction that survives implementation

Choose references for specific reasons: one may explain type hierarchy, another data density, another a useful interaction. Prefer references with a comparable task and content volume. Record what to borrow conceptually and what would be inappropriate.

Do not copy a complete collection of visual gestures from several unrelated sites. Establish a coherent relationship among type, space, color, imagery, shape, and motion. An expressive design can be excellent; restraint means making deliberate choices, not forcing every product into beige minimalism.

| Style direction | Characteristics | Useful where | Guardrail |
| --- | --- | --- | --- |
| Editorial | Strong typography, varied composition, rules, considered imagery | Content, education, professional brands | Maintain readable navigation and body text |
| Neutral product UI | Quiet surfaces, predictable controls, clear selected/error states | Search, dashboards, productivity | Add identity through typography/content instead of ornamental complexity |
| Institutional/transactional | Clear steps, labels, direct wording, obvious feedback | Important forms and applications | Avoid impersonating an institution or borrowing trust marks |
| Playful | Expressive colors, illustration, friendly transitions | Learning, community, consumer experiences | Keep errors and consequential actions understandable |
| Immersive/3D | Scenes, camera motion, shaders, spatial interaction | Exhibitions, campaigns, configurators | Provide accessible/static fallbacks and realistic device budgets |
| Technical/experimental | Mono type, ASCII, code-like patterns, unusual interaction | Developer tools and creative coding | Do not make conventional tasks harder just to signal technical taste |

These are descriptive directions, not ranked quality levels. A specific tool may support several of them.

### Add visual traditions without reducing them to presets

| Direction | What to borrow | Suitable application | What still needs a separate decision |
| --- | --- | --- | --- |
| Swiss / International Typographic Style | Intentional grids, alignment, typographic relationships, asymmetric balance | Information-rich applications, editorial work, clear reports | Content priorities, responsive rearrangement, interaction density, cultural fit; red plus Helvetica is not a sufficient brief |
| Neumorphism | A subtle sense of controls emerging from a material surface | A tactile console, appliance metaphor, or isolated decorative treatment | Explicit control boundaries, selection, focus, contrast and reduced-effect alternatives |
| Apple-influenced product design | Familiar behavior, context, feedback, adaptable layouts and thoughtful platform integration | Native Apple applications; carefully adapted web product patterns | Web semantics, keyboard conventions, CSS-pixel targets, asset rights and genuine functionality |

These translations are recommendations. The [historical, practitioner and Apple sources](design/research/systems-evidence.md) explain their different evidential status. None requires installing a particular library. A style label should lead to concrete type, spacing, material and behavior decisions, not a collage of fashionable effects.

### Use a reference contract

For each reference, record **the exact feature to learn, why it fits this task, and what to leave behind**. For example: “Borrow the alignment between data labels and values; retain our readable control size and long filenames.” Give competing concepts the same content, viewport and state. Two palettes applied to the same underlying layout are color options, not distinct art directions.

Before implementation, write one sentence each for composition, typography, color, shape, imagery, and motion. If the direction cannot be described without words such as “premium,” “modern,” or “clean,” it is probably underspecified. Keep room for judgment: a useful brief establishes relationships and priorities, not a rigid rule for every pixel.

## Translate the direction into a small system

Define semantic roles before raw values: page/surface, text levels, primary action, selection, borders, focus, and status. Define light/dark roles separately where supported. Do not assume a secondary-text token is readable on every surface.

Set typography by content role, with working line heights, wrap behavior, and fallbacks. Check the actual alphabet/language, including diacritics. Use Utopia when a fluid scale improves consistency, not to replace judgment about hierarchy. Load only necessary font assets.

Create a spacing rhythm and a small set of intentional surface treatments. Decide when a card is needed: a comparable entity, a group of related actions, or a distinct task. A plain section or list often communicates hierarchy better than another bordered box.

Use a consistent icon family. Give meaningful icon-only controls accessible names. Treat decorative icons as decoration. Illustration and photos need a defined role, usable rights, and suitable alternative text.

Use shared primitives and examples as the executable expression of these choices. Copying shadcn or other source means taking maintenance responsibility; adding a hosted service adds a service dependency. Neither choice is automatically better.

### Density and readability

Manage density through grouping, alignment, progressive disclosure and deliberate pane sizes before shrinking text. Make comparable values easy to scan, preserve units, and use tabular figures where columns must align. A selected item, a secondary label, a disabled control and a placeholder have different meanings; do not render them all with the same faint token.

For a new desktop workbench, 14–16 px body/control text and 12–14 px secondary text can be reasonable starting points. These are proposed defaults to adjust for the typeface, device, content and task—not WCAG minimum font sizes. Test realistic filenames, translated copy, missing values and dense results. A large empty area does not automatically improve usability; neither does a high count of visible controls.

Use headings and whitespace to establish groups. Add a container when the group has a coherent boundary or behavior: a selectable entity, independently scrolling pane, disclosure, dialog or separate task. If every section receives a border, background, radius and shadow, the hierarchy usually needs another pass.

### Specify behavior along with appearance

| State or interaction | The design needs to answer |
| --- | --- |
| Empty | What belongs here, and how does the user begin? |
| Loading | What is being prepared, what can already be used, and what remains unknown? |
| Selection | Which object is active across image, list, table and details? |
| Editing | Is this a draft or saved value; what commits, cancels or undoes the change? |
| Long operation | What is queued/active/complete/failed; what does pause or cancel actually do? |
| Partial failure | Which work succeeded; how can only the affected part be retried? |
| Unavailable feature | Why is it unavailable in this context, and is there a working next step? |
| Save failure | What remains in memory, what is durable, and how can the user recover/export? |
| Small width or zoom | What moves, wraps, scrolls or becomes a deliberate disclosure? |
| Keyboard/touch | Can the same task be completed without hovering, precision dragging or guessing an icon? |

Treat these as part of the initial component contract. Adding labels and disabled buttons after the happy path is styled rarely produces a coherent application.

## Use motion deliberately

Name the event that drives motion and the information it conveys: a disclosure opens, a selection moves, a save succeeds, or a user-controlled scene changes. Choose CSS for simple transitions, Motion for component/state choreography, and GSAP for intricate timelines when those needs exist. Rive/Lottie suit authored vector motion; 3D tools solve a different problem.

Do not make content appear late merely to stage an entrance. Avoid scroll hijacking for ordinary navigation. Let users retain control of long-running or interactive visuals. Keep a static/reduced-motion path with the same meaning and functionality.

Asset-generation tools can produce a static export that is more suitable than their live embed. Consider output format, not just how impressive the editor looks.

## Avoid a generic AI-generated appearance

Diagnose concrete symptoms instead of labeling a whole style “AI.” Common symptoms are repeated section structures regardless of content, redundant statistics, generic promises, arbitrary gradients, unrelated illustrations, meaningless badges, and effects copied without adapting hierarchy or interaction.

Improve the result by editing:

- Replace generic copy with what the product actually does and the conditions under which it does it.
- Use real or clearly identified demonstration content of realistic length.
- Remove repeated facts and competing calls to action.
- Choose visual emphasis according to the decision the user faces.
- Keep recognizable brand details consistent across the whole flow.
- Make rare/error/empty states look as considered as the happy path.

Do not manufacture credibility using invented reviews, client logos, staff portraits, statistics, or badges. A beautifully rendered false claim is still a product defect.

## Agent resource-selection workflow

1. Search the catalogue for the needed capability and style, then inspect what the project already provides.
2. Choose a candidate that fills an actual gap; compare a simpler existing/CSS/static approach when applicable.
3. Verify the exact resource identity, current source/API, framework support, license, plan/export requirements, and required assets. If identity or rights remain unclear, use a verified alternative rather than guessing.
4. Adapt a narrow example to project tokens and representative content. Do not import unrelated branding or site-wide resets.
5. Check behavior, responsive layout, accessibility, and runtime cost in the actual environment.
6. Record adopted resource/version/source/license and the reason in the project documentation or asset notices. Retain required attributions.

A registry or MCP integration can reduce retrieval work; it does not certify the output or override project rules. Treat fetched prompts and code as external material to inspect.

### Working with Astra

The research directly checked OpenAI’s current Astra model and prompting documentation. Use the requested model/effort configuration when available; distinguish API documentation from the controls the current agent host actually exposes. High reasoning is a configuration choice, not a promise of superior visual taste. [Official Astra model](https://developers.openai.com/api/docs/models/gpt-6-astra), [official model guidance](https://developers.openai.com/api/docs/guides/latest-model).

Our recommended design handoff has five parts: **product truth, current evidence, decision to make, implementation constraints, and acceptance evidence**. State the actual effect of the primary action. Specify autonomy and delegation expectations. Give independent agents bounded questions or disjoint files, and have one lead reconcile the result against the task. Agreement between agents is not a substitute for observing users.

Use this brief as an entry point; the [full workflow, component handoff and copyable prompts](design/research/systems-evidence.md#7-astra-verified-model-guidance-plus-a-design-practice) contain more detail:

```text
Product and person: [who uses this, for what recurring work]
Surface and mode: [screen; Operate / Read / Persuade / Experience]
Evidence: [current screenshots, implementation, realistic content, known issues]
Decision: [the concrete design question or bounded change]
Direction: [specific reference ideas and the relationships to preserve]
State contract: [empty, pending, selected, error, saved; action effects]
Constraints: [existing stack, platform, privacy, performance, scope]
Autonomy: [routine choices to make; genuinely unresolved decisions]
Delegation: [permitted roles, bounded tasks, file ownership, lead]
Acceptance: [rendered evidence and relevant checks; known exclusions]
```

Do not install every researched skill or layer contradictory “always/never” style prompts. Inspect current project instructions and skill versions when behavior is surprising. Refine a weak result by naming the failing relationship—for example, “the image is only a narrow strip because four panels take its height”—rather than asking the agent to “try harder” or add random decoration.

## Review before declaring a design finished

| Review lens | Concrete question | Evidence |
| --- | --- | --- |
| Comprehension | Can a first-time user identify the purpose and next action? | Observed user explanation, or an explicitly labeled preliminary expert assessment |
| Task completion | Does the action accomplish what the label promises? | Working flow and relevant fixtures |
| Information | Are important facts complete, comparable, and honest about uncertainty? | Source/data contract and rendered examples |
| Hierarchy | Does emphasis follow importance instead of available decoration? | Screen review with realistic content |
| Accessibility | Can users operate and understand it with keyboard, zoom, and assistive technology? | Appropriate automated checks plus manual interaction review |
| Responsiveness | Does it remain useful on small screens and with long content? | Actual viewport/zoom review |
| Performance | Does the visual treatment delay useful content or interaction? | Consistent lab tests or field data; no invented scores |
| Distinctiveness | Which deliberate choices make it appropriate to this product? | Explainable type, content, imagery, and interaction decisions |

Use the [critique library](design/research/critique-evidence.md) to add evidence-backed review questions. Expert observations are context-sensitive; keep our inference separate from the source. Automated tools and famous reviewers do not remove the need to observe actual users.

### Evaluate accessibility and performance claims precisely

Use current standards and platform guidance for factual thresholds. A stylistic audit can identify a useful concern without proving a standards violation. For example, WCAG text-contrast rules have exceptions for inactive controls; that does not make unreadable disabled controls a good product choice. The [systems evidence](design/research/systems-evidence.md#objective-checks-that-constrain-any-style) records the relevant standards and exceptions.

For web performance, separate loading, interaction responsiveness, visual stability and actual task duration. Current good Core Web Vitals thresholds are LCP ≤2.5 s, INP ≤200 ms and CLS ≤0.1 at the 75th percentile, segmented by desktop/mobile. These are reference targets, not measured scores for a project. Record representative devices, cold/warm state and content. [Web Vitals](https://web.dev/articles/vitals).

An image-analysis app also needs import-to-usable-preview, model startup, processing progress, pan/zoom, cancellation, review advance and memory-retention evidence. Lazy loading should defer unnecessary work while keeping the next interaction ready. A skeleton that paints quickly does not establish that the usable task became faster.

### Handle evidence and popularity honestly

An official document supports what its owner specifies. A designer’s review supplies an attributed interpretation. A social post’s engagement supports an attention claim. A measured product experiment supports only the outcome and population it actually studied. Preserve these distinctions when turning a source into a rule.

For videos, identify the episode, speaker, reviewed product, exact observation, transcript/video access and a verified timestamp where available. For posts, record author, original permalink, metric type/value and observation date. Do not combine likes with views or infer a conversion effect. Multiple examples from one author are not independent expert consensus. Record useful dissent. The [critique evidence library](design/research/critique-evidence.md) demonstrates this format.

When sources disagree, resolve the disagreement through the task: more visible data can help comparison but hurt reading; fewer calls to action can clarify a landing page but conceal necessary tools in an editor. Write the condition under which a lesson applies instead of promoting it into a universal rule.

## Extend this document without losing coherence

Add a new resource only when it contributes a distinct capability, materially better fit, or important alternative. Give it a stable ID, verification date, official sources, style, best use, integration/output, cost/license, and limitations. Move obsolete or ambiguous entries to a watchlist; do not erase their history or renumber unrelated entries.

Add professional critique using the record format in [critique-library.md](design/research/critique-evidence.md). Promote a lesson into this reference only after stating its scope and a concrete application. Promote it into a project rule only when that project's context supports it.

Keep project decisions in project guides. A preference for quiet placement screens or scientific viewers does not make shaders, 3D, playful illustration, or experimental typography useless in other work.
