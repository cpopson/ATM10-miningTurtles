# cc-fleet-miner documentation

Operator guides for the mining fleet. These are HTML pages — open them in a
browser from a local clone (github.com shows the raw source, not the page).
`index.html` is the same list as a styled landing page.

## Guides

| Guide | Covers | Read it when |
| ----- | ------ | ------------ |
| [control.html](control.html) | The `control.lua` station: job wizard, live dashboard, fleet keyboard controls, crash-safe resume. | You want to run 2–5 turtles on a quarry from one computer + monitor. |
| [dig.html](dig.html) | The `dig` program (the `tunnel.lua` pattern): a straight W×L×H corridor, torch-lit, floor patched over caves and lava, loot streamed to an Ender Chest. | You want one standalone turtle to cut a corridor. No modem needed. |
| [strip.html](strip.html) | The `strip` program (the `branch.lua` pattern): a spine corridor with paired ribs at a fixed spacing, plus ore-vein following. | You want one standalone turtle to run a strip mine that also chases the ore it uncovers. |
| [fleet-and-control.html](fleet-and-control.html) | The `ccfleet` rednet protocol: the six message types, who sends what, and a full run traced message by message. | You're changing `comms.lua`, `coordinator.lua`, or `worker.lua`, or debugging a fleet that won't start. |

Start with **control.html** if you're new — it's the operator guide.
**fleet-and-control.html** is its internals companion.

## Archived plans

[`plans/`](plans/) holds completed build plans, kept for design rationale.
They describe finished work and are **not** current documentation — the code
and its tests are the source of truth.

- [plans/quarry-plan.md](plans/quarry-plan.md) — how `quarry.lua` was designed
  and built (box geometry, the layer-flip rule, the return path).
- [plans/branch-plan.md](plans/branch-plan.md) — how `branch.lua` was designed
  and built (why ribs are cut mid-sweep, the vein DFS, the `onProgress`
  excursion contract it leans on).

## Adding a guide

Every page shares one stylesheet, [`style.css`](style.css) — the palette
(light + dark), page shell, typography, TOC, code/terminal blocks, tables,
callouts and cards. A new guide starts:

```html
<link rel="stylesheet" href="style.css">
<style>
  /* only this page's own widgets go here */
</style>
```

Conventions to keep the set consistent:

- **Name the file after the thing it documents** — the program (`dig.html`,
  `control.html`) or the topic (`fleet-and-control.html`).
- **`<title>` is `cc-fleet-miner — <Page Name>`**, and it should match the `<h1>`.
- **Put page-specific rules inline, not in `style.css`.** Widget classes are
  page-local by design: `.legend` means different things in `dig.html` and
  `fleet-and-control.html`, so each defines its own.
- **Need a wider page?** Override `--wrap-max` in the page's own `:root`
  (`fleet-and-control.html` uses `940px`); don't edit the shared default.
- **One breakpoint: `640px`.** Use it for page-specific responsive rules too.
- Add the new page to this table and to `index.html`.
