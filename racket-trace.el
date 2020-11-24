;;; racket-trace.el -*- lexical-binding: t; -*-

;; Copyright (c) 2013-2020 by Greg Hendershott.
;; Portions Copyright (C) 1985-1986, 1999-2013 Free Software Foundation, Inc.

;; Author: Greg Hendershott
;; URL: https://github.com/greghendershott/racket-mode

;; License:
;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version. This is distributed in the hope that it will be
;; useful, but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose. See the GNU
;; General Public License for more details. See
;; http://www.gnu.org/licenses/ for details.

(require 'semantic/symref/grep)
(require 'xref)
(require 'pulse)
(require 'racket-util)

(defvar racket-trace-mode-map
  (racket--easy-keymap-define
   '((("." "RET") xref-find-definitions)
     ("n"         racket-trace-next)
     ("p"         racket-trace-previous)
     ("u"         racket-trace-up-level))))

(define-derived-mode racket-trace-mode special-mode "Racket-Trace"
  "Major mode for trace output.
\\<racket-trace-mode-map>

Shows items logged to the racket-mode-trace topic, for example by
the \"vestige\" package, which is like racket/trace but supports
source location information.

\\{racket-trace-mode-map}"
  (setq-local buffer-undo-list t) ;disable undo
  (setq-local window-point-insertion-type t)
  (add-hook 'before-change-functions #'racket-trace-before-change-function)
  (add-hook 'kill-buffer-hook #'racket-trace-delete-all-overlays nil t)
  (setq-local revert-buffer-function #'racket-trace-revert-buffer-function)
  ;; xref
  (add-hook 'xref-backend-functions
            #'racket-trace-xref-backend-function
            nil t)
  (add-to-list 'semantic-symref-filepattern-alist
               '(racket-trace-mode "*.rkt" "*.rktd" "*.rktl")))

(defun racket-trace-revert-buffer-function (_ignore-auto noconfirm)
  (when (or noconfirm
            (y-or-n-p "Clear buffer?"))
    (with-silent-modifications
      (erase-buffer))
    (racket-trace-delete-all-overlays)))

(defconst racket--trace-buffer-name "*Racket Trace*")

(defun racket--trace-get-buffer-create ()
  "Create buffer if necessary."
  (unless (get-buffer racket--trace-buffer-name)
    (with-current-buffer (get-buffer-create racket--trace-buffer-name)
      (racket-trace-mode)))
  (get-buffer racket--trace-buffer-name))

(defun racket--trace-on-notify (data)
  (with-current-buffer (racket--trace-get-buffer-create)
    (let* ((inhibit-read-only  t)
           (original-point     (point))
           (point-was-at-end-p (equal original-point (point-max))))
      (goto-char (point-max))
      (pcase data
        (`(,callp ,show ,name ,level ,def ,sig ,call ,ctx)
         (racket--trace-insert callp
                               (if callp show (concat " ⇒ " show))
                               level
                               (cons name (racket--trace-srcloc-line+col def))
                               (cons show (racket--trace-srcloc-beg+end sig))
                               (cons show (racket--trace-srcloc-beg+end call))
                               (cons show (racket--trace-srcloc-beg+end ctx)))))
      (unless point-was-at-end-p
        (goto-char original-point)))))

(defun racket--trace-srcloc-line+col (v)
  "Extract the line and col from a srcloc."
  (pcase v
    (`(,path ,line ,col ,_pos ,_span)
     `(,path ,line ,col))))

(defun racket--trace-srcloc-beg+end (v)
  "Extract the pos and span from a srcloc and convert to beg and end."
  (pcase v
    (`(,path ,_line ,_col ,pos ,span)
     `(,path ,pos ,(+ pos span)))))

(defun racket--trace-insert (callp str level xref signature caller context)
  (cl-loop for n to (1- level)
           do
           (insert
            (propertize "  "
                        'face `(:inherit default :background ,(racket--trace-level-color n))
                        'racket-trace-callp callp
                        'racket-trace-level level
                        'racket-trace-xref xref
                        'racket-trace-signature signature
                        'racket-trace-caller caller
                        'racket-trace-context context))
           finally
           (insert
            (propertize (concat str "\n")
                        'face `(:inherit default :background ,(racket--trace-level-color level))
                        'racket-trace-callp callp
                        'racket-trace-level level
                        'racket-trace-xref xref
                        'racket-trace-signature signature
                        'racket-trace-caller caller
                        'racket-trace-context context))))

(defun racket--trace-level-color (level)
  ;; TODO: Make an array of deffaces for customization
  (let ((colors ["cornsilk1" "cornsilk2" "LightYellow1" "LightYellow2" "LemonChiffon1" "LemonChiffon2"]))
    (aref colors (mod level (length colors)))))

;;; xref

(defun racket-trace-xref-backend-function ()
  'racket-trace-xref)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql racket-trace-xref)))
  (pcase (get-text-property (point) 'racket-trace-xref)
    ((and v `(,name . ,_)) (propertize name 'racket-trace-xref v))))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql racket-trace-xref)))
  nil)

(cl-defmethod xref-backend-definitions ((_backend (eql racket-trace-xref)) str)
  (pcase (get-text-property 0 'racket-trace-xref str)
    (`(,_name ,path ,line ,col)
     (list (xref-make str (xref-make-file-location path line col))))))

;;; Commands

(defun racket-trace ()
  "Create the `racket-trace-mode' buffer and select it in a window."
  (interactive)
  (select-window
   (display-buffer (racket--trace-get-buffer-create)
                   '((display-buffer-reuse-window
                      display-buffer-below-selected
                      display-buffer-use-some-window)
                     (inhibit-same-window . t)))))

(defun racket-trace-next ()
  "Move to next line and show caller and definition sites."
  (interactive)
  (forward-line 1)
  (racket--trace-back-to-sexp)
  (racket--trace-show-sites))

(defun racket-trace-previous ()
  "Move to previous line and show caller and definition sites."
  (interactive)
  (forward-line -1)
  (racket--trace-back-to-sexp)
  (racket--trace-show-sites))

(defun racket-trace-up-level ()
  "Move up one level and show caller and definition sites."
  (interactive)
  (when (racket--trace-up-level)
    (racket--trace-back-to-sexp)
    (racket--trace-show-sites)))

(defun racket--trace-up-level ()
  "Try to move up one level, returning boolean whether moved."
  (let ((orig (point)))
    (pcase (get-text-property (point) 'racket-trace-level)
      ((and (pred numberp) this-level)
       (let ((desired-level (1- this-level)))
         (cl-loop until (or (not (zerop (forward-line -1)))
                            (equal (get-text-property (point) 'racket-trace-level)
                                   desired-level)))
         (if (equal (get-text-property (point) 'racket-trace-level)
                    desired-level)
             t
           (goto-char orig)
           nil))))))

(defun racket--trace-back-to-sexp ()
  "Move to the start of information for a line, based on its indent."
  (back-to-indentation)
  (forward-sexp)
  (backward-sexp))

;;; Showing call values in situ

(defvar racket--trace-overlays nil
  "List of overlays we've added in various buffers.")

(defun racket-trace-delete-all-overlays ()
  (dolist (o racket--trace-overlays)
    (delete-overlay o))
  (setq racket--trace-overlays nil))

(defun racket-trace-before-change-function (_beg _end)
  "When a buffer is modified, hide all overlays we have in it.
We don't actually delete them, just move them \"nowhere\"."
  (dolist (o racket--trace-overlays)
    (when (equal (overlay-buffer o) (current-buffer))
      (with-temp-buffer (move-overlay o 1 1)))))

(defun racket--trace-show-sites ()
  "Show caller and definition sites for all parent levels and current level."
  (racket-trace-delete-all-overlays)
  ;; Show sites for parent levels, in reverse order
  (let ((here    (point))
        (parents (cl-loop until (not (racket--trace-up-level))
                          collect (point))))
    (cl-loop for pt in (nreverse parents)
             do
             (goto-char pt)
             (racket--trace-show-sites-at-point nil))
    ;; Show sites for current level, last.
    (goto-char here)
    (racket--trace-show-sites-at-point t)))

(defun racket--trace-show-sites-at-point (display-buffer-for-caller-site-p)
  (let ((level (get-text-property (point) 'racket-trace-level))
        (callp (get-text-property (point) 'racket-trace-callp)))
    ;; Caller: Always create buffer if necessary. Maybe display-buffer
    ;; and move window point.
    (pcase (get-text-property (point) 'racket-trace-caller)
      (`(,show ,file ,beg ,end)
       (with-current-buffer (or (get-file-buffer file)
                                (let ((find-file-suppress-same-file-warnings t))
                                  (find-file-noselect file)))
         (when display-buffer-for-caller-site-p
           (let ((win (display-buffer (current-buffer)
                                      '((display-buffer-reuse-window
                                         display-buffer-below-selected
                                         display-buffer-use-some-window)
                                        (inhibit-same-window . t)))))
             (save-selected-window
               (select-window win)
               (goto-char beg))))
         ;; For nested trace-expressions, we might need to make an
         ;; overlay "on top of" an existing one, but that doesn't
         ;; work, so hide any existing trace overlay(s) here. (We
         ;; don't try to delete the overlay and remove it from
         ;; `racket--trace-overlays' here; just move it "nowhere".)
         (dolist (o (overlays-in beg end))
           (when (eq (overlay-get o 'name) 'racket-trace-overlay)
             (with-temp-buffer (move-overlay o 1 1))))
         (let ((o (make-overlay beg end))
               (face `(:inherit default :background ,(racket--trace-level-color level))))
           (push o racket--trace-overlays)
           (overlay-put o 'priority (+ 100 level))
           (overlay-put o 'name 'racket-trace-overlay)
           (overlay-put o 'display (if callp show t))
           (unless callp
             (overlay-put o 'after-string (propertize (concat " ⇒ " show)
                                                      'face face)))
           (overlay-put o 'face face)))))
    ;; Signature at definition site. Only show overlay for calls (not
    ;; results), i.e. "in" the function. If there is not already a
    ;; buffer, don't create one. If the buffer is not already shown in
    ;; a window, don't show it. If already overlay here with exact
    ;; same beg/end, it's probably from "caller", above, for some
    ;; syntactic form where the caller and signature are identical;
    ;; don't create another overlay next to it.
    (pcase (get-text-property (point) 'racket-trace-signature)
      (`(,show ,file ,beg ,end)
       (let ((buf (get-file-buffer file)))
         (when (and callp
                    buf
                    (cl-notany (lambda (o)
                                 (and (eq (overlay-get o 'name) 'racket-trace-overlay)
                                      (eq (overlay-start o) beg)
                                      (eq (overlay-end o) end)))
                               (with-current-buffer buf (overlays-in beg end))))
           (with-current-buffer buf
             (let ((o (make-overlay beg end))
                   (face `(:inherit default :background ,(racket--trace-level-color level))))
               (push o racket--trace-overlays)
               (overlay-put o 'name 'racket-trace-overlay)
               (overlay-put o 'priority 100)
               (overlay-put o 'display show)
               (overlay-put o 'face face)))))))))

(provide 'racket-trace)

;;; racket-trace.el ends here
