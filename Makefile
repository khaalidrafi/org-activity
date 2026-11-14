EMACS ?= emacs

# Pure elisp: the engine's journal writer is plain string work behind
# temp dirs, the android module parses fixture strings/files, and the
# linux tests stub the process layer entirely.  No -Q here, so a
# distribution's site-lisp is still found (same law as actlog/lark-org).
LOAD = -L .

SRCS = org-activity.el org-activity-linux.el org-activity-android.el

all: compile

compile:
	$(EMACS) --batch $(LOAD) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

test: compile
	$(EMACS) --batch $(LOAD) -l test -l test-linux -l test-android \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f $(SRCS:.el=.elc) test.elc test-linux.elc test-android.elc

.PHONY: all compile test clean
