# AGENTS.md — khaalidrafi/org-activity

Local law for agents working in this repo. Global owner rules apply on
top (Guix-first machine, simple code, tests before implementation,
commit early/often, never procrastinate).

## Identity & commits (HARD LAW)

- Author every commit as your model identity: `MODEL <model@provider>`
  (e.g. `GLM-5.3-Flash <glm-5.3-flash@z.ai>`).
- End every commit message with BOTH trailers:

        Co-authored-by: <agent/harness> <agent@harness>
        Co-authored-by: Khalid Rafi <khaalidrafi@gmail.com>

  Canonical owner email is `khaalidrafi@gmail.com` — no variants.
- One model per commit. Never mix agents' work in one commit.
- Never commit directly to `main`. Branch `ai/main` is the working
  default; feature work on `ai/<topic>`.
- Descriptive subjects; put what comments can't hold in the body.

## This package

- org-activity — a cross-platform (Linux + Android) ActivityWatch
  alternative that journals into plain Org.  Four modules:
  `org-activity.el` (engine, Org CLOCK journal),
  `org-activity-linux.el` (system foreground-window source),
  `org-activity-android.el` (Usage Access screen time import),
  `org-activity-widget.el` (elwidget home-screen widgets).
- Provenance: the engine continues `actlog`; the Android module
  continues `android-usage.el`.  Those repos are superseded — do not
  port fixes back to them; fix here.
- Gate before any push: `make compile` (warnings are errors) and
  `make test` (ERT loads test.el + test-linux.el + test-android.el +
  test-widget.el, all green).  CI runs the same gate.
- Tests live next to the modules; add tests BEFORE the fix/feature
  they cover.  Linux tests stub `org-activity-linux--run`; Android
  tests parse fixture strings — neither needs a desktop or a device.
- elwidget is a SOFT dependency of the widget module: it must
  byte-compile and test green without elwidget on the load-path, and
  only `org-activity-widget-register` may require it at runtime.
- Keep code simple and short; comment the WHY, not the what.
- The engine is a live sampler: never add network, daemons, or
  blocking calls to the tick path.
- Record anything the owner should personally review in AI-REVIEW.org.
