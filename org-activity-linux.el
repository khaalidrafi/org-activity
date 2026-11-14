;;; org-activity-linux.el --- system-window source for org-activity -*- lexical-binding: t; -*-

;; Author: z.ai-agent <noreply@z.ai>
;; Maintainer: Khalid Rafi <khaalidrafi@gmail.com>
;; Version: 1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: org, convenience, tools
;; URL: https://github.com/khaalidrafi/org-activity
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The Linux module of org-activity (see org-activity.el): credit the
;; SYSTEM foreground window while you work outside Emacs -- the
;; aw-watcher-window role of ActivityWatch, driven from Elisp.
;;
;; Enable it by loading this file and flipping the engine's source:
;;
;;   (require 'org-activity-linux)
;;   (setq org-activity-source-function #'org-activity-linux-source)
;;
;; Two best-effort detectors are tried in order, both optional
;; external binaries resolved from PATH:
;;
;;   - hyprctl (Hyprland):  `hyprctl activewindow -j'
;;   - xdotool (X11):       `xdotool getactivewindow' + window queries
;;
;; Behavior:
;;   - Active window belongs to this Emacs  ->  the default Emacs
;;     source answers (so buffers/projects get credited, not "Emacs").
;;   - Any other window                     ->  "System:<class>" with
;;     the window title as the entry's mode.
;;   - No detector works (plain Wayland, headless, tools missing)
;;     ->  honest degradation to Emacs-side tracking, exactly what
;;     org-activity does without this module.  Plain Wayland has no
;;     universal "active window" API; that is a Wayland rule, not a
;;     choice, and it is documented instead of hidden.

;;; Code:

(require 'cl-lib)
(require 'json)

(declare-function org-activity-emacs-source "org-activity" ())

(defgroup org-activity-linux nil
  "System-window source for the org-activity engine on Linux."
  :group 'org-activity)

(defcustom org-activity-linux-title-max 60
  "Truncate window titles stored as activity modes to this length.
Titles change constantly; the journal records one mode per activity
per day (the first seen), so a bound keeps entries readable."
  :type 'natnum
  :group 'org-activity-linux)

;; ------------------------------------------------------------------------
;; Detector helpers.  Each returns (PID CLASS TITLE) for the active
;; window, or nil when it cannot answer.  PID may be nil or 0 when the
;; WM does not expose it; only a PID equal to `emacs-pid' counts as
;; "the active window is this Emacs".
;; ------------------------------------------------------------------------

(defun org-activity-linux--run (prog &rest args)
  "Run PROG with ARGS; return trimmed stdout, or nil on any failure.
Never signals: a missing or failing tool just disables its detector."
  (when-let* ((bin (executable-find prog)))
    (with-temp-buffer
      (when (zerop (apply #'call-process bin nil t nil args))
        (string-trim (buffer-string))))))

(defun org-activity-linux--hyprctl ()
  "Ask Hyprland for the active window: (PID CLASS TITLE) or nil."
  (when-let* ((out (org-activity-linux--run "hyprctl" "activewindow" "-j")))
    ;; json-false -> nil keeps the alist small when fields are absent.
    (let ((json-false nil))
      (when-let* ((js (ignore-errors
                        (json-parse-string out :object-type 'alist))))
        (list (alist-get 'pid js)
              (format "%s" (or (alist-get 'initialClass js) "?"))
              (format "%s" (or (alist-get 'title js) "")))))))

(defun org-activity-linux--xdotool ()
  "Ask X11 (via xdotool) for the active window: (PID CLASS TITLE) or nil."
  (when-let* ((wid (org-activity-linux--run "xdotool" "getactivewindow")))
    (let ((pid (org-activity-linux--run "xdotool" "getwindowpid" wid))
          (class (org-activity-linux--run "xdotool" "getwindowclassname" wid))
          (title (org-activity-linux--run "xdotool" "getwindowname" wid)))
      (list (and pid (ignore-errors (string-to-number pid)))
            (or class "?")
            (or title "")))))

(defun org-activity-linux--active-window ()
  "Probe the desktop for the active window: (PID CLASS TITLE) or nil."
  (or (org-activity-linux--hyprctl)
      (org-activity-linux--xdotool)))

;;;###autoload
(defun org-activity-linux-source ()
  "Return the current activity as (KEY . MODE) for the engine sampler.
Suitable as `org-activity-source-function' on a Linux desktop.
See the file header of org-activity-linux.el for the full contract."
  (let ((win (org-activity-linux--active-window)))
    (cond
     ;; No detector answered: degrade to the default, Emacs-only view.
     ((null win) (org-activity-emacs-source))
     ;; This Emacs owns the active window: credit the front buffer.
     ((equal (car win) (emacs-pid)) (org-activity-emacs-source))
     ;; Anything else on screen: one row per application class.
     (t (cons (concat "System:" (or (cadr win) "?"))
              (let ((title (or (nth 2 win) "")))
                (if (> (length title) org-activity-linux-title-max)
                    (substring title 0 org-activity-linux-title-max)
                  title)))))))

(provide 'org-activity-linux)
;;; org-activity-linux.el ends here
