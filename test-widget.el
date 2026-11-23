;;; test-widget.el --- ERT suite for org-activity-widget -*- lexical-binding: t; -*-

;; TZ is pinned so CLOCK timestamps and day boundaries are
;; deterministic (same law as test.el).

(require 'ert)
(set-time-zone-rule "UTC")

(unless (bound-and-true-p org-activity-widget-test--loaded)
  (load (expand-file-name "org-activity-widget.el"
                          (file-name-directory load-file-name)))
  (setq org-activity-widget-test--loaded t))

(defvar org-activity-widget-test--dirs nil
  "Temp directories made by this suite, cleaned after each test.")

(defun org-activity-widget-test--temp (name)
  "Make (and remember) a temp directory named NAME."
  (let* ((parent (make-temp-file "org-activity-widget-test-" 'directory))
         (dir (expand-file-name name parent)))
    (push parent org-activity-widget-test--dirs)
    (make-directory dir t)
    dir))

(defun org-activity-widget-test--clean ()
  "Delete every temp directory this suite made."
  (dolist (d org-activity-widget-test--dirs)
    (ignore-errors (delete-directory d 'recursive)))
  (setq org-activity-widget-test--dirs nil))

(defmacro org-activity-widget-test--env (&rest body)
  "Run BODY with a hermetic org-activity: temp journal, fresh books."
  `(let* ((dir (org-activity-widget-test--temp "env"))
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
       (org-activity-widget-test--clean))))

(defun org-activity-widget-test--secs (sec min hour day month year)
  "Epoch float for the given UTC wall time."
  (time-to-seconds
   (encode-time sec min hour day month year 0)))

(defun org-activity-widget-test--text-node (nodes content)
  "Non-nil when NODES holds a :text node whose text contains CONTENT."
  (cl-some (lambda (n)
             (and (eq (car n) :text)
                  (string-match-p (regexp-quote content)
                                  (plist-get n :text))))
           nodes))

(defun org-activity-widget-test--props (node)
  "NODE as an aligned plist for `plist-get'.
A node's leading keyword is its type; for :progress that keyword
takes no value, so the aligned property list starts after it.
Other nodes (:text, :button, ...) carry their value right after
the type keyword and are already aligned."
  (if (eq (car node) :progress) (cdr node) node))

;;; ---------------------------------------------------------------------
;;; Day totals (journal + live session)
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-widget-day-seconds-journal-and-live ()
  (org-activity-widget-test--env
   (let ((today (org-activity-day-string))
         (start (org-activity-widget-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock today "a" "m" start (+ start 1800.0))
     (org-activity--journal-clock today "b" "m" start (+ start 5400.0))
     ;; Journal only, no live session.
     (should (= (org-activity-widget--day-seconds today) 7200.0))
     ;; A running session's unflushed seconds are added on today...
     (setq org-activity--current-key "k"
           org-activity--session-secs 30.0)
     (should (= (org-activity-widget--day-seconds today) 7230.0))
     ;; ...but never on another day's number.
     (should (= (org-activity-widget--day-seconds "1999-01-01") 0.0)))))

;;; ---------------------------------------------------------------------
;;; org-activity widget render
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-widget-render-shape ()
  (org-activity-widget-test--env
   (let ((today (org-activity-day-string))
         (start (org-activity-widget-test--secs 0 20 11 7 11 2026)))
     ;; Journaled in file order a (0:30) then b (1:30): the widget
     ;; must rank by TIME, so b leads.
     (org-activity--journal-clock today "a" "m" start (+ start 1800.0))
     (org-activity--journal-clock today "b" "m" start (+ start 5400.0))
     (let ((nodes (org-activity-widget--render)))
       (should (equal (plist-get (nth 0 nodes) :text) "Activity today"))
       ;; The big total row: 7200 s -> "2:00".
       (should (equal (plist-get (nth 1 (nth 1 nodes)) :text) "2:00"))
       ;; Top activity first, proportional to itself.
       (should (equal (plist-get (nth 1 (nth 2 nodes)) :text) "b"))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 2 nodes)))
                   :value)
                  5400))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 2 nodes)))
                   :max)
                  5400))
       (should (equal (plist-get
                       (org-activity-widget-test--props (nth 2 (nth 2 nodes)))
                       :label)
                      "1:30"))
       ;; Second activity relative to the first.
       (should (equal (plist-get (nth 1 (nth 3 nodes)) :text) "a"))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 3 nodes)))
                   :value)
                  1800))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 3 nodes)))
                   :max)
                  5400))
       (should (equal (plist-get
                       (org-activity-widget-test--props (nth 2 (nth 3 nodes)))
                       :label)
                      "0:30"))
       ;; Last node is the Report/Journal button row.
       (should (eq (car (nth 4 nodes)) :row))
       (should (equal (plist-get (nth 1 (nth 4 nodes)) :button) "Report"))
       ;; No limits set: no warning lines.
       (should-not (org-activity-widget-test--text-node nodes "Over "))))))

(ert-deftest org-activity-widget-render-limit-warning ()
  (org-activity-widget-test--env
   (let ((org-activity-limits '(("^a$" . 1)))   ; 1 minute
         (today (org-activity-day-string))
         (start (org-activity-widget-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock today "a" "m" start (+ start 120.0))
     (let ((nodes (org-activity-widget--render)))
       (should (org-activity-widget-test--text-node
                nodes "Over ^a$: 0:02 (limit 0:01)"))
       (should (equal (plist-get
                       (cl-find-if (lambda (n)
                                     (and (eq (car n) :text)
                                          (string-match-p "Over "
                                                          (plist-get n :text))))
                                   nodes)
                                      :color)
                      org-activity-widget-warn-color))))))

(ert-deftest org-activity-widget-render-empty-day ()
  (org-activity-widget-test--env
   (let ((nodes (org-activity-widget--render)))
     (should (org-activity-widget-test--text-node
              nodes "Nothing tracked yet"))
     (should (equal (plist-get (nth 1 (nth 1 nodes)) :text) "0:00"))
     ;; Buttons stay even on an empty day.
     (should (eq (car (car (last nodes))) :row))
     (should (equal (plist-get (nth 1 (car (last nodes))) :button)
                    "Report")))))

;;; ---------------------------------------------------------------------
;;; org-activity-timeline widget
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-widget-timeline-buckets ()
  (org-activity-widget-test--env
   (let ((today (org-activity-day-string))
         (start (org-activity-widget-test--secs 0 20 11 7 11 2026)))
     ;; One session 11:20 -> 12:40: 40 min in hour 11, 40 in hour 12.
     (org-activity--journal-clock today "a" "m" start (+ start 4800.0))
     (let ((buckets (org-activity-widget--timeline-buckets today)))
       (should (= (length buckets) 8))
       (should (equal (car (car buckets)) "00-03"))
       (should (equal (car (car (last buckets))) "21-24"))
       (should (= (cdr (assoc "09-12" buckets)) 2400.0))
       (should (= (cdr (assoc "12-15" buckets)) 2400.0))
       (should (= (cdr (assoc "00-03" buckets)) 0.0))
       (should (= (cdr (assoc "21-24" buckets)) 0.0))))))

(ert-deftest org-activity-widget-timeline-render-shape ()
  (org-activity-widget-test--env
   (let ((today (org-activity-day-string))
         (start (org-activity-widget-test--secs 0 20 11 7 11 2026)))
     (org-activity--journal-clock today "a" "m" start (+ start 4800.0))
     (let ((nodes (org-activity-widget--timeline-render)))
       (should (equal (plist-get (nth 0 nodes) :text) "Hour of day"))
       ;; nodes[1] is the 00-03 row: zero usage, no duration label.
       (should (equal (plist-get (nth 1 (nth 1 nodes)) :text) "00-03"))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 1 nodes)))
                   :value)
                  0.0))
       (should (null (plist-get
                      (org-activity-widget-test--props (nth 2 (nth 1 nodes)))
                      :label)))
       ;; nodes[4] is the 09-12 row: 40 min, full-width bar (the max
       ;; bucket), labeled.
       (should (equal (plist-get (nth 1 (nth 4 nodes)) :text) "09-12"))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 4 nodes)))
                   :value)
                  2400.0))
       (should (= (plist-get
                   (org-activity-widget-test--props (nth 2 (nth 4 nodes)))
                   :max)
                  2400.0))
       (should (equal (plist-get
                       (org-activity-widget-test--props (nth 2 (nth 4 nodes)))
                       :label)
                      "0:40"))
       ;; Total 4800 s -> "1:20", then the Chart/Report button row.
       (should (equal (plist-get (nth 9 nodes) :text) "Total 1:20"))
       (should (eq (car (nth 10 nodes)) :row))
       (should (equal (plist-get (nth 1 (nth 10 nodes)) :button)
                      "Chart"))))))

;;; ---------------------------------------------------------------------
;;; Events and registration
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-widget-on-event-dispatches ()
  (org-activity-widget-test--env
   (let ((calls nil))
     (cl-letf (((symbol-function 'org-activity-report)
                (lambda (&optional _day) (push 'report calls)))
               ((symbol-function 'org-activity-open-journal)
                (lambda (&optional _day) (push 'journal calls)))
               ((symbol-function 'org-activity-timeline)
                (lambda (&optional _day) (push 'chart calls))))
       (should (org-activity-widget--on-event "report" "today"))
       (should (org-activity-widget--on-event "journal" ""))
       (should (org-activity-widget--on-event "chart" ""))
       ;; The generic tap word opens the report, like a whole-widget tap.
       (should (org-activity-widget--on-event "open" ""))
       ;; Unknown actions are not handled (no refresh).
       (should-not (org-activity-widget--on-event "bogus" "")))
     (should (equal (reverse calls) '(report journal chart report))))))

(ert-deftest org-activity-widget-register-gates-on-elwidget ()
  ;; elwidget is not a dependency of this repo: registration must
  ;; fail loudly rather than half-register.  Skipped (not failed)
  ;; in environments that DO have elwidget on the load-path.
  (skip-unless (not (locate-library "elwidget")))
  (should-error (org-activity-widget-register)))

(provide 'org-activity-widget-test)
;;; test-widget.el ends here
