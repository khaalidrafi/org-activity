# HUMANS.md

A guide for human developers who did not write this code. Written from a
fresh read of the sources on 2026-11-18, per the Owner's order that
agents explain AI-generated codebases to humans.

## What this is

org-activity is an ActivityWatch alternative that lives in Emacs and
writes data you own: plain Org files. The same package runs on a Linux
desktop and on Android (the org.gnu.emacs app or Termux). No daemon, no
database, no network. Emacs 29.1 or newer; no other Elisp dependencies.

Three modules, one story:

- `org-activity.el` (the engine): a global minor mode samples the
  current activity every 15 s and journals wall time as ordinary Org
  CLOCK data, one file per day. Because the journal is plain clock
  data, `org-clock-report`, the agenda, and `org-clock-sum` all work
  without this package loaded.
- `org-activity-linux.el` (optional): a source for the engine that also
  credits the system foreground window (hyprctl on Hyprland, xdotool on
  X11) while you work outside Emacs.
- `org-activity-android.el` (optional): device-wide per-app screen time
  from Android's Usage Access data, either read natively by a patched
  Emacs app or imported from a CSV/JSON export, journaled as Org tables.

Provenance (also in AI-REVIEW.org): the engine continues the superseded
`actlog` repo; the Android module continues the superseded
`android-usage.el`. Fixes land here, not there.

## Mental model

The engine is a sampler plus a small accounting machine plus an Org
writer.

    every org-activity-interval seconds:
      org-activity--tick
        -> org-activity-source-function ()  =>  (KEY . MODE) or nil
        -> org-activity--account key mode now idle-secs
             - same activity, user active: accrue delta into the
               live session (session-secs)
             - activity switch or idle: close the old session (write
               its CLOCK line, credit the total), open a new one
             - gap > org-activity-max-gap: process was suspended; close
               what the old session earned, never credit the gap

A "session" is a continuous stretch of one activity key. Live seconds
accumulate in `org-activity--session-secs` and are only credited to the
day totals (and written as a CLOCK line) when the session closes: on
activity switch, on idle, on the periodic flush, on day rollover, or on
shutdown. The flush timer (default 5 min) closes and reopens the
session so a hard kill loses at most that much journal.

The activity key comes from the source function. The default
(`org-activity-emacs-source`) names the front Emacs buffer: the project
name for files inside a project, `Files:<dir>` for project-less files,
`Emacs:<mode>` for special buffers. The Linux module is a drop-in
replacement source that answers `System:<app-class>` when another
application holds the foreground.

The journal layout, one file per day under
`org-directory/org-activity/` (configurable):

    * 2026-11-14 Sat
    ** telega-org
    :PROPERTIES:
    :MODE: Markdown
    :END:
    :LOGBOOK:
    CLOCK: [2026-11-14 Sat 09:00]--[2026-11-14 Sat 09:15] =>  0:15
    :END:

Reports (`org-activity-report`) parse these CLOCK lines back with plain
regexes, so they work on any machine with the files, package loaded or
not.

The Android module is deliberately separate: it keeps its own journal
(`org-activity/android.org`) of per-day tables (App | Package | Time |
Opens), not CLOCK data, because the two data shapes differ (clocked
sessions vs daily aggregates) and the import must stay idempotent by
rewriting whole day sections.

## Code map

| File / symbol | Role |
|---|---|
| `org-activity.el` | The engine. `org-activity-mode`, `org-activity-report`, `org-activity-open-journal`, `org-activity-toggle`; accounting (`org-activity--account`), Org writer (`org-activity--append-clock`), state persistence, the default `org-activity-emacs-source`. |
| `org-activity-linux.el` | System-window source. `org-activity-linux-source` plus hyprctl/xdotool detectors (`org-activity-linux--hyprctl`, `--xdotool`, all funneled through `org-activity-linux--run`). |
| `org-activity-android.el` | Usage Access module: CSV/JSON parsing, aggregation, idempotent day-table journal, pure-Elisp SVG charts, dynamic blocks, native `android-usage-stats` pull, `org-activity-android-mode`, reports, capture template. |
| `test.el` | Engine ERT suite (22 tests). Hermetic: temp dirs via `org-activity-test--env`, TZ pinned to UTC. |
| `test-linux.el` | Linux source suite (6 tests). Stubs `org-activity-linux--run` with `cl-letf`; no X server or binaries needed. |
| `test-android.el` | Android module suite (43 tests), fixture strings; native primitive stubbed with the fbind/fmakunbound dance. |
| `Makefile` | `make compile`, `make test`, `make clean`. |
| `NATIVE-USAGE.org` | Spec for the Emacs-fork patch series that adds the `android-usage-stats` primitive. |
| `AI-REVIEW.org` | Provenance notes, design decisions to sanity-check, test state, what is deliberately not done. |
| `AGENTS.md` | Repo law: identity, branch rules, gates. Read before committing. |

## Core algorithms

The accounting machine (`org-activity--account` in org-activity.el).
Every tick funnels here with the sampled key, the mode, the time, and
the input idle seconds. It computes `delta` since the last sample and
branches: (1) `delta > org-activity-max-gap` (default 900 s) means the
process was suspended or killed (common on Android); the pre-gap
session is closed for what it honestly earned and the gap itself is
never credited, so a phone in a pocket cannot log phantom hours. (2)
Same key and idle below `org-activity-idle-threshold` (default 180 s):
add `delta` to the live accumulator. (3) Otherwise (switch or idle):
close the live session, ending it at `now - idle-secs` when idle (an
idle stretch only counts up to where idleness began), and open a new
session. Totals are credited only when sessions close, never per tick.

Day rollover (`org-activity--rotate-day-if-needed`). When the day
string changes, a running session is split at local midnight: its
pre-midnight live seconds are closed into the old day's journal, then
books reset and the session continues in the new day.

The Org writer (`org-activity--append-clock`). Finds the day's level-1
heading (creating it at the end if absent), finds the `** KEY` entry
inside that section (creating it with a `:MODE:` property and a
`:LOGBOOK:` drawer on first session of the day), and inserts the CLOCK
line inside the drawer. Hand-written entries without a drawer get one
appended after their body; the writer never touches a `:PROPERTIES:`
block. Files are opened with backups and lockfiles disabled.

Reading the journal back (`org-activity--parse-day`). Line-oriented
regex scan: a `** KEY` heading sets the current key; each
`CLOCK: [...]--[...] =>  H:MM` line adds its minutes to that key. This
is why report totals are minute-granular (the writer floors durations
to minutes to match Org convention).

State persistence (`org-activity--save-state` / `--load-state`). The
whole tracking state is `prin1` of a plist to
`org-activity-state-file` (default `org-activity-state.el` under
`user-emacs-directory`). Loading tolerates corruption (a broken file
means a fresh day, never an error) and drops state whose `:day` is not
today, since that day's journal already holds its time.

The Linux source (`org-activity-linux-source`). Probes hyprctl first,
then xdotool, via `org-activity-linux--run`, which never signals (a
missing tool just disables its detector). If the active window's PID
equals `emacs-pid`, the default Emacs source answers so buffers, not
"Emacs", get credited. Any other window becomes one row per
application class (`System:firefox`) with the window title as the
entry's mode, truncated to `org-activity-linux-title-max` (60). When no
detector answers (plain Wayland, headless), it degrades to Emacs-only
tracking rather than miscrediting unfocused time.

The Android CSV parser (`org-activity-android--split-csv` and friends).
A hand-rolled RFC 4180 splitter (quote handling, doubled quotes, CRLF).
Column detection normalizes header cells (lowercase, non-alphanumerics
stripped) and matches against a candidate table
(`org-activity-android--header-candidates`): a `:package` or `:label`
column is required or import errors. Durations parse from `H:MM:SS`,
`H:MM`, `1h 23m 4s`, or bare numbers; bare numbers get a unit sniff
(`org-activity-android--sniff-duration-unit`): if any value in the
column exceeds 48 h worth of seconds, the column is milliseconds.
JSON imports accept the canonical `{"days": [{"date": ..., "apps":
[...]}]}` shape, a flat `{"usage": [...]}` list, or a bare list of
rows.

Aggregation (`org-activity-android--aggregate`). Rolls row plists into
day -> package -> `(SECONDS . OPENS)`, dropping ignored packages (by
default `^com\.android\.systemui$`; launchers are NOT ignored). Labels
ride along as `label:PKG` pseudo-entries; the longest label seen per
package wins.

Idempotent day writes (`org-activity-android--write-day`). Each day's
section in the journal is located by its level-1 heading regexp, and
the whole section body between that heading and the next level-1
heading is deleted and rewritten. Re-importing the same export never
duplicates rows.

Charts (`org-activity-android--svg-hbars` / `--svg-vbars`). Pure
string SVG generation: a horizontal bar chart (at most 20 rows, label
width estimated from the longest label) and a per-day vertical bar
chart. No gnuplot, no ImageMagick; works on Emacs Android. Text is
XML-escaped.

The native pull (`org-activity-android--pull-native`). On a patched
Emacs app (see NATIVE-USAGE.org), the primitive
`(android-usage-stats BEGIN-MS END-MS)` is queried over each of the
last `org-activity-android-native-days` day windows (local midnight to
midnight, epoch milliseconds). Entries with zero foreground time are
dropped; opens are honestly 0 because UsageStats carries no open
count. `--pull-auto`, the default `org-activity-android-pull-function`,
tries native first and falls back to the newest recognizable export in
the import directory.

## Invariants and gotchas

- Totals are credited only at session close. The live accumulator
  (`org-activity--session-secs`) keeps the mode line current but is
  not in the totals until a close happens.
- Never credit a suspension gap. Anything longer than
  `org-activity-max-gap` (900 s default) between samples is discarded.
  Idleness beyond `org-activity-idle-threshold` (180 s default) stops
  accrual the same way.
- The flush timer bounds data loss: every
  `org-activity-flush-interval` (300 s default) the session is closed
  into the journal, reopened, and state saved.
- Tick path law (AGENTS.md): never add network, daemons, or blocking
  calls to the sampler tick. Note the Linux source does run
  hyprctl/xdotool synchronously each tick; that is the existing design
  and the reason the detectors must stay cheap.
- Two journals, two shapes. The engine writes CLOCK data to
  `org-activity/YYYY-MM-DD.org`; the Android module writes tables to
  `org-activity/android.org`. They are not merged (a deliberate v1.0
  scope cut, recorded in AI-REVIEW.org).
- Report totals are minute-granular because CLOCK durations are written
  floor-to-minute and parsed back as H:MM.
- State from a previous day is dropped on load; only same-day state is
  restored. A corrupt state file silently starts fresh.
- In the Android module, the row labeled `Total` is skipped when tables
  are parsed back; the `label:PKG` entries are internal aggregate
  bookkeeping, never table rows.
- `org-activity-android-import` is an alias for
  `org-activity-android-import-file` (kept for the README).
- Journal writes disable backups and lockfiles
  (`make-backup-files`/`create-lockfiles` bound nil).
- Provenance rule: do not port fixes back to `actlog` or
  `android-usage.el`; those repos are superseded. Fix here.

## Developing

From the Makefile and CI:

    make compile   # byte-compile all three modules, warnings are errors
                   # (byte-compile-error-on-warn t)
    make test      # depends on compile; loads test.el + test-linux.el +
                   # test-android.el, runs ERT batch; exits 0/1
    make clean

Test counts (grep of the sources): 71 `ert-deftest` forms total, 22 in
`test.el`, 6 in `test-linux.el`, 43 in `test-android.el`. All offline:
the engine suite uses temp dirs and pins TZ to UTC, the Linux suite
stubs the process runner, the Android suite parses fixture strings.
CI (`.github/workflows/ci.yml`) runs `make compile` and `make test` on
Emacs 30.1 (purcell/setup-emacs).

Branch law (AGENTS.md): never commit directly to `main`. `ai/main` is
the working default; feature work on `ai/<topic>`. Gate before any
push: `make compile` and `make test` green. Write tests before the fix
or feature they cover. Commit as the model identity with both
co-author trailers. Record anything the Owner should personally review
in AI-REVIEW.org.
