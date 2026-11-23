;;; test.el --- ERT suite for org-activity -*- lexical-binding: t; -*-

;; TZ is pinned so day boundaries and CLOCK timestamps are deterministic.

(require 'ert)
(set-time-zone-rule "UTC")

(unless (bound-and-true-p org-activity--loaded)
  (load (expand-file-name "org-activity.el" (file-name-directory load-file-name)))
  (setq org-activity--loaded t))

(require 'org)
(require 'org-clock)

(defvar org-activity-test--dirs nil
  "Temp directories made by the suite, cleaned in `org-activity-test--clean'.")

(defun org-activity-test--clean ()
  (dolist (d org-activity-test--dirs)
    (ignore-errors (delete-directory d 'recursive)))
  (setq org-activity-test--dirs nil))

(defun org-activity-test--temp (name)
  (let* ((parent (make-temp-file "org-activity-test-" 'directory))
         (dir (expand-file-name name parent)))
    (push parent org-activity-test--dirs)
    (make-directory dir t)
    dir))

(defmacro org-activity-test--env (&rest body)
  "Run BODY with a hermetic org-activity: temp journal + state, fresh books."
  `(let* ((dir (org-activity-test--temp "env"))
          (org-activity-org-dir (expand-file-name "j" dir))
          (org-activity-state-file (expand-file-name "state.el" dir))
          (org-activity--day nil)
          (org-activity--totals nil)
          (org-activity--current-key nil)
          (org-activity--current-mode nil)
          (org-activity--since nil)
          (org-activity--session-secs 0)
          (org-activity--last-sample nil))
     (unwind-protect
         (progn ,@body)
       (org-activity-test--clean))))

(defun org-activity-test--secs (sec min hour day month year)
  "Epoch float for the given UTC wall time."
  (time-to-seconds
   (encode-time sec min hour day month year 0)))

(defun org-activity-test--show (buf)
  "Return BUF's contents as a string."
  (with-current-buffer buf (buffer-string)))

(defun org-activity-test--occurrences (needle haystack)
  "Count non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((n 0) (start 0))
    (while (string-match needle haystack start)
      (setq n (1+ n) start (match-end 0)))
    n))

;;; ---------------------------------------------------------------------
;;; Activity identification
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-key-project-file ()
  (org-activity-test--env
   (let* ((proj (org-activity-test--temp "projX"))
          (gitdir (expand-file-name ".git" proj)))
     (make-directory gitdir t)
     (with-temp-file (expand-file-name "a.el" proj) (insert "x"))
     (let ((buf (find-file-noselect (expand-file-name "a.el" proj))))
       (set-window-buffer (selected-window) buf)
       (let ((am (org-activity-emacs-source)))
         (should (equal (car am) "projX"))
         ;; MODE is the display name (mode-name), not the symbol.
         ;; The capitalization varies across Emacs versions (30 "ELisp",
         ;; 31 "Elisp") -- compare case-insensitively.
         (should (equal (downcase (cdr am)) "elisp")))
       (set-window-buffer (selected-window)
                          (get-buffer-create "*scratch*"))
       (kill-buffer buf)))))

(ert-deftest org-activity-key-no-project-falls-to-dir ()
  (org-activity-test--env
   (let* ((plain (org-activity-test--temp "downloads"))
          (file (expand-file-name "note.txt" plain)))
     (with-temp-file file (insert "hi"))
     (let ((buf (find-file-noselect file)))
       (set-window-buffer (selected-window) buf)
       ;; No .git anywhere above the temp tree -> project-current nil.
       (should (equal (car (org-activity-emacs-source)) "Files:downloads"))
       (kill-buffer buf)))))

(ert-deftest org-activity-key-special-buffer-uses-mode ()
  (org-activity-test--env
   (let ((buf (get-buffer-create "*org-activity test special*")))
     (with-current-buffer buf (text-mode))
     (set-window-buffer (selected-window) buf)
     (should (equal (car (org-activity-emacs-source)) "Emacs:Text"))
     (kill-buffer buf))))

(ert-deftest org-activity-key-ignored-buffers-skip ()
  (org-activity-test--env
   (let ((buf (get-buffer-create "*Messages*")))
     (set-window-buffer (selected-window) buf)
     (should (null (org-activity-emacs-source)))
     ;; Restore the window to a plain buffer.  Never kill *Messages*:
     ;; batch ERT writes its own reporting through it, and killing it
     ;; makes ert-run-test die with a dead-marker error.
     (set-window-buffer (selected-window)
                        (get-buffer-create "*scratch*")))))

;;; ---------------------------------------------------------------------
;;; Accounting
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-account-accrues-live-only ()
  (org-activity-test--env
   (org-activity--account "k" "m" 1000.0 0)
   (should (equal org-activity--current-key "k"))
   (should (= org-activity--since 1000.0))
   (org-activity--account "k" "m" 1060.0 0)
   ;; Totals stay empty while the session is open...
   (should (null org-activity--totals))
   ;; ...and the live accumulator carries the time.
   (should (= org-activity--session-secs 60.0))
   (should (= (org-activity--today-total) 60.0))))

(ert-deftest org-activity-account-switch-closes-previous ()
  (org-activity-test--env
   (org-activity--account "k" "m" 1000.0 0)
   (org-activity--account "k" "m" 1060.0 0)
   (org-activity--account "k2" "m2" 1120.0 0)
   ;; k closed with exactly its live 60 s, no double counting.
   (should (= (cdr (assoc "k" org-activity--totals)) 60.0))
   (should (equal org-activity--current-key "k2"))
   (should (= org-activity--since 1120.0))
   (should (= org-activity--session-secs 0.0))))

(ert-deftest org-activity-account-idle-stops-crediting ()
  (org-activity-test--env
   (org-activity--account "k" "m" 1000.0 0)
   ;; Still active (under the threshold): grace accrues.
   (org-activity--account "k" "m" 1060.0 0)
   (should (= org-activity--session-secs 60.0))
   ;; Now a 200 s idle sample at 1300: credit ends where idleness
   ;; began (1100), and only the live 60 s are journaled.
   (org-activity--account "k" "m" 1300.0 200.0)
   (should (= (cdr (assoc "k" org-activity--totals)) 60.0))
   ;; The idle stretch opened no phantom session time.
   (should (= org-activity--session-secs 0.0))
   (should (= org-activity--since 1300.0))))

(ert-deftest org-activity-account-max-gap-discards-suspension ()
  (org-activity-test--env
   (org-activity--account "k" "m" 1000.0 0)
   (org-activity--account "k" "m" 1060.0 0)
   ;; A 1940 s gap: process was suspended.  Pre-gap work is closed at
   ;; the last sample, the gap itself is never credited.
   (org-activity--account "k" "m" 3000.0 0)
   (should (= (cdr (assoc "k" org-activity--totals)) 60.0))
   (should (= org-activity--since 3000.0))
   (should (= org-activity--session-secs 0.0))))

(ert-deftest org-activity-account-day-rollover-splits-midnight ()
  (org-activity-test--env
   (setq org-activity--day "2026-11-06"
         org-activity--current-key "k" org-activity--current-mode "m"
         org-activity--since (org-activity-test--secs 50 59 23 6 11 2026)
         org-activity--session-secs 600.0)
   (let* ((old-file (org-activity-journal-file "2026-11-06"))
          (new-file (org-activity-journal-file "2026-11-07")))
     (org-activity--account "k" "m"
                      (org-activity-test--secs 10 0 0 7 11 2026) 0)
     ;; Rolled over.
     (should (equal org-activity--day "2026-11-07"))
     (should (null org-activity--totals))
     ;; Pre-midnight live seconds (10 s worth before 00:00) landed in
     ;; the OLD day's file.
     (should (file-exists-p old-file))
     (should (string-match-p
              "^CLOCK: .+ =>  0:00$" (org-activity-test--show
                                      (find-file-noselect old-file))))
     (should-not (file-exists-p new-file)))))

(ert-deftest org-activity-flush-closes-and-reopens ()
  (org-activity-test--env
   (setq org-activity--current-key "k" org-activity--current-mode "m"
         org-activity--since (- (time-to-seconds) 120.0)
         org-activity--session-secs 120.0)
   (let* ((day (org-activity-day-string))
          (file (org-activity-journal-file day)))
     (org-activity--flush)
     (should (file-exists-p file))
     (should (= (cdr (assoc "k" org-activity--totals)) 120.0))
     (should (= org-activity--session-secs 0.0))
     ;; State persisted for crash recovery.
     (should (file-exists-p org-activity-state-file)))))

;;; ---------------------------------------------------------------------
;;; Org journal
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-journal-creates-entry-with-clock ()
  (org-activity-test--env
   (let* ((start (org-activity-test--secs 0 20 11 7 11 2026))
          (end (+ start 300.0))
          (file (org-activity-journal-file "2026-11-07")))
     (org-activity--journal-clock "2026-11-07" "telega-org"
                            "emacs-lisp-mode" start end)
     (should (file-exists-p file))
     (let ((text (org-activity-test--show (find-file-noselect file))))
       (should (string-match-p "^\\* 2026-11-07 Sat$" text))
       (should (string-match-p "^\\*\\* telega-org$" text))
       (should (string-match-p "^:MODE: emacs-lisp-mode$" text))
       (should (string-match-p
                "^CLOCK: \\[2026-11-07 Sat 11:20\\]--\\[2026-11-07 Sat 11:25\\] =>  0:05$"
                text))
       (kill-buffer (find-buffer-visiting file))))))

(ert-deftest org-activity-journal-merges-sessions-into-one-entry ()
  (org-activity-test--env
   (let* ((start (org-activity-test--secs 0 20 11 7 11 2026))
          (file (progn
                  (org-activity--journal-clock "2026-11-07" "k" "m"
                                         start (+ start 300.0))
                  (org-activity--journal-clock "2026-11-07" "k" "m"
                                         (+ start 600.0) (+ start 900.0))
                  (org-activity-journal-file "2026-11-07"))))
     (with-current-buffer (find-file-noselect file)
       ;; One entry, one drawer, two CLOCK sessions.
       (should (= (count-matches "^\\*\\* k$") 1))
       (should (= (count-matches "^:LOGBOOK:$") 1))
       (should (= (count-matches "^CLOCK: ") 2))
       (kill-buffer)))))

(ert-deftest org-activity-parse-day-sums-clock-lines ()
  (org-activity-test--env
   (let ((start (org-activity-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock "2026-11-07" "a" "m" start (+ start 3600.0))
     (org-activity--journal-clock "2026-11-07" "a" "m"
                            (+ start 7200.0) (+ start 7260.0))
     (org-activity--journal-clock "2026-11-07" "b" "m2"
                            (+ start 3600.0) (+ start 5400.0))
     (let ((totals (org-activity--parse-day "2026-11-07")))
       (should (= (cdr (assoc "a" totals)) 3660.0))
       (should (= (cdr (assoc "b" totals)) 1800.0))))))

(ert-deftest org-activity-journal-reads-as-real-org-clock-data ()
  (org-activity-test--env
   (let* ((start (org-activity-test--secs 0 20 11 7 11 2026))
          (file (progn
                  (org-activity--journal-clock "2026-11-07" "a" "m"
                                         start (+ start 1500.0))
                  (org-activity--journal-clock "2026-11-07" "b" "m"
                                         start (+ start 600.0))
                  (org-activity-journal-file "2026-11-07")))
          (buf (find-file-noselect file)))
     (with-current-buffer buf
       (org-mode)
       (org-clock-sum)
       ;; 25 min + 10 min of real Org clock time, read back by Org
       ;; itself -- the "Org integration" law, checked from org's side.
       (should (= org-clock-file-total-minutes 35)))
     (kill-buffer buf))))

(ert-deftest org-activity-summary-table-sorts-and-totals ()
  (org-activity-test--env
   (let ((table (org-activity-summary-table
                 '(("b" . 900.0) ("a" . 60.0)))))
     (should (string-match-p "^| Activity | Time |$" table))
     ;; Sorted by activity name, not insertion order.
     (should (< (string-match "^| a " table)
                (string-match "^| b " table)))
     (should (string-match-p "^| Total | 0:16 |$" table)))))

(ert-deftest org-activity-fmt-dur-floors-to-minutes ()
  (should (equal (org-activity--fmt-dur 59.0) "0:00"))
  (should (equal (org-activity--fmt-dur 60.0) "0:01"))
  (should (equal (org-activity--fmt-dur 3661.0) "1:01"))
  (should (equal (org-activity--fmt-dur 0.0) "0:00")))

;;; ---------------------------------------------------------------------
;;; State persistence
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-state-round-trips ()
  (org-activity-test--env
   (setq org-activity--day (org-activity-day-string)
         org-activity--totals '(("k" . 125.0))
         org-activity--current-key "k" org-activity--current-mode "m"
         org-activity--since 12345.0
         org-activity--session-secs 45.0)
   (org-activity--save-state)
   (setq org-activity--day nil org-activity--totals nil org-activity--current-key nil
         org-activity--current-mode nil org-activity--since nil
         org-activity--session-secs 0)
   (should (org-activity--load-state))
   (should (equal org-activity--totals '(("k" . 125.0))))
   (should (equal org-activity--current-key "k"))
   (should (= org-activity--session-secs 45.0))
   (should (= org-activity--since 12345.0))))

(ert-deftest org-activity-state-corrupt-file-tolerated ()
  (org-activity-test--env
   (with-temp-file org-activity-state-file (insert "this is not ( a plist"))
   (should-not (org-activity--load-state))
   ;; Books stay fresh, never broken.
   (should (null org-activity--totals))))

(ert-deftest org-activity-state-other-day-dropped ()
  (org-activity-test--env
   (setq org-activity--day (org-activity-day-string))
   (with-temp-file org-activity-state-file
     (prin1 `(org-activity-state :version 1 :day "2001-01-01"
                           :totals (("old" . 99.0)))
            (current-buffer)))
   (should-not (org-activity--load-state))
   (should (null org-activity--totals))))

;;; ---------------------------------------------------------------------
;;; Mode plumbing
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-mode-starts-and-stops-cleanly ()
  (org-activity-test--env
   (unwind-protect
       (progn
         (org-activity-mode 1)
         (should org-activity-mode)
         (should (timerp org-activity--sampler-timer))
         (should (timerp org-activity--flusher-timer))
         (should (member 'org-activity--mode-line global-mode-string))
         (should (member #'org-activity--shutdown kill-emacs-hook))
         (org-activity-mode -1)
         (should-not org-activity-mode)
         (should (null org-activity--sampler-timer))
         (should (null org-activity--flusher-timer))
         (should-not (member 'org-activity--mode-line global-mode-string))
         (should-not (member #'org-activity--shutdown kill-emacs-hook)))
     (when org-activity-mode (org-activity-mode -1)))))

(ert-deftest org-activity-tick-attributes-current-buffer ()
  (org-activity-test--env
   (let* ((proj (org-activity-test--temp "tickproj"))
          (gitdir (expand-file-name ".git" proj)))
     (make-directory gitdir t)
     (let ((buf (find-file-noselect
                 (prog1 (expand-file-name "b.el" proj)
                   (with-temp-file (expand-file-name "b.el" proj)
                     (insert "x"))))))
       (set-window-buffer (selected-window) buf)
       (org-activity--tick)
       (should (equal org-activity--current-key "tickproj"))
       (should (equal (downcase org-activity--current-mode) "elisp"))
       (kill-buffer buf)))))

(ert-deftest org-activity-report-renders-today-table ()
  (org-activity-test--env
   (let* ((start (org-activity-test--secs 0 20 11 7 11 2026))
          (today (org-activity-day-string))
          (day (progn
                 (org-activity--journal-clock today "a" "m" start
                                        (+ start 60.0))
                 today))
          (buf (org-activity-report day)))
     (with-current-buffer buf
       ;; Escape the + -- in a regexp it is a quantifier.
       (should (string-match-p "^#\\+title: Actlog " (buffer-string)))
       (should (string-match-p "^| a | 0:01 |$" (buffer-string)))
       (should (string-match-p "^| Total | 0:01 |$" (buffer-string)))))))

;;; ---------------------------------------------------------------------
;;; Categories, limits (StayFree/ActivityWatch parity)
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-category-of-matches-in-order ()
  (let ((org-activity-categories
         '(("Comms" . ("telega\\|Emacs:Telega"))
           ("Code" . ("-org$")))))
    (should (equal (org-activity--category-of "telega-org") "Comms"))
    (should (equal (org-activity--category-of "Emacs:Telega") "Comms"))
    (should (equal (org-activity--category-of "lark-org") "Code"))
    ;; Nothing matched: the honest bucket.
    (should (equal (org-activity--category-of "Files:downloads") "Other"))))

(ert-deftest org-activity-category-table-rolls-up ()
  (let ((org-activity-categories
         '(("Comms" . ("telega\\|Telega")))))
    (let ((table (org-activity-category-table
                  '(("telega-org" . 3600.0)
                    ("Emacs:Telega" . 600.0)
                    ("Files:downloads" . 60.0)))))
      (should (string-match-p "^| Category | Time |$" table))
      ;; Comms bucket: 3600 + 600 = 1:10, sorted before Other.
      (should (string-match-p "^| Comms | 1:10 |$" table))
      (should (string-match-p "^| Other | 0:01 |$" table))
      (should (string-match-p "^| Total | 1:11 |$" table))
      (should (< (string-match "Comms" table)
                 (string-match "Other" table))))))

(ert-deftest org-activity-over-limits-sums-matching-keys ()
  (let ((org-activity-limits
         '(("telega\\|Telega" . 60) ("^b$" . 30))))
    (should (equal (org-activity--over-limits
                    '(("telega-org" . 3600.0) ("Emacs:Telega" . 600.0)))
                   '(("telega\\|Telega" 3600 4200.0))))
    ;; Under the limit: nothing.
    (should (null (org-activity--over-limits
                   '(("telega-org" . 60.0) ("b" . 1800.0)))))))

;;; ---------------------------------------------------------------------
;;; Hourly timeline
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-day-events-and-hourly-buckets ()
  (org-activity-test--env
   ;; One session 11:20 -> 12:40: 40 min in hour 11, 40 min in hour 12.
   (let ((start (org-activity-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock "2026-11-07" "a" "m" start (+ start 4800.0))
     (let ((events (org-activity--day-events "2026-11-07")))
       (should (= (length events) 1))
       (should (equal (nth 0 events)
                      (list "a" "m" start (+ start 4800.0))))
       (let ((hours (org-activity--hourly-from-events events)))
         (should (= (aref hours 11) 2400.0))
         (should (= (aref hours 12) 2400.0))
         (should (= (aref hours 10) 0.0)))))))

(ert-deftest org-activity-svg-timeline-renders-24-hours ()
  (let ((hours (make-list 24 0.0)))
    (setcar (nthcdr 9 hours) 1800.0)
    (setcar (nthcdr 14 hours) 600.0)
    (let ((svg (org-activity--svg-timeline hours "Hour of day, X")))
      (should (string-match-p "<svg" svg))
      ;; background + the two nonzero bars
      (should (= (org-activity-test--occurrences "<rect" svg) 3))
      (should (string-match-p "Hour of day, X" svg))
      ;; hour labels every 3rd hour
      (should (string-match-p ">00<" svg))
      (should (string-match-p ">21<" svg)))))

(ert-deftest org-activity-write-timeline-chart-and-timeline-buffer ()
  (org-activity-test--env
   (let ((start (org-activity-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock "2026-11-07" "a" "m" start (+ start 300.0))
     (let ((link (org-activity--write-timeline-chart "2026-11-07")))
       (should (equal link "charts/timeline-2026-11-07.svg"))
       (should (file-exists-p
                (expand-file-name link (org-activity-journal-dir)))))
     ;; Empty day: no chart, no crash.
     (should (null (org-activity--write-timeline-chart "1999-01-01")))
     (let ((buf (org-activity-timeline "2026-11-07")))
       (with-current-buffer buf
         (should (string-match-p "timeline-2026-11-07\\.svg"
                                 (buffer-string))))))))

;;; ---------------------------------------------------------------------
;;; JSON export
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-export-json-shape ()
  (org-activity-test--env
   (let* ((start (org-activity-test--secs 0 20 11 7 11 2026))
          (out (expand-file-name "export.json"
                                 (file-name-directory
                                  org-activity-state-file))))
     (org-activity--journal-clock "2026-11-07" "a" "m" start (+ start 900.0))
     (let ((file (org-activity-export-json "2026-11-07" out)))
       (should (file-exists-p file))
       (with-temp-buffer
         (insert-file-contents file)
         (let ((json (buffer-string)))
           ;; One event, ActivityWatch's shape.
           (should (string-match-p "\"timestamp\":\"2026-11-07T11:20:00" json))
           (should (string-match-p "\"duration\":900" json))
           (should (string-match-p "\"app\":\"a\"" json))
           (should (string-match-p "\"mode\":\"m\"" json))))))))

(ert-deftest org-activity-report-categories-and-limits-integrated ()
  (org-activity-test--env
   (let* ((org-activity-categories '(("Comms" . ("^a$"))))
          (org-activity-limits '(("^a$" . 1)))  ; 1 minute
          (start (org-activity-test--secs 0 20 11 7 11 2026))
          (buf (progn
                 (org-activity--journal-clock "2026-11-07" "a" "m"
                                        start (+ start 120.0))
                 (org-activity-report "2026-11-07"))))
     (with-current-buffer buf
       (should (string-match-p "^\\*By category\\*" (buffer-string)))
       (should (string-match-p "^| Comms | 0:02 |$" (buffer-string)))
       ;; 120 s against a 60 s limit: warned.
       (should (string-match-p "WARNING: over limit: \\^a\\$ at 0:02 (limit 0:01)"
                               (buffer-string)))
       ;; timeline chart linked
       (should (string-match-p "timeline-2026-11-07\\.svg"
                               (buffer-string)))))))

(provide 'org-activity-test)
;;; test.el ends here
