(in-package :cl-user)
(defpackage fast-http.stateless-parser
  (:use :cl
        :fast-http.error)
  (:import-from :fast-http.byte-vector
                :+space+
                :+tab+
                :+cr+
                :+lf+
                :simple-byte-vector
                :alpha-byte-char-p
                :digit-byte-char-p
                :digit-byte-char-to-integer)
  (:import-from :fast-http.util
                :casev=
                :case-byte)
  (:import-from :alexandria
                :with-gensyms
                :hash-table-alist
                :define-constant)
  (:export :make-parser
           :parser-method
           :parser-http-major
           :parser-http-minor
           :parser-content-length
           :parser-chunked-p
           :parser-upgrade-p
           :parse-request))
(in-package :fast-http.stateless-parser)

;;
;; Macro utilities

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *insane-declaration* '(declare (optimize (speed 3) (safety 2) (debug 2) (space 0) (compilation-speed 0))))
  (defvar *speedy-declaration* '(declare (optimize (speed 3) (safety 2) (space 2) (compilation-speed 0))))
  (defvar *careful-declaration* '(declare (optimize (speed 3) (safety 2)))))

(defmacro defun-insane (name lambda-list &body body)
  `(progn
     (declaim (inline ,name))
     (defun ,name ,lambda-list
       ,*insane-declaration*
       ,@body)))

(defmacro defun-speedy (name lambda-list &body body)
  `(progn
     (declaim (notinline ,name))
     (defun ,name ,lambda-list
       ,*speedy-declaration*
       ,@body)))

(defmacro defun-careful (name lambda-list &body body)
  `(progn
     (declaim (notinline ,name))
     (defun ,name ,lambda-list
       ,*careful-declaration*
       ,@body)))


;;
;; Types

(deftype pointer () 'integer)


;; Parser declaration

(defstruct parser
  (method nil :type symbol)
  (http-major 0 :type fixnum)
  (http-minor 0 :type fixnum)
  (content-length nil :type (or null integer))
  (chunked-p nil :type boolean)
  (upgrade-p nil :type boolean))


;;
;; Parser utilities

(define-condition eof () ())

(defmacro check-eof ()
  `(when (= p end)
     (error 'eof)))

(defmacro advance (&optional (degree 1))
  `(progn
     (incf p ,degree)
     (check-eof)
     (setq byte (aref data p))))

(defmacro advance-to (to)
  `(progn
     (setq p ,to)
     (check-eof)
     (setq byte (aref data p))))

(defmacro skip-while (form)
  `(loop do (advance)
         while (progn ,form)))

(defmacro skip-until (form)
  `(loop until (progn ,form)
         do (advance)))

(defmacro skip-until-crlf ()
  `(loop if (= byte +cr+)
           do (progn (expect-byte +lf+)
                     (return))
         else
           do (advance)))

(defmacro expect (form &optional (advance T))
  `(progn
     ,@(and advance `((advance)))
     (assert ,form)))

(defmacro expect-byte (byte &optional (advance T))
  "Advance the pointer and check if the next byte is BYTE."
  `(expect (= byte ,byte) ,advance))

(defmacro expect-char (char &optional (advance T))
  `(expect-byte ,(char-code char) ,advance))

(defmacro expect-string (string &optional (advance T))
  (if advance
      `(progn
         ,@(loop for char across string
                 collect `(expect-char ,char)))
      (when (/= 0 (length string))
        `(progn
           (expect-char ,(aref string 0) nil)
           (expect-string ,(subseq string 1))))))

(defmacro expect-crlf ()
  `(casev= byte
     (+cr+ (expect-byte +lf+))
     (otherwise (assert (= byte +cr+)))))

(defmacro expect-one-of (strings &optional (errorp T) (case-sensitive T))
  (let ((expect-block (gensym "EXPECT-BLOCK")))
    (labels ((grouping (i strings)
               (let ((map (make-hash-table)))
                 (loop for string in strings
                       when (< 0 (- (length (string string)) i))
                         do (push string
                                  (gethash (aref (string string) i) map)))
                 (alexandria:hash-table-alist map)))
             (build-case-byte (i strings)
               (let ((alist (grouping i strings)))
                 `(case-byte byte
                    ,@(loop for (char . candidates) in alist
                            if (cdr candidates)
                              collect `(,(if case-sensitive
                                             char
                                             (if (lower-case-p char)
                                                 `(,char ,(code-char (- (char-code char) 32)))
                                                 `(,char ,(code-char (+ (char-code char) 32)))))
                                        (advance) ,(build-case-byte (1+ i) candidates))
                            else
                              collect `(,(if case-sensitive
                                             char
                                             (if (lower-case-p char)
                                                 `(,char ,(code-char (- (char-code char) 32)))
                                                 `(,char ,(code-char (+ (char-code char) 32)))))
                                        (expect-string ,(subseq (string (car candidates)) (1+ i)))
                                        (return-from ,expect-block ,(car candidates))))
                    (otherwise ,(if errorp
                                    `(error ,(format nil "Expected one of ~S" strings))
                                    `(return-from ,expect-block nil)))))))
      `(block ,expect-block
         ,(build-case-byte 0 strings)))))

(defmacro case-expect-token (strings &body clauses)
  (with-gensyms (expect-block)
    (labels ((grouping (i strings)
               (let ((map (make-hash-table)))
                 (loop for string in strings
                       when (< 0 (- (length (string string)) i))
                         do (push string
                                  (gethash (aref (string string) i) map)))
                 (alexandria:hash-table-alist map)))
             (build-case (i strings)
               (let ((alist (grouping i strings)))
                 (if alist
                     `(case (the character (svref +tokens+ byte))
                        (#\Nul (error 'invalid-header-token))
                        ,@(loop for (char . candidates) in alist
                                collect `(,char (advance) ,(build-case (1+ i) candidates)))
                        (otherwise (return-from ,expect-block
                                     (progn ,@(cdr (assoc 'otherwise clauses))))))
                     `(return-from ,expect-block
                        (if (= byte (char-code #\:))
                            (progn ,@(cdr (assoc (intern (car strings) :keyword) clauses)))
                            (progn ,@(cdr (assoc 'otherwise clauses)))))))))
      `(block ,expect-block
         ,(build-case 0 strings)))))


;;
;; Tokens

(declaim (type (simple-array character (128)) +tokens+))
(define-constant +tokens+
    #( #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul
       #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul
       #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul
       #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul
       #\Nul   #\!   #\Nul   #\#    #\$    #\%    #\&    #\'
       #\Nul  #\Nul   #\*    #\+   #\Nul    #\-   #\.   #\Nul
        #\0    #\1    #\2    #\3    #\4    #\5    #\6    #\7
        #\8    #\9   #\Nul  #\Nul  #\Nul  #\Nul  #\Nul  #\Nul
       #\Nul   #\a    #\b    #\c    #\d    #\e    #\f    #\g
        #\h    #\i    #\j    #\k    #\l    #\m    #\n    #\o
        #\p    #\q    #\r    #\s    #\t    #\u    #\v    #\w
        #\x    #\y    #\z   #\Nul  #\Nul  #\Nul   #\^    #\_
        #\`    #\a    #\b    #\c    #\d    #\e    #\f    #\g
        #\h    #\i    #\j    #\k    #\l    #\m    #\n    #\o
        #\p    #\q    #\r    #\s    #\t    #\u    #\v    #\w
        #\x    #\y    #\z   #\Nul   #\|   #\Nul   #\~   #\Nul )
  :test 'equalp)


;;
;; Main

(defun-insane parse-method (data start end)
  (declare (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p)))
    (declare (type (unsigned-byte 8) byte)
             (type pointer p))
    (values (expect-one-of
             (:CONNECT
              :DELETE
              :GET
              :HEAD
              :LOCK
              :MKCOL
              :MKCALENDAR
              :MKACTIVITY
              :MOVE
              :MERGE
              :M-SEARCH
              :NOTIFY
              :OPTIONS
              :POST
              :PROPFIND
              :PROPPATCH
              :PUT
              :PURGE
              :PATCH
              :REPORT
              :SEARCH
              :SUBSCRIBE
              :TRACE
              :UNLOCK
              :UNSUBSCRIBE))
            p)))

(defun-insane parse-url (data start end)
  (declare (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p)))
    (declare (type (unsigned-byte 8) byte)
             (type pointer p))
    (skip-while (or (<= (char-code #\!) byte (char-code #\~))
                    (<= 128 byte)))
    ;; callback :url start p
    p))

(defun-insane parse-http-version (data start end)
  (declare (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p))
         major minor)
    (declare (type (unsigned-byte 8) byte)
             (type pointer p end))
    (expect-string "HTTP/" nil)
    ;; Expect the HTTP major is only once digit.
    (expect (digit-byte-char-p byte))
    (setq major (digit-byte-char-to-integer byte))
    (expect-byte (char-code #\.))
    ;; Expect the HTTP minor is only once digit.
    (expect (digit-byte-char-p byte))
    (setq minor (digit-byte-char-to-integer byte))

    (values major minor p)))

(defmacro parse-header-field ()
  `(macrolet ((skip-until-field-end ()
                `(do ((char (svref +tokens+ byte)
                            (svref +tokens+ byte)))
                     ((= byte (char-code #\:)))
                   (declare (type character char))
                   (when (char= char #\Nul)
                     (error 'invalid-header-token))
                   (advance))))
     ;; callback :header-field start p
     (case-expect-token ("content-length" "transfer-encoding" "upgrade")
       (:|content-length|
         (multiple-value-bind (next content-length)
             (parse-header-value-content-length data p end)
           (declare (type pointer next))
           (setf (parser-content-length parser) content-length)
           (advance-to next)))
       (:|transfer-encoding|
         (multiple-value-bind (next chunkedp)
             (parse-header-value-transfer-encoding data p end)
           (declare (type pointer next))
           (setf (parser-chunked-p parser) chunkedp)
           (advance-to next)))
       (:|upgrade|
         (setf (parser-upgrade-p parser) T)
         (skip-until-crlf)
         ;; callback :header-value next next2
         (advance))
       (otherwise (skip-until-field-end)
                  (parse-header-value)))))

(defmacro parse-header-value ()
  `(progn
     (skip-while (or (= byte +space+)
                     (= byte +tab+)))
     (skip-until-crlf)
     ;; callback :header-value start (1+ p)
     (advance)))

(defun-speedy parse-header-value-transfer-encoding (data start end)
  (declare (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p)))
    (declare (type (unsigned-byte 8) byte)
             (type pointer p))
    (skip-while (or (= byte +space+)
                    (= byte +tab+)))
    (setq start p)
    (if (expect-one-of ("chunked") nil nil)
        (casev= byte
          (+cr+ (expect-byte +lf+)
                ;; callback :header-value start next
                (values T (1+ p)))
          (otherwise
           (skip-until-crlf)
           (advance)
           ;; callback :header-value start next
           (values nil (1+ p))))
        (progn
          (skip-until-crlf)
          (advance)
          ;; callback :header-value start next
          (values nil (1+ p))))))

(defun-speedy parse-header-value-content-length (data start end)
  (declare (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p))
         (content-length 0))
    (declare (type pointer p)
             (type (unsigned-byte 8) byte)
             (type integer content-length))
    (unless (digit-byte-char-p byte)
      (error 'invalid-content-length))
    (setq content-length (digit-byte-char-to-integer byte))
    (loop
      (advance)
      (when (= byte +cr+)
        (expect-byte +lf+)
        ;; callback :header-value start next
        (return (values (1+ p) content-length)))
      (unless (digit-byte-char-to-integer byte)
        (error 'invalid-content-length))
      (setq content-length
            (+ (* 10 content-length)
               (digit-byte-char-to-integer byte))))))

(defmacro case-header-line-start (&body clauses)
  `(casev= byte
     ((+tab+ +space+)
      (skip-while (or (= byte +tab+) (= byte +space+)))
      ,@(cdr (assoc :value clauses)))
     (+cr+ (expect-byte +lf+)
           (incf p)
           ,@(cdr (assoc :last clauses)))
     (otherwise ,@(cdr (assoc :field clauses)))))

(defmacro parse-header-line ()
  `(case-header-line-start
    (:field (parse-header-field))
    ;; folding value
    (:value (parse-header-value))
    (:last (return))))

;; TODO: check max header length
(defun-speedy parse-headers (parser data start end)
  (declare (type parser parser)
           (type simple-byte-vector data)
           (type pointer start end))
  (let* ((p start)
         (byte (aref data p)))
    (declare (type pointer p)
             (type (unsigned-byte 8) byte))
    ;; empty headers
    (when (= byte +cr+)
      (expect-byte +lf+)
      (return-from parse-headers (1+ p)))
    (parse-header-field)
    ;; skip #\:
    (advance)
    (parse-header-value)
    (advance)
    (loop (parse-header-line))
    p))

(defun-speedy parse-request (parser data &key (start 0) end)
  (declare (type parser parser)
           (type simple-byte-vector data))
  (let* ((p start)
         (byte (aref data p))
         (end (or end (length data))))
    (declare (type (unsigned-byte 8) byte)
             (type pointer p end))

    (check-eof)

    ;; skip first empty line (some clients add CRLF after POST content)
    (when (= byte +cr+)
      (expect-byte +lf+)
      (advance))

    (multiple-value-bind (method next)
        (parse-method data p end)
      (declare (type pointer next))
      (setf (parser-method parser) method)
      (advance-to next))
    (skip-while (= byte +space+))
    (let ((next (parse-url data p end)))
      (declare (type pointer next))
      (advance-to next))
    (skip-while (= byte +space+))
    (multiple-value-bind (major minor next)
        (parse-http-version data p end)
      (declare (type pointer next))
      (setf (parser-http-major parser) major
            (parser-http-minor parser) minor)
      (advance-to next))

    (advance)
    (expect-crlf)
    (advance)

    (parse-headers parser data p end)))
