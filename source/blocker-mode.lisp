(uiop:define-package :next/blocker-mode
  (:use :common-lisp :trivia :next)
  (:documentation "Block resource queries blacklisted hosts."))
(in-package :next/blocker-mode)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (trivial-package-local-nicknames:add-package-local-nickname :alex :alexandria)
  (trivial-package-local-nicknames:add-package-local-nickname :sera :serapeum))

;; TODO: Add convenient interface to block hosts depending on the current URL.

(defclass-export hostlist ()
  ((url :accessor url :initarg :url
        :initform ""
        :type string
        :documentation "URL where to download the list from.  If empty, no attempt
will be made at updating it.")
   (path :initarg :path
         :initform nil
         :documentation "Where to find the list locally.
If nil, the list won't be persisted.
If path is relative, it will be set to (xdg-data-home path).")
   (hosts :accessor hosts :initarg :hosts
          :initform '()
          :documentation "The list of domain name.")
   (update-interval :accessor update-interval :initarg :update-interval
                    :initform (* 60 60 24)
                    :documentation "If URL is provided, update the list after
this amount of seconds.")))

(serapeum:export-always 'path)
(defmethod path ((hostlist hostlist))
  (with-slots (path) hostlist
    (if (uiop:absolute-pathname-p path)
        path
        (xdg-data-home path))))

(serapeum:export-always 'make-hostlist)
(defun make-hostlist (&rest args)
  (apply #'make-instance 'hostlist args))

(defmethod update ((hostlist hostlist))
  "Fetch HOSTLIST and return it.
If HOSTLIST has a `path', persist it locally."
  (unless (uiop:emptyp (url hostlist))
    (log:info "Updating hostlist ~a from ~a" (path hostlist) (url hostlist))
    (let ((hosts (dex:get (url hostlist))))
      (when (path hostlist)
        ;; TODO: In general, we should do more error checking when writing to disk.
        (alex:write-string-into-file hosts (path hostlist)
                                           :if-exists :overwrite
                                           :if-does-not-exist :create))
      hosts)))

(defvar update-lock (bt:make-lock))

(defmethod read-hostlist ((hostlist hostlist))
  "Return hostlist file as a string.
Return nil if hostlist file is not ready yet.
Auto-update file if older than UPDATE-INTERVAL seconds.

The hostlist is downloaded in the background.
The new hostlist will be used as soon as it is available."
  (when (or (not (uiop:file-exists-p (path hostlist)))
            (< (update-interval hostlist)
               (- (get-universal-time) (uiop:safe-file-write-date (path hostlist)))))
    (bt:make-thread
     (lambda ()
       (when (bt:acquire-lock update-lock nil)
         (update hostlist)
         (bt:release-lock update-lock)))))
  (handler-case
      (uiop:read-file-string (path hostlist))
    (error ()
      (log:warn "Hostlist not found: ~a" (path hostlist))
      nil)))

(defmethod parse ((hostlist hostlist))
  "Return the hostlist as a list of strings.
Return nil if hostlist cannot be parsed."
  ;; We could use a hash table instead, but a simple benchmark shows little difference.
  (setf (hosts hostlist)
        (or (hosts hostlist)
            (let ((hostlist-string (read-hostlist hostlist)))
              (unless (uiop:emptyp hostlist-string)
                (with-input-from-string (stream hostlist-string)
                  (loop as line = (read-line stream nil)
                        while line
                        unless (or (< (length line) 2) (string= (subseq line 0 1) "#"))
                          collect (second (str:split " " line)))))))))

(serapeum:export-always '*default-hostlist*)
(defparameter *default-hostlist*
  (make-instance 'hostlist
                 :url "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                 :path "hostlist-stevenblack"))

(define-mode blocker-mode ()
    "Enable blocking of blacklisted hosts."
    ((hostlists :accessor hostlists :initarg :hostlists
                :initform (list *default-hostlist*))
     (destructor
      :initform
      (lambda (mode)
        (hooks:remove-hook (request-resource-hook (buffer mode))
                           'request-resource-block)))
     (constructor
      :initform
      (lambda (mode)
        (hooks:add-hook (request-resource-hook (buffer mode))
                        (next:make-handler-resource #'request-resource-block))))))

(defmethod blacklisted-host-p ((mode blocker-mode) host)
  "Return non-nil of HOST if found in the hostlists of MODE.
Return nil if MODE's hostlist cannot be parsed."
  (when host
    (not (loop for hostlist in (hostlists mode)
               never (member-string host (parse hostlist))))))

(defun request-resource-block (buffer
                               &key url
                                 &allow-other-keys)
  "Block resource queries from blacklisted hosts.
This is an acceptable handler for `request-resource-hook'."
  ;; TODO: Use quri:uri-domain?
  (let ((mode (find-submode buffer 'blocker-mode)))
    (if (and mode
             (blacklisted-host-p mode
                                 (ignore-errors (quri:uri-host (quri:uri url)))))
        (progn
          (log:info "Dropping ~a" url)
          :stop)
        ;; Fallback on the other handlers from `request-resource-hook'.
        nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :s-serialization)

(defmethod serializable-slots ((object next/blocker-mode::blocker-mode))
  "Discard hostlists which can get pretty big."
  (delete 'next/blocker-mode::hostlists
          (mapcar #'closer-mop:slot-definition-name (closer-mop:class-slots (class-of object)))))
