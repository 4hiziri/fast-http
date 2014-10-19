(in-package :cl-user)
(defpackage fast-http.multipart-parser
  (:use :cl
        :fast-http.parser
        :fast-http.byte-vector
        :fast-http.variables
        :fast-http.error)
  (:import-from :fast-http.parser
                :ll-callbacks-body
                :ll-callbacks-headers-complete
                :parser-state)
  (:import-from :fast-http.util
                :check-strictly
                :tagcasev
                :casev)
  (:import-from :babel
                :string-to-octets)
  (:import-from :alexandria
                :when-let)
  (:export :ll-multipart-parser
           :ll-multipart-parser-state
           :make-ll-multipart-parser
           :http-multipart-parse))
(in-package :fast-http.multipart-parser)

(defstruct (ll-multipart-parser (:constructor make-ll-multipart-parser
                                  (&key boundary
                                   &aux (header-parser
                                         (let ((parser (make-ll-parser :type :both)))
                                           (setf (parser-state parser) +state-header-field-start+)
                                           parser)))))
  (state 0 :type fixnum)
  (header-parser)
  boundary
  body-mark
  body-buffer
  boundary-mark)

#.`(eval-when (:compile-toplevel :load-toplevel :execute)
     ,@(loop for i from 0
             for state in '(parsing-delimiter-dash-start
                            parsing-delimiter-dash
                            parsing-delimiter
                            parsing-delimiter-end
                            parsing-delimiter-almost-done
                            parsing-delimiter-done
                            header-field-start
                            body-start
                            looking-for-delimiter
                            maybe-delimiter-start
                            maybe-delimiter-first-dash
                            maybe-delimiter-second-dash
                            body-almost-done
                            body-done)
             collect `(defconstant ,(intern (format nil "+~A+" state)) ,i)))

(defun http-multipart-parse (parser callbacks data &key (start 0) end)
  (declare (type simple-byte-vector data))
  (let* ((end (or end (length data)))
         (boundary (babel:string-to-octets (ll-multipart-parser-boundary parser)))
         (boundary-length (length boundary))
         (header-parser (ll-multipart-parser-header-parser parser)))
    (declare (type simple-byte-vector boundary))
    (when (= start end)
      (return-from http-multipart-parse start))

    (macrolet ((call-body-cb (&optional (end '(ll-multipart-parser-boundary-mark parser)))
                 (let ((g-end (gensym "END")))
                   `(handler-case
                        (when-let (callback (ll-callbacks-body callbacks))
                          (when (ll-multipart-parser-body-buffer parser)
                            (funcall callback parser
                                     (ll-multipart-parser-body-buffer parser)
                                     0 (length (ll-multipart-parser-body-buffer parser)))
                            (setf (ll-multipart-parser-body-buffer parser) nil))
                          (when-let (,g-end ,end)
                            (funcall callback parser data
                                     (ll-multipart-parser-body-mark parser)
                                     ,g-end)))
                      (error (e)
                        (error 'cb-body :error e))))))
      (let* ((p start)
             (byte (aref data p)))
        (log:debug (code-char byte))
        (tagbody
           (macrolet ((go-state (tag &optional (advance 1))
                          `(progn
                             ,(case advance
                                (0 ())
                                (1 '(incf p))
                                (otherwise `(incf p ,advance)))
                             (setf (ll-multipart-parser-state parser) ,tag)
                             ,@(and (not (eql advance 0))
                                    `((when (= p end)
                                        (go exit-loop))
                                      (setq byte (aref data p))
                                      (log:debug (code-char byte))
                                      (log:debug ,(princ-to-string tag))))
                             (go ,tag))))
             (tagcasev (ll-multipart-parser-state parser)
               (+parsing-delimiter-dash-start+
                (unless (= byte +dash+)
                  (go-state +header-field-start+ 0))
                (go-state +parsing-delimiter-dash+))

               (+parsing-delimiter-dash+
                (unless (= byte +dash+)
                  (error 'invalid-multipart-body))
                (go-state +parsing-delimiter+))

               (+parsing-delimiter+
                (unless (search boundary data :start2 p :end2 (+ p boundary-length))
                  ;; Still in the body
                  (when (ll-multipart-parser-body-mark parser)
                    (go-state +looking-for-delimiter+))
                  (error 'invalid-boundary))
                (go-state +parsing-delimiter-end+ boundary-length))

               (+parsing-delimiter-end+
                (casev byte
                  (+cr+ (go-state +parsing-delimiter-almost-done+))
                  (+lf+ (go-state +parsing-delimiter-almost-done+ 0))
                  (+dash+ (go-state +body-almost-done+))
                  (otherwise (error 'invalid-boundary))))

               (+parsing-delimiter-almost-done+
                (unless (= byte +lf+)
                  (error 'invalid-boundary))
                (when (and (ll-multipart-parser-body-mark parser)
                           (ll-multipart-parser-boundary-mark parser))
                  ;; got a part
                  (call-body-cb))
                (go-state +parsing-delimiter-done+))

               (+parsing-delimiter-done+
                (setf (ll-multipart-parser-body-mark parser) p)
                (go-state +header-field-start+ 0))

               (+header-field-start+
                (let ((next (http-parse-headers header-parser callbacks data :start p :end end)))
                  (setq p next)
                  ;; parsing headers done
                  (when (= (parser-state header-parser) +state-headers-almost-done+)
                    (when-let (callback (ll-callbacks-headers-complete callbacks))
                      (handler-case (funcall callback parser)
                        (error (e)
                          (error 'cb-headers-complete :error e))))
                    (setf (parser-state header-parser) +state-header-field-start+))
                  (go-state +body-start+ 0)))

               (+body-start+
                (setf (ll-multipart-parser-body-mark parser) (1+ p))
                (go-state +looking-for-delimiter+))

               (+looking-for-delimiter+
                (setf (ll-multipart-parser-boundary-mark parser) nil)
                (casev byte
                  (+cr+ (setf (ll-multipart-parser-boundary-mark parser) p)
                        (go-state +maybe-delimiter-start+))
                  ;; they might be just sending \n instead of \r\n so this would be
                  ;; the second \n to denote the end of line
                  (+lf+ (setf (ll-multipart-parser-boundary-mark parser) p)
                        (go-state +maybe-delimiter-start+ 0))
                  (otherwise (go-state +looking-for-delimiter+))))

               (+maybe-delimiter-start+
                (unless (= byte +lf+)
                  (go-state +looking-for-delimiter+ 0))
                (go-state +maybe-delimiter-first-dash+))

               (+maybe-delimiter-first-dash+
                (if (= byte +dash+)
                    (go-state +maybe-delimiter-second-dash+)
                    (go-state +looking-for-delimiter+)))

               (+maybe-delimiter-second-dash+
                (if (= byte +dash+)
                    (go-state +parsing-delimiter+)
                    (go-state +looking-for-delimiter+)))

               (+body-almost-done+
                (casev byte
                  (+dash+ (go-state +body-done+))
                  (otherwise (error 'invalid-multipart-body))))

               (+body-done+
                (when (ll-multipart-parser-body-mark parser)
                  ;; got a part
                  (call-body-cb)
                  (setf (ll-multipart-parser-body-mark parser) nil))
                (go exit-loop))))
         exit-loop)
        (when (ll-multipart-parser-body-mark parser)
          (call-body-cb (or (ll-multipart-parser-boundary-mark parser) p))
          ;; buffer the last part
          (when (ll-multipart-parser-boundary-mark parser)
            (setf (ll-multipart-parser-body-buffer parser)
                  (subseq data (ll-multipart-parser-boundary-mark parser))))

          (setf (ll-multipart-parser-body-mark parser) 0
                (ll-multipart-parser-boundary-mark parser) nil))
        p))))
