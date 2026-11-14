;;; test.el --- ERT tests for org-activity-android.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-activity-android)

(defun org-activity-android-test--occurrences (needle haystack)
  "Count non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((n 0) (start 0))
    (while (string-match needle haystack start)
      (setq n (1+ n) start (match-end 0)))
    n))

(defmacro org-activity-android-test--with-journal (&rest body)
  "Run BODY with `org-activity-android-org-file' at a fresh temp file."
  `(let ((org-activity-android-org-file
          (make-temp-file "org-activity-android-test" nil ".org")))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-file org-activity-android-org-file)))))

;; Fixture days are computed at load time (2 and 3 days ago) so the
;; "last N days" window filters can never rot as real time passes;
;; the first version of this suite hardcoded 2026-11-05/06 and went
;; red nine days later for exactly that reason.
(defconst org-activity-android-test--day-a
  (format-time-string "%Y-%m-%d" (time-subtract nil (* 2 86400)))
  "Fixture day A: two days ago (inside every range window used).")

(defconst org-activity-android-test--day-b
  (format-time-string "%Y-%m-%d" (time-subtract nil (* 3 86400)))
  "Fixture day B: three days ago.")

(defconst org-activity-android-test--csv-date-col
  (concat "Date,Application label,Package,Duration (seconds),Opens\n"
          org-activity-android-test--day-a ",WhatsApp,org.whatsapp,3600,12\n"
          org-activity-android-test--day-a ",GNU Emacs,org.gnu.emacs,7200,40\n"
          org-activity-android-test--day-b ",WhatsApp,org.whatsapp,1800,5\n"))

(defconst org-activity-android-test--csv-stayfree-like
  "App,Package,Time,Opens
WhatsApp,org.whatsapp,1:30:00,7
Maps,com.google.android.apps.maps,0:45:30,3
")

(defconst org-activity-android-test--csv-ms
  "Package,Duration in ms
org.whatsapp,1500
org.gnu.emacs,90000
")

(defconst org-activity-android-test--json
  (concat "{\"days\": [
     {\"date\": \"" org-activity-android-test--day-a "\",
      \"apps\": [{\"package\": \"org.whatsapp\", \"label\": \"WhatsApp\",
                  \"seconds\": 3600, \"opens\": 12}]}]}"))

(ert-deftest org-activity-android--split-csv-quoted ()
  (should (equal
           (org-activity-android--split-csv
            "a,b\n\"x, y\",\"say \"\"hi\"\"\"\r\nz,w\n")
           '(("a" "b") ("x, y" "say \"hi\"") ("z" "w")))))

(ert-deftest org-activity-android--split-csv-no-trailing-newline ()
  (should (equal (org-activity-android--split-csv "a,b\nc,d")
                 '(("a" "b") ("c" "d")))))

(ert-deftest org-activity-android--parse-hms ()
  (should (= (org-activity-android--parse-hms "1:23:45") 5025))
  (should (= (org-activity-android--parse-hms "1:23") 4980))
  (should (= (org-activity-android--parse-hms "0:05") 300))
  (should (null (org-activity-android--parse-hms "5"))))

(ert-deftest org-activity-android--duration-secs-formats ()
  (let ((org-activity-android-duration-unit :auto))
    (should (= (org-activity-android--duration-secs "45") 45))
    (should (= (org-activity-android--duration-secs "1h 23m") 4980))
    (should (= (org-activity-android--duration-secs "1h 5m 10s") 3910))
    (should (= (org-activity-android--duration-secs "45m") 2700))
    (should (= (org-activity-android--duration-secs "2:05") 7500))
    ;; :auto: only past the two-day threshold is it milliseconds
    (should (= (org-activity-android--duration-secs 90000) 90000))
    (should (= (org-activity-android--duration-secs 200000) 200))
    (should (null (org-activity-android--duration-secs "not a time")))))

(ert-deftest org-activity-android--duration-unit-pinned ()
  (let ((org-activity-android-duration-unit 'millis))
    (should (= (org-activity-android--duration-secs 500) 0.5)))
  (let ((org-activity-android-duration-unit 'seconds))
    (should (= (org-activity-android--duration-secs 90000) 90000))))

(ert-deftest org-activity-android--norm-header ()
  (should (equal (org-activity-android--norm-header "Duration (ms)") "durationms"))
  (should (equal (org-activity-android--norm-header " Application Label ")
                 "applicationlabel")))

(ert-deftest org-activity-android--detect-columns-maps ()
  (let ((cols (org-activity-android--detect-columns
               '("Date" "Application label" "Package"
                 "Duration (seconds)" "Opens"))))
    (should (= (plist-get cols :date) 0))
    (should (= (plist-get cols :label) 1))
    (should (= (plist-get cols :package) 2))
    (should (= (plist-get cols :seconds) 3))
    (should (= (plist-get cols :opens) 4))))

(ert-deftest org-activity-android--parse-csv-date-column ()
  (let ((rows (org-activity-android--parse-csv org-activity-android-test--csv-date-col)))
    (should (= (length rows) 3))
    (should (equal (plist-get (nth 0 rows) :day) org-activity-android-test--day-a))
    (should (equal (plist-get (nth 0 rows) :package) "org.whatsapp"))
    (should (equal (plist-get (nth 0 rows) :label) "WhatsApp"))
    (should (= (plist-get (nth 0 rows) :seconds) 3600))
    (should (= (plist-get (nth 0 rows) :opens) 12))))

(ert-deftest org-activity-android--parse-csv-stayfree-like ()
  (let* ((file (concat "/tmp/stayfree-" org-activity-android-test--day-b ".csv"))
         (rows (org-activity-android--parse-csv
                org-activity-android-test--csv-stayfree-like file)))
    (should (= (length rows) 2))
    (should (equal (plist-get (nth 0 rows) :day) org-activity-android-test--day-b))
    (should (= (plist-get (nth 0 rows) :seconds) 5400))
    (should (= (plist-get (nth 1 rows) :seconds) 2730))))

(ert-deftest org-activity-android--parse-csv-millis ()
  (let ((rows (org-activity-android--parse-csv org-activity-android-test--csv-ms)))
    (should (= (plist-get (nth 0 rows) :seconds) 1.5))
    (should (= (plist-get (nth 1 rows) :seconds) 90))))

(ert-deftest org-activity-android--parse-json-canonical ()
  (let ((rows (org-activity-android--parse-json org-activity-android-test--json)))
    (should (= (length rows) 1))
    (should (equal (plist-get (nth 0 rows) :day) org-activity-android-test--day-a))
    (should (equal (plist-get (nth 0 rows) :package) "org.whatsapp"))
    (should (= (plist-get (nth 0 rows) :seconds) 3600))
    (should (= (plist-get (nth 0 rows) :opens) 12))))

(ert-deftest org-activity-android--aggregate-sums-and-labels ()
  (let* ((rows (org-activity-android--parse-csv org-activity-android-test--csv-date-col))
         (days (org-activity-android--aggregate rows))
         (d05 (cdr (assoc org-activity-android-test--day-a days))))
    (should (= (length days) 2))
    (should (= (car (cdr (assoc "org.whatsapp" d05))) 3600))
    (should (= (cdr (cdr (assoc "org.whatsapp" d05))) 12))
    (should (equal (cdr (assoc "label:org.whatsapp" d05)) "WhatsApp"))
    (should (= (car (cdr (assoc "org.gnu.emacs" d05))) 7200))))

(ert-deftest org-activity-android--aggregate-longest-label-wins ()
  (let ((days (org-activity-android--aggregate
               (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                           :seconds 10 :opens 1)
                     (list :day org-activity-android-test--day-a :package "org.x" :label "App X"
                           :seconds 20 :opens 1)))))
    (should (equal (cdr (assoc "label:org.x" (cdr (assoc org-activity-android-test--day-a days))))
                   "App X"))))

(ert-deftest org-activity-android--aggregate-ignores ()
  (let ((org-activity-android-ignore-packages '("^com\\.android\\.systemui$")))
    (let ((days (org-activity-android--aggregate
                 (list (list :day org-activity-android-test--day-a
                             :package "com.android.systemui"
                             :label "System UI" :seconds 999 :opens 9)
                       (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                             :seconds 10 :opens 1)))))
      (should (null (assoc "com.android.systemui"
                           (cdr (assoc org-activity-android-test--day-a days))))))))

(ert-deftest org-activity-android--day-table-sorted-with-total ()
  (let ((table (org-activity-android--day-table
                (list (cons "label:org.a" "App A")
                      (cons "org.a" (cons 60 1))
                      (cons "org.b" (cons 3600 2))))))
    (should (string-match-p "| App A | org\\.a | 0:01 | 1 |" table))
    (should (string-match-p "| org\\.b | org\\.b | 1:00 | 2 |" table))
    ;; sorted descending: org.b row must appear before org.a row
    (should (< (string-match "org\\.b" table) (string-match "org\\.a" table)))
    (should (string-match-p "| Total | | 1:01 | 3 |" table))))

(ert-deftest org-activity-android--write-day-idempotent ()
  (org-activity-android-test--with-journal
   (let ((rows (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                           :seconds 60 :opens 1))))
     (org-activity-android--write-day org-activity-android-test--day-a rows)
     (org-activity-android--write-day org-activity-android-test--day-a rows)
     (with-temp-buffer
       (insert-file-contents org-activity-android-org-file)
       (let ((s (buffer-string)))
         (should (= (org-activity-android-test--occurrences "| App | Package |" s) 1))
         (should (= (org-activity-android-test--occurrences "| Total |" s) 1))
         (should (string-match-p (concat "^\\* " (regexp-quote org-activity-android-test--day-a) " ") s)))))))

(ert-deftest org-activity-android--read-day-tables-roundtrip ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                :seconds 3660 :opens 3)))
   (let ((days (org-activity-android--read-day-tables)))
     (should (= (length days) 1))
     (should (equal (car (car days)) org-activity-android-test--day-a))
     (let ((row (cadr (car days))))
       (should (equal (nth 0 row) "X"))
       (should (equal (nth 1 row) "org.x"))
       (should (= (nth 2 row) 3660))
       (should (= (nth 3 row) 3))))))

(ert-deftest org-activity-android--import-and-range ()
  (org-activity-android-test--with-journal
   (with-temp-file "/tmp/au-test-export.csv"
     (insert org-activity-android-test--csv-date-col))
   (org-activity-android-import-file "/tmp/au-test-export.csv")
   (let ((table (org-activity-android--range-table 7 15)))
     (should (string-match-p "org\\.whatsapp" table))
     (should (string-match-p "Total (top 15 of last 7 days)" table))
     ;; 3600+7200+1800 = 12600s = 3:30
     (should (string-match-p "3:30" table)))
   (ignore-errors (delete-file "/tmp/au-test-export.csv"))))

(ert-deftest org-activity-android--pull-latest-imports-newest ()
  (org-activity-android-test--with-journal
   (let* ((dir (make-temp-file "au-pull" t))
          (org-activity-android-import-dir dir)
          (old (expand-file-name "usage-old.csv" dir))
          (new (expand-file-name "usage-new.csv" dir)))
     ;; old: no package column (unusable); new: valid
     (with-temp-file old (insert "foo,bar\n1,2\n"))
     (sleep-for 0 20)
     (with-temp-file new (insert org-activity-android-test--csv-date-col))
     ;; days come back date-ascending (day-b is older than day-a)
     (should (equal (org-activity-android--pull-latest-file)
                    (list org-activity-android-test--day-b org-activity-android-test--day-a)))
     (should (file-exists-p org-activity-android-org-file))
     (delete-directory dir t))))

(ert-deftest org-activity-android--pull-no-file-returns-nil ()
  (org-activity-android-test--with-journal
   (let ((org-activity-android-import-dir (make-temp-file "au-empty" t)))
     (should (null (org-activity-android--pull-latest-file)))
     (delete-directory org-activity-android-import-dir t))))

(ert-deftest org-activity-android--dblock-writes-table ()
  (with-temp-buffer
    (org-mode)
    (insert "#+BEGIN: org-activity-android :days 7 :top 5\n#+END:\n")
    (goto-char (point-min))
    (cl-letf (((symbol-function #'org-activity-android--range-table)
               (lambda (_days _top)
                 "| App | Package | Time | Opens |\n| X | org.x | 1:00 | 1 |\n")))
      (org-update-all-dblocks))
    (should (string-match-p "org\\.x" (buffer-string)))
    (should (string-match-p "#\\+BEGIN: org-activity-android" (buffer-string)))))

(ert-deftest org-activity-android--report-buffer ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                :seconds 60 :opens 1)))
   (let ((buf (org-activity-android-report 7)))
     (with-current-buffer buf
       (should (string-match-p "org\\.x" (buffer-string)))))))

;;; ---------------------------------------------------------------------
;;; Charts (v0.2)
;;; ---------------------------------------------------------------------

(ert-deftest org-activity-android--xml-escape ()
  (should (equal (org-activity-android--xml-escape "a&b<c>\"d\"'e'")
                 "a&amp;b&lt;c&gt;&quot;d&quot;&apos;e&apos;"))
  (should (equal (org-activity-android--xml-escape "plain") "plain")))

(ert-deftest org-activity-android--svg-hbars-renders-bars ()
  (let ((svg (org-activity-android--svg-hbars
               '(("App A" . 3600) ("App B" . 60)) "Top apps")))
    (should (string-match-p "<svg" svg))
    ;; background + one bar rect per row
    (should (= (org-activity-android-test--occurrences "<rect" svg) 3))
    (should (string-match-p "App A" svg))
    (should (string-match-p "App B" svg))
    (should (string-match-p "1:00" svg))
    (should (string-match-p "Top apps" svg))))

(ert-deftest org-activity-android--svg-hbars-empty ()
  (should (string-match-p "no usage data"
                          (org-activity-android--svg-hbars nil))))

(ert-deftest org-activity-android--svg-hbars-escapes-labels ()
  (let ((svg (org-activity-android--svg-hbars '(("A&B <x>" . 60)))))
    (should (string-match-p "A&amp;B &lt;x&gt;" svg))
    (should-not (string-match-p "A&B" svg))))

(ert-deftest org-activity-android--svg-vbars-renders-days ()
  (let ((svg (org-activity-android--svg-vbars
              `((,org-activity-android-test--day-a . 3600) (,org-activity-android-test--day-b . 1800)) "Trend")))
    (should (string-match-p "<svg" svg))
    (should (= (org-activity-android-test--occurrences "<rect" svg) 3))
    (should (string-match-p (substring org-activity-android-test--day-a 5) svg))
    (should (string-match-p (substring org-activity-android-test--day-b 5) svg))
    (should (string-match-p "1:00" svg))))

(ert-deftest org-activity-android--range-day-totals-sums-days ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.a" :label "A"
                :seconds 3600 :opens 1)
          (list :day org-activity-android-test--day-a :package "org.b" :label "B"
                :seconds 7200 :opens 2)))
   (org-activity-android--write-day
    org-activity-android-test--day-b
    (list (list :day org-activity-android-test--day-b :package "org.a" :label "A"
                :seconds 1800 :opens 1)))
   ;; Force both days inside a 7-day window regardless of real date.
   (cl-letf (((symbol-function #'org-activity-android--read-day-tables)
              (lambda ()
                (list (cons org-activity-android-test--day-a
                            (list (list "A" "org.a" 3600 1)
                                  (list "B" "org.b" 7200 2)))
                      (cons org-activity-android-test--day-b
                            (list (list "A" "org.a" 1800 1)))))))
     (should (equal (org-activity-android--range-day-totals 7)
                    `((,org-activity-android-test--day-b . 1800) (,org-activity-android-test--day-a . 10800)))))))

(ert-deftest org-activity-android--day-top-sorts-and-falls-back ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.a" :label "A"
                :seconds 60 :opens 1)
          (list :day org-activity-android-test--day-a :package "org.b" :label "B"
                :seconds 3600 :opens 2)))
   ;; known day
   (should (equal (org-activity-android--day-top org-activity-android-test--day-a 1)
                  '(("B" . 3600))))
   ;; unknown day falls back to last day with data
   (should (= (length (org-activity-android--day-top "1999-01-01")) 2))
   ;; empty journal -> nil
   (cl-letf (((symbol-function #'org-activity-android--read-day-tables) #'ignore))
     (should (null (org-activity-android--day-top nil))))))

(ert-deftest org-activity-android--write-chart-rel-path ()
  (org-activity-android-test--with-journal
   (let ((link (org-activity-android--write-chart "t.svg" "<svg/>")))
     (should (equal link "charts/t.svg"))
     (should (file-exists-p
              (expand-file-name "t.svg" (org-activity-android-chart-dir)))))))

(ert-deftest org-activity-android--day-table-org ()
  (let ((table (org-activity-android--day-table-org
                (list (list "A" "org.a" 60 1)
                      (list "B" "org.b" 3660 2)))))
    (should (string-match-p "| B | org\\.b | 1:01 | 2 |" table))
    (should (< (string-match "org\\.b" table) (string-match "org\\.a" table)))
    (should (string-match-p "| Total | | 1:02 | 3 |" table))))

(ert-deftest org-activity-android--dblock-with-chart-inserts-links ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                :seconds 60 :opens 1)))
   (with-temp-buffer
     (org-mode)
     (insert "#+BEGIN: org-activity-android :days 7 :top 5\n#+END:\n")
     (goto-char (point-min))
     (org-update-all-dblocks)
     (let ((s (buffer-string)))
       (should (string-match-p "org\\.x" s))
       (should (string-match-p "\\[\\[file:charts/usage-trend-7d\\.svg\\]\\]" s))
       (should (string-match-p "\\[\\[file:charts/usage-top-day\\.svg\\]\\]" s))))
   (ignore-errors
     (delete-directory (org-activity-android-chart-dir) t))))

(ert-deftest org-activity-android--dblock-chart-off ()
  (org-activity-android-test--with-journal
   (with-temp-buffer
     (org-mode)
     (insert "#+BEGIN: org-activity-android :days 7 :top 5 :chart nil\n#+END:\n")
     (goto-char (point-min))
     (cl-letf (((symbol-function #'org-activity-android--range-table)
                (lambda (_d _t) "| T |\n")))
       (org-update-all-dblocks))
     (should-not (string-match-p "file:charts" (buffer-string))))))

(ert-deftest org-activity-android--dblock-day-writes-table-and-chart ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                :seconds 60 :opens 1)))
   (with-temp-buffer
     (org-mode)
     (insert (format "#+BEGIN: org-activity-android-day :date %S\n#+END:\n" org-activity-android-test--day-a))
     (goto-char (point-min))
     (org-update-all-dblocks)
     (let ((s (buffer-string)))
       (should (string-match-p "org\\.x" s))
       (should (string-match-p "\\[\\[file:charts/usage-top-day\\.svg\\]\\]" s))))
   (ignore-errors
     (delete-directory (org-activity-android-chart-dir) t))))

(ert-deftest org-activity-android--day-report-buffer ()
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "X"
                :seconds 60 :opens 1)))
   (let ((buf (org-activity-android-day-report org-activity-android-test--day-a)))
     (with-current-buffer buf
       (should (string-match-p "org\\.x" (buffer-string)))
       (should (string-match-p "file:charts/usage-top-day" (buffer-string)))))))

(ert-deftest org-activity-android--capture-snip-empty-and-data ()
  (org-activity-android-test--with-journal
   (should (equal (org-activity-android--capture-snip) "No usage data yet today."))
   (org-activity-android--write-day
    (org-activity-android--day-string)
    (list (list :day (org-activity-android--day-string) :package "org.x"
                :label "X" :seconds 60 :opens 1)))
   (should (string-match-p "Total: 0:01 | X (0:01)"
                           (org-activity-android--capture-snip)))))

(ert-deftest org-activity-android--capture-template-shape ()
  (should (equal (car org-activity-android-capture-template) "au"))
  (should (string-match-p "org-activity-android--capture-snip"
                          (nth 4 org-activity-android-capture-template)))
  ;; setup-capture installs into org-capture-templates
  (require 'org-capture)
  (let ((org-capture-templates nil))
    (org-activity-android-setup-capture)
    (should (member org-activity-android-capture-template org-capture-templates))))

(ert-deftest org-activity-android--import-alias ()
  (should (fboundp 'org-activity-android-import)))

(ert-deftest org-activity-android--range-table-shows-labels ()
  ;; Regression (v0.1): the App column showed the package and Opens
  ;; was printed twice; the label column must show the real label.
  (org-activity-android-test--with-journal
   (org-activity-android--write-day
    org-activity-android-test--day-a
    (list (list :day org-activity-android-test--day-a :package "org.x" :label "GNU Emacs"
                :seconds 3660 :opens 7)))
   (cl-letf (((symbol-function #'org-activity-android--read-day-tables)
              (lambda ()
                (list (cons org-activity-android-test--day-a
                            (list (list "GNU Emacs" "org.x" 3660 7)))))))
     (let ((table (org-activity-android--range-table 7 15)))
       (should (string-match-p "| GNU Emacs | org\\.x | 1:01 | 7 |" table))
       ;; label must appear in column 1, package in column 2
       (should (< (string-match "GNU Emacs" table)
                  (string-match "org\\.x" table)))))))
