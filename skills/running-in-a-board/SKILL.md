---
name: running-in-a-board
description: Use when building or changing any Boogy app with a page (every page runs in a board's panes unless the person says it is standalone-only), when the person mentions their board, or when a board's Back, Forward, reload, Smaller/Larger or background misbehave for an app
---

# Running in a board

A board frames your app in a pane and drives it: its own Back and Forward, a
reload that reopens the pane where it was, Smaller/Larger buttons, and its
background behind your page. None of that works by accident, and a check in a
browser tab proves none of it.

**Every app with a page is board-ready by default**, unless the person has said
it is only ever opened on its own. Board-ready from stage 0 means:

- `[boards] background = "board"` in the manifest (below);
- `connectPane({ service })` in the page, with `onNavigate` once it has routes;
- the page scale, which is on by default (never `scale: false`);
- every colour and size in your CSS from an `@boogy/web` token, so it reads in
  the board's scheme on the board's background and follows its size.

`board-ready` is a platform rule: publish refuses an app that is neither
board-ready nor `[frontend] frame_options = "deny"` (`boogy:boogy-serving-frontends`).

## The acceptance checks

Try each in a real board pane, on every stage a person will use there:

| Check in the pane | Passes when | Mechanism |
|---|---|---|
| Open a sub-screen (a form, a detail page) | the pane's Back and Forward appear and step through your screens | every page-like screen is a route, opened with `pane.navigate` |
| Reload the board while on a sub-screen | the same screen comes back | the board reopens the pane at its last reported location; a cold load renders the route from the address |
| Press the board's Smaller / Larger | the type on EVERY screen changes and the layout still fills the pane | the board's zoom arrives as `--u-zoom`; sizes come from SDK tokens or are multiplied by it |
| Open the app from Your apps on a board with a coloured background | the board's colour shows through the app; its text reads | `[boards] background = "board"`: the app draws no page background and renders in the board's scheme |

## Every page-like screen is a route

A screen that fills the pane or reads as a page (New poll, Edit, Invite links,
a detail view) gets its own address. A sheet held in component state leaves
the address unchanged, so the board has nothing to step back over.

```ts
import { connectPane } from "@boogy/web";

type Route = { name: "home" } | { name: "new" } | { name: "retro"; id: string };

function parse(path: string): Route {
  const m = path.match(/^\/retros\/([^/.]+)$/);
  if (m) return { name: "retro", id: m[1] };
  return path === "/new" ? { name: "new" } : { name: "home" };
}

function render(path: string): void {
  const route = parse(path);
  // draw `route` into #app
}

// The board's Back / Forward: the address already shows `path`.
const pane = connectPane({ service: "retro", onNavigate: render });
// A browser tab's Back, where navigate is an ordinary pushState.
window.addEventListener("popstate", () => render(location.pathname));

export function go(path: string): void {
  pane.navigate(path);   // never history.pushState in a frame
  render(path);
}

render(location.pathname);   // a cold load or reload starts on its own route
```

- **`pane.navigate`, never plain `history.pushState`.** In a frame, pushState
  adds to the BOARD's history: the browser's Back walks your app instead of
  leaving the board, and the pane gets no Back/Forward of its own.
- **`onNavigate` turns the pane's buttons on.** The board offers Back and
  Forward only to an app that passes it.
- **`service` is the app's `service.id`.** A board ignores a pane that reports
  another.
- **`navigate` only changes the address**, so render after calling it.
  `pane.navigate("/", { reset: true })` after a sign-out, so Back cannot
  return into the old session.
- **No dot in a route's last segment** (`/retros/42`, not `/retros/v1.2`).
  A dotted request is read as a file and 404s instead of serving your page
  (`boogy:boogy-serving-frontends`).
- There is no replace option: after a save that navigates, the form stays one
  Back away.

## The board's size reaches you as `--u-zoom`

The board's Smaller/Larger (the whole board) and a pane's "Pane size" set the
host zoom. `connectPane` applies it as `--u-zoom` on your page's root. Every
`@boogy/web` component and size token (`--fs-*`, `--space-*`, `--control-*`)
is derived from it and follows.

What does NOT follow:
- `rem` and `px`: the zoom never changes the root font size;
- container-query units (`cqi`, `cqb`, `cqmin`) and viewport units (`vw`,
  `vh`, `dvh`).

So size type from the tokens. When a size must be fluid, multiply it:

```css
.board-title { font-size: calc(6cqmin * var(--u-zoom)); }
```

Code that measures (fitting text to its box, a canvas) re-runs on a zoom
change: `onZoomChange(() => refit())` from `@boogy/web`. At Smaller the
layout must still fill the pane on both axes, not only narrow.

## Showing the board's background

Without a declaration an app paints its own page background over the board.
Declare it from stage 0, unless the page is standalone-only:

```toml
[frontend]
root = "web"

[boards]
background = "board"
```

In a Boards pane the app then draws no page background, renders in the
board's colour scheme (Boards is dark) whatever the viewer's system setting,
and the board paints behind it a colour and transparency the person picks for
each pane, by default black at 33%. Outside a board nothing changes.
The board's colour itself is never told to the app.

In a board your page renders in the board's colour scheme — your text and
controls must read in that scheme (an opaque light page background with
default dark-scheme text will be unreadable).

The CSS contract: paint your page background with `var(--ground)` from
`@boogy/web`, or redefine your own background token under
`:root[data-board-background]`. The SDK's own rule sits in its cascade layer,
so an app's own (unlayered) `body` or `--ground` rule outranks it; a page that
paints its background some other way keeps that paint.

**Redefine only a token used as page paint.** A token also used as a colour
(an ink, a solid ground) must stay opaque, or everything it colours vanishes
with the page: a pill whose text is the page colour goes blank, a switch loses
its thumb. Give the page a token of its own:

```css
:root { --page-paint: var(--paper); }      /* read by nothing but page paint */
body, .screen { background: var(--page-paint); }
:root[data-board-background] { --page-paint: transparent; }   /* never --paper */
```

Covering surfaces keep the app's own colour: an SDK sheet covers with the
opaque `--ground-solid` unless the app sets `--sheet-ground`, and full-page
popovers use `--ground-solid` too. An app that wants them see-through sets
`--sheet-ground: transparent` and hides what they cover.

## Updates

When a newer version of the app is available, the board shows it as an
indicator in the pane's header and the owner updates through the platform's
confirmation page. You write nothing for that. An app that also shows its own
Update control uses `checkForUpdate` and `installUpdate`:

```ts
import { connectPane, checkForUpdate, installUpdate } from "@boogy/web";

const pane = connectPane({ service: "retro", onNavigate: render });
const button = document.querySelector<HTMLButtonElement>("#update")!;

const update = await checkForUpdate({ pane });
if (update) {
  button.hidden = false;
  button.textContent = `Update to ${update.version}`;
  // From a click: framed by a board, this asks the board to open its update
  // dialog; alone, it opens the platform confirmation and reloads on success.
  button.onclick = () =>
    installUpdate(update, { pane }).catch((e) => {
      if (e.code === "popup_blocked") button.textContent = "Allow pop-ups to update";
      else if (e.code !== "upgrade_aborted") throw e; // closed unanswered: a "no"
    });
}
```

- `checkForUpdate({ pane })` is `null` for anyone who does not own the app,
  when nothing newer exists, and inside a board that shows updates itself.
  Show no control of your own when it is `null`. In a frame it waits briefly
  for the board to connect, so call it right after `connectPane`.
- `update.notes` is text from the author; render it as text, never markup.
- `installUpdate` must run from a click, or the browser blocks the window
  (`popup_blocked`); `upgrade_aborted` means the window was closed unanswered.

## Opening the app in a board

1. Open `https://boards.<base>/` (`boards.boogy.app` on the production app
   plane), signed in as the app's owner.
2. Split a pane (**Split into columns**) or pick an empty one. In **Choose an
   app for this pane**, open the app from **Your apps** with **Open in this
   pane**.
3. Run the checks.

Pick it from **Your apps**. Pasting its address makes a plain web-page pane,
which gets no Back/Forward, no reported location and no zoom, so every check
there is meaningless. `[frontend] frame_options = "deny"` keeps an app out of
boards entirely.

**Who runs the checks:** you run them only in a browser signed in to the
person's own board. Otherwise the stage hands the person the checks, in
their words, beside its one question: "In your board: open New retro, press
Back; reload; press Larger. Does your board's colour show through it, with its
text readable? Did each work?"

## Red flags

| Thought | Reality |
|---|---|
| "Nobody said it would run in a board, so I'll leave that out." | Board-ready is the default; only a page the person says is standalone-only leaves it out. |
| "A pushState/popstate router gives back and forward." | In a frame, pushState moves the board's history. Use `pane.navigate` + `onNavigate`. |
| "Text in `rem` scales with the board." | The zoom never changes the root font size. Use SDK tokens; multiply fluid sizes by `var(--u-zoom)`. |
| "`clamp(…vw)` makes it scale with the screen." | Viewport and container units ignore the board's zoom. Multiply by `var(--u-zoom)`. |
| "The New-poll form is a full-pane sheet; no route needed." | A page-like screen without an address has no Back and is lost on reload. Make it a route. |
| "I checked back, reload and size in a browser tab." | A tab is not a pane. Only the board's own buttons are evidence. |
| "I pasted the app's address into a pane to test it." | That is a plain page pane. Open it from **Your apps**. |
| "I'll add my own Update button in the pane." | Pass `pane` to `checkForUpdate`: a board that shows updates answers `null`, so there is one indicator, not two. |
| "The skills give no way to check in a real board." | The steps are above; if you cannot drive their board, hand the person the checks. |
| "In a board my page is see-through, so I'll make my ground token transparent." | Only if nothing else reads it. A token that is also a colour (a pill's text, a solid ground) vanishes with it: give the page a paint token of its own. |
