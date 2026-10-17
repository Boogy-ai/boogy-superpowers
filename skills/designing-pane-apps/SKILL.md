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
- **A `TopBar`** (`@boogy/web/preact`, or the core `topBar()` attributes in
  an app without Preact). If the app has one, **every screen
  has it, with the same structure**: the same leading control, the title in
  the same place, actions in the same slot. A TopBar that appears on the list
  but not the detail, or moves its actions between screens, reads as two apps.
  An action may carry an SDK glyph beside its label (`glyph: 'plus'`), or be
  the glyph alone (`icon`, named by its label).
- **Tabs** (`TabList`, or `TabPager` for swipeable pages on a phone) when the
  app is a few peer views. The tabs show on every screen they lead to.

Whatever you pick, **draw no Back button of your own**: the pane's header has
Back and Forward, driven by your routes (`boogy:running-in-a-board`). A second
Back inside the page disagrees with the board's.

**Back and Forward never show a screen half-drawn.** A screen whose title
comes from data (a room's name, a record's title) draws it at once from the
copy the app already read, from the list it came from or an earlier visit,
and replaces it when its own re-read lands. A blank title, then the real one,
flickers on every Back. Keep the last copy of each record the page read, by
id, and forget one the reader lost. A part still loading holds its place
(an empty body the size of the list it will be), so nothing below it jumps,
and it never says "nothing here" before it has read.

The `@boogy/web/preact` components work in a `build = "source"` app as well
as a built one: the platform serves them for the app's pinned SDK version, as
long as the app vendors Preact, which the source template does
(`boogy:boogy-serving-frontends`).

## 3. Lay out each screen by what it holds, at every width

Before drawing a screen, name what it holds. A screen is rarely one thing,
and each kind of content gets a place of its own:

- **A list that grows** (people, messages, things a person made) goes in a
  `Panel` of its own. The panel's head holds the list's title, its count, its
  filter and its search, and stays put. Only its body scrolls, a page at a
  time. Never put a growing list in the page's flow above anything else:
  every row it gains pushes the rest down.
- **A form that makes something** (an invite link, a room) goes in a `Panel`
  of its own, as tall as its content. What it just made shows in the same
  panel (the new link, with Copy). It never shares a column with the list of
  what it made.
- **A fact or two** (a name, a state) goes in an `InfoList`, or in a panel's
  head.

Then lay those out for the width the screen has, the way products people
already know do it (a members page in a chat app's settings, an inbox):

| The screen's width | Layout |
|---|---|
| Wide (a pane on its own, a big tab) | Columns. The main list takes the width, and a form with its list sits in an aside beside it: `SplitView`, with an `aside` region. Every column fills the height, and nothing makes the page scroll |
| Narrow (a pane beside others, a phone) | `SplitView` shows a row of tabs, one region at a time, each tab with its region's count |

`SplitView` decides by its own width, not the window's, so a pane in a board
is narrow in a wide window. Pick its `collapseAt` from what the widest region
needs: a list with columns (Role, Joined) needs `lg`.

- **No single column stretched across a wide pane, and no half of it left
  empty.** Content that fits one column on a wide pane is a narrow screen:
  give the rest of the width to a second region.
- **A list's columns earn their place.** On a narrow screen they fold into a
  row's second line ("Member · joined Oct 9").
- **A count beside a label is a `Count` badge**, never "Label · 12" or
  "Label 12" run together: on a tab (`TabItem.count`), on a segment
  (`ChoiceItem.count`), anywhere a label says how many it holds.
- **Name a thing by what it is.** A field choosing a room is "Room", not
  "Opens"; a row for an invite shows the room's name. A label describes the
  thing, not what the code does with it.

**Match the control to the size of the choice:**

| The choice | Control |
|---|---|
| Two to four short, fixed options (1 day / 7 days / 30 days; Active / Removed) | `ChoiceGroup variant="segmented"`, `fill` to share a column's width, a `count` on a segment that holds some |
| A short fixed list, each option worth a line of description | `ChoiceGroup` |
| One of a set that grows (rooms, people, anything a person or the service adds to) | `SearchSelect`: a field that opens a search over the service's own paged results. Never a radio per row of data, and never a dropdown of the first page |
| On or off | `Switch` |

## 4. One scroll region per panel

- The page never scrolls sideways at any pane width.
- On a wide screen nothing makes the page itself scroll: each growing list
  scrolls in its own `Panel`, whose head (and foot) stay put. On a narrow one,
  the selected tab's region is what scrolls.
- Never a scroll inside a scroll: a panel's body scrolls and nothing inside
  it does. A pane is often short, and nested scrolling traps the wheel.
- A list pages: it loads the next page as the reader nears its end, and any
  total it shows is a count the service stores, never the rows loaded so far
  (`boogy:boogy-serving-frontends`, "Every list pages; every count is
  stored").

## 5. Density follows the intent

- Panel apps use the SDK's compact sizes (`size="sm"` controls) and show the
  one thing first. A pane can be a few hundred pixels high.
- Full apps keep their normal density.
- Both follow the board's Smaller/Larger only through SDK tokens
  (`boogy:running-in-a-board`).

## 6. Surfaces and forms in a board

In a board an app that shows the board's background (`[boards] background =
"board"`) draws no page colour. The board's colour shows through, and:

- **Form fields** from the SDK (`TextField`, `TextArea`, `SearchField`, or
  the core `field()` attributes on plain elements) fill
  with a light translucent wash, so the board shows through them. Build fields
  from the SDK, never a hand-styled `<input>` with an opaque fill.
- **Raised surfaces** (a card) use `--ground-raised`. Surfaces that cover the
  page (a `Sheet`, a `SidePanel`) use `--ground-solid`, which in a board is the
  board's own colour.
- **Background components are translucent and frosted, to a reasonable
  degree.** A side panel, a drawer, a bar along an edge, a message bar: the
  board shows through them, blurred, so the app reads as part of the board
  rather than a box on top of it. Never at the cost of reading: text on them
  must still read over a busy board (a pattern, a photo). So keep most of the
  ground behind text and blur what is behind it. The SDK's `Drawer` (over the
  board's background) and a `Sheet`'s composer bar already do; a panel of
  your own uses the same tokens:

  ```css
  .my-panel {
    background: color-mix(in oklch, var(--ground-raised) var(--panel-frost), transparent);
    backdrop-filter: blur(var(--blur-md));
  }
  ```
- **No opaque page-colour fill** behind content: a white or black box behind a
  list hides the board and reads as a hole in it.
- **A popover has no padding of its own; whatever is in it pads itself.**
  Each SDK component made for a popover (a menu, a `ColorPicker`) pads its
  own sections with `--space-3` and rules them apart. Content of yours in a
  popover, above all beside or under one of those, does the same: its own
  `padding: var(--space-3)` and a `--rule` between it and its neighbour.
  Never count on a neighbour's padding: a column placed beside a
  self-padding component has none, and runs into the popover's edge.
- **A sidebar is compact, and two sidebars do not look alike.** A list of
  places to go (rooms, pages, channels) is `<List density="compact"
  variant="nav">`: one short line each with `size="xs"` media, the open one
  (`current`) filled with the accent. A second drawer beside it (a
  conversation's members) is `<Drawer variant="plain">`, on the page's own
  ground with only its edge between them, so the two read as different
  things; laid over the page in a narrow pane it still has a ground. A
  `SearchField` in a drawer's `head` gives way on the strip by itself.
  The drawer's title (a `DrawerItem variant="title"`, the app's or
  workspace's name and logo, a link home) and its own `DrawerToggle` go in
  its `head` together: the SDK lays them in one row, the toggle beside the
  link, never inside it. With that toggle `shown="expanded"` and its pair
  `shown="collapsed"` in the `foot`, the folded strip keeps the logo at its
  head, ruled off from the list. Give every `DrawerToggle` the same size
  (the default): a size per toggle makes the fold and unfold buttons differ.
  On the strip the open item is the only one not dimmed, with a thin rail at
  the edge; never a ring, outline or tile round it. Give the layout `resizable` (and keep the
  `onWidthChange` width) so the reader can drag it wider. A sidebar's toggle
  never goes before a bar's title, where a Back is read: the bar gets a named
  action instead (`glyph: 'sidebar'`), and only while that drawer is laid
  over the page (`useDrawerMode() === 'overlay'`): beside the page, it is
  already there, with its own toggle.
- **A place or a group wears a flat colour; a person, seeded art.** A room's
  or a channel's avatar is `<Avatar art="flat" variant="rounded">`: one
  bright colour from a few far apart, seeded from its id, so neighbours
  differ plainly. People keep the default, darker art.
- **A drawer pads and scrolls its own content; put yours straight in it.**
  No wrapper of yours with an `overflow` of its own: a second scroller inside
  the drawer draws its own scrollbars, and `overflow-y: auto` scrolls the
  other axis too, so anything a hair too wide gets a horizontal scrollbar.
  Folded to its strip, the drawer folds what is in it for you: a `List` to
  its items' media (an avatar, say), entry-sized and centred, and a `Section`
  to its `glyph` over its `meta`, with a rule under them
  (`<Section title="Members" glyph="users" meta={<NumericValue value={n} variant="compact" />}>`).
  Never hide the SDK's slots by hand to make a strip: a hand-made fold keeps
  sizes that were set for the open drawer, and they do not fit. A heading that
  must not scroll away (the list's title, its count, the collapse toggle)
  goes in the drawer's `head`, which stays at the top while the list under it
  scrolls. Actions go in the drawer's `foot`, which stays at its bottom edge while the rest scrolls
  under it and on the strip keeps only its toggles; to collapse it from its
  head and expand it from its foot, give the head
  `<DrawerToggle shown="expanded" />` and the foot
  `<DrawerToggle shown="collapsed" />`, each with a `label` naming what it
  shows ("Show members").
- **A form is a `Form`**, put in the screen's column after its bar. Its
  fields scroll in its body, as wide as it is (they grow with the pane, as
  everything does); its actions stay in its foot, never scrolling in or out of
  view, at the fields' edge. While
  its `onSubmit` runs, its primary action says so ("Saving…") and cannot be
  pressed twice; throw from `onSubmit` and the error's message shows in the
  foot.

  ```tsx ignore-snippet: a screen fragment; the app's own state and calls are not in scope
  <Form onSubmit={save} actions={<><ActionButton kind="cancel" onClick={back} /><ActionButton kind="save" /></>}>
    <TextField label="Name" value={name} onValueChange={setName} maxLength={60} />
    <TextArea label="Description" value={about} onValueChange={setAbout} maxLength={200} />
  </Form>
  ```
- **Every common action is an `ActionButton` of its kind**: `save`, `create`,
  `add`, `send`, `accept`, `confirm`, `done`, `upload`, `cancel`, `close`,
  `decline`, `delete`, `remove`, `discard`, `archive`, `unarchive`. The kind sets its words, its look,
  its glyph, what it says while it runs ("Deleting…") and its place in a foot
  (a destructive one first, the rest at the end). Give it words of your own
  only to say more (`<ActionButton kind="delete">Delete room</ActionButton>`).
  Never a `Button` with a hand-set variant and label for one of these.
- **A field with a limit shows it**: `maxLength` on a `TextField` or a
  `TextArea` counts under it ("62 / 200"). **One image** (a logo, a picture)
  is an `ImageField`: the image or its name's initials, Upload and Remove,
  with the type and size checked before anything is sent; its `onPick` gets
  the file and uploads it (`boogy:boogy-file-storage`).
- **A list beside the content** (rooms beside a conversation, as a chat
  shows them) is a `<List density="compact">` in a `Drawer` on the start side,
  the open item `current`. Folded to its rail it shows each item's media, a
  pip for one with something new and a ring round the open one; in a narrow
  pane it slides over the content, and its `DrawerToggle` in the bar shows a
  dot (`unread`) when something behind it is new. A second drawer on the end
  side (members) is a second `DrawerLayout` inside the first's `DrawerMain`:
  each folds and opens on its own, and the nested one fills the main area. A
  toggle in the bar sits inside the nested layout, so a toggle for the rooms
  is given the rooms layout's handle: `useDrawerHandle()` called under the
  rooms layout, passed down as `<DrawerToggle drawer={rooms} />`.
- **A destructive action asks once, in place**: `<ConfirmAction label="Delete"
  question="Delete this message?" onConfirm={…}>` turns into the question
  and its two answers where the button was. No dialog covering what is being
  acted on, and no action that destroys on the first press. On a row repeated
  many times (a message), `iconOnly` with a `glyph` keeps it to its icon.
- **What a reader can do to one message goes in `Bubble`'s `actions`**: at
  the end of its meta line, shown on hover or focus where a mouse can hover,
  always on touch. A notice that offers one thing to do takes it as
  `Notice`'s `action` ("Archived. Unarchive"); a row with something new in it
  is `ListItem`'s `unread`.
- **A count or an amount is a `NumericValue`**: grouped the reader's way
  (4,200 or 4.200), or `variant="compact"` (4.2K) where room is short, with
  `decimals` and `trimZeros` for amounts. Never format a number by hand.
- **Code is a `CodeBlock`**: highlighted by highlight.js (the SDK loads it
  from the platform the first time a block shows, so a page with no code
  never downloads it), under its language's name, with Copy, scrolling
  sideways inside itself. Text people write that may hold code (a message, a
  note) renders through `<FencedText text={…} collapseAfter={10} />`, which
  turns markdown fences (```` ```py ````) into code blocks, each showing its
  first lines with a footer that shows the rest. A markdown block
  (```` ```md ````) shows two tabs, Preview (rendered) and Markdown (its
  source); markdown anywhere else renders through `<Markdown text={…} />`.
  Its HTML is always sanitised (DOMPurify), and links open in a new tab.
  Never a highlighter or markdown renderer of your own, and never code or
  markdown set as HTML yourself.
- **Links in a message are links, and the first two get a preview**, as
  other messengers show them. `FencedText` does both: the web addresses in
  its text (never its code) open in a new tab, and its first two https links
  each get a card under the text (the site, the title, the description, the
  image), side by side where the message has room. Further links stay links
  only, and a card is kept for hours, so an edited page shows its old card a
  while. `previews={0}` turns the cards off;
  `<LinkPreview url={…} />` shows one anywhere else. The platform reads the
  linked page and serves its image (`boogy:boogy-serving-frontends`), so the
  app needs no `outbound_http`, no allowed host and no CSP change. Never fetch
  a linked page from your own service to preview it.
- **A message bar** at the foot of a page is the SDK's `Composer`: in a
  `Sheet`'s foot it is the bar by itself, and on any other page
  `<Composer variant="bar">` makes it one. Either way it is a light, frosted
  well with its send button level with the text; do not frame or style your
  own.

## 7. Colour comes from the board

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
- **Leave the colours to the board unless you mean otherwise.** A colour
  token your app sets on plain `:root` (`--accent`, `--hue`, `--tint`)
  outranks the board's, so the app keeps it on every board. The project
  template (`boogy new`) sets its colours only outside a board, under
  `:root:not([data-board-background])`; keep yours there.
- **An app with its own brand accent** sets `--accent` in its own stylesheet,
  **outside any `@layer`**, on plain `:root`. Unlayered CSS outranks the board's accent, which
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
| Put a busy pattern behind the board | drawers, bars and panels show it through, blurred; every word on them still reads |
| Open every popover and menu you compose | nothing touches its edge: every block in it has the same padding as the SDK's own sections |
| Fold every drawer to its strip | nothing is clipped and no scrollbar appears; a section shows its glyph over its meta, with even space either side of the rule under them |
| Change the pane's colour (its **Pane colour**, in the pane's bar or menu) while the app is open | the app follows without a reload |
| Walk every screen | the chosen chrome (none, TopBar, tabs) is on every screen with the same structure; no screen draws its own Back |
| Make the pane short and narrow | one region scrolls; nothing scrolls sideways |
| Open every screen in a wide pane (about 1100 px) and a narrow one (about 400 px) | wide: its regions in columns, each the full height, no empty half, the page itself never scrolls; narrow: tabs with their counts, one region at a time |
| Seed every list past one page, then scroll it | the next page loads as you near the end; the list scrolls in its own panel and nothing beside or below it moves; every total shown is the stored count, not the rows loaded |
| Choose from every picker with the set seeded past a page | a set that grows is searched through the service, not listed; a fixed set of a few is segmented |

## Red flags

| Thought | Reality |
|---|---|
| "The list screen needs a TopBar; the detail is fine without." | Chrome is a whole-app decision: every screen has it, the same, or none do. |
| "It's a short list; one request gets it all." | Lists grow. It pages from the first screen, and its total is a stored count. |
| "Everything fits in one column." | On a wide pane that is one column and an empty half, and every list in it pushes the next down. Name the regions; lay them out with `SplitView` and `Panel`. |
| "A radio for each room keeps it simple." | Rooms grow; that radio list is a list as long as the set. A choice from a set that grows is a `SearchSelect` over the service's search. |
| "I'll put the count after the label: Members 10K." | It reads as part of the label. A count is a `Count` badge. |
| "I'll add a Back button at the top of the detail page." | The pane's header has Back and Forward. Drive them with routes; draw none of your own. |
| "A white card behind the list makes it readable." | An opaque page colour hides the board. Use `--board-surface` / `--ground-raised`. |
| "I'll hand-style the inputs to match." | SDK fields are already translucent and board-coloured in a board. Use them. |
| "The chart uses a nice fixed palette." | It clashes with every board but one. Derive series from `--board-accent`. |
| "It's built for my board, but I'll design it as a full website." | A panel app is compact and shows the one thing first. Settle the intent before the screens. |
