;;; test-linux.el --- ERT tests for org-activity-linux.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Unit tests for the Linux system-window source.  Everything that
;; touches the desktop goes through `org-activity-linux--run', so the
;; tests stub that one function (cl-letf) and never need a running X
;; server, Hyprland or any binary.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-activity-linux)

;; The real Emacs PID must never match a stubbed foreign PID.
(defconst org-activity-linux-test--foreign-pid
  (1+ (emacs-pid))
  "A PID that is certainly not this Emacs.")

(ert-deftest org-activity-linux-hyprctl-foreign-window ()
  "A non-Emacs Hyprland window becomes System:<class> with its title."
  (cl-letf (((symbol-function 'org-activity-linux--run)
             (lambda (prog &rest _args)
               (when (string= prog "hyprctl")
                 "{\"address\":\"0x1\",\"pid\":4242,\
\"initialClass\":\"firefox\",\"title\":\"GNU savannah\"}"))))
    (let ((am (org-activity-linux-source)))
      (should (equal (car am) "System:firefox"))
      (should (equal (cdr am) "GNU savannah")))))

(ert-deftest org-activity-linux-hyprctl-emacs-window-defers ()
  "When this Emacs is the active window the Emacs source answers.
We verify the defer by the result shape: in a batch session the
front buffer is this very test file, so the key is a Files:/Emacs:
row -- never System:."
  (cl-letf (((symbol-function 'org-activity-linux--run)
             (lambda (prog &rest _args)
               (when (string= prog "hyprctl")
                 (format "{\"pid\":%d,\"initialClass\":\"Emacs\",\
\"title\":\"emacs\"}" (emacs-pid))))))
    (let ((am (org-activity-linux-source)))
      (should am)
      (should-not (string-prefix-p "System:" (car am))))))

(ert-deftest org-activity-linux-xdotool-fallback ()
  "Without hyprctl the xdotool detector is used."
  (cl-letf (((symbol-function 'org-activity-linux--run)
             (lambda (prog &rest args)
               (pcase (list prog (car args))
                 (`("hyprctl" . _) nil)      ; Hyprland absent
                 (`("xdotool" "getactivewindow") "12345")
                 (`("xdotool" "getwindowpid")
                  (number-to-string org-activity-linux-test--foreign-pid))
                 (`("xdotool" "getwindowclassname") "org.gnome.Nautilus")
                 (`("xdotool" "getwindowname") "Home")))))
    (let ((am (org-activity-linux-source)))
      (should (equal (car am) "System:org.gnome.Nautilus"))
      (should (equal (cdr am) "Home")))))

(ert-deftest org-activity-linux-no-detector-degrades ()
  "No detector -> the default Emacs source answers (never an error,
and never a System: row that would miscredit focused Emacs time)."
  (cl-letf (((symbol-function 'org-activity-linux--run)
             (lambda (&rest _args) nil)))
    (let ((am (org-activity-linux-source)))
      (should am)
      (should-not (string-prefix-p "System:" (car am))))))

(ert-deftest org-activity-linux-long-title-truncated ()
  "Titles longer than `org-activity-linux-title-max' are cut."
  (let ((long-title (make-string 200 ?x))
        (org-activity-linux-title-max 40))
    (cl-letf (((symbol-function 'org-activity-linux--run)
               (lambda (prog &rest _args)
                 (when (string= prog "hyprctl")
                   (format "{\"pid\":%d,\"initialClass\":\"app\",\
\"title\":\"%s\"}" org-activity-linux-test--foreign-pid long-title)))))
      (let ((am (org-activity-linux-source)))
        (should (equal (cdr am) (make-string 40 ?x)))))))

(ert-deftest org-activity-linux-hyprctl-bad-json-is-absent ()
  "Garbage hyprctl output counts as 'not available', not as an error."
  (cl-letf (((symbol-function 'org-activity-linux--run)
             (lambda (prog &rest _args)
               (when (string= prog "hyprctl") "{not json"))))
    ;; no xdotool either -> full degrade
    (let ((am (org-activity-linux-source)))
      (should am)
      (should-not (string-prefix-p "System:" (car am))))))

(provide 'test-linux)
;;; test-linux.el ends here
