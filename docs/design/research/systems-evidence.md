# Design systems, visual traditions, and agent workflow evidence

Research date: **8 September 2026**. This is a selective supplement to the inherited 5 September resource catalogue and general design reference. It supplies reusable guidance; it does not adopt a new application theme, install tools, or claim that an attractive demonstration proves usability.

**Evidence labels:** **Official** means a maintainer, platform owner, standards body, museum, or publisher speaking about its own material. **Practitioner** means an attributed designer's analysis. **Recommendation** means our application of those sources. **Inherited** means the original catalogue carried the claim and this pass did not recheck it. Page contents and linked repository branches can change; recheck at adoption.

## 1. Three decisions that should remain separate

**Recommendation:** make three explicit decisions before choosing a component collection:

| Decision | Question | Example answer for an image analysis workbench |
| --- | --- | --- |
| Information structure | What must the person see together to do the work? | Image and overlays first; active input, run status, results, and settings remain discoverable |
| Interaction foundation | Which implementation handles semantics and difficult behavior? | Existing controls plus one appropriate primitive library for dialogs, menus, sliders, and selection |
| Art direction | What visual relationships make this product recognizably appropriate? | A precise laboratory instrument, an editorial research desk, or a soft tactile console |

A Swiss grid can organize any of these directions. A neumorphic surface can sit behind a conventional accessible control. A behavior library does not choose the product's identity. Conversely, typography and shadow recipes do not implement keyboard behavior or preserve analysis state.

## 2. Impeccable: a valuable design workflow with explicit limits

**Official identity and provenance.** Impeccable is Paul Bakaus's project for AI design guidance. Its repository says it began from Anthropic's frontend-design skill; it is an independent extension, not an OpenAI or Apple product. The inspected repository advertises one skill, 23 commands, live browser iteration, and deterministic design checks. Its repository license is Apache-2.0. These are maintainer statements and inspectable source, not independent evidence of design quality or production adoption. [Repository](https://github.com/pbakaus/impeccable), [license](https://github.com/pbakaus/impeccable/blob/main/LICENSE).

**Official context model, summarized.** Current documentation separates durable product facts in `PRODUCT.md`, visual rules in `DESIGN.md`, and individual surface briefs. The four surface modes are Persuade, Operate, Read, and Experience. A task interface belongs to Operate, a guide to Read, a sales page to Persuade, and an artifact-led showcase to Experience. A responsive PWA remains `web`; native guidance is described as alpha. The page describes modes as replacing the older v3 register model, so avoid assigning these observed docs to v3 without checking the installed version. [Design Context](https://impeccable.style/docs/context/).

### Which commands solve which problems?

| Need | Documented capability | Recommended use and boundary |
| --- | --- | --- |
| Vague purpose or undefined content | `shape` develops an intent brief through discovery; standalone it does not implement | Supply known answers from existing context first. Use a separate brief phase only when useful; do not force another interview after the user has already defined the task. [Shape](https://impeccable.style/docs/shape/) |
| Working screen feels incoherent | `critique` combines model review, heuristic/persona lenses, and detector results | Ask for concrete observations and the three most consequential changes; label simulated personas as expert walkthroughs, never user research. Scores help organize discussion. [Critique](https://impeccable.style/docs/critique/) |
| Need implementation robustness review | `audit` reports accessibility, performance, theming, responsiveness, and anti-pattern findings; it does not fix them | Require reproduction steps and standards references, then act on verified issues. An audit command is not an accessibility certification. [Audit](https://impeccable.style/docs/audit/) |
| Specific refinement | Commands include `typeset`, `layout`, `clarify`, `adapt`, `harden`, `polish`, `bolder`, and `quieter` | Name the surface, failure, and constraint. “Fix image-toolbar hierarchy at 390px width” is actionable; “make everything premium” is not. [Command reference](https://impeccable.style/docs/impeccable/) |

**Source evaluation:** the fetched critique page names 25 anti-patterns while the repository advertises 61 deterministic rules. Treat counts as version-specific, and use the installed release's help. Detector matches are evidence that a pattern exists, not evidence that it harms this product. A purple palette, familiar typeface, or card has to be judged in context. [Critique documentation](https://impeccable.style/docs/critique/), [repository](https://github.com/pbakaus/impeccable).

The audit page's illustrative report flags disabled-button contrast. WCAG's contrast criterion exempts text in inactive controls. This is a concrete reason to check a generated finding against its cited criterion before labeling it a compliance failure. Disabled controls can still deserve a usability improvement, but that is a different claim. [Audit example](https://impeccable.style/docs/audit/), [W3C contrast explanation](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).

**Recommendation:** inspect a skill's provenance, version, file permissions, scripts, and scope before adoption. Read its content as external reference material during research. Installing it is a separate task. Preserve user authorization, project constraints, and real implementation evidence when its recommendations conflict with them. Record narrow intentional exceptions rather than silently weakening all checks.

## 3. Swiss / International Typographic Style: structure with purpose

**Historical evidence.** Poster House's exhibition traces the International Typographic Style through posters and ephemera, relating it to Bauhaus Concrete art, Jan Tschichold's typography, and geometric grids. Its educational microsite also includes contemporary criticism of the style's restrictions. This is a historical design tradition with competing interpretations, not a universal usability theorem. [Poster House exhibition](https://posterhouse.org/exhibition/the-swiss-grid/), [museum learning resource](https://swissgrid.posterhouse.org/).

Josef Müller-Brockmann's *Grid systems in graphic design* is a published reference for constructing and applying grids; Niggli lists the original publication date as 1981. The publisher's description covers two- and three-dimensional work, with examples rather than a web-specific recipe. A publisher listing verifies identity and scope; this research did not read or reproduce the full book. [Niggli](https://niggli.ch/en/products/rastersysteme-fur-die-visuelle-gestaltung).

**Recommendation: translate the method, not a poster's proportions.** Typography can establish hierarchy without making titles enormous; alignment can clarify relationships without making every region equal; white space means deliberate separation, including on dark surfaces. Swiss influence does not require red, Helvetica, giant numerals, all caps, or harsh minimalism.

| Principle to explore | Product translation | Failure to avoid | Review question |
| --- | --- | --- | --- |
| Grid and alignment | Align image boundary, toolbar, results headings, and inspector sections; use a few stable anchors | Twelve equal columns that make the image too small or mobile controls unusable | Do related items align and remain together as content changes? |
| Typographic hierarchy | Distinguish screen title, current object, field label, value, explanation, and warning | Every label tiny and uppercase; oversized titles competing with the task | Can a person identify the active image and result without reading every label? |
| Proximity and spacing | Use a small internal gap for a label/value pair and a larger gap between task groups | Equal spacing everywhere, making unrelated controls appear related | Does grouping remain understandable if all boxes disappear? |
| Asymmetric balance | Give the image more area than controls; let a narrow inspector balance a broad canvas | Perfect symmetry that wastes the workspace | Does area follow task importance? |
| Restrained palette | Reserve emphasis for selection, action, and meaningful status | Treating every surface as nearly the same green or gray | Are selected, actionable, informative, and disabled states distinct? |
| Real content and image | Let actual work carry the composition; use honest units, labels, and provenance | Decorative microscopy images that displace the specimen being inspected | Is the screen about the user's current work? |

**Example direction A — Research instrument.** Neutral charcoal around the image, lighter opaque inspectors, crisp rules, modest corners, compact but readable sans-serif labels, tabular result numerals, and one carefully tested accent. Density is concentrated in comparable values; navigation gets room to read. The image stage expands on larger screens. Status uses text plus a visual cue. This is an authored direction, not a museum-derived specification.

**Example direction B — Editorial research desk.** Warm paper or cool near-white chrome, dark text, a disciplined type scale, subtle section rules, and spacious explanatory views. Use a quieter image surround when necessary for visual inspection; the actual image stays color-faithful. Brand character may appear in report titles and documentation while operational controls remain familiar. Warmth does not imply beige everywhere or oversized whitespace.

**When Swiss influence is a poor sole brief:** an emotionally expressive game, culturally specific publication, or immersive artwork may need a different organizing voice. Even in a workbench, localization, zoom, touch, and real data outrank a fixed grid. A grid is a means of making relationships legible.

## 4. Neumorphism / “Neomorphic Design”: controlled depth

**Practitioner evidence.** Michał Malewicz describes neumorphic shapes as appearing to emerge from the same material as the background, typically through opposed light and dark shadows. His article credits Jason Kelley's naming contribution and an alexplyuto concept. It discusses low-contrast state problems and proposes stronger additional cues. The text contains a 2021 update; it is practitioner commentary, including explicitly untested assumptions, not a controlled accessibility study. [Neumorphism in user interfaces](https://hype4.academy/articles/design/neumorphism-in-user-interfaces).

His separate shadows article identifies a particular problem: changing only from an outer shadow to an inner shadow can make selection hard to perceive. This is a useful hypothesis to test in a real control; do not turn all of the article's stylistic assertions into universal laws. [Shadows and blurs](https://hype4.academy/articles/design/ui-design-shapes-objects-basics-shadows-and-blurs).

**Recommendation:** treat neumorphism as a surface treatment with optional character, not the sole encoding of action or state. It can be attractive for a calm appliance-like panel, a focus timer, a physical-control metaphor, or decorative framing. It becomes risky when essential boundaries, selection, or focus depend on almost invisible depth.

| Element | Constrained use | Required independent meaning |
| --- | --- | --- |
| Decorative panel | Gentle embossed surface around a group | Heading and spacing preserve the group if shadows vanish |
| Button | Soft surface in its normal state | Clear label, discernible action treatment, press response, visible keyboard focus |
| Toggle or segmented control | Tactile movement as reinforcement | Explicit selected marker/fill and programmatic checked/selected state |
| Slider | Soft track or knob decoration | Track/thumb remain perceptible; value and accessible name exist; keyboard operation works |
| Image stage | Optional outer frame | No shadow, blur, tint, or refraction changes the pixels being judged |
| Error or warning | Keep treatment consistent with the system | Text explains the problem and recovery; recognition does not depend on red alone |

**Example direction C — Soft precision console.** A lightly tinted gray control rail, subtle bevels on large group surfaces, dark readable labels, a solid accent on the primary action, and explicit selected ticks. Keep the specimen area neutral and opaque. Use no embossed mini-controls. Collapse the tactile effect in high-contrast presentation while preserving the control structure. This is a recommendation for a prototype, not an adoption decision.

### Objective checks that constrain any style

W3C's explanatory documents distinguish requirements from aesthetic preferences:

| Criterion | Accurate brief | Practical application |
| --- | --- | --- |
| Text contrast, WCAG 1.4.3 AA | Generally 4.5:1 for text and 3:1 for qualifying large text; exceptions include inactive controls, incidental text, and logos | Test actual text/background pairs, including composited backgrounds. Avoid classifying every faint decoration as text. [W3C](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) |
| Non-text contrast, 1.4.11 AA | Visual information necessary to identify controls/states, and essential graphic parts, generally needs 3:1 against adjacent colors; exceptions apply | Essential thumb, focus, or selected-state cues need evidence. A decorative card edge need not automatically satisfy a control-boundary rule. [W3C](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html) |
| Focus visible, 2.4.7 AA | Keyboard-operable interfaces need a visible focus indicator | Moving from an outer to inner shadow alone is a weak focus strategy. [W3C](https://www.w3.org/WAI/WCAG22/Understanding/focus-visible.html) |
| Target size, 2.5.8 AA | A 24 × 24 CSS pixel minimum or an applicable spacing/other exception | Treat this as the web criterion with exceptions; use larger comfortable targets where the task warrants them. Do not substitute native points for CSS pixels. [W3C](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html) |
| Status messages, 4.1.3 AA | Relevant status changes must be programmatically determinable without forcing focus | Processing, completion, and recoverable errors need a meaningful accessible status strategy. Avoid announcing every frame of progress. [W3C](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html) |

**Recommendation for visual review:** inspect normal, pressed, selected, focus, disabled, and error states side by side; then remove shadows and transparency. If a person can no longer determine what is actionable or selected, the surface effect is carrying too much meaning. Follow with keyboard, zoom, contrast, and assistive-technology review. Passing a contrast ratio alone does not establish good affordance or successful task completion.

## 5. Apple: official design guidance and authentic agent resources

| Resource | Ownership and evidence | Best use | Boundary |
| --- | --- | --- | --- |
| Human Interface Guidelines | Official Apple platform guidance | Learn hierarchy, familiar controls, feedback, adaptation, and accessibility expectations | Platform-specific instructions must be read in their platform context. The HIG landing page required JavaScript in this research tool. [HIG](https://developer.apple.com/design/human-interface-guidelines) |
| Apple Design Resources | Official downloadable design templates and assets, with linked terms | Native Apple UI design and reference measurements | Availability to download does not grant unrestricted cross-platform reuse. Check the exact asset terms. [Resources](https://developer.apple.com/design/resources/), [resource license](https://developer.apple.com/support/downloads/terms/apple-design-resources/Apple-Design-Resources-License-20230621-English.pdf) |
| Apple typography resources | Official Apple fonts and platform typography material | Understand platform text rendering and type roles | Do not assume downloaded SF font binaries are general-purpose webfonts. Read their licenses; a web project can choose a system-font stack or separately licensed web family. [Fonts](https://developer.apple.com/fonts/) |
| Xcode 27 agent skills | Official Apple material: SwiftUI page and WWDC26 session describe built-in skills | Native SwiftUI conventions, current APIs, and app modernization | Not a CSS/PWA design engine; installed Xcode version and available skill set must be checked. No Apple skill was installed or exported in this research. [SwiftUI what's new](https://developer.apple.com/swiftui/whats-new/), [UIKit modernization session](https://developer.apple.com/videos/play/wwdc2026/278/) |
| AvdLee SwiftUI Agent Skill | **Third party**, Antoine van der Lee and Omar Elsayed; repository identifies MIT licensing | SwiftUI code review, state/data flow, views, current API guidance | Apple-platform expertise does not make the repository Apple-authored. Verify specific references and release before installing. [Repository](https://github.com/AvdLee/SwiftUI-Agent-Skill), [license](https://github.com/AvdLee/SwiftUI-Agent-Skill/blob/main/LICENSE) |
| twostraws SwiftUI Agent Skill | **Third party**, originally created by Paul Hudson | SwiftUI implementation guidance including design, performance, and accessibility | Community skill, not Apple's official HIG or official skill distribution; exact license/version remains an adoption check here. [Repository](https://github.com/twostraws/SwiftUI-Agent-Skill) |

**Official Apple skill evidence:** the SwiftUI page explicitly describes Xcode 27 skills. Apple's WWDC26 UIKit session documents exporting Xcode's skills with `xcrun agent skills export` for use in other workflows. The public “Extending and customizing agents” page's indexed text describes built-in expertise and configuration, but its direct fetch returned only a JavaScript shell. The WWDC transcript and rendered SwiftUI page provide the stronger directly read evidence. [Apple SwiftUI](https://developer.apple.com/swiftui/whats-new/), [Apple WWDC transcript](https://developer.apple.com/videos/play/wwdc2026/278/), [Xcode documentation](https://developer.apple.com/documentation/Xcode/extending-and-customizing-agents).

**Recommendation for a PWA:** borrow the intention—clear hierarchy, comfortable controls, predictable feedback, adaptive layouts—and implement with web semantics and web requirements. A browser application does not inherit native accessibility or platform materials by resembling a screenshot. A generic CSS blur is not Apple's adaptive Liquid Glass system. Keep image analysis pixels and annotations unobscured. Do not automatically turn the app into an iOS imitation, or use Apple asset downloads as an unreviewed general-purpose kit.

## 6. Choose component foundations by behavior and maintenance

These candidates were rechecked at their official overview pages on 8 September. This table does **not** reverify every license, supported release, or inherited catalogue claim. Recommendations are conditional; the existing application stack is the first constraint.

| Candidate / role | Official current fact | Recommendation / ownership trade-off |
| --- | --- | --- |
| Native HTML and existing project components | Baseline implementation option | Start here for ordinary buttons, labels, inputs, and simple layouts. Add a library for an actual gap. Existing code can still contain defects; audit it. |
| shadcn/ui — editable source and distribution | Its docs describe a code distribution platform with component source open to modification | Strong when agents need to inspect and adapt owned UI. Your team maintains its modifications and reviews upstream changes. Verify the primitive behind each generated component instead of assuming all current components use the same base. [Official docs](https://ui.shadcn.com/docs) |
| Base UI — unstyled React foundation | Official overview says components contain no CSS and do not prescribe a styling engine | Useful when a bespoke interface needs a coherent interaction base. You own appearance, tokens, and composition; maintain package compatibility. [About](https://base-ui.com/react/overview/about) |
| Radix Primitives — low-level accessible components | Official introduction describes accessibility-oriented, customizable primitives | Useful for existing Radix-based products and discrete complex controls. Preserve semantics when changing structure or styles. A switch to another foundation needs a concrete benefit. [Introduction](https://www.radix-ui.com/primitives/docs/overview/introduction) |
| React Aria — behavior, accessible components, internationalization | Adobe documents components and hooks, keyboard/ARIA behavior, locale-aware dates/numbers, and assistive-technology testing | Especially worth comparing for complex selection, calendars, localized numbers, and varied input methods. Foundation capability is not proof that a composed app is accessible. [Official site](https://react-aria.adobe.com/) |
| Material UI — styled system | Official overview identifies an open-source React library implementing Material Design | Efficient when broad component coverage and coherent defaults fit the product. Budget adaptation carefully if the desired art direction fights Material conventions. Evaluate advanced data components separately. [Overview](https://mui.com/material-ui/getting-started/) |
| Mantine — styled components and supporting tools | Official site presents customizable React components, hooks, and supporting packages | Useful for rapid coherent product interfaces. Compare required component behavior and theming effort on a representative screen before committing. [Official site](https://mantine.dev/) |

**Recommendation:** compare at most two plausible foundations by building the same small, demanding slice: labeled numeric control, error message, dialog, selection, and keyboard return path, using realistic long content. Compare implementation effort, behavior, styling constraints, dependency weight, and who fixes an upstream defect. Do not score candidates on homepage polish or stars.

**Inherited, not rechecked here:** Ant Design, Fluent UI, Chakra, Ark/Park UI, Headless UI, animation packages, icon families, gallery subscriptions, and the original catalogue's plan/export/license restrictions retain their earlier verification status. This research does not silently upgrade those entries to “verified today.” Effects collections and inspiration galleries remain potential references; they are not substitutes for a component's behavior contract.

### A reusable component handoff

**Recommended template; authored for this guide.** Make each important control reviewable in isolation and in its task:

```text
Component: [name and actual job]
Foundation: [native / existing / dependency and version]
Anatomy: [label, value, help, action, feedback]
States: default, hover, pressed, focus, selected, disabled, pending, error
State meaning: [what changes in data, and whether it is reversible]
Input: [keyboard, pointer, touch; accessible name and semantics]
Layout: [long text, zoom, small width, overflow]
Visual roles: [tokens; which cue establishes action/selection/focus]
Integration: [async behavior, ownership of state, recovery]
Evidence: [fixture/screenshot and interaction checks actually completed]
Known limits: [unsupported state or environment; owner and next action]
```

## 7. Astra: verified model guidance plus a design practice

**Official model facts.** On this research date, OpenAI's directly opened model page documents `gpt-6-astra` and supports `high` reasoning, among other effort levels. Local task metadata also exposes Astra/high. That is enough to name the requested configuration. It does not establish that Astra has unique aesthetic taste, guarantees production quality, or removes the need for design references and observation. [OpenAI model page](https://developers.openai.com/api/docs/models/gpt-6-astra).

**Official prompting guidance, concise summary.** OpenAI's Astra guide recommends expressing autonomy expectations, reviewing skill/file instructions that may influence behavior, specifying writing style, deliberately setting delegation expectations, and calibrating verification to the change. These are documented model-specific recommendations. The page is a mutable latest-model route; recheck its selected model when reusing this citation. [OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model).

**Recommended design practice, not an OpenAI formula:** give the agent an evidence package and a bounded decision. More adjectives do not resolve missing product truth. More reasoning effort does not replace a useful screenshot, state inventory, or acceptance condition.

| Stage | Give the agent | Require back | Decision rule |
| --- | --- | --- | --- |
| Diagnose | Current screenshots, live surface when available, task, realistic content | Specific defects with visible evidence; distinguish observation from hypothesis | Fix an observed comprehension or task problem before decoration |
| Direct | Two or three purposeful references with credited URLs | Two genuinely different directions using the same task/content | Compare hierarchy, density, and interaction, not two palettes on the same template |
| Specify | Selected direction plus constraints | Small token set, layout relationships, component/state examples | A direction must survive long labels and non-happy states |
| Implement | Existing code, dependencies, authorization, acceptance conditions | One coherent working slice, then related surfaces | Do not replace a stack to imitate a screenshot without a concrete need |
| Verify | Representative fixtures, viewport/input matrix | Browser evidence, interaction outcomes, relevant checks, honest gaps | Stop repeating passing checks unless changes or new concerns justify them |
| Consolidate | Accepted decisions and evidence | Updated project design record and reusable components | Keep project choices separate from general taste or tool facts |

### Copyable prompt patterns

These are original recommended prompts. Replace bracketed fields; they do not assume a skill is installed.

**Diagnosis prompt**

```text
Assess [surface] for [person and task]. Inspect the actual rendered interface
and relevant implementation. Identify the three most consequential design
problems. For each, give observed evidence, task impact, proposed correction,
and confidence. Separate visible facts from assumptions and simulated user
walkthroughs. Account for the current empty, pending, error, and completed
states. Preserve existing task scope. Produce a review, not code.
```

**Direction prompt**

```text
Using the same realistic content for [surface], develop two distinct art
directions. Reference A contributes [specific typographic/layout idea];
reference B contributes [specific interaction idea]. Credit the sources.
For each direction specify hierarchy, spatial allocation, typography roles,
palette roles, density, control treatment, and motion purpose. State how it
handles small widths, long content, selection, focus, and errors. Recommend
one based on [task criteria]. Do not invent product claims or replace the
working interface with marketing sections.
```

**Implementation prompt**

```text
Implement the selected direction for [bounded surface] using the existing
project conventions and the supplied design record. Make routine reversible
choices within this scope and record meaningful assumptions. The main action
is [action and actual effect]. The required states are [states]. Use [content
fixtures], including the long and failed cases. Reuse the existing behavior
foundation; justify a new dependency if a real gap requires one. Verify the
rendered result at [viewports/input methods] and complete checks appropriate
to the change. Report what changed, evidence, and unresolved limitations.
```

**Focused refinement prompt**

```text
Refine [specific weakness] in [surface]. Preserve [task/state/data contract].
Show before/after evidence using the same content and viewport. Change the
fewest design variables that resolve the weakness, then inspect the affected
states. If the issue is structural, correct the layout or hierarchy rather
than compensating with decoration. Update the design record if a durable
rule changes.
```

**Optional delegation clause, only when the user/task permits parallel agents:**

```text
Assign one independent reviewer to interaction/accessibility and one to
visual hierarchy. Give both the same evidence and explicit file ownership.
Have the lead reconcile conflicting recommendations against the task.
Do not count agreement between agents as independent user validation.
```

## 8. Applying the guide to an image analysis PWA

**Recommendation, informed by the root task's observed screen:** organize the interface around the active image and the analysis decision. The separate project case study should own exact measurements and findings; this chapter gives transferable checks.

1. **Make work occupy the workspace.** Compare the image's usable area against navigation, repeated preview controls, processing panels, and secondary metadata. Expand image inspection where controls currently consume disproportionate area. Do not impose a universal percentage: the chosen mode and content determine it.
2. **Keep identity and provenance adjacent.** A person should be able to connect the displayed image, active run, visible overlays, settings, and result. Avoid a polished count that appears detached from the source or processing state.
3. **Use progressive disclosure by task.** Frequent viewing controls remain available; advanced configuration and metadata can open when needed. Hidden does not mean unavailable, and showing a panel must not silently reset work.
4. **Reserve color for meaning.** UI selection should remain identifiable over varied specimens. Overlay colors should have clear legends and should not be confused with success/error chrome. Do not tint source imagery for brand consistency.
5. **Treat processing as a real state.** Show whether processing is queued, active, completed, or failed according to actual data. Keep cancellation/retry available when implemented; do not imply features the application does not support.
6. **Separate product navigation from implementation jargon.** Group destinations by what the user is trying to accomplish. Developer verification tools need a deliberate home rather than equal prominence with the primary task.
7. **Test the visual trade-offs.** Use a sparse image, a dense image, an unusually proportioned image, long file names, empty results, and failed processing. Judge the screen as an instrument used repeatedly, not a one-time launch page.

No visual style validates the scientific accuracy of an analysis. Evaluation of algorithms, image preprocessing, metrics, and research claims belongs to separate evidence and tests.

## 9. Adoption and maintenance record

**Recommended catalogue fields:** stable ID; exact resource identity; owner; resource type; job solved; current primary URL; verification date; framework/platform; license/plan scope checked; adopted version or commit; user-data implications if applicable; evidence class; project-specific decision; unresolved limits.

**Research limits:** no dependencies installed, no paid plans purchased, no full books read, no user study performed, and no component implementation benchmark run. Some Apple HIG pages exposed only JavaScript shells to direct retrieval; indexed passages were used for discovery, while stronger readable Apple pages and WWDC transcripts support the concrete official-skill claims. Inherited resource claims not listed as rechecked remain inherited. Live mutable documentation showed discrepancies; record versions at adoption and avoid copying sample scores or marketing claims as facts about this PWA.
