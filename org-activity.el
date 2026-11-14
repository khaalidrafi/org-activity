;;; org-activity.el --- Cross-platform activity tracking into Org -*- lexical-binding: t; -*-

;; Author: z.ai-agent <noreply@z.ai>
;; Maintainer: Khalid Rafi <khaalidrafi@gmail.com>
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: org, convenience, tools
;; URL: https://github.com/khaalidrafi/org-activity
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; org-activity is an ActivityWatch alternative that lives in Emacs
;; and writes data you own: plain Org files.  It works on Linux and
;; Android with the same commands, and has three parts:
;;
;;   - org-activity.el (this file): the engine.  A global minor mode
;;     samples the current activity every `org-activity-interval'
;;     seconds and journals wall time as ordinary Org CLOCK data --
;;     one file per day under org-directory/org-activity/.  Because
;;     the journal is plain clock data, `org-clock-report', the
;;     agenda and `org-clock-sum' all work without this package.
;;
;;   - org-activity-linux.el (optional): a Linux source for the
;;     engine that also credits the SYSTEM foreground window
;;     (xdotool on X11, hyprctl on Hyprland) while you are outside
;;     Emacs -- the aw-watcher-window part of ActivityWatch.
;;
;;   - org-activity-android.el (optional): pulls Android's Usage
;;     Access screen time (the data StayFree shows) from a usage-app
;;     CSV/JSON export into its own Org journal -- the device-wide
;;     part no Emacs-internal sampler can reach.
;;
;; What the engine counts as an "activity" (default Emacs source):
;;
;;   - a file inside a project  ->  the project name    ("telega-org")
;;   - a file with no project   ->  "Files:<directory>" ("Files:downloads")
;;   - a special buffer         ->  "Emacs:<mode-name>" ("Emacs:Telega")
;;
;; Commands:
;;   M-x org-activity-mode          turn tracking on/off (global minor mode)
;;   M-x org-activity-report        today's per-activity table (or any day)
;;   M-x org-activity-open-journal  open the day's Org file
;;   M-x org-activity-toggle        quick pause/resume
;;
;; Android notes (org.gnu.emacs / Termux, Emacs 30):
;;   - The sampler is a 15 s timer and the journal flusher a 5 min
;;     timer; both are trivial battery-wise.
;;   - When Android freezes or kills the process the sampler stops
;;     ticking.  A gap larger than `org-activity-max-gap' (default 15 min)
;;     is treated as suspension and never credited, so you do not get
;;     phantom hours after the phone sat in your pocket.
;;   - Idleness (no input for `org-activity-idle-threshold') stops crediting
;;     too, the same way StayFree stops when the screen is off.
;;   - State survives restarts via `org-activity-state-file'; a flush every
;;     `org-activity-flush-interval' bounds what a hard kill can lose.
;;
;; Scope, honestly: Android sandboxes apps away from each other, so
;; Emacs cannot read UsageStatsManager -- device-wide per-app usage
;; needs the one export step described in org-activity-android.el.
;; Everything stays on the device; no network, no daemon.

;;; Code:

(require 'cl-lib)

(declare-function project-current "project" (&optional maybe-prompt dir))
(declare-function project-root "project" (project))

(defgroup org-activity nil
  "Activity tracking with Org integration."
  :prefix "org-activity-"
  :group 'org
  :link '(url-link :tag "Repository" "https://github.com/khaalidrafi/org-activity"))

(defcustom org-activity-interval 15
  "Seconds between activity samples."
  :type 'integer
  :group 'org-activity)

(defcustom org-activity-flush-interval 300
  "Seconds between journal flushes.
Each flush closes the running session (writing its CLOCK line) and
opens a fresh one, so a hard process kill can lose at most this many
seconds of journal.  Totals are updated continuously regardless."
  :type 'integer
  :group 'org-activity)

(defcustom org-activity-idle-threshold 180
  "Seconds of input idleness after which time stops accruing."
  :type 'integer
  :group 'org-activity)

(defcustom org-activity-max-gap 900
  "Largest sample gap, in seconds, that still counts as usage.
A gap bigger than this means the process was suspended or restarted
(common on Android) and the gap is discarded, not credited."
  :type 'integer
  :group 'org-activity)

(defcustom org-activity-org-dir nil
  "Directory holding the daily journal files, or nil to derive it.
When nil, the journal lives under `org-directory' (or \"~/org\")
in an \"org-activity/\" subdirectory."
  :type '(choice directory (const nil))
  :group 'org-activity)

(defcustom org-activity-state-file nil
  "File keeping the tracking state across restarts, or nil to derive it.
When nil, \"org-activity-state.el\" inside `user-emacs-directory'."
  :type '(choice file (const nil))
  :group 'org-activity)

(defcustom org-activity-ignore-buffer-regexps
  '("^ " "^\\*Completions\\*$" "^\\*Messages\\*$" "^\\*Warnings\\*$"
    "^\\*Compile-Log\\*$" "^\\*vc\\*$")
  "Buffers whose names match any regexp are never tracked."
  :type '(repeat regexp)
  :group 'org-activity)

(defcustom org-activity-source-function #'org-activity-emacs-source
  "Function the sampler calls each tick to name the current activity.
It must return (KEY . MODE) -- the journal row and its mode label --
or nil when nothing should be credited.  The default watches the
front Emacs buffer.  Load org-activity-linux.el and set this to
`org-activity-linux-source' to also credit the system foreground
window while you work outside Emacs (ActivityWatch-style)."
  :type 'function
  :group 'org-activity)

(defcustom org-activity-lighter " OrgAct"
  "Mode-line lighter for `org-activity-mode'."
  :type 'string
  :group 'org-activity)

;; ------------------------------------------------------------------------
;; Internal state (all plain, printable values -- the state file is
;; just `prin1' of a plist).
;; ------------------------------------------------------------------------

(defvar org-activity--day nil
  "Day being tracked, \"YYYY-MM-DD\".")

(defvar org-activity--totals nil
  "Alist (ACTIVITY-KEY . SECONDS) for `org-activity--day'.")

(defvar org-activity--current-key nil
  "Activity of the running session, or nil when none is open.")

(defvar org-activity--current-mode nil
  "Major mode name of the running session.")

(defvar org-activity--since nil
  "Float epoch seconds when the running session started.")

(defvar org-activity--session-secs 0
  "Live seconds accrued by the running session, not yet closed.
Totals are only credited when a session closes, so this keeps the
mode line live without double-crediting the open window.")

(defvar org-activity--last-sample nil
  "Float epoch seconds of the previous sample.")

(defvar org-activity--sampler-timer nil)
(defvar org-activity--flusher-timer nil)

(defvar org-activity--mode-line nil
  "Dynamic mode-line string showing the running activity and total.")

;; ------------------------------------------------------------------------
;; Paths and formatting
;; ------------------------------------------------------------------------

(defun org-activity-journal-dir ()
  "Return the journal directory."
  (directory-file-name
   (expand-file-name
    "org-activity"
    (or org-activity-org-dir
        (expand-file-name
         "org" (or (bound-and-true-p org-directory) "~/org"))))))

(defun org-activity-journal-file (&optional day)
  "Return the journal file for DAY (default today)."
  (expand-file-name
   (concat (or day (org-activity-day-string)) ".org")
   (concat (org-activity-journal-dir) "/")))

(defun org-activity-day-string (&optional time)
  "Return \"YYYY-MM-DD\" for TIME (default now)."
  (format-time-string "%Y-%m-%d" (or time (current-time))))

(defun org-activity--fmt-dur (secs)
  "Format SECS as an Org clock duration \"H:MM\" (floor to minutes)."
  (let ((mins (floor (max 0 secs) 60)))
    (format "%d:%02d" (/ mins 60) (% mins 60))))

(defun org-activity--ts (secs)
  "Format float epoch SECS as an inactive Org timestamp."
  (format-time-string "[%Y-%m-%d %a %H:%M]" (seconds-to-time secs)))

(defun org-activity--clock-line (start end)
  "Return one Org CLOCK line for the window START..END (epoch floats)."
  (format "CLOCK: %s--%s =>  %s\n" (org-activity--ts start) (org-activity--ts end)
          (org-activity--fmt-dur (- end start))))

;; ------------------------------------------------------------------------
;; Activity identification
;; ------------------------------------------------------------------------

(defun org-activity--mode-name (buffer)
  "Return a display name for BUFFER's major mode."
  (let ((name (buffer-local-value 'mode-name buffer)))
    (format "%s" (if (consp name) (car name) name))))

(defun org-activity-emacs-source ()
  "Return the current Emacs activity as (KEY . MODE), or nil.
KEY is the journal row (project, Files:dir or Emacs:mode), MODE the
major mode display name.  This is the default value of
`org-activity-source-function'."
  (let ((buffer (window-buffer (selected-window))))
    (when (and buffer (not (active-minibuffer-window)))
      (let ((name (buffer-name buffer)))
        (unless (seq-some
                 (lambda (re) (string-match-p re name))
                 org-activity-ignore-buffer-regexps)
          (let* ((file (buffer-local-value 'buffer-file-name buffer))
                 (mode (org-activity--mode-name buffer)))
            (cond
             ((and file (file-exists-p file))
              (let* ((dir (file-name-directory file))
                     (proj (and (fboundp 'project-current)
                                (ignore-errors
                                  (project-current nil dir))))
                     (root (and proj (fboundp 'project-root)
                                (ignore-errors (project-root proj)))))
                (cons (cond
                       (root (file-name-nondirectory
                              (directory-file-name
                               (expand-file-name root))))
                       (dir (concat "Files:"
                                    (file-name-nondirectory
                                     (directory-file-name dir))))
                       (t "Files:?"))
                      mode)))
             (t (cons (concat "Emacs:" mode) mode)))))))))

;; ------------------------------------------------------------------------
;; Accounting
;; ------------------------------------------------------------------------

(defun org-activity--add-total (key secs)
  "Add SECS to KEY's total for the tracked day."
  (when (> secs 0)
    (cl-incf (alist-get key org-activity--totals 0 nil #'equal) secs)))

(defun org-activity--close-session (key mode start end &optional day)
  "Credit the session KEY/MODE from START to END (epoch floats).
The window is written as a CLOCK line into DAY's journal file
(default: the day END falls on)."
  (when (and key (> end start))
    (org-activity--add-total key (- end start))
    (let ((jday (or day (org-activity-day-string (seconds-to-time end)))))
      (condition-case err
          (org-activity--journal-clock jday key mode start end)
        (error (message "org-activity: journal write failed: %s" err))))))

(defun org-activity--day-start (day)
  "Return epoch float for local midnight of DAY (\"YYYY-MM-DD\")."
  (time-to-seconds (date-to-time (concat day " 00:00"))))

(defun org-activity--close-live (end)
  "Close the running session, crediting its live seconds, ending at END.
The journaled window is exactly the live accrual (never more than the
session could honestly claim), so idle stretches inside it shrink it.
Resets the live accumulator; the session itself stays open (same key)
until the caller decides otherwise."
  (when (and org-activity--current-key org-activity--since
             (> org-activity--session-secs 0))
    (let* ((end (max end org-activity--since))
           (secs (min org-activity--session-secs (- end org-activity--since))))
      (when (> secs 0)
        (org-activity--close-session org-activity--current-key org-activity--current-mode
                               (- end secs) end))))
  (setq org-activity--session-secs 0))

(defun org-activity--rotate-day-if-needed (now)
  "If NOW (epoch float) left `org-activity--day', roll the books over.
The open session's pre-midnight seconds stay in the old day's file,
then the session continues in the new day."
  (let ((today (org-activity-day-string (seconds-to-time now))))
    (unless (equal today org-activity--day)
      (when (and org-activity--current-key org-activity--since)
        (let ((midnight (org-activity--day-start today)))
          (when (> midnight org-activity--since)
            (let ((secs (min org-activity--session-secs
                             (- midnight org-activity--since))))
              (when (> secs 0)
                (org-activity--close-session org-activity--current-key
                                       org-activity--current-mode
                                       (- midnight secs) midnight
                                       org-activity--day))))))
      (setq org-activity--day today
            org-activity--totals nil
            org-activity--session-secs 0
            org-activity--since now))))

(defun org-activity--account (key mode now idle-secs)
  "Credit one sample: activity KEY/MODE at NOW (epoch float) with
IDLE-SECS of input idleness.  All bookkeeping paths funnel here.
Totals are credited only when sessions close, never per tick."
  (setq key (or key "Emacs:unknown") mode (or mode "unknown"))
  (let ((delta (if org-activity--last-sample (- now org-activity--last-sample) 0))
        (old-last org-activity--last-sample))
    (setq org-activity--last-sample now)
    (org-activity--rotate-day-if-needed now)
    (cond
     ;; Process suspended or restarted: never credit the gap itself,
     ;; but do close what the pre-gap session honestly earned.
     ((> delta org-activity-max-gap)
      (org-activity--close-live old-last)
      (setq org-activity--current-key key org-activity--current-mode mode
            org-activity--since now))
     ;; Same activity, user active: live accrual (credited at close).
     ((and (equal key org-activity--current-key)
           (< idle-secs org-activity-idle-threshold))
      (setq org-activity--session-secs (+ org-activity--session-secs delta)))
     ;; Activity switch or idleness: close the old window (an idle
     ;; stretch only counts up to where idleness began), open a new one.
     (t
      (org-activity--close-live
       (if (>= idle-secs org-activity-idle-threshold) (- now idle-secs) now))
      (setq org-activity--current-key key org-activity--current-mode mode
            org-activity--since now)))))

(defun org-activity--tick ()
  "One sampler pass."
  (let* ((now (time-to-seconds))
         (idle (if-let* ((it (current-idle-time))) (float-time it) 0))
         (am (funcall org-activity-source-function)))
    (when am
      (org-activity--account (car am) (cdr am) now idle)
      (org-activity--update-mode-line))))

(defun org-activity--flush ()
  "Close the running session into the journal and reopen it.
Bounds the loss a hard process kill can cause; also saves state."
  (when (and org-activity--current-key org-activity--since)
    (org-activity--close-live (time-to-seconds))
    (setq org-activity--since (time-to-seconds)))
  (org-activity--save-state)
  (org-activity--update-mode-line))

;; ------------------------------------------------------------------------
;; Org journal
;; ------------------------------------------------------------------------

(defun org-activity--day-heading (day)
  "Return the level-1 heading text for DAY."
  (format "* %s %s" day
          (format-time-string "%a" (date-to-time (concat day " 12:00")))))

(defun org-activity--ensure-day-heading (day)
  "In the current journal buffer, make sure DAY's heading exists.
Return the position right after the heading line (the section start)."
  (goto-char (point-min))
  (if (re-search-forward
       (concat "^" (regexp-quote (org-activity--day-heading day)) "$") nil t)
      (line-end-position)
    (goto-char (point-max))
    (unless (eq (point-min) (point-max)) (insert "\n"))
    (insert (org-activity--day-heading day) "\n")
    (point)))

(defun org-activity--append-clock (day key mode start end)
  "In the current journal buffer, record one CLOCK session of KEY
and MODE (START..END epoch floats) under DAY's section.  The line
goes into the \"** KEY\" entry, creating the entry (with a :MODE:
property and a :LOGBOOK: drawer) on the first session of the day."
  (let* ((sec-beg (org-activity--ensure-day-heading day))
         (sec-end (save-excursion
                    (goto-char sec-beg)
                    (if (re-search-forward "^\\* " nil t)
                        (match-beginning 0)
                      (point-max))))
         (headline (concat "^\\*\\* " (regexp-quote key) "$")))
    (goto-char sec-beg)
    (if (re-search-forward headline sec-end t)
        ;; Existing entry: insert just before its LOGBOOK's :END:.
        (let ((entry-beg (match-beginning 0))
              (entry-end (progn
                           (forward-line 1)
                           (or (re-search-forward "^\\*\\* " sec-end t)
                               sec-end))))
          (goto-char entry-beg)
          (if (re-search-forward "^:LOGBOOK:\n" entry-end t)
              (progn
                (goto-char (or (re-search-forward "^:END:\n" entry-end t)
                               entry-end))
                (forward-line 0)
                (insert (org-activity--clock-line start end)))
            ;; Hand-made entry without a drawer: give it one after the
            ;; entry body, never touching its :PROPERTIES: :END:.
            (goto-char entry-end)
            (insert ":LOGBOOK:\n" (org-activity--clock-line start end)
                    ":END:\n")))
      ;; New entry for this activity, at the end of the day section.
      (goto-char sec-end)
      (insert "\n** " key "\n"
              ":PROPERTIES:\n:MODE: " mode "\n:END:\n"
              ":LOGBOOK:\n"
              (org-activity--clock-line start end)
              ":END:\n"))))

(defun org-activity--journal-clock (day key mode start end)
  "Write one CLOCK session (START..END) of KEY/MODE into DAY's file."
  (let* ((file (org-activity-journal-file day))
         (make-backup-files nil)
         (create-lockfiles nil))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (org-activity--append-clock day key mode start end)
      (save-buffer)
      (kill-buffer))))

;; ------------------------------------------------------------------------
;; Reading the journal back (reports work without this package running)
;; ------------------------------------------------------------------------

(defun org-activity--parse-day (day)
  "Sum DAY's journal into an alist (ACTIVITY-KEY . SECONDS)."
  (let ((file (org-activity-journal-file day))
        (totals nil)
        (key nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((looking-at "^\\*\\* \\(.*\\)$")
            (setq key (match-string 1)))
           ((and key
                 (looking-at
                  "^CLOCK: \\[[^]]*\\]--\\[[^]]*\\] => +\\([0-9]+\\):\\([0-9]+\\)$"))
            (let ((mins (+ (* 60 (string-to-number (match-string 1)))
                           (string-to-number (match-string 2)))))
              (cl-incf (alist-get key totals 0 nil #'equal)
                       (* mins 60)))))
          (forward-line 1))))
    totals))

(defun org-activity-summary-table (totals)
  "Render TOTALS (alist key->seconds) as an Org table string."
  (let* ((rows (cl-sort
                (mapcar (lambda (kv)
                          (list (car kv) (org-activity--fmt-dur (cdr kv))))
                        totals)
                #'string< :key #'car))
         (total (org-activity--fmt-dur
                 (cl-reduce #'+ (mapcar #'cdr totals)
                            :initial-value 0))))
    (concat "| Activity | Time |\n"
            "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
            (mapconcat (lambda (row)
                         (format "| %s | %s |\n" (car row) (cadr row)))
                       rows)
            "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
            (format "| Total | %s |\n" total))))

(defun org-activity--today-total ()
  "Seconds tracked so far today (closed totals + the live session)."
  (+ (cl-reduce #'+ (mapcar #'cdr org-activity--totals) :initial-value 0)
     org-activity--session-secs))

(defun org-activity--update-mode-line ()
  "Refresh the dynamic mode-line element."
  (setq org-activity--mode-line
        (if org-activity--current-key
            (format " A:%s %s" org-activity--current-key
                    (org-activity--fmt-dur (org-activity--today-total)))
          " A:-")))

;; ------------------------------------------------------------------------
;; State persistence (Android kills processes without warning)
;; ------------------------------------------------------------------------

(defun org-activity--save-state ()
  "Write the tracking state to `org-activity-state-file'."
  (when org-activity-state-file
    (condition-case err
        (let ((make-backup-files nil) (create-lockfiles nil))
          (make-directory
           (file-name-directory (expand-file-name org-activity-state-file)) t)
          (with-temp-file org-activity-state-file
            (prin1 `(org-activity-state :version 1
                                  :day ,org-activity--day
                                  :totals ,org-activity--totals
                                  :key ,org-activity--current-key
                                  :mode ,org-activity--current-mode
                                  :since ,org-activity--since
                                  :session-secs ,org-activity--session-secs)
                   (current-buffer))))
      (error (message "org-activity: state save failed: %s" err)))))

(defun org-activity--load-state ()
  "Restore tracking state from `org-activity-state-file'.
Tolerates corruption (a broken file means a fresh day, never an
error) and drops state belonging to another day -- that day's
journal already holds its time."
  (when (and org-activity-state-file (file-exists-p org-activity-state-file))
    (condition-case _
        (let* ((state (with-temp-buffer
                        (insert-file-contents org-activity-state-file)
                        (read (current-buffer))))
               (plist (when (and (listp state)
                                 (eq (car state) 'org-activity-state))
                        (cdr state))))
          (when (equal (plist-get plist :day) (org-activity-day-string))
            (setq org-activity--day (plist-get plist :day)
                  org-activity--totals (copy-alist (plist-get plist :totals))
                  org-activity--current-key (plist-get plist :key)
                  org-activity--current-mode (plist-get plist :mode)
                  org-activity--since (plist-get plist :since)
                  org-activity--session-secs (or (plist-get plist :session-secs) 0)
                  org-activity--last-sample nil)
            t))
      (error (message "org-activity: unreadable state file, starting fresh")
             nil))))

;; ------------------------------------------------------------------------
;; Mode and commands
;; ------------------------------------------------------------------------

(defun org-activity--start ()
  "Start timers, hooks and state for `org-activity-mode'."
  (unless org-activity-state-file
    (setq org-activity-state-file
          (expand-file-name "org-activity-state.el" user-emacs-directory)))
  (org-activity--load-state)
  (unless org-activity--day
    (setq org-activity--day (org-activity-day-string)))
  (setq org-activity--since (or org-activity--since (time-to-seconds))
        org-activity--last-sample nil
        org-activity--sampler-timer (run-at-time 0 org-activity-interval
                                           #'org-activity--tick)
        org-activity--flusher-timer (run-at-time org-activity-flush-interval
                                           org-activity-flush-interval
                                           #'org-activity--flush))
  (add-hook 'kill-emacs-hook #'org-activity--shutdown)
  (add-to-list 'global-mode-string 'org-activity--mode-line 'append)
  (org-activity--update-mode-line))

(defun org-activity--stop ()
  "Stop everything `org-activity--start' set up, flushing first."
  (org-activity--flush)
  (dolist (timer (list org-activity--sampler-timer org-activity--flusher-timer))
    (when timer (cancel-timer timer)))
  (setq org-activity--sampler-timer nil org-activity--flusher-timer nil)
  (remove-hook 'kill-emacs-hook #'org-activity--shutdown)
  (setq global-mode-string (delq 'org-activity--mode-line global-mode-string))
  (org-activity--save-state))

(defun org-activity--shutdown ()
  "Kill-emacs hook: close the open session and persist."
  (org-activity--flush)
  (org-activity--save-state))

;;;###autoload
(define-minor-mode org-activity-mode
  "Track Emacs activity into an Org journal (StayFree, in Emacs)."
  :global t
  :lighter org-activity-lighter
  :group 'org-activity
  (if org-activity-mode (org-activity--start) (org-activity--stop)))

;;;###autoload
(defun org-activity-report (&optional day)
  "Show a per-activity time table for DAY (default today) in Org."
  (interactive)
  (require 'org nil t)
  (let* ((day (or day (org-activity-day-string)))
         (totals (org-activity--parse-day day))
         (buffer (get-buffer-create "*Actlog Report*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'org-mode) (org-mode) (fundamental-mode))
        (insert "#+title: Actlog " day "\n\n")
        (insert (if totals
                    (org-activity-summary-table totals)
                  "Nothing tracked yet.\n"))
        (goto-char (point-min)))
      (display-buffer buffer))
    buffer))

;;;###autoload
(defun org-activity-open-journal (&optional day)
  "Open DAY's (default today) journal file."
  (interactive)
  (find-file (org-activity-journal-file day)))

;;;###autoload
(defun org-activity-toggle ()
  "Pause or resume tracking."
  (interactive)
  (org-activity-mode (if org-activity-mode -1 1))
  (message "org-activity: %s" (if org-activity-mode "resumed" "paused")))

(provide 'org-activity)
;;; org-activity.el ends here
