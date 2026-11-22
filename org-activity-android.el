;;; org-activity-android.el --- Android screen-time (Usage Access) data in Org -*- lexical-binding: t; -*-

;; Author: GLM-5.3-Flash <glm-5.3-flash@z.ai>
;; Maintainer: Khalid Rafi <khaalidrafi@gmail.com>
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: org, android, convenience, tools
;; URL: https://github.com/khaalidrafi/org-activity
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The Android module of org-activity (see org-activity.el): the
;; device-wide half of the ActivityWatch alternative.  StayFree's
;; numbers, in your Org file: per-app screen time pulled from
;; Android's Usage Access data, journaled as plain Org tables you own.
;;
;; Honest about the bridge: Emacs (29 through 31, feature/android
;; included) cannot call UsageStatsManager itself -- there is no
;; Java interop in any stock Android build.  Android only exposes
;; that data to apps holding the "Usage access" special permission.
;; So this package pulls the data through an export file written by
;; an app that DOES hold Usage access:
;;
;;   - StayFree's own CSV export works today (Settings > Backup >
;;     Export CSV); export to Download, then M-x org-activity-android-import.
;;   - Any other Usage-Access app exporting CSV/JSON with recognizable
;;     columns works the same way.
;;   - Integrators can emit the canonical JSON documented in the README
;;     (or a custom `org-activity-android-pull-function').
;;
;; What lands in `org-activity-android-org-file' (default: org-directory/
;; org-activity-android.org) is one level-1 heading per day with a table:
;;
;;   * 2026-11-07 Sat
;;   Unlocks: 42
;;   | App           | Package        | Time | Opens | Notif |
;;   |---------------+----------------+------+-------+-------|
;;   | WhatsApp      | org.whatsapp   | 2:15 |    31 |    20 |
;;   ...
;;   #+name: hourly
;;   | Hour | Minutes |     (StayFree's hourly view, bridge pulls)
;;
;; The Notif column and the Unlocks line are StayFree's notification
;; and unlock counts; they fill from the Emacshell bridge (below) or
;; from imports whose exporter carries them, and read as 0 otherwise.
;; Day sections are rewritten idempotently, so re-importing or
;; re-pulling the same data never duplicates rows.
;; A dynamic block `#+BEGIN: org-activity-android :days 7 :top 15 :chart t'
;; renders the StayFree-style top list over any range PLUS two SVG
;; charts (per-day totals trend, top apps of the last day) generated
;; in pure Elisp -- no gnuplot, no ImageMagick, works on Emacs
;; Android.  `M-x org-activity-android-report' shows it instantly (with
;; a category rollup when `org-activity-android-categories' is set and
;; over-limit warnings from `org-activity-android-limits'), and
;; `M-x org-activity-android-setup-capture' adds an org-capture template for
;; daily usage snapshots.  Day tables are rewritten idempotently, so
;; re-importing the same export never duplicates.
;;
;; NATIVE USAGE ACCESS, three ways (in order of preference):
;;
;;   1. The Emacshell usage bridge -- the tech.khalidrafi.emacshell app
;;      (the Owner's Emacs-for-Android packaging) runs a token-gated
;;      loopback server exposing UsageStatsManager: per-app screen time
;;      AND the event stream (real opens, screen unlocks, notification
;;      counts, hour-of-day timeline -- the full StayFree set, no
;;      export step, no third-party app, no Emacs C rebuild).  "Patch
;;      the Emacshell app if necessary" was the Owner's order; see
;;      EmacshellUsageServer in the app's DESIGN.org.
;;   2. The patched-Emacs primitive (android-usage-stats, the
;;      org-activity patch series, NATIVE-USAGE.org) -- stats only.
;;   3. Export files in `org-activity-android-import-dir' (StayFree CSV
;;      or any recognizable exporter) -- the stock-build fallback.
;;
;; Together with the org-activity engine (in-Emacs and, on Linux,
;; system-window hours per activity) this covers both halves of an
;; ActivityWatch replacement: what the device did, and where your
;; own working time went.  Everything stays on the device.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'json)

;; The engine ships beside this module and provides the timeline SVG
;; renderer; soft require so a standalone vendored copy still loads.
(require 'org-activity nil t)

(declare-function org-activity--svg-timeline "org-activity" (hours &optional title))

;; Emacs Android port notification primitive (guarded by fboundp at the
;; call site; declared so the warnings-as-errors byte compile stays quiet
;; on non-Android builds).
(declare-function android-notifications-notify "ext:android"
                  (title body &rest extras))

(declare-function org-dynamic-block-insert-dblock
                  "org" (type &optional interactive))

;; Patched-Emacs Android primitive (org-activity patch series, see
;; NATIVE-USAGE.org); "ext:" because it lives outside this repo.
;; Stock org.gnu.emacs declares android.permission.PACKAGE_USAGE_STATS
;; in its manifest but ships no code querying UsageStatsManager --
;; every call is guarded by `org-activity-android-usage-native-p'.
(declare-function android-usage-stats "ext:android" (begin-ms end-ms))

(defgroup org-activity-android nil
  "Android Usage Access screen-time data in Org."
  :prefix "org-activity-android-"
  :group 'org
  :link '(url-link :tag "Repository" "https://github.com/khaalidrafi/org-activity-android.el"))

(defcustom org-activity-android-org-file nil
  "Org file holding the usage journal, or nil to derive it.
When nil: \"org-activity-android.org\" under `org-directory' (or \"~/org\")."
  :type '(choice file (const nil))
  :group 'org-activity-android)

(defcustom org-activity-android-import-dir nil
  "Directory pullers scan for usage export files, or nil to derive it.
When nil, the first existing of: \"~/Download\", \"/sdcard/Download\",
\"~/storage/downloads\" (Termux), then `org-directory'."
  :type '(choice directory (const nil))
  :group 'org-activity-android)

(defcustom org-activity-android-import-regexp "\\.\\(?:csv\\|json\\)\\'"
  "File-name regexp for export files considered by the auto puller."
  :type 'regexp
  :group 'org-activity-android)

(defcustom org-activity-android-ignore-packages
  '("^com\\.android\\.systemui$")
  "Package regexps excluded from tables and totals.
System UI is noise; launchers are NOT ignored by default (StayFree
counts them as \"Home\")."
  :type '(repeat regexp)
  :group 'org-activity-android)

(defcustom org-activity-android-duration-unit :auto
  "Unit of unitless integer duration values in imports.
:auto assumes milliseconds when a value exceeds two days' worth of
seconds, otherwise seconds.  Exporters that always write one unit
can pin it to \\='seconds or \\='millis."
  :type '(choice (const :auto) (const seconds) (const millis))
  :group 'org-activity-android)

(defcustom org-activity-android-column-map nil
  "Optional plist forcing column indices, e.g. (:package 1 :seconds 3).
Keys: :date :package :label :seconds :millis :opens.  When nil,
columns are detected from the CSV header row."
  :type '(plist)
  :group 'org-activity-android)

(defcustom org-activity-android-refresh-interval 3600
  "Seconds between automatic pulls in `org-activity-android-mode'."
  :type 'integer
  :group 'org-activity-android)

(defcustom org-activity-android-pull-function #'org-activity-android--pull-auto
  "Function that pulls new usage data into the journal.
Default `org-activity-android--pull-auto' goes NATIVE first: when this
Emacs can query Usage Access directly (the patched org.gnu.emacs app:
`android-usage-stats' fboundp), the last
`org-activity-android-native-days' days are read from the system --
no export step, no third-party app.  Otherwise it falls back to the
newest usable export in `org-activity-android-import-dir'.  Replace
it (or advise it) to integrate any exporter -- the function must
write day snapshots via `org-activity-android--write-day'."
  :type 'function
  :group 'org-activity-android)

(defcustom org-activity-android-native-days 7
  "Days the native Usage Access puller queries per refresh.
Used by `org-activity-android--pull-native' (patched Emacs only)."
  :type 'integer
  :group 'org-activity-android)

(defcustom org-activity-android-lighter " AU"
  "Mode-line lighter for `org-activity-android-mode'."
  :type 'string
  :group 'org-activity-android)

(defcustom org-activity-android-emacshell-port-file "~/emacshell-usage-port"
  "File where the Emacshell app publishes its usage-bridge port.
The bridge server binds loopback only; the port file and the secret
file live in the app's private files dir, which IS HOME for Emacs on
the Android port -- hence the ~/ defaults.  Stock org.gnu.emacs and
upstream Termux builds cannot read them (different UID), which is
exactly what makes the bridge private to Emacshell's Emacs."
  :type 'file
  :group 'org-activity-android)

(defcustom org-activity-android-emacshell-secret-file "~/emacshell-usage-secret"
  "File holding the Emacshell usage-bridge shared secret.
Regenerated by the app at every boot; Elisp re-reads it per request."
  :type 'file
  :group 'org-activity-android)

(defcustom org-activity-android-categories nil
  "Alist (CATEGORY . REGEXPS) classifying packages for reports.
ActivityWatch-style rule categories on Android package names,
rolled up in `org-activity-android-report' and the dynamic block.
Example:
  ((\='Comms\=' . (\"whatsapp\\|telegram\\|discord\"))
   (\='Reading\=' . (\"^com\\.amazon\\.kindle\" \"^org\\.readera\")))"
  :type '(repeat (cons string (repeat regexp)))
  :group 'org-activity-android)

(defcustom org-activity-android-limits nil
  "Daily screen-time limits as (REGEX . MINUTES) on package names.
StayFree-style limits, informing instead of blocking: after each
pull and in reports, packages past their limit are warned about
(message + Android notification when the port provides one).  This
package never blocks or restricts anything.
Example: ((\"whatsapp\\|telegram\" . 45) (\"youtube\" . 60))"
  :type '(repeat (cons regexp natnum))
  :group 'org-activity-android)

;;; ------------------------------------------------------------------------
;;; Small helpers
;;; ------------------------------------------------------------------------

(defun org-activity-android--day-string (&optional time)
  "Return \"YYYY-MM-DD\" for TIME (default now)."
  (format-time-string "%Y-%m-%d" (or time (current-time))))

(defun org-activity-android-org-file-path ()
  "Return the expanded journal file."
  (expand-file-name
   (or org-activity-android-org-file
       (expand-file-name
        "org-activity/android.org"
        (or (bound-and-true-p org-directory) "~/org")))))

(defun org-activity-android-import-directory ()
  "Return the directory scanned for export files."
  (or org-activity-android-import-dir
      (seq-find #'file-directory-p
                '("~/Download" "/sdcard/Download" "~/storage/downloads"))
      (expand-file-name (or (bound-and-true-p org-directory) "~/org"))))

(defun org-activity-android--fmt-dur (secs)
  "Format SECS as \"H:MM\" (floor to minutes), StayFree style."
  (let ((mins (floor (max 0 secs) 60)))
    (format "%d:%02d" (/ mins 60) (% mins 60))))

(defun org-activity-android--parse-hms (value)
  "Parse \"H:MM:SS\" or \"H:MM\" VALUE into seconds, or nil."
  (when (and (stringp value)
             (string-match "\\`\\([0-9]+\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\'" value))
    (let ((h (string-to-number (match-string 1 value)))
          (m (string-to-number (match-string 2 value)))
          (s (if (match-string 3 value)
                 (string-to-number (match-string 3 value))
               0)))
      (+ (* h 3600) (* m 60) s))))

(defun org-activity-android--duration-secs (value)
  "Parse duration VALUE into seconds; nil when unparseable.
Accepts \"H:MM:SS\", \"H:MM\", \"1h 23m 4s\" style suffixes, and bare
numbers (unit per `org-activity-android-duration-unit', :auto heuristic
included)."
  (cond
   ((stringp value)
    (cond
     ((string-match "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" value)
      (org-activity-android--unitless-secs (string-to-number value)))
     ((string-match-p "\\`[0-9]+:[0-9]+\\(?::[0-9]+\\)?\\'" value)
      (org-activity-android--parse-hms value))
     ((string-match
       "\\`\\s-*\\([0-9]+\\)\\s-*h\\(?:r?s?\\)?\\s-\\([0-9]+\\)\\s-*m\\(?:in\\)?\\(?:\\s-\\([0-9]+\\)\\s-*s\\)?\\s-*\\'"
       value)
      (+ (* 3600 (string-to-number (match-string 1 value)))
         (* 60 (string-to-number (match-string 2 value)))
         (if (match-string 3 value)
             (string-to-number (match-string 3 value))
           0)))
     ((string-match "\\`\\s-*\\([0-9]+\\)\\s-*m\\(?:in\\)?\\s-*\\'" value)
      (* 60 (string-to-number (match-string 1 value))))
     (t nil)))
   ((numberp value)
    (org-activity-android--unitless-secs value))
   (t nil)))

(defun org-activity-android--unitless-secs (n)
  "Interpret unitless duration N per `org-activity-android-duration-unit'."
  (pcase org-activity-android-duration-unit
    ('seconds n)
    ('millis (/ n 1000.0))
    (_ (if (> n 172800) (/ n 1000.0) n))))        ; >48h worth => millis

(defun org-activity-android--ignored-p (package)
  "Return non-nil when PACKAGE matches `org-activity-android-ignore-packages'."
  (and package
       (seq-some
        (lambda (re) (string-match-p re package))
        org-activity-android-ignore-packages)))

(defun org-activity-android--norm-header (s)
  "Normalize header cell S for column detection."
  (downcase
   (replace-regexp-in-string "[^a-z0-9]+" "" (downcase (or s "")))))

(defun org-activity-android--header-match (norm candidates)
  "Non-nil if normalized header NORM equals any of CANDIDATES."
  (member norm candidates))

;;; ------------------------------------------------------------------------
;;; CSV parsing
;;; ------------------------------------------------------------------------

(defun org-activity-android--split-csv (text)
  "Split CSV TEXT into rows of string fields (RFC 4180 quoting)."
  (let ((rows nil) (row nil) (field nil) in-quote
        (i 0) (len (length text)))
    (while (< i len)
      (let ((c (aref text i)))
        (cond
         (in-quote
          (cond
           ((= c ?\")
            (if (and (< (1+ i) len) (= (aref text (1+ i)) ?\"))
                (setq field (cons ?\" field) i (1+ i))
              (setq in-quote nil)))
           (t (setq field (cons c field)))))
         ((= c ?\") (setq in-quote t))
         ((= c ?,)
          (setq row (cons (apply #'string (reverse field)) row)
                field nil))
         ((= c ?\n)
          (setq row (cons (apply #'string (reverse field)) row)
                field nil)
          (setq rows (cons (nreverse row) rows) row nil))
         ((= c ?\r))                       ; CRLF: drop the CR
         (t (setq field (cons c field)))))
        (setq i (1+ i)))
    (when (or field row)
      (setq row (cons (apply #'string (reverse field)) row))
      (setq rows (cons (nreverse row) rows)))
    (nreverse rows)))

(defconst org-activity-android--header-candidates
  '((:date    ("date" "day" "usagedate"))
    (:package ("package" "pkg" "packagename" "apppackage" "applicationpackage"
               "application"))
    (:label   ("app" "appname" "applicationlabel" "applicationname" "name"
               "label" "title"))
    (:seconds ("seconds" "sec" "duration" "time" "usage" "foreground"
               "totaltime" "timeinforeground" "totaltimeinforeground"
               "durationinforeground" "durationseconds" "durationsecs"
               "screentime" "usageseconds"))
    (:millis  ("millis" "milliseconds" "ms" "durationmillis" "timems"
               "durationms" "durationinms" "durationinmillis"
               "durationinmilliseconds" "totaltimeinmillis" "timeinms"))
    (:opens   ("opens" "open" "launches" "launchcount" "opencount"
               "timesopened" "count")))
  "Column detection table: KEY . list of accepted normalized headers.")

(defun org-activity-android--detect-columns (header)
  "Return plist mapping data kinds to HEADER column indices."
  (let ((map nil))
    (dotimes (i (length header))
      (let* ((norm (org-activity-android--norm-header (nth i header)))
             (key (cl-loop for (k cands) in org-activity-android--header-candidates
                           when (org-activity-android--header-match norm cands)
                           return k)))
        ;; First matching column wins; later duplicates are ignored.
        (when (and key (not (plist-get map key)))
          (setq map (plist-put map key i)))))
    (unless (or (plist-get map :package) (plist-get map :label))
      (error "org-activity-android: no app/package column in header: %S" header))
    map))

(defun org-activity-android--sniff-duration-unit (rows col)
  "Heuristic unit for integer duration column COL across ROWS.
Returns \\='millis when values plainly exceed two days of seconds."
  (let ((max 0))
    (dolist (row rows)
      (let ((v (org-activity-android--nth col row)))
        (when (and (stringp v)
                   (string-match "\\`\\s-*\\([0-9]+\\)\\s-*\\'" v))
          (setq max (max max (string-to-number (match-string 1 v)))))))
    (if (> max 172800) 'millis 'seconds)))

(defun org-activity-android--parse-csv (text &optional file)
  "Parse CSV TEXT into a list of row plists.
FILE (when given) supplies the fallback day for rows without a
date column: a YYYY-MM-DD in the file name, else the file's day."
  (let* ((rows (cl-remove-if
                (lambda (r) (or (null r)
                                (cl-every (lambda (f) (string= f "")) r)))
                (org-activity-android--split-csv text)))
         (header (car rows))
         (data (cdr rows))
         (cols (or org-activity-android-column-map
                   (org-activity-android--detect-columns header)))
         (unit nil)
         (out nil))
    (when (and (plist-get cols :seconds)
               (eq org-activity-android-duration-unit :auto))
      ;; Only sniff when the unit is :auto and the column holds bare
      ;; integers (durations with ":" are unambiguous).
      (setq unit (org-activity-android--sniff-duration-unit
                  data (plist-get cols :seconds))))
    (let ((fallback-day (or (and file
                                 (string-match "20[0-9][0-9]-[01][0-9]-[0-3][0-9]"
                                               (file-name-nondirectory file))
                                 (match-string 0 (file-name-nondirectory file)))
                            (and file
                                 (file-exists-p file)
                                 (org-activity-android--day-string
                                  (nth 5 (file-attributes file))))
                            (org-activity-android--day-string))))
      (dolist (row data)
        (let* ((date-col (plist-get cols :date))
               (pkg-col (plist-get cols :package))
               (label-col (plist-get cols :label))
               (sec-col (plist-get cols :seconds))
               (ms-col (plist-get cols :millis))
               (open-col (plist-get cols :opens))
               (pkg (and pkg-col (< pkg-col (length row))
                         (string-trim (nth pkg-col row))))
               (label (and label-col (< label-col (length row))
                           (string-trim (nth label-col row))))
               (day (cond
                     (date-col
                      (let ((d (string-trim (org-activity-android--nth date-col row))))
                        (if (and (stringp d)
                                 (string-match
                                  "\\`20[0-9][0-9]-[01][0-9]-[0-3][0-9]" d))
                            (match-string 0 d)
                          fallback-day)))
                     (t fallback-day)))
               (secs (cond
                      (ms-col (let ((v (org-activity-android--nth ms-col row)))
                                (and (string-match
                                      "\\`\\s-*\\([0-9]+\\)\\s-*" v)
                                     (/ (string-to-number
                                         (match-string 1 v))
                                        1000.0))))
                      (sec-col
                       (let* ((v (string-trim
                                  (or (org-activity-android--nth sec-col row) "")))
                              (integerp-val
                               (and (string-match "\\`\\s-*[0-9]+\\s-*\\'" v)
                                    (string-to-number v))))
                         (cond
                          ;; A bare integer honours the sniffed/pinned
                          ;; unit -- :auto cannot be decided per value.
                          ((and integerp-val unit)
                           (if (eq unit 'millis) (/ integerp-val 1000.0)
                             integerp-val))
                          (integerp-val
                           (org-activity-android--unitless-secs integerp-val))
                          (t (org-activity-android--duration-secs v)))))
                      (t nil))))
          (when (and (or pkg label) secs)
            (push (list :day day
                        :package (or pkg label)
                        :label (or label pkg)
                        :seconds secs
                        :opens (and open-col
                                    (string-to-number
                                     (or (org-activity-android--nth open-col row)
                                         ""))))
                  out)))))
    (nreverse out)))

(defun org-activity-android--nth (n list)
  "Return Nth element of LIST, or nil when out of range."
  (when (and (>= n 0) (< n (length list)))
    (nth n list)))

;;; ------------------------------------------------------------------------
;;; JSON parsing (canonical schema, tolerant extras)
;;; ------------------------------------------------------------------------

(defun org-activity-android--parse-json (text)
  "Parse canonical usage JSON TEXT into a list of row plists.
Canonical shape:
  {\"days\": [{\"date\": \"YYYY-MM-DD\",
              \"apps\": [{\"package\": ..., \"label\": ...,
                         \"seconds\": N, \"millis\": N, \"opens\": N}]}]}
Flat {\"usage\": [{\"date\"... \"package\"... \"seconds\"...}]} lists
and a bare list of such rows are also accepted."
  (let* ((obj (json-parse-string text
                                 :object-type 'alist
                                 :array-type 'list
                                 :null-object nil
                                 :false-object nil))
         (days (or (alist-get 'days obj)
                   (alist-get 'usage obj)
                   (if (consp obj) obj nil)))
         (out nil))
    (dolist (entry days)
      (let* ((day (alist-get 'date entry))
             (apps (or (alist-get 'apps entry)
                       ;; A flat row IS its own app entry.
                       (if (alist-get 'package entry) (list entry)))))
        (dolist (app apps)
          (let* ((secs (or (alist-get 'seconds app)
                           (and (alist-get 'millis app)
                                (/ (alist-get 'millis app) 1000.0))))
                 (pkg (or (alist-get 'package app)
                          (alist-get 'label app))))
            (when (and day pkg secs)
              (push (list :day day
                          :package pkg
                          :label (or (alist-get 'label app) pkg)
                          :seconds secs
                          :opens (alist-get 'opens app))
                    out))))))
    (nreverse out)))

(defun org-activity-android-parse (text &optional file)
  "Parse export TEXT (CSV or JSON, FILE names it) into row plists."
  (let ((trimmed (string-trim text)))
    (if (and (> (length trimmed) 0)
             (memq (aref trimmed 0) '(?\{ ?\[)))
        (org-activity-android--parse-json trimmed)
      (org-activity-android--parse-csv trimmed file))))

;;; ------------------------------------------------------------------------
;;; Aggregation
;;; ------------------------------------------------------------------------

(defun org-activity-android--aggregate (rows)
  "Roll ROWS into alist DAY -> alist PACKAGE -> (SECONDS OPENS NOTIFS).
Labels resolve to the longest label seen per package.  Ignored
packages (per `org-activity-android-ignore-packages') are dropped here."
  (let ((days nil))
    (dolist (row rows)
      (unless (org-activity-android--ignored-p (plist-get row :package))
        (let* ((day (plist-get row :day))
               (pkg (plist-get row :package))
               (label (or (plist-get row :label) pkg))
               (day-cell (assoc day days)))
          (unless day-cell
            (setq day-cell (cons day nil))
            (push day-cell days))
          (let ((day-map (cdr day-cell)))
            (let ((cell (assoc pkg day-map)))
              (unless cell
                (setq cell (cons pkg (list 0 0 0)))
                (push cell day-map))
              (setf (nth 1 cell)
                    (+ (nth 1 cell) (or (plist-get row :seconds) 0)))
              (setf (nth 2 cell)
                    (+ (nth 2 cell) (or (plist-get row :opens) 0)))
              (setf (nth 3 cell)
                    (+ (nth 3 cell) (or (plist-get row :notifications) 0))))
            ;; Remember the label (longest label seen wins).
            (let ((lcell (assoc (concat "label:" pkg) day-map)))
              (if lcell
                  (when (< (length (cdr lcell)) (length label))
                    (setcdr lcell label))
                (push (cons (concat "label:" pkg) label) day-map)))
            (setcdr day-cell day-map)))))
    days))

;;; ------------------------------------------------------------------------
;;; Org journal
;;; ------------------------------------------------------------------------

(defun org-activity-android--day-heading-regexp (day)
  "Return the regexp matching DAY's level-1 heading."
  (concat "^\\* " (regexp-quote day) "\\(?: \\|$\\)"))

(defun org-activity-android--day-table (rows)
  "Render aggregated day ROWS (pkg -> (secs opens notifs)) as an Org table.
Includes labels from the label pseudo-entries; sorted by time,
descending (StayFree order).  Notif is the per-app notification
count -- StayFree's notifications column; sources without it read 0."
  (let* ((labels nil)
         (apps (cl-loop for (pkg . cell) in rows
                        unless (string-prefix-p "label:" pkg)
                        collect (cons pkg cell)))
         (label-rows (cl-loop for (pkg . label) in rows
                              when (string-prefix-p "label:" pkg)
                              collect (cons (substring pkg 6) label))))
    (dolist (lr label-rows)
      (setq labels (cons lr labels)))
    (setq apps
          (cl-sort apps #'> :key (lambda (a) (nth 1 a))))
    (let ((total 0) (total-opens 0) (total-notifs 0) (lines nil))
      (dolist (app apps)
        (let ((secs (nth 1 app)) (opens (nth 2 app)) (notifs (nth 3 app)))
          (setq total (+ total secs)
                total-opens (+ total-opens opens)
                total-notifs (+ total-notifs notifs))
          (push (format "| %s | %s | %s | %d | %d |"
                        (or (alist-get (car app) labels nil nil #'equal)
                            (car app))
                        (car app)
                        (org-activity-android--fmt-dur secs)
                        opens notifs)
                lines)))
      (concat "| App | Package | Time | Opens | Notif |\n"
              "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
              "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
              "+-" (make-string 5 ?-) "-|\n"
              (mapconcat #'identity (nreverse lines) "\n")
              "\n"
              "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
              "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
              "+-" (make-string 5 ?-) "-|\n"
              (format "| Total | | %s | %d | %d |\n"
                      (org-activity-android--fmt-dur total)
                      total-opens total-notifs)))))

(defun org-activity-android--hourly-table (minutes)
  "Render MINUTES (24 per-hour minute counts) as an Org table."
  (concat "#+name: hourly\n| Hour | Minutes |\n|------+---------|\n"
          (mapconcat (lambda (h)
                       (format "| %2d | %7d |" h (nth h minutes)))
                     (number-sequence 0 23) "\n")
          "\n"))

(defun org-activity-android--day-body (day-map extras)
  "Render one day section's body from aggregated DAY-MAP and EXTRAS.
EXTRAS is a plist optionally carrying :unlocks (device unlock
count) and :hourly (24 per-hour minutes) -- bridge pulls provide
them; imports do not."
  (let ((unlocks (and extras (plist-get extras :unlocks)))
        (hourly (and extras (plist-get extras :hourly))))
    (concat
     (when (and extras (plist-member extras :unlocks))
       (format "Unlocks: %d\n\n" (or unlocks 0)))
     (if day-map
         (org-activity-android--day-table day-map)
       "No usage data for this day.\n")
     (when (and hourly (cl-some (lambda (m) (> m 0)) hourly))
       (concat "\n" (org-activity-android--hourly-table hourly))))))

(defun org-activity-android--write-day (day rows &optional extras)
  "Rewrite DAY's section in the journal with aggregated ROWS.
EXTRAS, when given, is a plist with :unlocks (device unlock count)
and/or :hourly (24 per-hour minutes) recorded beside the table --
bridge pulls provide them, imports do not.  Idempotent: an existing
DAY section is replaced, never duplicated."
  (let* ((file (org-activity-android-org-file-path))
         (make-backup-files nil)
         (create-lockfiles nil)
         (aggregated (org-activity-android--aggregate rows))
         (day-map (alist-get day aggregated nil nil #'equal))
         (heading (format "* %s %s" day
                          (format-time-string
                           "%a" (date-to-time (concat day " 12:00"))))))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (unwind-protect
          (progn
            (goto-char (point-min))
            (if (re-search-forward
                 (org-activity-android--day-heading-regexp day) nil t)
                (let ((sec-beg (progn (forward-line 1) (point))))
                  ;; Find the start of the next level-1 heading (or EOB).
                  (let ((sec-end
                         (save-excursion
                           (if (re-search-forward "^\\* " nil t)
                               (match-beginning 0)
                             (point-max)))))
                    (delete-region sec-beg sec-end)
                    (goto-char sec-beg)
                    (insert "\n"
                            (org-activity-android--day-body day-map extras))))
              (goto-char (point-max))
              (unless (eq (point-min) (point-max)) (insert "\n"))
              (insert heading "\n\n"
                      (org-activity-android--day-body day-map extras)))
            (save-buffer))
        (kill-buffer)))
    day))

;;; ------------------------------------------------------------------------
;;; Reading the journal back
;;; ------------------------------------------------------------------------

(defun org-activity-android--hms->secs (time-str)
  "Parse an \='H:MM\=' table cell into seconds."
  (let ((colon (string-match ":" time-str)))
    (+ (* 3600 (string-to-number (substring time-str 0 colon)))
       (* 60 (string-to-number (substring time-str (1+ colon)))))))

(defun org-activity-android--read-day-tables ()
  "Return alist DAY -> list of (LABEL PACKAGE SECONDS OPENS NOTIFS).
Parsed from the journal file's per-day tables.  Tables written
before the Notif column existed still parse (Notifs reads as 0)."
  (let ((file (org-activity-android-org-file-path))
        (days nil) (day nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((looking-at "^\\* \\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\\)")
            (setq day (match-string 1)))
           ;; Current 5-column rows (App Package Time Opens Notif).
           ((and day (looking-at
                      "^| \\(.*?\\) | \\(.*?\\) | \\([0-9]+:[0-9][0-9]\\) | \\([0-9]+\\) | \\([0-9]+\\) |$"))
            (let ((label (match-string 1)))
              (unless (equal label "Total")
                (push (list label (match-string 2)
                            (org-activity-android--hms->secs (match-string 3))
                            (string-to-number (match-string 4))
                            (string-to-number (match-string 5)))
                      (alist-get day days nil nil #'equal)))))
           ;; Pre-Notif 4-column rows: Notifs reads as 0.
           ((and day (looking-at
                      "^| \\(.*?\\) | \\(.*?\\) | \\([0-9]+:[0-9][0-9]\\) | \\([0-9]+\\) |$"))
            (let ((label (match-string 1)))
              (unless (equal label "Total")
                (push (list label (match-string 2)
                            (org-activity-android--hms->secs (match-string 3))
                            (string-to-number (match-string 4))
                            0)
                      (alist-get day days nil nil #'equal))))))
          (forward-line 1))))
    (nreverse days)))

(defun org-activity-android--read-day-meta ()
  "Return alist DAY -> plist (:unlocks N :hourly (24 minute ints)).
Reads the \='Unlocks:\=' summary line and the #+name: hourly table
from each day section; days carrying neither get no plist fields."
  (let ((file (org-activity-android-org-file-path))
        (days nil) (day nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((looking-at "^\\* \\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\\)")
            (setq day (match-string 1)))
           ((and day (looking-at "^Unlocks: \\([0-9]+\\)$"))
            (let ((cell (assoc day days)))
              (unless cell
                (setq cell (cons day nil))
                (push cell days))
              (setcdr cell (plist-put (cdr cell) :unlocks
                                      (string-to-number
                                       (match-string 1))))))
           ((and day (looking-at
                      "^| *\\([0-9][0-9]?\\) *| *\\([0-9]+\\) *|$"))
            (let* ((hour (string-to-number (match-string 1)))
                   (mins (string-to-number (match-string 2)))
                   (cell (assoc day days)))
              (unless cell
                (setq cell (cons day nil))
                (push cell days))
              (let ((hours (or (plist-get (cdr cell) :hourly)
                               (make-list 24 0))))
                (setcar (nthcdr hour hours) mins)
                (setcdr cell (plist-put (cdr cell) :hourly hours))))))
          (forward-line 1))))
    (nreverse days)))

(defun org-activity-android--range-table (days top)
  "Render a top-TOP table over the last DAYS journal days."
  (let* ((day-list (org-activity-android--read-day-tables))
         (cutoff (time-subtract
                  (current-time) (days-to-time (1- days))))
         (cutoff-day (org-activity-android--day-string (float-time cutoff)))
         (totals nil))
    (dolist (entry day-list)
      (when (not (string< (car entry) cutoff-day))
        (dolist (row (cdr entry))
          (let* ((pkg (nth 1 row))
                 (cell (or (assoc pkg totals)
                           (let ((c (list pkg 0 0 0 (nth 0 row))))
                             (push c totals) c))))
            (setf (nth 1 cell) (+ (nth 1 cell) (nth 2 row)))
            (setf (nth 2 cell) (+ (nth 2 cell) (or (nth 3 row) 0)))
            (setf (nth 3 cell) (+ (nth 3 cell) (or (nth 4 row) 0)))))))
    (setq totals (cl-sort totals #'> :key (lambda (c) (nth 1 c))))
    (let ((lines nil) (total 0) (total-opens 0) (total-notifs 0) (count 0))
      (dolist (cell totals)
        (when (< count top)
          (setq total (+ total (nth 1 cell))
                total-opens (+ total-opens (nth 2 cell))
                total-notifs (+ total-notifs (nth 3 cell))
                count (1+ count))
          (push (format "| %s | %s | %s | %d | %d |"
                        ;; cell = (PKG SECS OPENS NOTIFS LABEL); label
                        ;; falls back to the package when none was seen.
                        (or (nth 4 cell) (car cell))
                        (car cell)
                        (org-activity-android--fmt-dur (nth 1 cell))
                        (nth 2 cell) (nth 3 cell))
                lines)))
      (concat (format "#+name: org-activity-android-range\n")
              "| App | Package | Time | Opens | Notif |\n"
              "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
              "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
              "+-" (make-string 5 ?-) "-|\n"
              (mapconcat #'identity (nreverse lines) "\n")
              "\n"
              "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
              "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
              "+-" (make-string 5 ?-) "-|\n"
              (format "| Total (top %d of last %d days) | | %s | %d | %d |\n"
                      top days
                      (org-activity-android--fmt-dur total)
                      total-opens total-notifs)))))

;;; ------------------------------------------------------------------------
;;; Charts (pure-Elisp SVG -- no gnuplot, no ImageMagick, Android-safe)
;;; ------------------------------------------------------------------------

(defcustom org-activity-android-chart-bar-color "#3a6ea5"
  "Fill color of chart bars (any SVG/CSS color)."
  :type 'color
  :group 'org-activity-android)

(defcustom org-activity-android-chart-text-color "#333333"
  "Text color used inside charts."
  :type 'color
  :group 'org-activity-android)

(defun org-activity-android--xml-escape (s)
  "Escape S for safe inclusion in SVG text content."
  (replace-regexp-in-string
   "[&<>\"']"
   (lambda (c)
     (cdr (assq (aref c 0)
                '((?& . "&amp;") (?< . "&lt;") (?> . "&gt;")
                  (?\" . "&quot;") (?' . "&apos;")))))
   s))

(defconst org-activity-android--svg-nodata
  (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"360\" height=\"56\""
          " font-family=\"sans-serif\" font-size=\"13\">"
          "<rect x=\"0\" y=\"0\" width=\"360\" height=\"56\" fill=\"#ffffff\"/>"
          "<text x=\"10\" y=\"34\" fill=\"#888888\">no usage data</text></svg>\n")
  "Placeholder chart shown when the journal has no rows.")

(defun org-activity-android--svg-hbars (rows &optional title)
  "Render ROWS ((LABEL . SECS)...) as a horizontal bar chart SVG string.
Shows at most 20 bars, longest first as given; TITLE drawn on top.
Pure string generation -- renderable by any SVG-capable Emacs or
browser, and trivially unit-testable."
  (if (null rows)
      org-activity-android--svg-nodata
    (let* ((rows (seq-take rows 20))
           (rowh 26) (barh 16) (fs 13) (barw 360)
           (namew (min 260
                       (max 70
                            ;; ~9px/char at font-size 13, plus padding:
                            ;; too tight clips the first glyph (seen with
                            ;; "GNU Emacs" in cairosvg render, 2026-11-07).
                            (+ 12 (* 9 (1+ (apply #'max
                                                  (mapcar (lambda (r)
                                                            (length (car r)))
                                                          rows))))))))
           (maxv (apply #'max 1 (mapcar #'cdr rows)))
           (w (max (+ 10 namew 6 barw 66)
                   (if title (+ 16 (* 8 (length title))) 0)))
           (h (+ 30 (* rowh (length rows)) 6))
           (tc org-activity-android-chart-text-color)
           (bc org-activity-android-chart-bar-color))
      (concat
       (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" font-family=\"sans-serif\" font-size=\"%d\">\n"
               w h w h fs)
       (format "<rect x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#ffffff\"/>\n" w h)
       (when title
         (format "<text x=\"10\" y=\"18\" fill=\"%s\" font-weight=\"bold\">%s</text>\n"
                 tc (org-activity-android--xml-escape title)))
       (let ((y 26) (out nil))
         (dolist (r rows)
           (let* ((label (car r)) (secs (cdr r))
                  (bw (max 1 (round (* (/ (float secs) maxv) barw))))
                  (tx (- namew 4)))
             (push (format "<text x=\"%d\" y=\"%d\" text-anchor=\"end\" fill=\"%s\">%s</text>\n"
                           tx (+ y barh -2) tc (org-activity-android--xml-escape label))
                   out)
             (push (format "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"%s\" rx=\"2\"/>\n"
                           (+ namew 6) y bw barh bc)
                   out)
             (push (format "<text x=\"%d\" y=\"%d\" fill=\"%s\">%s</text>\n"
                           (+ namew 6 barw 8) (+ y barh -2) tc
                           (org-activity-android--fmt-dur secs))
                   out))
           (setq y (+ y rowh)))
         (apply #'concat (nreverse out)))
       "</svg>\n"))))

(defun org-activity-android--svg-vbars (rows &optional title)
  "Render ROWS ((DAY . SECS)...) as a vertical bar chart SVG string.
One bar per DAY (labeled MM-DD), value in H:MM on top of each bar."
  (if (null rows)
      org-activity-android--svg-nodata
    (let* ((n (length rows))
           (colw 58) (barw 36) (fs 12)
           (plot-h 150) (val-h 18) (top 28) (label-h 22)
           (maxv (apply #'max 1 (mapcar #'cdr rows)))
           ;; widen for long titles so they never clip on the right
           (w (max (+ 20 (* colw n))
                   (if title (+ 16 (* 8 (length title))) 0)))
           (h (+ top val-h plot-h label-h))
           (tc org-activity-android-chart-text-color)
           (bc org-activity-android-chart-bar-color))
      (concat
       (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" font-family=\"sans-serif\" font-size=\"%d\">\n"
               w h w h fs)
       (format "<rect x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#ffffff\"/>\n" w h)
       (when title
         (format "<text x=\"10\" y=\"18\" fill=\"%s\" font-weight=\"bold\">%s</text>\n"
                 tc (org-activity-android--xml-escape title)))
       (let ((i 0) (out nil))
         (dolist (r rows)
           (let* ((day (car r)) (secs (cdr r))
                  (bh (max 1 (round (* (/ (float secs) maxv) plot-h))))
                  (bx (+ 20 (* i colw) (/ (- colw barw) 2)))
                  (by (+ top val-h (- plot-h bh)))
                  (cx (+ 20 (* i colw) (/ colw 2))))
             (push (format "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"%s\" rx=\"2\"/>\n"
                           bx by barw bh bc)
                   out)
             (push (format "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"%s\">%s</text>\n"
                           cx (- by 4) tc (org-activity-android--fmt-dur secs))
                   out)
             (push (format "<text x=\"%d\" y=\"%d\" text-anchor=\"middle\" fill=\"%s\">%s</text>\n"
                           cx (+ top val-h plot-h 16) tc
                           (org-activity-android--xml-escape
                            (if (> (length day) 5) (substring day 5) day)))
                   out))
           (setq i (1+ i)))
         (apply #'concat (nreverse out)))
       "</svg>\n"))))

(defun org-activity-android--range-day-totals (days)
  "Return ascending ((DAY . SECS)...) totals for the last DAYS days."
  (let* ((day-list (org-activity-android--read-day-tables))
         (cutoff-day (org-activity-android--day-string
                      (float-time (time-subtract
                                   (current-time)
                                   (days-to-time (1- days)))))))
    (sort (cl-loop for (day . rows) in day-list
                   when (not (string< day cutoff-day))
                   collect (cons day
                                 (apply #'+
                                        (mapcar (lambda (r) (nth 2 r))
                                                rows))))
          (lambda (a b) (string< (car a) (car b))))))

(defun org-activity-android--day-rows (day)
  "Journal rows ((LABEL PACKAGE SECS OPENS)...) for DAY, or nil."
  (alist-get day (org-activity-android--read-day-tables) nil nil #'equal))

(defun org-activity-android--day-top (day &optional top)
  "((LABEL . SECS)...) of the TOP apps on DAY, longest use first.
DAY nil (or a day without data) falls back to the last day that has
data; nil when the whole journal is empty."
  (let* ((day-list (org-activity-android--read-day-tables))
         (rows (or (and day (alist-get day day-list nil nil #'equal))
                   (cdr (car (last day-list))))))
    (when rows
      (seq-take (cl-sort (mapcar (lambda (r) (cons (car r) (nth 2 r))) rows)
                         #'> :key #'cdr)
                (or top 10)))))

(defun org-activity-android-chart-dir ()
  "Directory chart SVGs are written to (beside the journal file)."
  (expand-file-name "charts" (file-name-directory (org-activity-android-org-file-path))))

(defun org-activity-android--write-chart (name svg)
  "Write SVG as NAME under `org-activity-android-chart-dir'.
Returns the Org file link target relative to the journal file."
  (let* ((dir (org-activity-android-chart-dir))
         (file (expand-file-name name dir)))
    (make-directory dir t)
    (with-temp-file file (insert svg))
    (concat "charts/" name)))

(defun org-activity-android--chart-links (days)
  "Write and link this range's two charts (trend + last-day top apps).
DAYS is the range length used for the trend chart's file name."
  (let* ((trend (org-activity-android--write-chart
                 (format "usage-trend-%dd.svg" days)
                 (org-activity-android--svg-vbars
                  (org-activity-android--range-day-totals days)
                  (format "Screen time per day, last %d days" days))))
         (last-day (car (car (last (org-activity-android--read-day-tables)))))
         (top (org-activity-android--write-chart
               "usage-top-day.svg"
               (org-activity-android--svg-hbars
                (org-activity-android--day-top last-day 10)
                (format "Top apps, %s" (or last-day "no data"))))))
    (concat "#+caption: Screen time per day\n"
            "[[file:" trend "]]\n"
            "#+caption: Top apps, " (or last-day "no data") "\n"
            "[[file:" top "]]\n")))

(defun org-activity-android--day-table-org (rows)
  "Render journal ROWS ((LABEL PACKAGE SECS OPENS NOTIFS)...) as an Org table,
sorted by time, descending, with a total row."
  (let* ((rows (cl-sort (copy-sequence rows) #'> :key (lambda (r) (nth 2 r))))
         (total 0) (total-opens 0) (total-notifs 0) (lines nil))
    (dolist (r rows)
      (setq total (+ total (nth 2 r))
            total-opens (+ total-opens (or (nth 3 r) 0))
            total-notifs (+ total-notifs (or (nth 4 r) 0)))
      (push (format "| %s | %s | %s | %d | %d |"
                    (nth 0 r) (nth 1 r)
                    (org-activity-android--fmt-dur (nth 2 r))
                    (or (nth 3 r) 0) (or (nth 4 r) 0))
            lines))
    (concat "| App | Package | Time | Opens | Notif |\n"
            "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
            "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
            "+-" (make-string 5 ?-) "-|\n"
            (mapconcat #'identity (nreverse lines) "\n")
            "\n"
            "|-" (make-string 18 ?-) "+-" (make-string 24 ?-)
            "+-" (make-string 6 ?-) "+-" (make-string 5 ?-)
            "+-" (make-string 5 ?-) "-|\n"
            (format "| Total | | %s | %d | %d |\n"
                    (org-activity-android--fmt-dur total)
                    total-opens total-notifs))))

;;; ------------------------------------------------------------------------
;;; Dynamic block
;;; ------------------------------------------------------------------------

;;;###autoload
(defun org-dblock-write:org-activity-android (params)
  "Writer for `#+BEGIN: org-activity-android' dynamic blocks.
PARAMS: :days (default 7), :top (default 15), :chart (default t --
append per-day trend + top-apps chart links after the table).  A
category rollup is appended when `org-activity-android-categories'
is set."
  (let* ((days (or (plist-get params :days) 7))
         (top (or (plist-get params :top) 15))
         (chart (if (plist-member params :chart)
                    (plist-get params :chart)
                  t)))
    (insert (org-activity-android--range-table days top))
    (when org-activity-android-categories
      (let ((cat (org-activity-android--category-table days)))
        (when cat
          (insert "\n*By category*\n\n" cat))))
    (when chart
      (insert "\n" (org-activity-android--chart-links days)))
    (when (and chart (fboundp 'org-display-inline-images))
      (ignore-errors (org-display-inline-images nil t
                                                (point-min) (point-max))))))

;;;###autoload
(defun org-dblock-write:org-activity-android-day (params)
  "Writer for `#+BEGIN: org-activity-android-day' dynamic blocks (one day).
PARAMS: :date (default: last day with data), :top (default 10),
:chart (default t -- bar chart of that day's top apps)."
  (let* ((date (or (plist-get params :date)
                   (car (car (last (org-activity-android--read-day-tables))))))
         (top (or (plist-get params :top) 10))
         (chart (if (plist-member params :chart)
                    (plist-get params :chart)
                  t))
         (rows (org-activity-android--day-rows date)))
    (insert (format "*%s*\n\n" (or date "no data"))
            (if rows
                (org-activity-android--day-table-org rows)
              "No usage data for this day.\n"))
    (when chart
      (let ((link (and date
                       (org-activity-android--write-chart
                        "usage-top-day.svg"
                        (org-activity-android--svg-hbars
                         (org-activity-android--day-top date top)
                         (format "Top apps, %s" date))))))
        (when link
          (insert "\n#+caption: Top apps, " date "\n"
                  "[[file:" link "]]\n"))))
    (when (and chart (fboundp 'org-display-inline-images))
      (ignore-errors (org-display-inline-images nil t
                                                (point-min) (point-max))))))

;;;###autoload
(defun org-activity-android-insert-block (&optional days top)
  "Insert an `org-activity-android' dynamic block for DAYS/TOP at point."
  (interactive (list (read-number "Days: " 7) (read-number "Top apps: " 15)))
  (insert (format "#+BEGIN: org-activity-android :days %d :top %d\n" days top)
          "#+END:\n")
  (when (derived-mode-p 'org-mode)
    (org-update-dblock)))

;;;###autoload
(defun org-activity-android-insert-day-block (&optional date)
  "Insert an `org-activity-android-day' dynamic block for DATE at point."
  (interactive (list (read-string "Day (YYYY-MM-DD): "
                                  (org-activity-android--day-string))))
  (insert (format "#+BEGIN: org-activity-android-day :date \"%s\"\n" date)
          "#+END:\n")
  (when (derived-mode-p 'org-mode)
    (org-update-dblock)))

;;; ------------------------------------------------------------------------
;;; Pull and import
;;; ------------------------------------------------------------------------

(defun org-activity-android--sniff-usage-file (file)
  "Non-nil when FILE looks like a usage export (quick content sniff)."
  (condition-case _
      (let ((head (with-temp-buffer
                    (insert-file-contents file nil 0 2048 t)
                    (buffer-string))))
        (if (string-match-p "\\`[[ \t\r\n]*{" head)
            (string-match-p "package\\|apps\\|usage" head)
          (string-match-p "package\\|app\\|duration\\|seconds\\|foreground"
                          (org-activity-android--norm-header head))))
    (error nil)))

(defun org-activity-android--import-file-rows (file)
  "Parse FILE into row plists; nil when it holds no usable rows."
  (condition-case _
      (let ((text (with-temp-buffer
                    (insert-file-contents file)
                    (buffer-string))))
        (org-activity-android-parse text file))
    (error nil)))

(defun org-activity-android--write-rows (rows &optional extras)
  "Write one journal day table per day in ROWS; return the day list.
EXTRAS is an optional alist (DAY . PLIST) carrying :unlocks and
:hourly per day (bridge pulls provide them; imports do not)."
  (let ((days (mapcar (lambda (d) (car d)) (org-activity-android--aggregate rows))))
    (dolist (day days)
      (org-activity-android--write-day
       day (cl-remove-if-not
            (lambda (r) (equal (plist-get r :day) day)) rows)
       (cdr (assoc day extras))))
    (sort days #'string<)))

(defun org-activity-android-import-file (file)
  "Import the usage export FILE into the journal.
Returns the list of day strings written."
  (interactive
   (list (read-file-name "Usage export file: "
                         (org-activity-android-import-directory) nil nil nil
                         org-activity-android-import-regexp)))
  (let ((rows (org-activity-android--import-file-rows file)))
    (unless rows
      (user-error "org-activity-android: no usage rows found in %s" file))
    (let ((days (org-activity-android--write-rows rows)))
      (message "org-activity-android: imported %s (%d rows, days: %s)"
               (file-name-nondirectory file) (length rows)
               (mapconcat #'identity days ", "))
      days)))

(defun org-activity-android--pull-latest-file ()
  "Default puller: import the newest usable export in the import dir."
  (let* ((dir (org-activity-android-import-directory))
         (candidates
          (cl-sort
           (cl-remove-if
            #'file-directory-p
            (mapcar (lambda (f) (expand-file-name f dir))
                    (directory-files dir nil org-activity-android-import-regexp)))
           #'file-newer-than-file-p))
         (imported-days nil))
    (while (and candidates (null imported-days))
      (let ((file (pop candidates)))
        (when (org-activity-android--sniff-usage-file file)
          (condition-case err
              (setq imported-days
                    (org-activity-android-import-file file))
            (error (message "org-activity-android: skipping %s: %s"
                            (file-name-nondirectory file)
                            (error-message-string err)))))))
    (or imported-days
        (and (featurep 'android)
             (message
              "org-activity-android: no export found in %s -- export from your usage app (or grant Emacs \"All files access\")" dir)
             nil))))

;;;###autoload
(defun org-activity-android-refresh ()
  "Pull new usage data via `org-activity-android-pull-function',
then warn about exceeded `org-activity-android-limits'."
  (interactive)
  (let ((days (funcall org-activity-android-pull-function)))
    (if days
        (message "org-activity-android: journal updated (%d day(s))"
                 (length days))
      (message "org-activity-android: nothing new pulled")))
  (when (file-exists-p (org-activity-android-org-file-path))
    (org-activity-android-update-blocks))
  (org-activity-android--warn-limits))

(defun org-activity-android-update-blocks ()
  "Refresh every org-activity-android dynamic block in the journal."
  (let* ((file (org-activity-android-org-file-path))
         (buffer (find-buffer-visiting file)))
    (when (and buffer
               (eq 'org-mode (buffer-local-value 'major-mode buffer)))
      (with-current-buffer buffer
        (org-update-all-dblocks)))))

;;; ------------------------------------------------------------------------
;;; Native Usage Access (patched Emacs app — no export step)
;;; ------------------------------------------------------------------------

(defun org-activity-android--on-android-p ()
  "Non-nil when running inside the Emacs Android port."
  (featurep 'android))

(defun org-activity-android-usage-native-p ()
  "Non-nil when THIS Emacs can query Usage Access directly.
True only on the patched org.gnu.emacs app (built with the
org-activity patch series, NATIVE-USAGE.org): the primitive
`android-usage-stats' is defined.  Stock Emacs Android declares
android.permission.PACKAGE_USAGE_STATS in its manifest but ships
no code that queries UsageStatsManager, and has no generic Java
interop — there the export-file path is the fallback."
  (and (org-activity-android--on-android-p)
       (fboundp 'android-usage-stats)))

(defun org-activity-android--day-begin-ms (day)
  "Epoch milliseconds at DAY's (\"YYYY-MM-DD\") local midnight."
  (pcase-let ((`(,y ,m ,d)
               (mapcar #'string-to-number (split-string day "-"))))
    (round (float-time (encode-time 0 0 0 d m y)))))

(defun org-activity-android--native-day-rows (day)
  "Query one DAY natively; return rows in the importer's shape.
Calls the patched-Emacs primitive
  (android-usage-stats BEGIN-MS END-MS)
over the day's window.  Each (PACKAGE LABEL LAST-USED-MS
FOREGROUND-MS) entry with FOREGROUND-MS > 0 becomes one plist row
(:day :package :label :seconds :opens); FOREGROUND-MS becomes
seconds and LABEL falls back to PACKAGE when nil.  Opens are 0:
UsageStats carries no open count (an events-based count is a
later unit — NATIVE-USAGE.org)."
  (let ((stats (android-usage-stats
                (org-activity-android--day-begin-ms day)
                (+ (org-activity-android--day-begin-ms day) 86400000)))
        (rows nil))
    (dolist (entry (nreverse stats) rows)
      (let ((pkg (nth 0 entry)) (label (nth 1 entry))
            (fg-ms (nth 3 entry)))
        (when (and pkg (> fg-ms 0))
          (push (list :day day :package pkg
                      :label (or label pkg)
                      :seconds (/ fg-ms 1000.0)
                      :opens 0)
                rows))))))

(defun org-activity-android--pull-native ()
  "Pull the last `org-activity-android-native-days' days natively.
The whole-device StayFree question answered without StayFree:
Usage Access read straight from the system by the patched Emacs
app.  Returns the day list written, or nil when the query yields
nothing."
  (let ((rows nil))
    (dotimes (i org-activity-android-native-days)
      (let ((day (org-activity-android--day-string
                  (time-subtract nil (* i 86400)))))
        (setq rows (append rows (org-activity-android--native-day-rows day)))))
    (if rows
        (org-activity-android--write-rows rows)
      (message "org-activity-android: native query returned no rows")
      nil)))

(defun org-activity-android--pull-auto ()
  "Native Usage Access when available; export files otherwise.
Order: Emacshell bridge (stats + events: the full StayFree set),
then the patched-Emacs primitive (stats only), then export files."
  (cond
   ((org-activity-android-emacshell-p)
    (or (org-activity-android--pull-bridge)
        (org-activity-android--pull-latest-file)))
   ((org-activity-android-usage-native-p)
    (or (org-activity-android--pull-native)
        (org-activity-android--pull-latest-file)))
   (t (org-activity-android--pull-latest-file))))

;;; ------------------------------------------------------------------------
;;; Emacshell usage bridge (loopback server in the Owner's app)
;;; ------------------------------------------------------------------------

(defun org-activity-android--bridge-endpoint ()
  "Return (PORT . SECRET) for the Emacshell usage bridge, or nil.
Never signals: unreadable/absent/rotten files just mean \"no
bridge\" (stock Emacs builds, upstream Termux, other devices)."
  (condition-case _
      (let ((port-file (expand-file-name
                        org-activity-android-emacshell-port-file))
            (secret-file (expand-file-name
                          org-activity-android-emacshell-secret-file)))
        (when (and (file-readable-p port-file) (file-readable-p secret-file))
          (let* ((port (string-to-number
                        (string-trim
                         (with-temp-buffer
                           (insert-file-contents port-file)
                           (buffer-string)))))
                 (secret (string-trim
                          (with-temp-buffer
                            (insert-file-contents secret-file)
                            (buffer-string)))))
            (when (and (> port 0) (<= port 65535) (> (length secret) 0))
              (cons port secret)))))
    (error nil)))

(defun org-activity-android-emacshell-p ()
  "Non-nil when the Emacshell usage bridge is available (files present)."
  (and (org-activity-android--bridge-endpoint) t))

(defun org-activity-android--bridge-request (cmd &rest args)
  "Send one request to the Emacshell usage bridge; return decoded JSON.
CMD is a string (\"STATS\", \"EVENTS\", \"PING\"); ARGS are numbers
or nil.  The response is one JSON line.  Returns the decoded alist
(:object-type alist, :array-type list), or nil on any failure --
never signals; a failed bridge just means no data this pull."
  (when-let* ((endpoint (org-activity-android--bridge-endpoint)))
    (condition-case _
        (with-temp-buffer
          (let* ((proc (make-network-process
                        :name "org-activity-bridge"
                        :buffer (current-buffer)
                        :host "127.0.0.1" :service (car endpoint)
                        :noquery t))
                 (deadline (+ (float-time) 5.0))
                 (response ""))
            (unwind-protect
                (progn
                  (process-send-string
                   proc
                   (concat cmd " " (cdr endpoint)
                           (if args
                               (concat " "
                                       (mapconcat
                                        (lambda (n) (format "%d" (round n)))
                                        args " "))
                             "")
                           "\n"))
                  (while (and (< (float-time) deadline)
                              (process-live-p proc)
                              (progn (goto-char (point-min))
                                     (not (search-forward "\n" nil t))))
                    (accept-process-output proc 0.2))
                  (goto-char (point-min))
                  (setq response
                        (buffer-substring-no-properties
                         (point-min) (line-end-position))))
              (when (process-live-p proc) (delete-process proc)))
            (unless (string= response "")
              (json-parse-string response
                                 :object-type 'alist :array-type 'list
                                 :false-object nil))))
      (error nil))))

(defun org-activity-android--bridge-day-rows (day)
  "One DAY of per-app rows from the bridge; importer row shape.
Queries the day's window (local midnight + 24 h, epoch ms).  Returns
nil when the bridge is absent, ungranted or empty."
  (let ((begin (org-activity-android--day-begin-ms day)))
    (when-let* ((resp (org-activity-android--bridge-request
                       "STATS" begin (+ begin 86400000))))
      (when (alist-get 'granted resp)
        (let ((out nil))
          (dolist (app (alist-get 'apps resp))
            (let* ((pkg (alist-get 'package app))
                   (label (alist-get 'label app))
                   (fg (or (alist-get 'foregroundMs app) 0)))
              (when (and pkg (> fg 0))
                (push (list :day day :package pkg :label (or label pkg)
                            :seconds (/ fg 1000.0)
                            :opens 0 :notifications 0)
                      out))))
          (nreverse out))))))

(defun org-activity-android--bridge-day-events (day)
  "One DAY of filtered usage events from the bridge.
Returns ((PACKAGE TYPE TIMESTAMP-MS)...) with TYPE a symbol:
resume, pause, screen_on, screen_off, keyguard_shown,
keyguard_hidden, notification_seen.  nil when no events."
  (let ((begin (org-activity-android--day-begin-ms day)))
    (when-let* ((resp (org-activity-android--bridge-request
                       "EVENTS" begin (+ begin 86400000))))
      (when (alist-get 'granted resp)
        (mapcar (lambda (e)
                  (list (alist-get 'package e)
                        (intern (alist-get 'type e))
                        (alist-get 'tsMs e)))
                (alist-get 'events resp))))))

(defun org-activity-android--hour-of (ts-ms day-begin-ms)
  "Hour-of-day (0-23) for TS-MS relative to DAY-BEGIN-MS (local midnight)."
  (min 23 (max 0 (floor (/ (- ts-ms day-begin-ms) 3600000)))))

(defun org-activity-android--credit-hours (hourly start-ms end-ms begin-ms)
  "Credit START..END (epoch ms) across per-hour buckets in HOURLY.
Buckets are indexed by hour-of-day relative to BEGIN-MS, so no
timezone arithmetic is needed at all."
  (when (> end-ms start-ms)
    (let ((cursor (float start-ms)))
      (while (< cursor end-ms)
        (let* ((hour (org-activity-android--hour-of cursor begin-ms))
               (next (min end-ms (+ begin-ms (* 3600000 (1+ hour))))))
          (cl-incf (aref hourly hour) (/ (- next cursor) 1000.0))
          (setq cursor next))))))

(defun org-activity-android--derive-day-extras (events begin-ms end-ms)
  "Derive StayFree day extras from EVENTS ((PKG TYPE TS-MS)...).
Returns a plist (:unlocks N :opens ((PKG . N)...) :notifs
((PKG . N)...) :hourly (24 per-hour seconds)).  Opens count resume
events; unlocks count keyguard_hidden events, falling back to
screen_on when the device reports no keyguard events (API < 30);
the hourly timeline is built from resume/pause session pairs, with
a session still open at the window's end closed at that end."
  (let ((keyguard-hiddens 0) (screen-ons 0)
        (opens nil) (notifs nil)
        (hourly (make-vector 24 0.0))
        (cur-pkg nil) (cur-start nil))
    (pcase-dolist (`(,pkg ,type ,ts) events)
      (pcase type
        ('resume
         ;; Robust to streams that drop a pause: close whatever is
         ;; open at the resume's timestamp before opening the new one.
         (when (and cur-pkg cur-start)
           (org-activity-android--credit-hours
            hourly cur-start (min (or ts end-ms) end-ms) begin-ms))
         (setq cur-pkg pkg cur-start ts)
         (when pkg (cl-incf (alist-get pkg opens 0 nil #'equal))))
        ((or 'pause 'screen_off)
         (when (and cur-pkg cur-start)
           (org-activity-android--credit-hours
            hourly cur-start (min (or ts end-ms) end-ms) begin-ms))
         (setq cur-pkg nil cur-start nil))
        ('keyguard_hidden (cl-incf keyguard-hiddens))
        ('screen_on (cl-incf screen-ons))
        ('notification_seen
         (when pkg (cl-incf (alist-get pkg notifs 0 nil #'equal))))))
    (when (and cur-pkg cur-start)
      (org-activity-android--credit-hours hourly cur-start end-ms begin-ms))
    (list :unlocks (if (> keyguard-hiddens 0) keyguard-hiddens screen-ons)
          :opens opens :notifs notifs
          :hourly (append hourly nil))))

(defun org-activity-android--pull-bridge ()
  "Pull the last `org-activity-android-native-days' days via the
Emacshell usage bridge.  STATS gives per-app screen time, EVENTS
give opens, notification counts, unlock counts and the hourly
timeline.  Returns the day list written, or nil when the bridge
yields nothing (absent permission included -- the caller falls back)."
  (let ((rows nil) (extras nil))
    (dotimes (i org-activity-android-native-days)
      (let* ((day (org-activity-android--day-string
                   (time-subtract nil (* i 86400))))
             (begin (org-activity-android--day-begin-ms day))
             (end (+ begin 86400000))
             (day-rows (org-activity-android--bridge-day-rows day))
             (events (org-activity-android--bridge-day-events day)))
        (when (or day-rows events)
          (let ((x (and events
                        (org-activity-android--derive-day-extras
                         events begin end))))
            (dolist (row day-rows)
              (let ((pkg (plist-get row :package)))
                (when x
                  (plist-put row :opens
                             (or (cdr (assoc pkg (plist-get x :opens))) 0))
                  (plist-put row :notifications
                             (or (cdr (assoc pkg (plist-get x :notifs))) 0)))))
            (setq rows (append rows day-rows))
            ;; The journal's hourly table is written in whole minutes
            ;; (StayFree's hourly view); derive returns seconds.
            (when x
              (push (cons day
                          (list :unlocks (plist-get x :unlocks)
                                :hourly (mapcar (lambda (s) (floor (/ s 60.0)))
                                                (plist-get x :hourly))))
                    extras))))))
    (if rows
        (org-activity-android--write-rows rows extras)
      (message "org-activity-android: bridge returned no rows")
      nil)))

;;; ------------------------------------------------------------------------
;;; Categories and limits (StayFree goals / ActivityWatch rules)
;;; ------------------------------------------------------------------------

(defun org-activity-android--category-of (pkg)
  "Category for PKG per `org-activity-android-categories', or \\='Other\\='."
  (or (cl-loop for (name . regexps) in org-activity-android-categories
               when (seq-some (lambda (re) (string-match-p re pkg)) regexps)
               return name)
      "Other"))

(defun org-activity-android--category-table (days)
  "Category rollup over the last DAYS days of the journal, or nil
when nothing matched the window."
  (let* ((day-list (org-activity-android--read-day-tables))
         (cutoff-day (org-activity-android--day-string
                      (float-time (time-subtract
                                   (current-time)
                                   (days-to-time (1- days))))))
         (cats nil))
    (dolist (entry day-list)
      (when (not (string< (car entry) cutoff-day))
        (dolist (row (cdr entry))
          (cl-incf (alist-get
                    (org-activity-android--category-of (nth 1 row))
                    cats 0 nil #'equal)
                   (nth 2 row)))))
    (when cats
      (setq cats (cl-sort cats #'> :key #'cdr))
      (concat "| Category | Time |\n"
              "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
              (mapconcat (lambda (kv)
                           (format "| %s | %s |\n" (car kv)
                                   (org-activity-android--fmt-dur (cdr kv))))
                         cats)
              "|-" (make-string 20 ?-) "+-" (make-string 8 ?-) "-|\n"
              (format "| Total | %s |\n"
                      (org-activity-android--fmt-dur
                       (cl-reduce #'+ (mapcar #'cdr cats)
                                  :initial-value 0)))))))

(defun org-activity-android--over-limits (&optional day)
  "Package limits exceeded on DAY (default today): ((RE LIMIT ACTUAL)...)."
  (let* ((day (or day (org-activity-android--day-string)))
         (rows (org-activity-android--day-rows day))
         (overs nil))
    (dolist (limit org-activity-android-limits)
      (let ((actual (cl-reduce
                     #'+
                     (mapcar (lambda (r)
                               (if (string-match-p (car limit) (nth 1 r))
                                   (nth 2 r) 0))
                             rows)
                     :initial-value 0)))
        (when (> actual (* (cdr limit) 60))
          (push (list (car limit) (* (cdr limit) 60) actual) overs))))
    (nreverse overs)))

(defun org-activity-android--warn-limits (&optional day)
  "Warn about exceeded `org-activity-android-limits' (message, and an
Android notification when this Emacs can post one).  Informs only."
  (dolist (over (org-activity-android--over-limits day))
    (let ((msg (format "org-activity-android: over limit: %s at %s (limit %s)"
                       (nth 0 over)
                       (org-activity-android--fmt-dur (nth 2 over))
                       (org-activity-android--fmt-dur (nth 1 over)))))
      (message "%s" msg)
      (when (fboundp 'android-notifications-notify)
        (condition-case _
            (android-notifications-notify "org-activity" msg)
          (error nil))))))

;;; ------------------------------------------------------------------------
;;; Mode and report
;;; ------------------------------------------------------------------------

(defvar org-activity-android--timer nil)

(defun org-activity-android--tick ()
  "One scheduled pull (errors never break the timer)."
  (condition-case err
      (org-activity-android-refresh)
    (error (message "org-activity-android: pull failed: %s"
                    (error-message-string err)))))

;;;###autoload
(define-minor-mode org-activity-android-mode
  "Periodically pull Android usage data into the Org journal."
  :global t
  :lighter org-activity-android-lighter
  :group 'org-activity-android
  (if org-activity-android-mode
      (setq org-activity-android--timer
            (run-at-time 0 org-activity-android-refresh-interval
                         #'org-activity-android--tick))
    (when org-activity-android--timer
      (cancel-timer org-activity-android--timer))
    (setq org-activity-android--timer nil)))

;;;###autoload
(defun org-activity-android-report (&optional days)
  "Show a StayFree-style report for the last DAYS (7): top-apps table
with opens and notification counts, per-day trend chart, last-day
top-apps chart plus that day's hour-of-day timeline, a category
rollup when `org-activity-android-categories' is set, and warnings
for exceeded `org-activity-android-limits'."
  (interactive (list (read-number "Days: " 7)))
  (require 'org nil t)
  (let* ((days (or days 7))
         (buffer (get-buffer-create "*Android Usage*"))
         (cats (and org-activity-android-categories
                    (org-activity-android--category-table days)))
         (last-day (car (car (last
                              (org-activity-android--read-day-tables)))))
         (timeline (and last-day
                        (org-activity-android--timeline-chart last-day))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'org-mode) (org-mode) (fundamental-mode))
        (insert (format "#+title: Android usage, last %d days\n\n" days)
                (org-activity-android--range-table days 15))
        (when cats
          (insert "\n*By category*\n\n" cats))
        (insert "\n" (org-activity-android--chart-links days))
        (when timeline
          (insert "#+caption: Hour of day, " last-day "\n"
                  "[[file:" timeline "]]\n"))
        (dolist (over (org-activity-android--over-limits))
          (insert (format "WARNING: over limit: %s at %s (limit %s)\n"
                          (nth 0 over)
                          (org-activity-android--fmt-dur (nth 2 over))
                          (org-activity-android--fmt-dur (nth 1 over)))))
        (goto-char (point-min)))
      (display-buffer buffer)
      (when (and (fboundp 'org-display-inline-images)
                 (display-graphic-p))
        (ignore-errors (org-display-inline-images t t))))
    buffer))

(defun org-activity-android--timeline-chart (day)
  "Write DAY's hour-of-day timeline chart; return its link or nil.
Needs the engine's SVG renderer (org-activity.el, soft-required);
without it -- or without hourly data in the journal -- the timeline
is skipped silently."
  (when (and day (fboundp 'org-activity--svg-timeline))
    (let* ((meta (cdr (assoc day (org-activity-android--read-day-meta))))
           (hourly (plist-get meta :hourly)))
      (when (and hourly (cl-some (lambda (m) (> m 0)) hourly))
        (org-activity-android--write-chart
         (format "usage-timeline-%s.svg" day)
         (org-activity--svg-timeline
          (mapcar (lambda (m) (* m 60.0)) hourly)
          (format "Hour of day, %s" day)))))))

;;;###autoload
(defun org-activity-android-timeline (&optional date)
  "Show DATE's (default: last day with hourly data) hour-of-day chart."
  (interactive)
  (require 'org nil t)
  (let* ((date (or date
                   (car (car (last
                             (org-activity-android--read-day-meta))))))
         (link (and date (org-activity-android--timeline-chart date)))
         (buffer (get-buffer-create "*Android Timeline*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'org-mode) (org-mode) (fundamental-mode))
        (insert (format "#+title: Android timeline %s\n\n" (or date "no data")))
        (if link
            (insert (format "#+caption: Hour of day\n[[file:%s]]\n" link))
          (insert "No hourly data for this day (bridge pulls provide it).\n"))
        (goto-char (point-min)))
      (display-buffer buffer)
      (when (and (fboundp 'org-display-inline-images)
                 (display-graphic-p))
        (ignore-errors (org-display-inline-images t t))))
    buffer))

;;;###autoload
(defun org-activity-android-day-report (&optional date)
  "Show one day's (DATE, default: last day with data) report:\ntable + top-apps chart + hour-of-day timeline."
  (interactive (list (read-string "Day (YYYY-MM-DD): "
                                  (org-activity-android--day-string))))
  (require 'org nil t)
  (let* ((rows (org-activity-android--day-rows date))
         (timeline (and date (org-activity-android--timeline-chart date)))
         (meta (and date (cdr (assoc date
                                     (org-activity-android--read-day-meta)))))
         (buffer (get-buffer-create "*Android Usage Day*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (fboundp 'org-mode) (org-mode) (fundamental-mode))
        (insert (format "#+title: Android usage, %s\n\n"
                        (or date "no data"))
                (if rows
                    (org-activity-android--day-table-org rows)
                  "No usage data for this day.\n"))
        (when (and meta (plist-get meta :unlocks))
          (insert (format "\nUnlocks: %d\n" (plist-get meta :unlocks))))
        (when rows
          (let ((link (org-activity-android--write-chart
                       "usage-top-day.svg"
                       (org-activity-android--svg-hbars
                        (org-activity-android--day-top date 10)
                        (format "Top apps, %s" date)))))
            (insert "\n#+caption: Top apps\n[[file:" link "]]\n")))
        (when timeline
          (insert "#+caption: Hour of day\n[[file:" timeline "]]\n"))
        (goto-char (point-min)))
      (display-buffer buffer)
      (when (and (fboundp 'org-display-inline-images)
                 (display-graphic-p))
        (ignore-errors (org-display-inline-images t t))))
    buffer))

;;;###autoload
(defun org-activity-android-open-journal ()
  "Open the usage journal Org file."
  (interactive)
  (find-file (org-activity-android-org-file-path)))

;;; ------------------------------------------------------------------------
;;; JSON export (ActivityWatch-style events; data freedom)
;;; ------------------------------------------------------------------------

;;;###autoload
(defun org-activity-android-export-json (&optional days file)
  "Export the last DAYS (7) of the usage journal as event JSON to FILE.
One event per app per day, ActivityWatch-shaped: timestamp (the day,
midnight), duration (that day's screen time) and data ((app . LABEL)
(package . PKG) (opens . N) (notifications . N))."
  (interactive)
  (let* ((days (or days 7))
         (file (or file (read-file-name "Export to: " nil nil nil
                                        "org-activity-android.json")))
         (day-list (org-activity-android--read-day-tables))
         (cutoff-day (org-activity-android--day-string
                      (float-time (time-subtract
                                   (current-time)
                                   (days-to-time (1- days))))))
         (events nil))
    (dolist (entry day-list)
      (when (not (string< (car entry) cutoff-day))
        (dolist (row (cdr entry))
          (push `((timestamp . ,(concat (car entry) "T00:00:00"))
                  (duration . ,(nth 2 row))
                  (data . ((app . ,(nth 0 row))
                           (package . ,(nth 1 row))
                           (opens . ,(or (nth 3 row) 0))
                           (notifications . ,(or (nth 4 row) 0)))))
                events))))
    (with-temp-file file (insert (json-encode (nreverse events))))
    (message "org-activity-android: %d event(s) exported to %s"
             (length events) file)
    file))

;;; ------------------------------------------------------------------------
;;; Org capture integration
;;; ------------------------------------------------------------------------

;; Silence the byte compiler; org-capture defines the real defcustom.
(defvar org-capture-templates)

(defun org-activity-android--capture-snip ()
  "One-line usage summary for the capture template (today)."
  (let* ((rows (org-activity-android--day-rows (org-activity-android--day-string))))
    (if (not rows)
        "No usage data yet today."
      (let* ((total (apply #'+ (mapcar (lambda (r) (nth 2 r)) rows)))
             (top3 (seq-take (cl-sort (copy-sequence rows)
                                      #'> :key (lambda (r) (nth 2 r)))
                             3)))
        (format "Total: %s | %s"
                (org-activity-android--fmt-dur total)
                (mapconcat (lambda (r)
                             (format "%s (%s)" (nth 0 r)
                                     (org-activity-android--fmt-dur (nth 2 r))))
                           top3 ", "))))))

(defcustom org-activity-android-capture-template
  '("au" "Android usage snapshot" entry
    (file (lambda () (expand-file-name "org-activity-android-snapshots.org"
                                       (or (bound-and-true-p org-directory)
                                           "~/org"))))
    "* Usage snapshot %U\n%(org-activity-android--capture-snip)\n")
  "org-capture template capturing today's usage snapshot.
Added to `org-capture-templates' by `org-activity-android-setup-capture'."
  :type 'sexp
  :group 'org-activity-android)

;;;###autoload
(defun org-activity-android-setup-capture ()
  "Add `org-activity-android-capture-template' to `org-capture-templates'."
  (interactive)
  (require 'org-capture)
  (add-to-list 'org-capture-templates org-activity-android-capture-template)
  (message "org-activity-android: capture template %S installed"
           (car org-activity-android-capture-template)))

;; org-dynamic-block-insert-dblock completes over this alist (org 9.x).
(with-eval-after-load 'org
  (when (boundp 'org-dynamic-block-alist)
    (add-to-list 'org-dynamic-block-alist
                 '("org-activity-android" . org-activity-android-insert-block))
    (add-to-list 'org-dynamic-block-alist
                 '("org-activity-android-day" . org-activity-android-insert-day-block))))

;; README references `org-activity-android-import'; keep it working.
(defalias 'org-activity-android-import 'org-activity-android-import-file)

(provide 'org-activity-android)
;;; org-activity-android.el ends here
