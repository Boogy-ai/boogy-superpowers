---
name: running-in-a-board
description: Use when a Boogy app with a page will be used inside a board (Boards panes), when the person mentions their board, or when a board's Back, Forward, reload or Smaller/Larger buttons misbehave for an app
---

# Running in a board

A board frames your app in a pane and drives it: its own Back and Forward, a
reload that reopens the pane where it was, and Smaller/Larger buttons. None of
that works by accident, and a check in a browser tab proves none of it.

## The acceptance checks

Try each in a real board pane, on every stage a person will use there:

| Check in the pane | Passes when | Mechanism |
|---|---|---|
| Open a sub-screen (a form, a detail page) | the pane's Back and Forward appear and step through your screens | every page-like screen is a route, opened with `pane.navigate` |
| Reload the board while on a sub-screen | the same screen comes back | the board reopens the pane at its last reported location; a cold load renders the route from the address |
| Press the board's Smaller / Larger | the type on EVERY screen changes and the layout still fills the pane | the board's zoom arrives as `--u-zoom`; sizes come from SDK tokens or are multiplied by it |

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

## Opening the app in a board

1. Open `https://boards.<base>/` (`boards.boogy.app` on the production app
   plane), signed in as the app's owner.
2. Split a pane (**Split into columns**) or pick an empty one. In **Choose an
   app for this pane**, open the app from **Your apps** with **Open in this
   pane**.
3. Run the three checks.

Pick it from **Your apps**. Pasting its address makes a plain web-page pane,
which gets no Back/Forward, no reported location and no zoom, so every check
there is meaningless. `[frontend] frame_options = "deny"` keeps an app out of
boards entirely.

**Who runs the checks:** you run them only in a browser signed in to the
person's own board. Otherwise the stage hands the person the three checks, in
their words, beside its one question: "In your board: open New retro, press
Back; reload; press Larger. Did each work?"

## Red flags

| Thought | Reality |
|---|---|
| "A pushState/popstate router gives back and forward." | In a frame, pushState moves the board's history. Use `pane.navigate` + `onNavigate`. |
| "Text in `rem` scales with the board." | The zoom never changes the root font size. Use SDK tokens; multiply fluid sizes by `var(--u-zoom)`. |
| "`clamp(…vw)` makes it scale with the screen." | Viewport and container units ignore the board's zoom. Multiply by `var(--u-zoom)`. |
| "The New-poll form is a full-pane sheet; no route needed." | A page-like screen without an address has no Back and is lost on reload. Make it a route. |
| "I checked back, reload and size in a browser tab." | A tab is not a pane. Only the board's own buttons are evidence. |
| "I pasted the app's address into a pane to test it." | That is a plain page pane. Open it from **Your apps**. |
| "The skills give no way to check in a real board." | The steps are above; if you cannot drive their board, hand the person the three checks. |
