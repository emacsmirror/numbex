;;; numbex.el --- Manage numbered examples -*- lexical-binding: t; -*-

;; Copyright (C) 2021, 2022 Enrico Flor

;; Author: Enrico Flor <enrico@eflor.net>
;; Maintainer: Enrico Flor <enrico@eflor.net>
;; URL: https://github.com/enricoflor/numbex
;; Version: 0.3.0
;; Package-Requires: ((emacs "26.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; numbex.el provides a minor mode that manages numbered examples.
;; Its primary function is to take care for the user of the correct
;; sequential numbering of examples in the buffer.  It also takes care
;; that references to examples are updated with the change in the
;; numbering.
;;
;; For explanation as to how to use numbex, check the readme.org file
;; at <https://github.com/enricoflor/numbex>.

;;; Code:

(require 'subr-x)

(defvar numbex-mode)

(defgroup numbex nil
  "Automatically number examples and references to them."
  :prefix "numbex-"
  :link '(url-link :tag "Website for numbex"
                   "https://github.com/enricoflor/numbex")
  :group 'convenience)

(defvar-local numbex--total-number-of-items 0
  "Total number of numbex-items in the buffer.")

(defvar-local numbex--automatic-refresh t
  "If t, evaluate 'numbex-refresh' on idle timer and with other commands.
Specifically, with 'numbex-toggle-display' and 'numbex-do'.  Even
if nil, 'numbex-refresh will be added to 'auto-save-hook' and
'before-save-hook'.")

(defvar-local numbex--hidden-labels t
  "If t, numbex items have a numerical overlay.")

(defcustom numbex-delimiters '("(" . ")")
  "Opening and closing characters used around numbers.
Set two empty strings if you just want the number."
  :type '(cons string string)
  :group 'numbex)

(defcustom numbex-highlight-unlabeled t
  "If t, items that are missing a label are highlighted.
Blank strings (containing only white space) count as no label.
Unlabeled items have the appearance specified by
'font-lock-comment-face'."
  :type 'boolean
  :group 'numbex)

(defcustom numbex-highlight-duplicates t
  "If t, items that have an ambiguous label are highlighted.
A label is ambiguous if it not a blank string (it doesn't just
contain white space) and is used as a label of more than one
example item.  Items with non-unique labels have the appearance
specified by 'font-lock-warning-face'."
  :type 'boolean
  :group 'numbex)

(defvar numbex--idle-timer nil)

;; There is some redundancy in some of these regexp but it is done for
;; consistency: the first capture group is always the type, the second
;; is always the label of the item.
(defconst numbex--item-re "{\\[\\([pnr]?ex\\):\\(.*?\\)\\]}")
(defconst numbex--example-re "{\\[\\(ex\\):\\(.*?\\)\\]}")
(defconst numbex--reference-re "{\\[\\([pnr]+ex\\):\\(.*?\\)\\]}")

(defun numbex--item-at-point ()
  "Return position of the label of the item point is on and its type.
If point is on a numbex item, this function returns a cons cell
whose car is a cons cell with the buffer positions of the first
and last character of the label respectively, and its cdr is a
string corresponding to the type of the item.  Return nil if
point is not on a numbex item.

Thus, when point is on an item:
 - (caar (numbex--item-at-point)) is the beginning of the label
 - (cdar (numbex--item-at-point)) is the end of the label
 - (cdr (numbex--item-at-point)) is the type of the label"
  (let ((position (point)))
    (save-excursion
      (beginning-of-line)
      (catch 'found
        (while (re-search-forward numbex--item-re (line-end-position) t)
          (when (<= (match-beginning 0) position (match-end 0))
            (throw 'found
                   (cons (cons (match-beginning 2)
                               (match-end 2))
                         (buffer-substring-no-properties (match-beginning 1)
                                                         (match-end 1)))))
          nil)))))

;; These are the hash tables and list that are reset at every
;; evaluation of 'numbex--scan-buffer': they contain all the
;; information pertinent to the numbering and the referencing of
;; examples.
(defvar-local numbex--label-number nil
  "Hash table mapping labels of examples to the number assigned.")

(defvar-local numbex--label-line nil
  "Hash table a label to the line of the corresponding example.")

(defvar-local numbex--duplicates nil
  "A list of non-empty labels that are not unique in the buffer.")

(defvar-local numbex--existing-labels nil
  "A list of non-empty labels that are used in the buffer.")

;; An example is the best way to explain what this variable is for.
;; Suppose there are five examples in the buffer: three in the first
;; page, two in the second.  The value of this variable will be: ("1"
;; "2" "3" "1" "2")

;; When 'numbex--add-numbering' is evaluated, if 'numbex--relative' is
;; t, the examples will be numbered in loop by popping values out of
;; this list.
(defvar-local numbex--numbers-list nil
  "A list of strings with to the relative numbering in the buffer.")

(defcustom numbex-relative-numbering t
  "If nil, the numbering never restarts in the buffer.
If t, numbering restart at \"(1)\" at every regexp specified in
'numbex-numbering-reset-regexps'.  This variable is made
buffer-local its value can be toggled interactively with
'numbex-toggle-relative-numbering'."
  :type 'boolean
  :group 'numbex)

(make-variable-buffer-local 'numbex-relative-numbering)

(defcustom numbex-numbering-reset-regexps
  '("")
  "List of regexps at which numbering restarts.
If the buffer-local value of 'numbex-relative-numbering' is t,
numbering restarts at \"(1)\" at each of the regexp in this list.
The default value is the form-feed character (\"\f\" or \"\").

Other good values to add would be org headings.  If you want the
numbering to restart at each form feed character and at every
level 1st and 2nd org-mode heading you can add this regexp to the
list: \"^\\*\\*? \".

This variable is made buffer-local, and can be specified as a
file-local variable (for example, with
'add-file-local-variable')."
  :type '(list string)
  :group 'numbex)

(make-variable-buffer-local 'numbex-numbering-reset-regexps)

(defvar-local numbex--items-list nil
  "List of all the items or form-feed characters currently in the buffer.
Updated by 'numbex--scan-buffer'.")

(defvar-local numbex--annotation-alist '()
  "Alist mapping labels to strings of number and context.")

(defun numbex--scan-buffer ()
  "Collect information relevant for numbex from the buffer.
Remove all whitespace from items.  Reset the values for the
buffer-local variables.  The information is collected in a
widened indirect buffer, so that even if the current buffer is
narrowed, numbex will behave taking into consideration the entire
buffer.  This reduces the risk of working on a narrowed buffer
and ending up with many duplicate labels or mistaken references
once the buffer is widened again."
  ;; First of all, recreate the two hash tables with the size of the
  ;; last value of 'numbex--existing-labels'
  (let* ((old-number-labels (length numbex--existing-labels))
         (narrowed (buffer-narrowed-p))
         (start-of-buffer (point-min))
         (point-in-narrowing nil)
         (labels '())
         (duplicates '())
         (numbers '())
         (items '())
         (annotation '())
         (counter 1)
         (delimiters
          (if (assoc 'numbex-numbering-reset-regexps
                     file-local-variables-alist)
              (cdr (assoc 'numbex-numbering-reset-regexps
                          file-local-variables-alist))
            numbex-numbering-reset-regexps))
         (delimiters-re (mapconcat 'identity delimiters "\\|"))
         (global-re (concat numbex--item-re "\\|" delimiters-re)))
    (setq numbex--label-line (make-hash-table :test 'equal
                                              :size old-number-labels))
    (setq numbex--label-number (make-hash-table :test 'equal
                                                :size old-number-labels))
    (setq numbex--total-number-of-items 0)
    (with-current-buffer (clone-indirect-buffer nil nil t)
      (widen)
      (goto-char (point-min))
      (while (re-search-forward global-re nil t)
        (push (match-string-no-properties 0) items)
        (if (save-match-data
              (string-match delimiters-re (match-string-no-properties 0)))
            ;; We hit a delimiter character: If
            ;; numbex-relative-numbering is t, reset the counter to 1,
            ;; otherwise do nothing
            (when numbex-relative-numbering
              (setq counter 1))
          ;; We hit an item: first thing we do is removing whitespace.
          (let ((clean-label
                 (if (string-match "[[:space:]]"
                                   (match-string-no-properties 2)
                                   nil t)
                     (replace-match
                      (replace-regexp-in-string "[[:space:]]" ""
                                                (match-string-no-properties 2))
                      t t nil 2)
                   (match-string-no-properties 2)))
                (type (match-string-no-properties 1)))
            (setq numbex--total-number-of-items
                  (1+ numbex--total-number-of-items))
            ;; If the item is an example, we have to fill up our hash
            ;; tables and lists, otherwise, we have nothing more to do
            ;; Before doing this, we might need to reset the counter
            ;; to 1 if the buffer was narrowed, we want relative
            ;; numbering, and the point now is after the original
            ;; (point-min), that is, it has entered the narrowed
            ;; portion of the buffer.  If all this is the case, reset
            ;; the counter and set 'point-in-narrowing' to t so that
            ;; it won't reset again at the next match.
            (when (equal type "ex")
              (when (and (not point-in-narrowing)
                         numbex-relative-numbering
                         narrowed
                         (> (point) start-of-buffer))
                (setq point-in-narrowing t)
                (setq counter 1))
              ;; For convenience, let's store strings of the form
              ;; "(1)" instead of numbers like 1 in the lists, so we
              ;; won't have to bother convert it later when it's time
              ;; to put them as display text properties.
              (let ((n-string (concat (car numbex-delimiters)
                                      (number-to-string counter)
                                      (cdr numbex-delimiters))))
                (push n-string numbers)
                (unless (string-blank-p clean-label)
                  (when (and (member clean-label labels)
                             (not (member clean-label duplicates)))
                    ;; keep only one token for each type of duplicate
                    ;; label
                    (push clean-label duplicates))
                  (push clean-label labels))    ; only non-empty labels matter
                (puthash clean-label n-string numbex--label-number)
                (goto-char (match-end 0))
                ;; This will change match data: if there is a number
                ;; placeholder next to the item, it won't end up being
                ;; included in the line.
                (looking-at (concat (car numbex-delimiters)
                                    "[\\.]+"
                                    (cdr numbex-delimiters)))
                (puthash clean-label
                         (buffer-substring-no-properties (match-end 0)
                                                         (line-end-position))
                         numbex--label-line)
                (unless (string-blank-p clean-label)
                  (push
                   (cons clean-label
                         (concat n-string
                                 " "
                                 (buffer-substring-no-properties
                                  (match-end 0)
                                  (line-end-position))))
                   annotation)))
              ;; Before the next iteration, increment both counters
              (setq counter (1+ counter))))))
      (kill-buffer (current-buffer)))
    ;; Now we are out of the indirect buffer, and we can set the rest
    ;; of the buffer local variables with the values we obtained from
    ;; the loop.
    (setq numbex--numbers-list (nreverse numbers))
    (setq numbex--duplicates duplicates)
    (setq numbex--existing-labels labels)
    (setq numbex--items-list items)
    (setq numbex--annotation-alist annotation)))

(defun numbex--highlight (lab type b e)
  "Add face text properties to substring between B and E.
Do so according to the values of 'numbex-highlight-duplicates'
and 'numbex-highglight-unlabeled'.  LAB is the label of the item
and TYPE its type.  This function is called by
'numbex--remove-numbering' (when evaluated with optional argument
nil) and by 'numbex--add-numbering'."
  (cond ((and (member lab numbex--duplicates)
              numbex-highlight-duplicates)
         (add-text-properties b e
                              '(font-lock-face 'font-lock-warning-face))
         (put-text-property b e 'rear-nonsticky t))
        ((and numbex-highlight-unlabeled
              (equal type "rex")
              (string-blank-p lab))
         (add-text-properties b e '(font-lock-face 'font-lock-comment-face))
         (put-text-property b e 'rear-nonsticky t))
        (t nil)))

(defun numbex--remove-numbering (&optional no-colors)
  "Remove all numbex text properties from the buffer.
Set 'numbex--hidden-labels' to nil.  If NO-COLORS is t, don't set
font-lock-faces."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward numbex--item-re nil t)
      (let ((b (match-beginning 0))
            (e (match-end 0))
            (type (buffer-substring-no-properties (match-beginning 1)
                                                  (match-end 1)))
            (lab (buffer-substring-no-properties (match-beginning 2)
                                                 (match-end 2))))
        (set-text-properties b e nil)
        (when (or (equal type "ex")
                  (equal type "rex")
                  (not no-colors))
          (numbex--highlight lab type b e)))))
  (numbex--toggle-font-lock-keyword)
  (setq numbex--hidden-labels nil))

(defun numbex--add-numbering ()
  "Number items in the buffer as text properties.
Set 'numbex-hidden-labels' to t."
  (setq numbex--total-number-of-items 0)
  ;; First, let's number the examples.  If the buffer is narrowed and
  ;; 'numbex-relative-numbering' is t, we just need to number the examples in
  ;; the buffer.
  (with-current-buffer (clone-indirect-buffer nil nil t)
    (widen)
    (goto-char (point-min))
    (let ((previous-ex-n "(1)"))
      (while (re-search-forward numbex--item-re nil t)
        ;; Add to the total number first
        (setq numbex--total-number-of-items
              (1+ numbex--total-number-of-items))
        (let ((b (match-beginning 0))
              (e (match-end 0))
              (type (buffer-substring-no-properties (match-beginning 1)
                                                    (match-end 1)))
              (label (buffer-substring-no-properties (match-beginning 2)
                                                     (match-end 2))))
          (when (looking-at (concat (car numbex-delimiters)
                                    "[\\.]+"
                                    (cdr numbex-delimiters)))
            (delete-region (match-beginning 0)
                           (match-end 0)))
          (set-text-properties b e nil)
          (cond ((equal type "ex")
                 ;; As number, take the current car of
                 ;; numbex--numbers-list:
                 (let ((num (pop numbex--numbers-list)))
                   (insert (replace-regexp-in-string "[[:digit:]]\\|\\?"
                                                     "." num))
                   (put-text-property b (point) 'display num)
                   (numbex--highlight label type b (point))
                   (setq previous-ex-n num)))
                ;; If the item is {[rex:]}, without a label, give it
                ;; the number of the closes example.  Otherwise, look
                ;; up the hash table to find the number to give.  If
                ;; no key corresponding to the label is found it means
                ;; that the non-empty label is not being used by any
                ;; example (yet), so the reference will appear as
                ;; "(??)":
                ((equal type "rex")
                 (let ((num (if (string-blank-p label)
                                previous-ex-n
                              (gethash label
                                       numbex--label-number
                                       (concat (car numbex-delimiters)
                                               "??"
                                               (cdr numbex-delimiters))))))
                   (insert (replace-regexp-in-string "[[:digit:]]\\|\\?"
                                                     "." num))
                   (put-text-property b (point) 'display num)
                   (numbex--highlight label type b (point))))
                ((equal type "pex")
                 (insert (replace-regexp-in-string "[[:digit:]]\\|\\?" "."
                                                   previous-ex-n))
                 (put-text-property b (point) 'display previous-ex-n))
                ((equal type "nex")
                 (let ((num (if (car numbex--numbers-list)
                                (car numbex--numbers-list)
                              (concat (car numbex-delimiters)
                                      "??"
                                      (cdr numbex-delimiters)))))
                   (insert (replace-regexp-in-string "[[:digit:]]\\|\\?"
                                                     "." num))
                   (put-text-property b (point) 'display num)))))))
    (kill-buffer (current-buffer)))
  (numbex--toggle-font-lock-keyword t)
  (setq numbex--hidden-labels t))

(defun numbex-toggle-relative-numbering ()
  "Toggle value of 'numbex-relative-numbering' (buffer-local)."
  (interactive)
  (if numbex-relative-numbering
      (progn
        (setq numbex-relative-numbering nil)
        (message "Relative numbering deactivated"))
    (setq numbex-relative-numbering t)
    (message "Relative numbering activated")))

;;;###autoload
(defun numbex-toggle-display ()
  "Remove numbers if they are present, add them otherwise."
  (interactive)
  (when numbex--automatic-refresh
    (numbex-refresh))
  (if numbex--hidden-labels
      (numbex--remove-numbering)
    (numbex--add-numbering)))

(defun numbex--uniquify-string (s l)
  "Return modified S such that it is not a member of list L.
The suffix to be added is \"-NN\", where N is a digit."
  (let ((counter 1)
        (label s))
    (while (member label l)
      (let ((suffix (concat "--"
                            (format "%s" counter))))
        (setq label (concat s suffix))
        (setq counter (1+ counter))))
    label))

(defun numbex--prompt-with-duplicate-label (label)
  "Choose what to do if LABEL is in 'numbex--existing-labels'.
Allow the user to return a uniquified string by calling
'numbex--uniquify-string' on LABEL."
  (let ((choice (read-multiple-choice
                 (concat label
                         " is used already, are you sure?")
                 '((?y "yes")
                   (?n "no")
                   (?! "make label unique")))))
    (cond ((equal choice '(?y "yes"))
           label)
          ((equal choice '(?n "no"))
           nil)
          ((equal choice '(?! "make label unique"))
           (numbex--uniquify-string label numbex--existing-labels)))))

(defun numbex--annotation-function (label)
  "Return string mapped to LABEL in 'numbex--annotation-alist'."
  (let ((candidate (cdr (assoc label minibuffer-completion-table))))
    (when candidate
      (concat "  -- " candidate))))

(defun numbex--edit (item)
  "With ITEM the output of 'numbex--item-at-point', change label."
  (save-excursion
    (let* ((old-label
            (buffer-substring-no-properties (car (car item))
                                            (cdr (car item))))
           (type (cdr item))
           (new-label
            (if (equal type "ex")
                (replace-regexp-in-string "[[:space:]]" ""
                 (read-string (format
                               "New label [default \"%s\"]: "
                               old-label)
                              old-label nil
                              old-label t))
              ;; If the item is a reference, provide completion with
              ;; the existing labels.
              (let ((completion-extra-properties
                     '(:annotation-function numbex--annotation-function)))
                (completing-read
                 (format "Label [default \"%s\"]: " old-label)
                 numbex--annotation-alist
                 nil nil
                 old-label nil
                 old-label t))))
           (novel (not (member new-label numbex--existing-labels))))
      (if (and (equal type "ex")
               (not novel)
               (not (equal new-label old-label)))
          (let ((reaction (numbex--prompt-with-duplicate-label new-label)))
            (if (not reaction)
                (numbex--edit item)
              (goto-char (car (car item)))
              (delete-region (car (car item))
                             (cdr (car item)))
              (insert reaction)))
        (goto-char (car (car item)))
        (delete-region (car (car item))
                       (cdr (car item)))
        (insert new-label))
      (when (and (equal type "ex") novel)
        (let ((rename (yes-or-no-p
                       "Relabel all associated references?"))
              (target (concat "{\\[[r]?ex:\\(" old-label "\\)\\]}")))
          (when rename
            (goto-char (point-min))
            (while (search-forward-regexp target nil t)
              (replace-match new-label t t nil 1)))))
      ;; If item at point is nex: or pex:, make it into a rex:,
      ;; otherwise the new label will be wiped out automatically.  It
      ;; does not make sense to edit pex: and nex: items manually.
      (when (or (equal type "nex")
                (equal type "pex"))
        (re-search-backward "{\\[[pn]+ex")
        (replace-match "{[rex" t)))))

(defun numbex--example ()
  "Insert a new example item."
  (let* ((label (read-string "Label: "
                             nil nil
                             nil t))
         (sanitized-label (replace-regexp-in-string "[[:space:]]" "" label)))
    (if (member sanitized-label numbex--existing-labels)
        (let ((reaction (numbex--prompt-with-duplicate-label sanitized-label)))
            (if (not reaction)
                (numbex--example)
              (insert "{[ex:" reaction "]}")))
      (insert "{[ex:" sanitized-label "]}"))))

(defun numbex--reference ()
  "Insert a new reference item."
  (insert
   "{[rex:"
   (let ((completion-extra-properties
          '(:annotation-function numbex--annotation-function)))
     (completing-read "Label: "
                      numbex--annotation-alist))
   "]}"))

(defun numbex--new ()
  "Insert a new item."
  (let ((choice (read-multiple-choice "Insert new:"
                                      '((?e "example")
                                        (?r "reference")
                                        (?n "ref to next")
                                        (?p "ref to previous")))))
    (cond ((equal choice '(?e "example"))
           (numbex--example))
          ((equal choice '(?r "reference"))
           (numbex--reference))
          ((equal choice '(?n "ref to next"))
           (insert "{[nex:]}"))
          ((equal choice '(?p "ref to previous"))
           (insert "{[pex:]}")))
    (insert " ")))

;;;###autoload
(defun numbex-do ()
  "Insert a new item or edit the existing one at point."
  (interactive)
  (let ((hidden numbex--hidden-labels))
    (when hidden
      (numbex--remove-numbering))
    (if (numbex--item-at-point)
        (numbex--edit (numbex--item-at-point))
      (numbex--new))
    (when numbex--automatic-refresh
      (numbex-refresh t))
    (if hidden
        (numbex--add-numbering)
      (numbex--remove-numbering))))

(defun numbex--search-not-at-point ()
  "Let user choose a regexp and grep for it."
  (let ((choice (read-multiple-choice "Look for:"
                                      '((?a "all")
                                        (?e "examples")
                                        (?r "references")
                                        (?d "duplicates")
                                        (?u "unlabeled")))))
    (cond ((equal choice '(?a "all"))
           (occur numbex--item-re))
          ((equal choice '(?e "examples"))
           (occur numbex--example-re))
          ((equal choice '(?r "references"))
           (occur numbex--reference-re))
          ((equal choice '(?d "duplicates"))
           (occur (regexp-opt
                   (nconc (mapcar (lambda (x) (concat "{[ex:"
                                                      x
                                                      "]}"))
                                  numbex--duplicates)
                          (mapcar (lambda (x) (concat "{[rex:"
                                                      x
                                                      "]}"))
                                  numbex--duplicates)))))
          ((equal choice '(?u "unlabeled"))
           (occur "{\\[[pnr]?ex:\s*\\]}")))))

(defun numbex--search-at-point ()
  "Let user choose a regexp and grep for it."
  (let* ((positions (car (numbex--item-at-point)))
         (label (buffer-substring-no-properties (car positions)
                                                (cdr positions)))
         (reg (if (string-blank-p label)
                  numbex--item-re
                (concat "{\\[[pnr]?ex:" label "\\]}")))
         (choice (read-multiple-choice "Look for:"
                                       '((?a "all")
                                         (?e "examples")
                                         (?r "references")
                                         (?l "label at point")
                                         (?d "duplicates")
                                         (?u "unlabeled")))))
    (cond ((equal choice '(?a "all"))
           (occur numbex--item-re))
          ((equal choice '(?e "examples"))
           (occur numbex--example-re))
          ((equal choice '(?r "references"))
           (occur numbex--reference-re))
          ((equal choice '(?l "label at point"))
           (occur reg))
          ((equal choice '(?d "duplicates"))
           (occur (regexp-opt
                   (nconc (mapcar (lambda (x) (concat "{[ex:"
                                                      x
                                                      "]}"))
                                  numbex--duplicates)
                          (mapcar (lambda (x) (concat "{[rex:"
                                                      x
                                                      "]}"))
                                  numbex--duplicates)))))
          ((equal choice '(?u "unlabeled"))
           (occur "{\\[[pnr]?ex:\s*\\]}")))))

(defun numbex-previous-example (&optional arg)
  "Move point to previous example item.
Always skip the first example item if it is on the same line as
point.  Optional prefix ARG specifies how many examples backwards
to jump to.  Do nothing if there is no previous example item in
the accessible portion of the buffer."
  (interactive "p")
  (save-excursion
    (beginning-of-line)
    (unless (re-search-backward numbex--example-re nil t arg)
      (if (> arg 1)
          (user-error (format "No %s previous examples" arg))
        (user-error "No previous example"))))
  (beginning-of-line)
  (when (re-search-backward numbex--example-re nil t arg)
    (message "No previous example")))

(defun numbex-next-example (&optional arg)
  "Move point to next example item.
Optional prefix ARG specifies how many examples forwards to jump
to.  Do nothing if there is no next example item in the
accessible portion of the buffer."
  (interactive "p")
  (let ((item-at-point (numbex--item-at-point)))
    (save-excursion
      (when (string-equal "ex" (cdr item-at-point))
        (goto-char (cdar item-at-point)))
      (unless (re-search-forward numbex--example-re nil t arg)
        (if (> arg 1)
            (user-error (format "No %s next examples" arg))
          (user-error "No next example"))))
    (when (string-equal "ex" (cdr item-at-point))
      (goto-char (cdar item-at-point)))
    (if (re-search-forward numbex--example-re nil t arg)
        (goto-char (match-beginning 0))
      (message "No previous example"))))

;;;###autoload
(defun numbex-search ()
  "Grep the buffer for items."
  (interactive)
  (numbex--remove-numbering)
  (numbex-refresh t)
  (if (numbex--item-at-point)
      (numbex--search-at-point)
    (numbex--search-not-at-point))
  (numbex--add-numbering))

;;;###autoload
(defun numbex-convert-to-latex ()
  "Replace all numbex items into corresponding LaTeX macros."
  (interactive)
  (numbex--scan-buffer)
  (numbex--add-numbering)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward numbex--item-re nil t)
      (let ((label (match-string-no-properties 2))
            (type (match-string-no-properties 1)))
        (goto-char (match-beginning 0))
        (delete-region (match-beginning 0)
                       (match-end 0))
        (when (looking-at (concat (car numbex-delimiters)
                                    "[\\.\\?]+"
                                    (cdr numbex-delimiters)))
            (delete-region (match-beginning 0)
                           (match-end 0)))
        (if (equal type "ex")
            (insert "\\label{ex:" label "}")
          (insert "(\\ref{ex:" label "})"))))))

;;;###autoload
(defun numbex-convert-from-latex ()
  "Replace relevant LaTeX macros with corresponding numbex items."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward "\\\\label{ex:\\([^\\]*\\)}" nil t)
      (let ((label (match-string-no-properties 1)))
        (goto-char (match-beginning 0))
        (delete-region (match-beginning 0)
                       (match-end 0))
        (insert "{[ex:" label "]}")))
    (goto-char (point-min))
    (while (re-search-forward "(\\\\ref{ex:\\([^\\]*\\)})" nil t)
      (let ((label (match-string-no-properties 1)))
        (goto-char (match-beginning 0))
        (delete-region (match-beginning 0)
                       (match-end 0))
        (insert "{[rex:" label "]}"))))
  (when numbex--automatic-refresh
    (numbex-refresh)))

;;;###autoload
(defun numbex-write-out-numbers ()
  "Write buffer to new file with numbers instead of numbex items."
  (interactive)
  (numbex--scan-buffer)
  (numbex--add-numbering)
  (let* ((original-buffer (current-buffer))
         (new-buffer-name (concat "nb-"
                                  (format "%s" original-buffer)))
         (unique-new-name (if (file-exists-p new-buffer-name)
                              (generate-new-buffer-name new-buffer-name)
                            new-buffer-name)))
    (with-current-buffer (get-buffer-create unique-new-name)
      (insert-buffer-substring-as-yank original-buffer)
      (goto-char (point-min))
      (while (re-search-forward numbex--item-re nil t)
        (let* ((b (match-beginning 0))
               (e (match-end 0))
               (number (plist-get (text-properties-at (match-beginning 2))
                                  'display)))
          (goto-char b)
          (delete-region b e)
          (when (looking-at (concat (car numbex-delimiters)
                                    "[\\.\\?]+"
                                    (cdr numbex-delimiters)))
            (delete-region (match-beginning 0)
                           (match-end 0)))
          (insert number)))
      (write-file unique-new-name)
      (kill-current-buffer))))

(defun numbex--echo-duplicates ()
  "Display existing non-unique labels in the echo area."
  (when numbex--duplicates
    (if (= (length numbex--duplicates) 1)
        (message (concat ""
                         "1 duplicate label found: "
                         (car numbex--duplicates)))
      (message (concat (format  "%s duplicate labels found: "
                                (length numbex--duplicates))
                       (mapconcat #'identity
                                  numbex--duplicates
                                  "  "))))))

(defvar-local numbex--buffer-hash nil
  "Store value of 'buffer-hash' buffer-locally.")

(defun numbex-refresh (&optional no-echo)
  "Scan the buffer and assign numbers.
If NO-ECHO is non-nil, do not warn about duplicates.  This is to
be added to 'numbex-mode-hook', 'auto-save-hook' and
'before-save-hook'."
  (interactive)
  (let ((hidden numbex--hidden-labels)
        (old-items-list numbex--items-list))
    (numbex--scan-buffer)
    ;; Now 'numbex--items-list' has been updated: do nothing if the
    ;; new value is the same as the old one.
    (unless (= (sxhash-equal old-items-list)
               (sxhash-equal numbex--items-list))
      (numbex--add-numbering)
      (unless hidden
        (numbex--remove-numbering))
      (unless no-echo
        (numbex--echo-duplicates))))
  ;; Update the value of numbex--buffer-hash
  (setq numbex--buffer-hash (buffer-hash)))

(defconst numbex--safe-number-items 1000
  "The largest number of numbex items in a buffer considered safe.
Numbex can deal with larger numbers than that, but in the
interest of performance the refresh on idle timer should be
disabled at a certain point.")

(defun numbex--timed ()
  "Housekeeping function to be evaluated on 'numbex--idle-timer'.
If not in 'numbex-mode' or 'numbex--hidden-labels' is nil, do
nothing.  Otherwise, if point is on an item, display its label
and, if appropriate, the context of the referenced example in the
echo area.  If point is not on an item, evaluate
'numbex--scan-buffer' and 'numbex--add-numbering' so that the
appearance of the buffer is kept up to date as far as numbex is
concerned."
  (when (and numbex-mode
             numbex--hidden-labels)
    (let ((item (numbex--item-at-point)))
      (if item
          ;; Point is on an item: show the underlying label.  If the
          ;; item is a reference, show the context of the
          ;; corresponding example as well.
          (let* ((type (cdr item))
                 (label
                  (buffer-substring-no-properties (car (car item))
                                                  (cdr (car item)))))
            (if (not (equal type "ex"))
                (message (concat label
                                 ": "
                                 (gethash label
                                          numbex--label-line
                                          " ")))
              (message label)))
        ;; Point is not on an item, just rescan the buffer and
        ;; renumber the items.  Do it only if this wouldn't cripple
        ;; everything.
        (unless (or (> numbex--total-number-of-items numbex--safe-number-items)
                    (not numbex--automatic-refresh)
                    ;; If (buffer-hash) is the same as the stored
                    ;; value, it means the buffer hasn't changed, so
                    ;; don't do anything!  The value of
                    ;; 'numbex--buffer-hash' is updated by
                    ;; 'numbex-refresh'
                    (equal (buffer-hash)
                           numbex--buffer-hash))
          ;; Giving t as an argument prevents 'numbex-refresh' to
          ;; annoy the user with messages in the echo area about
          ;; duplicate labels.  They will only be shown if the
          ;; function is called interactively or when it is evaluated
          ;; on auto-save and before-save-hook.
          (numbex-refresh t))))))

(defun numbex--count-and-ask ()
  "With more than 1000 items, ask whether to automatically refresh.
1000 is the default value of 'numbex--safe-number-items'."
  (save-excursion
    (goto-char (point-min))
    (setq numbex--total-number-of-items 0)
    (while (re-search-forward numbex--item-re nil t)
      (setq numbex--total-number-of-items
            (1+ numbex--total-number-of-items)))
    (when (and (> numbex--total-number-of-items numbex--safe-number-items)
               numbex--automatic-refresh)
      (let* ((question
              (format "There are %s items in the buffer.\n
Do you want to disable automatic refresh\n
(you can refresh yourself with 'numbex-refresh')?"
                      numbex--total-number-of-items))
             (choice (yes-or-no-p question)))
        (when choice
            (setq numbex--automatic-refresh nil))))))

(defun numbex--toggle-font-lock-keyword (&optional add)
  "Remove or add font-lock-keyword making numbex items invisible.
If the value of ADD is t, add the keyword and set
'numbex--hidden-labels' to t.  Otherwise, remove the keyword and
set the same variable to nil.  Finally, refontify accessible
portion of the buffer."
  (if add
      (font-lock-add-keywords
       nil
       '(("{\\[[pnr]?ex:\\(.*?\\)\\]}"
          0 '(face nil invisible t) append)))
    (font-lock-remove-keywords
     nil
     '(("{\\[[pnr]?ex:\\(.*?\\)\\]}"
        0 '(face nil invisible t) append))))
  (save-excursion (font-lock-fontify-region (point-min) (point-max))))

;;;###autoload
(define-minor-mode numbex-mode
  "Automatically number examples and references to them."
  :init-value nil
  :global nil
  :lighter " nbex"
  :group 'convenience
  (if numbex-mode
      ;; activating numbex-mode
      (progn
        (unless numbex--idle-timer
          (setq numbex--idle-timer
                (run-with-idle-timer 0.3 t #'numbex--timed)))
        ;; Numbex needs font-lock
        (unless font-lock-mode
          (font-lock-mode 1))
        (font-lock-add-keywords
         nil
         '(("{\\[[pnr]?ex:\\(.*?\\)\\]}"
            0 '(face nil invisible t) append)))
        (save-excursion (font-lock-fontify-region (point-min) (point-max)))
        (numbex--count-and-ask)
        ;; For the first time they are created, let the hash tables
        ;; have the default size of 65
        (setq numbex--label-line (make-hash-table :test 'equal))
        (setq numbex--label-number (make-hash-table :test 'equal))
        (numbex-refresh)
        (add-hook 'auto-save-hook #'numbex-refresh nil t)
        (add-hook 'before-save-hook #'numbex-refresh nil t))
    ;; leaving numbex-mode
    (cancel-timer numbex--idle-timer)
    (setq numbex--idle-timer nil)
    ;; Evaluate numbex--remove-numbering with the optional argument
    ;; no-colors non-nil so that there won't be any color left
    ;; regardless of the value of the variables
    ;; numbex-highlight-unlabeled and numbex-highlight-duplicates:
    (numbex--remove-numbering t)
    (font-lock-remove-keywords
         nil
         '(("{\\[[pnr]?ex:\\(.*?\\)\\]}"
            0 '(face nil invisible t) append)))
    (save-excursion (font-lock-fontify-region (point-min) (point-max)))
    (remove-hook 'auto-save-hook #'numbex-refresh t)
    (remove-hook 'before-save-hook #'numbex-refresh t)))

(provide 'numbex)

;;; _
;; Local Variables:
;; indent-tabs-mode: nil
;; End:

;;; numbex.el ends here
