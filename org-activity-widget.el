;;; org-activity-widget.el --- org-activity widgets for the elwidget widget maker -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: GLM 5.3 <glm-5.3@z.ai>
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: org, widgets, android
;; URL: https://github.com/khaalidrafi/org-activity

;;; Commentary:

;; Home-screen widgets for org-activity, rendered through the
;; elwidget widget maker (Emacs on Android, emacshell app): the
;; day's screen time, top activities as proportional bars,
;; StayFree-style over-limit warnings, and the hour-of-day timeline
;; as 3-hour buckets.  Two specs (Owner order 2026-11-23: "Org
;; activity should also have widgets"):
;;
;;   org-activity           -- 4x2: total, top activities, limits
;;   org-activity-timeline  -- 4x3: hour of day, 3-hour buckets
;;
;; Everything renders OFFLINE from the day's journal; the numbers
;; are the engine's own parsers (`org-activity--parse-day',
;; `org-activity--day-events'), never a reimplementation, and the
;; buttons call the engine's own commands -- same law as
;; elwidget-org's built-ins.  elwidget is a SOFT dependency: this
;; module byte-compiles and tests green without it, and only
;; `org-activity-widget-register' needs elwidget to be loadable.
;;
;; Enable after elwidget:
;;
;;   (with-eval-after-load 'elwidget
;;     (org-activity-widget-register))

;;; Code:

(require 'cl-lib)
(require 'org-activity)

(declare-function elwidget-define "elwidget" (name &rest props))

(defgroup org-activity-widget nil
  "elwidget home-screen widgets for org-activity."
  :group 'org-activity)

(defcustom org-activity-widget-accent "#89b4fa"
  "Accent color for totals, labels and bars."
  :type 'string
  :group 'org-activity-widget)

(defcustom org-activity-widget-warn-color "#f38ba8"
  "Color for over-limit warnings."
  :type 'string
  :group 'org-activity-widget)

(defcustom org-activity-widget-row-count 4
  "How many top activities the org-activity widget shows."
  :type 'natnum
  :group 'org-activity-widget)

;;; --- Data (the engine's own parsers, plus the live session) ----------------

(defun org-activity-widget--day-seconds (day)
  "Total tracked seconds for DAY, journal plus the live session.
The journal already holds every CLOSED session of the day (the
engine writes each window as it closes), so the only number not
in the file yet is the running session's live accrual -- added
when DAY is today and a session is open.  Limit checks in the
widget use the journal alone, exactly like `org-activity-report':
the live session is only limit-checked when it closes."
  (+ (cl-reduce #'+ (mapcar #'cdr (org-activity--parse-day day))
                :initial-value 0)
     (if (and (equal day (org-activity-day-string))
              org-activity--current-key)
         (max 0 org-activity--session-secs)
       0)))

(defun org-activity-widget--timeline-buckets (day)
  "DAY's usage as eight 3-hour buckets ((\"HH-HH\" . SECONDS)...).
Straight map over `org-activity--hourly-from-events', the same
hour-of-day math the SVG timeline chart is drawn from."
  (let* ((hours (org-activity--hourly-from-events
                 (org-activity--day-events day)))
         (out nil))
    (dotimes (i 8)
      (let ((secs (+ (aref hours (* 3 i))
                     (aref hours (+ (* 3 i) 1))
                     (aref hours (+ (* 3 i) 2)))))
        (push (cons (format "%02d-%02d" (* 3 i) (* 3 (1+ i))) secs)
              out)))
    (nreverse out)))

;;; --- Renders ---------------------------------------------------------------

(defun org-activity-widget--render ()
  "Render the org-activity widget tree (a LIST of nodes).
Header, the day's total, the top activities as proportional
:progress bars (bar length relative to the day's longest
activity), StayFree-style over-limit lines, Report/Journal
buttons."
  (let* ((day (org-activity-day-string))
         (totals (org-activity--parse-day day))
         (top (seq-take (cl-sort (copy-alist totals) #'> :key #'cdr)
                        org-activity-widget-row-count))
         (maxsecs (max 1 (if top (cdr (car top)) 0)))
         (nodes (list `(:text "Activity today" :size 16 :bold t
                               :color ,org-activity-widget-accent)
                      `(:row (:text ,(org-activity--fmt-dur
                                      (org-activity-widget--day-seconds day))
                                    :size 22 :bold t
                                    :color ,org-activity-widget-accent)
                             (:text "tracked" :size 11)))))
    (dolist (kv top)
      (nconc nodes
             (list `(:row
                     (:text ,(truncate-string-to-width
                              (car kv) 26 nil nil "...")
                            :size 12)
                     (:progress :value ,(cdr kv) :max ,maxsecs
                                :label ,(org-activity--fmt-dur (cdr kv))
                                :color ,org-activity-widget-accent)))))
    ;; Limits are checked on journaled time, same source as the
    ;; report command (see `org-activity-widget--day-seconds').
    (dolist (over (org-activity--over-limits totals))
      (nconc nodes
             (list `(:text ,(truncate-string-to-width
                             (format "Over %s: %s (limit %s)"
                                     (nth 0 over)
                                     (org-activity--fmt-dur (nth 2 over))
                                     (org-activity--fmt-dur (nth 1 over)))
                             36 nil nil "...")
                           :size 11 :color ,org-activity-widget-warn-color))))
    (unless totals
      (nconc nodes (list '(:text "Nothing tracked yet" :size 13))))
    (nconc nodes
           (list '(:row
                   (:button "Report" :action "report" :arg "today")
                   (:button "Journal" :action "journal" :arg ""))))
    nodes))

(defun org-activity-widget--timeline-render ()
  "Render the org-activity-timeline widget tree (a LIST of nodes).
Eight 3-hour buckets as :progress bars (length relative to the
busiest bucket; empty buckets show no duration), the day's total,
and Chart/Report buttons."
  (let* ((day (org-activity-day-string))
         (buckets (org-activity-widget--timeline-buckets day))
         (maxb (max 1 (apply #'max (mapcar #'cdr buckets))))
         (nodes (list `(:text "Hour of day" :size 16 :bold t
                               :color ,org-activity-widget-accent))))
    (dolist (b buckets)
      (nconc nodes
             (list `(:row
                     (:text ,(car b) :size 10)
                     (:progress :value ,(cdr b) :max ,maxb
                                :color ,org-activity-widget-accent
                                ,@(when (> (cdr b) 0)
                                    (list :label
                                          (org-activity--fmt-dur
                                           (cdr b)))))))))
    (nconc nodes
           (list `(:text ,(format "Total %s"
                                  (org-activity--fmt-dur
                                   (org-activity-widget--day-seconds day)))
                         :size 12 :bold t)
                 '(:row (:button "Chart" :action "chart" :arg "")
                        (:button "Report" :action "report" :arg "today"))))
    nodes))

;;; --- Events ----------------------------------------------------------------

(defun org-activity-widget--on-event (action _arg)
  "Handle an org-activity widget tap.
The buttons are the engine's own commands: \"report\" opens
`org-activity-report', \"journal\" the day's journal file,
\"chart\" the SVG timeline.  \"open\" (the generic tap word) also
opens the report.  Return non-nil when handled, so elwidget
re-renders the specs afterwards."
  (pcase action
    ((or "report" "open") (org-activity-report) t)
    ("journal" (org-activity-open-journal) t)
    ("chart" (org-activity-timeline) t)
    (_ nil)))

;;; --- Registration ------------------------------------------------------------

;;;###autoload
(defun org-activity-widget-register ()
  "Define the org-activity home-screen widgets.
Needs elwidget (the widget maker); signals when it is not
installed.  Call from `with-eval-after-load' so both packages are
up first."
  (interactive)
  (unless (require 'elwidget nil t)
    (error "org-activity-widget: elwidget is not installed"))
  (elwidget-define "org-activity"
    :title "Activity today (screen time)" :size [4 2]
    :render #'org-activity-widget--render
    :on-event #'org-activity-widget--on-event)
  (elwidget-define "org-activity-timeline"
    :title "Hour of day (3h buckets)" :size [4 3]
    :render #'org-activity-widget--timeline-render
    :on-event #'org-activity-widget--on-event))

(provide 'org-activity-widget)
;;; org-activity-widget.el ends here
