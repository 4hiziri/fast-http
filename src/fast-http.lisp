(in-package :cl-user)
(defpackage fast-http
  (:use :cl
        :fast-http.http
        :fast-http.parser
        :fast-http.unparser
        :fast-http.multipart-parser
        :fast-http.byte-vector
        :fast-http.error
        :xsubseq
        :partial-bench)
  (:import-from :fast-http.multipart-parser
                :+body-done+)
  (:import-from :fast-http.util
                :make-collector
                :number-string-p)
  (:import-from :babel
                :octets-to-string)
  (:import-from :cl-utilities
                :with-collectors)
  (:import-from :alexandria
                :named-lambda)
  (:export :make-parser
           :http
           :http-request
           :http-response
           :make-http-request
           :make-http-response
           :http-p
           :http-request-p
           :http-response-p
           :http-version
           :http-headers
           :http-store-body
           :http-force-stream
           :http-body
           :http-method
           :http-resource
           :http-status
           :http-status-text

           :make-multipart-parser

           :*request-body-limit*

           ;; Low-level parser API
           :http-parse
           :ll-parser
           :ll-callbacks
           :make-ll-parser
           :make-ll-callbacks
           :parser-method
           :parser-status-code
           :parser-http-major
           :parser-http-minor

           :http-multipart-parse
           :ll-multipart-parser
           :make-ll-multipart-parser

           ;; unparser
           :http-unparse

           ;; Error
           :fast-http-error

           :body-buffer-exceeded

           :callback-error
           :cb-message-begin
           :cb-url
           :cb-first-line
           :cb-header-field
           :cb-header-value
           :cb-headers-complete
           :cb-body
           :cb-message-complete
           :cb-status

           :parsing-error
           :invalid-eof-state
           :header-overflow
           :closed-connection
           :invalid-version
           :invalid-status
           :invalid-method
           :invalid-url
           :invalid-host
           :invalid-port
           :invalid-path
           :invalid-query-string
           :invalid-fragment
           :lf-expected
           :invalid-header-token
           :invalid-content-length
           :invalid-chunk-size
           :invalid-constant
           :invalid-internal-state
           :strict-error
           :paused-error
           :unknown-error

           :multipart-parsing-error
           :invalid-multipart-body
           :invalid-boundary

           :header-value-parsing-error
           :invalid-header-value
           :invalid-parameter-key
           :invalid-parameter-value))
(in-package :fast-http)

(defvar *request-body-limit* nil
  "The limit length of HTTP request body. If this is NIL (default), there's no limitation.
If the request is chunked or :force-stream option of the HTTP object, the limit is only applied for each callback.")

(defun make-parser (http &key first-line-callback header-callback body-callback finish-callback multipart-callback store-body)
  "Returns a lambda function that takes a simple-byte-vector and parses it as an HTTP request/response."
  (declare (optimize (speed 3) (safety 2)))
  (let* ((headers (make-hash-table :test 'equal))

         (header-value-buffer nil)
         (header-complete-p nil)
         (completedp nil)

         (parsing-header-field "")
         (chunked nil)
         (content-length nil)
         (content-type nil)
         (body-bytes (make-concatenated-xsubseqs)) ;; for chunking

         (responsep (http-response-p http))
         (parser (make-ll-parser :type (if responsep :response :request)))
         (multipart-parser nil)
         callbacks)
    (declare (type simple-string parsing-header-field))
    (flet ((collect-prev-header-value ()
             (declare (optimize (speed 3) (safety 2)))
             (when header-value-buffer
               ;; Collect the previous header-value
               (let ((header-value
                       (locally (declare (optimize (speed 3) (safety 0)))
                         (coerce-to-string
                          (the (or octets-concatenated-xsubseqs
                                   octets-xsubseq)
                               header-value-buffer)))))
                 (declare (type simple-string header-value))
                 (multiple-value-bind (previous-value existp)
                     (gethash (the simple-string parsing-header-field) headers)
                   (setf (gethash (the simple-string parsing-header-field) headers)
                         (if existp
                             (format nil "~A, ~A" previous-value header-value)
                             (if (number-string-p header-value)
                                 (read-from-string header-value)
                                 header-value))))))))
      (setq callbacks
            (make-ll-callbacks
             :status (and responsep
                          (named-lambda status-cb (parser data start end)
                            (declare (type simple-byte-vector data))
                            (setf (http-status http)
                                  (parser-status-code parser))
                            (setf (http-status-text http)
                                  (babel:octets-to-string data :start start :end end))))
             :header-field (named-lambda header-field-cb (parser data start end)
                             (declare (ignore parser)
                                      (type simple-byte-vector data))
                             (collect-prev-header-value)
                             (setq header-value-buffer (make-concatenated-xsubseqs))
                             (setq parsing-header-field
                                   (ascii-octets-to-lower-string data :start start :end end)))
             :header-value (named-lambda header-value-cb (parser data start end)
                             (declare (ignore parser)
                                      (type simple-byte-vector data))
                             (xnconcf header-value-buffer
                                      (xsubseq (the simple-byte-vector data) start end)))
             :headers-complete (named-lambda headers-complete-cb-with-callback (parser)
                                 (declare (ignore parser))
                                 (collect-prev-header-value)
                                 (setq header-complete-p t)
                                 (setq chunked
                                       (equal (gethash "transfer-encoding" headers)
                                              "chunked")
                                       content-length (gethash "content-length" headers)
                                       content-type (gethash "content-type" headers))
                                 (setq header-value-buffer nil)
                                 (setf (http-headers http) headers)
                                 (when header-callback
                                   (funcall (the function header-callback) headers))
                                 (when (and multipart-callback
                                            (stringp content-type))
                                   (setq multipart-parser
                                         (make-multipart-parser content-type multipart-callback))))
             :first-line (named-lambda first-line-cb (parser)
                           (unless responsep
                             (setf (http-method http) (parser-method parser)))
                           (setf (http-version http) (+ (parser-http-major parser)
                                                        (/ (parser-http-minor parser) 10)))
                           (when first-line-callback
                             (funcall (the function first-line-callback))))
             :url (named-lambda url-cb (parser data start end)
                    (declare (ignore parser)
                             (type simple-byte-vector data))
                    (setf (http-resource http)
                          (babel:octets-to-string data :start start :end end)))
             :body (and (or body-callback multipart-callback store-body)
                        (named-lambda body-cb (parser data start end)
                          (declare (ignore parser)
                                   (type simple-byte-vector data))
                          (xnconcf body-bytes (xsubseq (the simple-byte-vector data) start end))
                          (when (and *request-body-limit*
                                     (< *request-body-limit* (xlength body-bytes)))
                            (error 'body-buffer-exceeded :limit *request-body-limit*))))
             :message-complete (named-lambda message-complete-cb (parser)
                                 (declare (ignore parser))
                                 (collect-prev-header-value)
                                 (when (and (http-store-body http)
                                            (null (http-body http)))
                                   (setf (http-body http)
                                         (coerce-to-sequence body-bytes)))
                                 (setq completedp t)))))
    (setf (http-store-body http) store-body)
    (return-from make-parser
      (named-lambda http-parser-execute (data &key (start 0) end)
        (cond
          ((eql data :eof)
           (when finish-callback
             (funcall (the function finish-callback))))
          (T (http-parse parser callbacks (the simple-byte-vector data) :start start :end end)
             (when (and (or body-callback
                            multipart-parser
                            (http-store-body http))
                        header-complete-p)
               ;; body-callback
               (cond
                 (chunked
                  (let ((body (coerce-to-sequence body-bytes)))
                    (when (or body-callback multipart-parser)
                      (let ((chunk-data body))
                        (when body-callback
                          (funcall (the function body-callback) chunk-data))
                        (when multipart-parser
                          (funcall (the function multipart-parser) chunk-data))))
                    (when (http-store-body http)
                      (setf (http-body http)
                            (if (http-body http)
                                (append-byte-vectors (http-body http) body)
                                body))))
                  (setq body-bytes (make-concatenated-xsubseqs)))
                 ((numberp content-length)
                  (if (http-force-stream http)
                      (when (or body-callback multipart-parser)
                        (let ((body (coerce-to-sequence body-bytes)))
                          (when body-callback
                            (funcall (the function body-callback) body))
                          (when multipart-parser
                            (funcall (the function multipart-parser) body))
                          (setq body-bytes (make-concatenated-xsubseqs))))
                      (if (<= content-length (xlength body-bytes))
                          (let ((body (coerce-to-sequence body-bytes)))
                            (when (http-store-body http)
                              (setf (http-body http) body))
                            (when body-callback
                              (funcall (the function body-callback) body))
                            (when multipart-parser
                              (funcall (the function multipart-parser) body)))
                          (return-from http-parser-execute nil))))
                 (T
                  ;; No Content-Length, no chunking, probably a request with no body
                  (setq completedp t))))
             (when (and completedp finish-callback)
               (funcall (the function finish-callback)))))
        (values http header-complete-p completedp)))))

(defun find-boundary (content-type)
  (declare (type string content-type))
  (let ((parsing-boundary nil))
    (parse-header-value-parameters content-type
                                   :header-value-callback
                                   (lambda (data start end)
                                     (unless (string= data "multipart/form-data"
                                                      :start1 start :end1 end)
                                       (return-from find-boundary nil)))
                                   :header-parameter-key-callback
                                   (lambda (data start end)
                                     (when (string= data "boundary"
                                                    :start1 start :end1 end)
                                       (setq parsing-boundary t)))
                                   :header-parameter-value-callback
                                   (lambda (data start end)
                                     (when parsing-boundary
                                       (return-from find-boundary (subseq data start end)))))))

(defun make-multipart-parser (content-type callback)
  (check-type content-type string)
  (let ((boundary (find-boundary content-type)))
    (unless boundary
      (return-from make-multipart-parser nil))

    (let ((parser (make-ll-multipart-parser :boundary boundary))
          (headers (make-hash-table :test 'equal))
          parsing-content-disposition
          parsing-header-field
          field-meta
          header-value-buffer
          callbacks)
      (flet ((collect-prev-header-value ()
               (when header-value-buffer
                 (let ((header-value
                         (coerce-to-string header-value-buffer)))
                   (when parsing-content-disposition
                     (setq field-meta
                           (let (parsing-key
                                 (field-meta (make-hash-table :test 'equal)))
                             (parse-header-value-parameters header-value
                                                            :header-parameter-key-callback
                                                            (lambda (data start end)
                                                              (setq parsing-key
                                                                    (string-downcase (subseq data start end))))
                                                            :header-parameter-value-callback
                                                            (lambda (data start end)
                                                              (setf (gethash parsing-key field-meta)
                                                                    (subseq data start end))))
                             field-meta)))
                   (setf (gethash parsing-header-field headers)
                         header-value)))))
        (setq callbacks
              (make-ll-callbacks
               :header-field (lambda (parser data start end)
                               (declare (ignore parser))
                               (collect-prev-header-value)
                               (setq header-value-buffer (make-concatenated-xsubseqs))

                               (let ((header-name
                                       (ascii-octets-to-lower-string data :start start :end end)))
                                 (setq parsing-content-disposition
                                       (string= header-name "content-disposition"))
                                 (setq parsing-header-field header-name)))
               :header-value (lambda (parser data start end)
                               (declare (ignore parser))
                               (xnconcf header-value-buffer
                                        (xsubseq data start end)))
               :body (lambda (parser data start end)
                       (declare (ignore parser))
                       (collect-prev-header-value)
                       (funcall callback
                                (gethash "name" field-meta)
                                headers
                                field-meta
                                (subseq data start end))
                       (setq headers (make-hash-table :test 'equal)
                             header-value-buffer nil)))))
      (lambda (data)
        (http-multipart-parse parser callbacks data)
        (= (ll-multipart-parser-state parser) +body-done+)))))
