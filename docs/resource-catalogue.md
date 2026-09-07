# Web design and development resource catalogue

Edition 2 · Expanded 8 September 2026 · Reusable across projects.

The 77-entry foundation below preserves the user-authored Famulus catalogue, researched 5 September 2026. Detailed inherited entries link to the pinned upstream revision `d4d3294ec37308c5a6844ed0aae2c9526a352185`; they have **not all been reverified** in this expansion. New dated research and selection guidance follow separately. Read the [design reference](design-reference.md) before choosing tools, and the [CellCounter application guide](design/cellcounter-guide.md) for project-specific decisions.

The inherited foundation contains **77 resource entries**, with **16 additions** in this edition, across UI foundations, icons, motion, 3D, asset creation, inspiration, design workflow, typography and quality checks. Some entries group a closely related ecosystem; a few preserve unresolved names or incomplete verification. This is a broad curated working library, not a claim to list every useful tool on the internet or to have tested every tool in production.

Each linked entry records purpose, practical value, design style, integration/output, cost or license constraints, primary sources and evidence limits. The tables below provide a quick selection index. For the method of using these resources, read the [general design reference](design-reference.md). Famulus-specific choices live in the [project guide](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/design-guide.md) and [roadmap](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/famulus-roadmap.md).

## What is actually worth learning or using?

My strongest general recommendations depend on the job:

| Job | Start here | Practical reason |
| --- | --- | --- |
| Own a distinctive React product interface | Existing system, then shadcn/ui plus the appropriate primitive foundation | Adapt behavior and appearance without adopting an entire unrelated theme |
| Build complex forms and accessible controls | React Aria, Base UI or Radix | Difficult interaction behavior deserves dedicated primitives |
| Ship a broad admin interface quickly | MUI, Mantine, Ant Design or Fluent UI | Consistent coverage saves more work than assembling individual visual demos |
| Understand how real products handle tasks | Mobbin and Page Flows | Complete flows reveal states that polished landing pages omit |
| Develop visual taste and art direction | Recent, Godly, Land-book, Awwwards | Study type, composition and interaction with credited references |
| Animate product state | CSS first, then Motion | Match implementation weight to the interaction |
| Choreograph an expressive website | GSAP; Osmo for implementation references | Useful for precise sequences and unusual interactions |
| Create interactive illustration or 3D | Rive; Three.js/R3F or Spline depending on authorship needs | Choose stateful artwork, coded scenes or visual authoring deliberately |
| Produce a family of brand assets | BRIK or Endless Tools | Repeatable controls and exports can save ongoing production work |
| Keep agents' UI changes consistent | Concrete component examples, Storybook, Playwright, axe-core | Review real behavior and states as well as appearance |

These are alternatives and complementary roles, not a shopping or installation list. Many smaller tools are useful for one specific effect. That can be enough to justify them without treating them as foundational software.

## New in the 8 September expansion

Read the [systems evidence](design/research/systems-evidence.md) for provenance, tradeoffs, examples and original Astra prompt patterns. Read the [critique evidence](design/research/critique-evidence.md) for six additional official YC reviews, four original design tweets with observed likes, and two substantial public discussions with preserved disagreements. Engagement snapshots are dated; they do not demonstrate effectiveness.

| ID and resource | Useful job / integration | Ownership, rights and evidence limits |
| --- | --- | --- |
| **REF-08 · [Impeccable](https://impeccable.style/docs/impeccable/)** | Design context, critique and focused refinement vocabulary for agent workflows | Independent Paul Bakaus project; repository Apache-2.0. Current docs and repository counts differ, so record the installed version. Reference material here; not installed. [Detailed evaluation](design/research/systems-evidence.md#2-impeccable-a-valuable-design-workflow-with-explicit-limits) |
| **REF-09 · [The Swiss Grid](https://posterhouse.org/exhibition/the-swiss-grid/)** | Historical examples for grids, alignment, type and visual relationships | Museum exhibition and [learning resource](https://swissgrid.posterhouse.org/); historical evidence, not web usability research. Reference images are not automatically reusable assets |
| **REF-10 · [Grid systems in graphic design](https://niggli.ch/en/products/rastersysteme-fur-die-visuelle-gestaltung)** | Deliberate grid construction and visual organization | Niggli’s publisher listing verifies the book’s identity/scope. Commercial publication; full book not read or reproduced in this research |
| **REF-11 · [Neumorphism in user interfaces](https://hype4.academy/articles/design/neumorphism-in-user-interfaces)** | Understand tactile surface vocabulary and its state/contrast tradeoffs | Michał Malewicz practitioner essay; attributed opinion with limits, not an accessibility study or downloadable component license |
| **REF-12 · [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)** | Platform conventions, hierarchy, feedback and adaptation | Official Apple reference. Some pages required JavaScript; distinguish directly read guidance from discovery snippets. Native guidance needs deliberate web adaptation |
| **REF-13 · [Apple Design Resources](https://developer.apple.com/design/resources/)** | Official native design templates and platform assets | Downloads have [specific terms](https://developer.apple.com/support/downloads/terms/apple-design-resources/Apple-Design-Resources-License-20230621-English.pdf). Do not treat availability as unrestricted cross-platform rights |
| **REF-14 · [napari viewer tour](https://napari.org/stable/getting_started/viewer.html)** | Study a scientific viewer’s canvas, contextual layer controls and dimension navigation | Official application documentation; study interaction organization, not a drop-in web component or validated CellCounter design |
| **REF-15 · [QuPath first steps](https://qupath.readthedocs.io/en/stable/docs/starting/first_steps.html)** | Study source calibration, object selection and linked measurements | Official application documentation. A workflow reference, not permission to copy all UI/assets or proof that its layout fits every product |
| **REF-16 · [YC Design Review evidence library](design/research/critique-evidence.md#six-additional-official-yc-review-records)** | Specific critiques from Katie Dill, Karri Saarinen, Ryo Lu, Raphael Schaad and others in their source contexts | Official YC transcript passages and published video chapters inspected; footage not watched. No claimed conversion uplift or scientific endorsement |
| **AGENT-01 · [OpenAI Astra model guidance](https://developers.openai.com/api/docs/guides/latest-model)** | Specify autonomy, style, delegation and proportionate verification; pair with our design handoff | Official guidance and [model page](https://developers.openai.com/api/docs/models/gpt-6-astra). Mutable latest-model URL; recheck selected model. Configuration does not guarantee aesthetic quality |
| **AGENT-02 · [Apple Xcode agent skills](https://developer.apple.com/swiftui/whats-new/)** | Native Apple implementation and modernization guidance | Apple-authored Xcode 27 capability, also documented in [WWDC26](https://developer.apple.com/videos/play/wwdc2026/278/). Check installed Xcode/support; no skills exported or installed in this task; not a PWA styling package |
| **AGENT-03 · [AvdLee SwiftUI Agent Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill)** | Community guidance for SwiftUI structure, state, APIs and review | Third party, MIT repository; inspect exact version, scripts and scope before adoption. Not Apple-authored |
| **AGENT-04 · [twostraws SwiftUI Agent Skill](https://github.com/twostraws/SwiftUI-Agent-Skill)** | Community SwiftUI implementation guidance | Third party, originally Paul Hudson; exact version/license is still an adoption check in this pass. Not Apple’s official distribution |
| **QA-07 · [WCAG 2.2 Understanding documents](https://www.w3.org/WAI/WCAG22/Understanding/)** | Interpret contrast, focus, target size and status-message criteria accurately | W3C explanatory material; consult the underlying normative criteria and exceptions. Automated audits cover only part of accessibility. [Selected criteria](design/research/systems-evidence.md#objective-checks-that-constrain-any-style) |
| **QA-08 · [Web Vitals](https://web.dev/articles/vitals)** | Separate loading, responsiveness and stability; define honest measurement conditions | Google’s documented metrics. Lab results and field percentiles are different; task-specific processing/memory metrics are also needed |
| **TYPE-06 · [Apple fonts](https://developer.apple.com/fonts/)** | Learn platform type roles and inspect Apple typography resources | Official Apple resource. Check exact font license before distributing binaries; do not assume a downloadable SF family is a general webfont |

The additions fill gaps in decision-making, operational UI and agent guidance; they are not a dependency installation list. Six existing foundations—shadcn/ui, Base UI, Radix, React Aria, MUI and Mantine—also received a [fresh official-overview comparison](design/research/systems-evidence.md#6-choose-component-foundations-by-behavior-and-maintenance). This verifies those overview facts, not every version/license/plan claim in the inherited records.

### Choose by the current problem

| Problem | Start with | Concrete output |
| --- | --- | --- |
| Working app looks generic or poorly composed | Current task/screens, REF-08, relevant YC/DISC records | Three observed defects, then a coherent direction with realistic content |
| Need a scientific image workbench | REF-14, REF-15 and our CellCounter guide | Canvas/control proportions, source/result state, linked selection and traceability |
| Need typographic discipline | REF-09, REF-10, TYPE-03 | A type hierarchy, alignment anchors and a spacing system adapted to the task |
| Want tactile or Apple-like character | REF-11 or REF-12, plus QA-07 | Explicit control states with appropriate materials and platform behavior |
| Agent produces attractive but unusable screens | AGENT-01 and the component/state handoff | Bounded task, true action effects, all required states, rendered evidence |
| Need native SwiftUI expertise | AGENT-02; compare AGENT-03/04 for a specific gap | Verified platform/API guidance with source ownership recorded |
| UI feels slow | QA-08 and task-specific timings | Identify the slow phase; separate shell rendering, usable preview and analysis completion |

## Evidence: usefulness and popularity are different claims

- **Survey:** people report having used a tool in a defined sample. State of React 2025 reports shadcn/ui and MUI usage experience at 56.1% and 57.2% respectively among respondents to those items. This is not active deployment share. [Survey](https://2025.stateofreact.com/en-US/libraries/)
- **Named use/integration:** an identifiable implementation is documented. Epic documents Sketchfab in Twinmotion; Motion's maintainers name Framer and Cursor integrations. These show specific use, not an adoption census. [Epic documentation](https://dev.epicgames.com/documentation/en-us/twinmotion/sketchfab-assets-in-the-twinmotion-library), [Motion repository](https://github.com/motiondivision/motion)
- **Inspectable implementation/documentation:** enough information exists to assess integration plausibility and source ownership. This supports technical evaluation, not claims of popularity or tested quality.
- **Vendor examples:** curated projects, customer logos, downloads or creator counts. Useful leads, clearly labeled as vendor-selected evidence.
- **Limited/unresolved:** the identity, rights or capabilities could not be established sufficiently. Such entries remain discovery leads, not approved dependencies.

No stars, social-media impressions, award scores or attractive demos are treated as proof of usability, conversion, maintenance or broad production adoption. Detailed research uses these distinctions locally; UI entries abbreviate them as S, U, P, V and ?.

## UI foundations and component systems

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [UI-01 · shadcn/ui](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-01) | Editable component source and registry workflow | Neutral defaults; bespoke React products |
| [UI-02 · Radix Primitives](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-02) | Unstyled interaction foundations | Your visual style; custom controls |
| [UI-03 · Base UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-03) | Unstyled React components | Custom systems needing behavior without a theme |
| [UI-04 · React Aria](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-04) | Accessible interaction and internationalization tools | Custom, complex forms and controls |
| [UI-05 · Headless UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-05) | Unstyled React/Vue interaction components | Tailwind-oriented custom interfaces |
| [UI-06 · MUI / MUI X](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-06) | Broad components and advanced data tools | Material/enterprise; rich admin applications |
| [UI-07 · Mantine](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-07) | Components, hooks and forms | Clean product UI; rapid broad coverage |
| [UI-08 · Chakra UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-08) | Composable styled components and tokens | Adaptable modern product interfaces |
| [UI-09 · Ant Design](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-09) | Extensive enterprise interface patterns | Dense operational/business applications |
| [UI-10 · daisyUI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-10) | Semantic component classes over Tailwind | Themeable UI with less class repetition |
| [UI-11 · Tailwind Plus](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-11) | Paid components and templates | Polished conventional product/marketing layouts |
| [UI-12 · Fluent UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-12) | Microsoft's component ecosystem | Familiar enterprise/productivity interfaces |
| [UI-13 · Ark UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-13) | Headless components across frameworks | Bespoke systems with shared behavior concepts |
| [UI-14 · Park UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-14) | Styled components built around Ark UI | Systematic neutral product UI |
| [UI-15 · Aceternity UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-15) | Expressive components and effects | Dramatic technology/campaign pages; custom license |
| [UI-16 · Magic UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-16) | Animated sections and visual components | Startup/product marketing; selective use |
| [UI-17 · React Bits](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-17) | Animated text, backgrounds and effects | Creative/experimental sites; license restrictions |
| [UI-18 · Origin UI → coss ui](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-18) | Editable product components | Quiet practical UI; mixed repository licenses |
| [UI-19 · Originkit](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-19) | **Watchlist:** identity confirmed, functionality insufficiently verified | Do not substitute Origin UI or infer a style/license |
| [UI-20 · Shadcnblocks](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-20) | Ready-made blocks and pages | Product/marketing layouts; public-repo reuse restricted |
| [UI-26 · Animate UI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-26) | Editable animated controls/components | Minimal defaults with purposeful interaction motion |

## Icons

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [UI-21 · Lucide](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-21) | Consistent SVG/component icon family | Light outline; general product UI |
| [UI-22 · Heroicons](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-22) | Coordinated outline/solid icons | Clean Tailwind-style interfaces |
| [UI-23 · Phosphor](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-23) | Multiple coordinated icon weights | Flexible light-to-bold visual systems |
| [UI-24 · Tabler Icons](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-24) | Broad icon vocabulary | Geometric outline; data-rich products |
| [UI-25 · Untitled UI Icons](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/components.md#ui-25) | Coordinated professional icon assets | Polished SaaS/editorial UI; free/paid rights differ |

## Animation, 3D and shaders

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [VIS-001 · Motion](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-001) | State, layout and gesture animation | Flexible; product feedback through expressive motion |
| [VIS-002 · GSAP](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-002) | Timelines and sophisticated choreography | Scroll narratives, typography and agency work |
| [VIS-003 · Anime.js](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-003) | General JavaScript/SVG animation | Rhythmic graphic and typographic movement |
| [VIS-004 · Rive](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-004) | Author interactive animation states | Branded vector art and responsive illustration |
| [VIS-005 · Lottie / LottieFiles](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-005) | Play/export/source prepared animation | Vector timelines, explainers and feedback |
| [VIS-006 · Three.js](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-006) | Build custom browser 3D | Realistic, abstract, technical or spatial experiences |
| [VIS-007 · React Three Fiber + Drei](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-007) | React scene rendering and 3D helpers | Custom React 3D applications |
| [VIS-008 · Spline](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-008) | Visually author interactive 3D | Sculptural/playful scenes; export plan matters |
| [VIS-009 · Paper Shaders](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-009) | Configurable shader treatments | Grain, mesh, metallic and digital art |
| [VIS-010 · ShaderGradient](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-010) | Configure flowing canvas gradients | Atmospheric luminous backgrounds |
| [VIS-011 · MengTo / ThreeUI](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-011) | Editable interactive visual components | Expressive, animated, sometimes dimensional |
| [VIS-012 · Sketchfab](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-012) | Discover/embed/control 3D models | Model-dependent product or educational viewing |
| [VIS-013 · Poly Haven](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-013) | Models, materials and HDRIs | Realistic scenes and lighting |

## Focused effects and creative assets

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [VIS-014 · Fluid](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-014) | Generate/export/embed procedural graphics | Fluid, chrome, noise and abstract digital art |
| [VIS-015 · ASCII](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-015) | Character-art creation and exports | Terminal, retro and developer-brand graphics |
| [VIS-016 · liquid-glass-js](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-016) | Glass/refraction effects; multiple candidate projects | Experimental translucent surfaces; identity must be chosen |
| [VIS-017 · liquid-logo](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-017) | Metallic logo animation; multiple candidate projects | Chrome campaign marks and creative identities |
| [VIS-018 · Thinking Orbs](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-018) | Animated AI status artwork | Organic/digital AI motifs; rights partly unverified |
| [VIS-019 · scrollytelling-prompt](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-019) | **Unresolved:** no confidently identified canonical resource | Scroll storytelling as a technique is documented separately |
| [VIS-020 · Haikei](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-020) | Generate static SVG compositions | Waves, blobs and abstract graphic backgrounds |
| [VIS-021 · Book of Shapes](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-021) | Explore customizable SVG patterns | Geometric/editorial; output rights unresolved |
| [VIS-022 · Endless Tools](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-022) | Repeatable creative asset production | Tactile/sculptural 3D and motion posters |
| [VIS-023 · BRIK](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-023) | Create visual generators with editable controls | Kinetic type, effects and brand campaigns |
| [VIS-024 · unDraw](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-024) | Ready-made illustration | Flat friendly scenes; can feel generic without adaptation |
| [VIS-025 · Recent](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-025) | Curated visual references | Varied website/interface/brand art direction |
| [VIS-026 · GetLayers](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-026) | Prompts and starters for visual implementation | Cinematic, dimensional, motion-rich pages |
| [VIS-027 · Higgsfield MCP](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-027) | Agent-driven image/video production | Prompt-dependent campaign/media aesthetics |
| [VIS-028 · Osmo](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/visual-tools.md#vis-028) | Creative implementation resources | Expressive editorial motion and refined interactions |

## Design, prototyping and publishing workflows

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [WF-01 · Figma](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#wf-01) | Collaborative design, prototypes and systems | Style-neutral; team design/handoff |
| [WF-02 · Penpot](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#wf-02) | Open-source design/prototyping | Style-neutral; design ownership/self-hosting needs |
| [WF-03 · Framer](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#wf-03) | Visual site authoring/publishing | Polished marketing; official export guidance conflicts |
| [WF-04 · Webflow](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#wf-04) | Visual web/CMS authoring | Flexible marketing/editorial sites; export has boundaries |
| [WF-05 · v0](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#wf-05) | Generate/edit interface implementation candidates | Fast prototypes; visual defaults need art direction |

## References and critique frameworks

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [REF-01 · Mobbin](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-01) | Real product screens and flows | Varied; learn interaction conventions |
| [REF-02 · Page Flows](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-02) | Recorded product journeys | Varied; understand sequencing and intermediate states |
| [REF-03 · Godly](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-03) | Curated web inspiration | Distinctive creative/portfolio art direction |
| [REF-04 · Land-book](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-04) | Website/landing-page references | Broad polished brand and marketing composition |
| [REF-05 · Awwwards](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-05) | Credited/judged website examples | Frequently expressive, ambitious and interactive |
| [REF-06 · GOV.UK Design System](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-06) | Transactional patterns and reasoning | Clear institutional forms; adapt principles to context |
| [REF-07 · NN/g heuristics](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#ref-07) | Structured usability review questions | Aesthetic-neutral; status, control and recovery |

The [critique library](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/critique-library.md) separately seeds three official YC Design Review summaries with named speakers, context and clearly separated applications. They are source summaries, not commissioned evaluations of Famulus.

## Documentation, testing and typography

| Resource and details | What it does / why useful | Style and best fit |
| --- | --- | --- |
| [QA-01 · Storybook](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-01) | Document/exercise components and states | Any system; shared implementation reference |
| [QA-02 · Chromatic](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-02) | Hosted visual-change review | Any system; regression collaboration |
| [QA-03 · Playwright](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-03) | Browser workflow testing | Any style; functional verification |
| [QA-04 · axe-core](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-04) | Automated accessibility analysis | Any style; partial automated coverage |
| [QA-05 · Lighthouse](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-05) | Page quality/performance diagnostics | Any style; lab checks with stated conditions |
| [QA-06 · WebPageTest](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#qa-06) | Loading analysis, waterfalls and filmstrips | Any style; investigate experience over time |
| [TYPE-01 · Google Fonts](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#type-01) | Search/source web typography | Broad families; verify each family's license |
| [TYPE-02 · Fontshare](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#type-02) | Curated typography discovery | Contemporary/editorial; terms partially verified |
| [TYPE-03 · Utopia](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#type-03) | Fluid type/spacing calculators | Proportional responsive systems |
| [TYPE-04 · Realtime Colors](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#type-04) | Preview palette/type combinations | Flexible visual exploration |
| [TYPE-05 · Radix Colors](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/workflow-tools.md#type-05) | Role-oriented color scales | Systematic product interfaces |

## Findings that can prevent wasted work

1. **Similar names are not interchangeable.** Originkit is distinct from Origin UI/coss. Two plausible liquid-glass-js projects and two liquid-logo projects exist. scrollytelling-prompt remains unresolved.
2. **Source visibility does not mean unrestricted reuse.** React Bits adds Commons Clause restrictions; Shadcnblocks restricts publishing components/derivatives in public repositories; coss uses different licenses by directory. This matters for a public GitHub project. See the exact linked entries before adoption.
3. **Export can determine whether a tool fits.** Rive's inspected plans require payment for shipping `.riv` exports; Spline lists code/self-hosted export under Enterprise. The Framer entry records contradictory official export articles rather than pretending the answer is settled.
4. **A subscription allowance may not cover agent usage.** Higgsfield documents MCP credit consumption separately from web Unlimited allowances. A catalogue entry is not an installed connector or purchasing authorization.
5. **Visual-reference access does not grant asset rights.** Recent, Mobbin, Godly and similar collections are research material. Study the reasoning; do not copy another company's identity or claims.

## Coverage of the originally supplied examples

| Supplied resource | Catalogue record |
| --- | --- |
| Untitled UI Icons | UI-25 |
| Animate UI | UI-26 |
| originkit.dev | UI-19; verification limited, distinct from UI-18 |
| getlayers.ai / Getlayers | VIS-026; duplicate combined |
| Shadcn UI | UI-01 |
| BRIK (brik.space) | VIS-023 |
| mengto/threeui | VIS-011 |
| recent.design | VIS-025 |
| Higgsfield MCP | VIS-027 |
| Sketchfab | VIS-012 |
| scrollytelling-prompt | VIS-019; unresolved identity retained |
| endlesstools | VIS-022 |
| ascii.krackeddevs.com | VIS-015 |
| fluid.krackkeddevs.com | VIS-014; verified domain spelling is fluid.krackeddevs.com |
| liquid-glass-js | VIS-016; ambiguous identity retained |
| liquid-logo | VIS-017; ambiguous identity retained |
| shadergradient | VIS-010 |
| bookofshapes.com | VIS-021 |
| libraries.dev/orbs | VIS-018 |

## Maintain the library

Add useful discoveries without waiting for the owner to supply a complete list. Prioritize a missing capability, better workflow or clear alternative over another indistinguishable effect. Keep IDs stable and record verification dates. Recheck licenses/APIs/plans when actually adopting a resource. Preserve unsuccessful verification as a visible limitation; do not turn “not verified” into “not useful” or “widely used.”

The inherited catalogue focuses on design and frontend delivery, following the supplied examples. Hosting, authentication, payments, backend frameworks and general AI coding products are outside this catalogue's main scope. Famulus's database/search choices are assessed separately in the [product audit](https://github.com/Alperen-Gur/Famulus/blob/d4d3294ec37308c5a6844ed0aae2c9526a352185/docs/research/famulus-audit.md).
