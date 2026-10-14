---
name: designing-pane-apps
description: Use when designing the screens of a Boogy app that will be used in board panes (every app with a page is, unless standalone-only) - deciding its navigation chrome, density, scrolling, forms, surfaces and colours before building them, and checking the result on a board's colours
---

# Designing pane apps

A board shows your app in a pane, beside other apps, on a colour the person
picks. The mechanics of running there (routes, zoom, the board's background)
are `boogy:running-in-a-board`. This skill covers the decisions that come
before them, the ones that shape every screen. Make them first and write them
down. Each one commits every screen, so a decision applied to some screens and
not others is the most common way a pane app breaks.

## 1. Intent: built for panels, or also works in a pane?

Ask the person, or read it from what they said. It decides every default below.

| | Built for board panels | Also works in a pane |
|---|---|---|
| What it is | A small, glanceable app that lives beside others: a counter, a feed, a poll, a status | A full app (several screens, real forms) that must not break when framed |
| Screens | Often one, with sheets for detail | Several, each a route |
| Density | Compact: the one thing first, no hero, no marketing copy | Normal |
| Chrome | Usually none | Decide (§2) |

"Next to my other apps", "on my board" and "a widget" mean built for panels.
"An app" with several pages, opened sometimes on its own, means also works in
a pane.

## 2. Navigation chrome: none, a TopBar, or tabs

Pick one for the WHOLE app before drawing a screen:

- **None.** The pane's own header already shows the app's name and the
  board's Back and Forward. A panel app usually needs nothing more.
- **A `TopBar`** (`@boogy/web/preact`). If the app has one, **every screen
  has it, with the same structure**: the same leading control, the title in
  the same place, actions in the same slot. A TopBar that appears on the list
  but not the detail, or moves its actions between screens, reads as two apps.
- **Tabs** (`TabList`, or `TabPager` for swipeable pages on a phone) when the
  app is a few peer views. The tabs show on every screen they lead to.

Whatever you pick, **draw no Back button of your own**: the pane's header has
Back and Forward, driven by your routes (`boogy:running-in-a-board`). A second
Back inside the page disagrees with the board's.

## 3. One scroll region per screen

- The page never scrolls sideways at any pane width.
- A screen has one region that scrolls (a list, a feed). Headers and actions
  stay put, as the SDK's `Sheet` holds its head and foot.
- Never a scroll inside a scroll. A pane is often short, and nested scrolling
  traps the wheel.

## 4. Density follows the intent

- Panel apps use the SDK's compact sizes (`size="sm"` controls) and show the
  one thing first. A pane can be a few hundred pixels high.
- Full apps keep their normal density.
- Both follow the board's Smaller/Larger only through SDK tokens
  (`boogy:running-in-a-board`).

## 5. Surfaces and forms in a board

In a board an app that shows the board's background (`[boards] background =
"board"`) draws no page colour. The board's colour shows through, and:

- **Form fields** from the SDK (`TextField`, `TextArea`, `SearchField`) fill
  with a light translucent wash, so the board shows through them. Build fields
  from the SDK, never a hand-styled `<input>` with an opaque fill.
- **Raised surfaces** (cards, a panel inside the page) use `--ground-raised`.
  Surfaces that cover the page (a `Sheet`, a `SidePanel`) use `--ground-solid`,
  which in a board is the board's own colour.
- **No opaque page-colour fill** behind content: a white or black box behind a
  list hides the board and reads as a hole in it.

## 6. Colour comes from the board

The board tells your app the colour it paints behind the pane, and the SDK
takes its palette from it with no code of yours. Text leans to the board's
hue, raised and covering surfaces sit on the board's colour, and the accent is
the board's hue at a lightness that reads on the dark scheme (grey on a grey
board). It follows the person's changes live.

For your own components, use the tokens. **Never a literal colour.**

| Token | Is |
|---|---|
| `--board-ground` | the colour behind the pane |
| `--board-surface` | a step above it: a card, a raised panel |
| `--board-accent` | the accent derived from it |
| `--board-field` | a form field's translucent wash |
| `--accent`, `--text-1`/`-2`/`-3`, `--edge` | the SDK's own, already adopted |

Outside a board the `--board-*` tokens are unset. Give each one a fallback to
the app's own token:

```css
.chart-series-1 { color: var(--board-accent, var(--accent)); }
.chart-series-2 { color: color-mix(in oklch, var(--board-accent, var(--accent)) 60%, var(--text-1)); }
.stat-card { background: var(--board-surface, var(--ground-raised)); }
```

- **A chart's series** derive from the accent, stepping its lightness or
  mixing it toward the ink. They never use a fixed rainbow that clashes with
  the board.
- **An app with its own brand accent** sets `--accent` in its own stylesheet,
  **outside any `@layer`**. Unlayered CSS outranks the board's accent, which
  the SDK sets inside its own layer. A framework that puts its theme in a layer
  of its own (Tailwind's `@layer theme`, say) declares that layer first, so it
  loses: set the accent unlayered. `--board-accent` stays the derived one, to
  use where matching matters more than the brand.

## Acceptance checks

Open the app in a real board pane from **Your apps**
(`boogy:running-in-a-board` has the steps). Then:

| Check | Passes when |
|---|---|
| Put the board on two different colours (one warm, one cool) | fields, cards and accents take each colour; text reads on both |
| Change the pane's colour (its **Pane colour**, in the pane's bar or menu) while the app is open | the app follows without a reload |
| Walk every screen | the chosen chrome (none, TopBar, tabs) is on every screen with the same structure; no screen draws its own Back |
| Make the pane short and narrow | one region scrolls; nothing scrolls sideways |

## Red flags

| Thought | Reality |
|---|---|
| "The list screen needs a TopBar; the detail is fine without." | Chrome is a whole-app decision: every screen has it, the same, or none do. |
| "I'll add a Back button at the top of the detail page." | The pane's header has Back and Forward. Drive them with routes; draw none of your own. |
| "A white card behind the list makes it readable." | An opaque page colour hides the board. Use `--board-surface` / `--ground-raised`. |
| "I'll hand-style the inputs to match." | SDK fields are already translucent and board-coloured in a board. Use them. |
| "The chart uses a nice fixed palette." | It clashes with every board but one. Derive series from `--board-accent`. |
| "It's built for my board, but I'll design it as a full website." | A panel app is compact and shows the one thing first. Settle the intent before the screens. |
