;;; renderer-gtk.lisp --- functions for creating GTK interface onscreen

(in-package :next)

(defclass-export gtk-browser (browser)
  (#+darwin
   (modifiers :accessor modifiers
              :initform '()
              :type list
              :documentation "On macOS some modifiers like Super and Meta are
seen like regular keys.
To work around this issue, we store them in this list while they are pressed.
See `push-modifiers', `pop-modifiers' and `key-event-modifiers'.")
   (modifier-translator :accessor modifier-translator
                        :initform #'translate-modifiers
                        :type function
                        :documentation "Function that returns a list of
modifiers understood by `keymap:make-key'.  You can customize this slot if you
want to change the behaviour of modifiers, for instance swap 'control' and
'meta'.")))

(setf *browser-class* 'gtk-browser)

(defmethod ffi-initialize ((browser gtk-browser) urls startup-timestamp)
  "gtk:within-main-loop handles all the GTK initialization. On
   GNU/Linux, Next could hang after 10 minutes if it's not
   used. Conversely, on Darwin, if gtk:within-main-loop is used, no
   drawing happens. Drawing operations on Darwin MUST originate from
   the main thread, which the GTK main loop is not guaranteed to be
   on."
  (log:debug "Initializing GTK Interface")
  #-darwin
  (progn
    (gtk:within-main-loop
      (gdk:gdk-set-program-class "next")
      (finalize browser urls startup-timestamp))
    (unless *keep-alive*
      (gtk:join-gtk-main)))
  #+darwin
  (progn
    (gdk:gdk-set-program-class "next")
    (finalize browser urls startup-timestamp)
    (gtk:gtk-main)))

(defmethod ffi-kill-browser ((browser gtk-browser))
  (gtk:leave-gtk-main))

(defclass-export gtk-window (window)
  ((gtk-object :accessor gtk-object)
   (box-layout :accessor box-layout)
   (minibuffer-container :accessor minibuffer-container)
   (minibuffer-view :accessor minibuffer-view)
   (key-string-buffer :accessor key-string-buffer)))

(define-class-type window)
(declaim (type (window-type) *window-class*))
(serapeum:export-always '*window-class*)
(defparameter *window-class* 'gtk-window)

(defclass-export gtk-buffer (buffer)
  ((gtk-object :accessor gtk-object)
   (proxy-uri :accessor proxy-uri
              :initarg :proxy-uri
              :type string
              :initform "")
   (proxy-ignored-hosts :accessor proxy-ignored-hosts
                        :initarg :proxy-ignored-hosts
                        :type list
                        :initform '())))

(define-class-type buffer)
(declaim (type (buffer-type) *buffer-class*))
(serapeum:export-always '*buffer-class*)
(defparameter *buffer-class* 'gtk-buffer)

(defmethod initialize-instance :after ((window gtk-window) &key)
  (with-slots (gtk-object box-layout minibuffer-container minibuffer-view active-buffer
               id key-string-buffer) window
    (setf id (get-unique-window-identifier *browser*))
    (setf gtk-object (make-instance 'gtk:gtk-window
                                    :type :toplevel
                                    :default-width 1024
                                    :default-height 768))
    (setf box-layout (make-instance 'gtk:gtk-box
                                    :orientation :vertical
                                    :spacing 0))
    (setf minibuffer-container (make-instance 'gtk:gtk-box
                                              :orientation :vertical
                                              :spacing 0))
    (setf key-string-buffer (make-instance 'gtk:gtk-entry))
    (setf minibuffer-view (make-instance 'webkit:webkit-web-view))
    (setf active-buffer (make-instance *buffer-class*))
    ;; Add the views to the box layout and to the window
    (gtk:gtk-box-pack-start box-layout (gtk-object active-buffer))
    (gtk:gtk-box-pack-end box-layout minibuffer-container :expand nil)
    (gtk:gtk-box-pack-start minibuffer-container minibuffer-view :expand t)
    (setf (gtk:gtk-widget-size-request minibuffer-container)
          (list -1 (status-buffer-height window)))
    (gtk:gtk-container-add gtk-object box-layout)
    (setf (slot-value *browser* 'last-active-window) window)
    (gtk:gtk-widget-show-all gtk-object)
    (gobject:g-signal-connect
     gtk-object "key_press_event"
     (lambda (widget event) (declare (ignore widget))
       #+darwin
       (push-modifier *browser* event)
       (on-signal-key-press-event window event)))
    (gobject:g-signal-connect
     gtk-object "key_release_event"
     (lambda (widget event) (declare (ignore widget))
       #+darwin
       (pop-modifier *browser* event)
       (on-signal-key-release-event window event)))
    (gobject:g-signal-connect
     gtk-object "destroy"
     (lambda (widget) (declare (ignore widget))
       (on-signal-destroy window)))))

(defmethod on-signal-destroy ((window gtk-window))
  ;; remove buffer from window to avoid corruption of buffer
  (gtk:gtk-container-remove (box-layout window) (gtk-object (active-buffer window)))
  (window-delete window))

(defmethod ffi-window-delete ((window gtk-window))
  "Delete a window object and remove it from the hash of windows."
  (gtk:gtk-widget-destroy (gtk-object window)))

(defmethod ffi-window-fullscreen ((window gtk-window))
  (gtk:gtk-window-fullscreen (gtk-object window)))

(defmethod ffi-window-unfullscreen ((window gtk-window))
  (gtk:gtk-window-unfullscreen (gtk-object window)))

(defun derive-key-string (keyval character)
  "Return string representation of a keyval.
Return nil when key must be discarded, e.g. for modifiers."
  (let ((result
          (match keyval
            ((or "Alt_L" "Super_L" "Control_L" "Shift_L"
                 "Alt_R" "Super_R" "Control_R" "Shift_R"
                 "ISO_Level3_Shift" "Arabic_switch")
             ;; Discard modifiers (they usually have a null character).
             nil)
            ((guard s (str:contains? "KP_" s))
             (str:replace-all "KP_" "keypad" s))
            ;; With a modifier, "-" does not print, so we me must translate it
            ;; to "hyphen" just like in `printable-p'.
            ("minus" "hyphen")
            ;; In most cases, return character and not keyval for punctuation.
            ;; For instance, C-[ is not printable but the keyval is "bracketleft".
            ;; ASCII control characters like Escape, Delete or BackSpace have a
            ;; non-printable character (usually beneath #\space), so we use the
            ;; keyval in this case.
            ;; Even if space in printable, C-space is not so we return the
            ;; keyval in this case.
            (_ (if (or (char<= character #\space)
                       (char= character #\Del))
                   keyval
                   (string character))))))
    (if (< 1 (length result))
        (str:replace-all "_" "" (string-downcase result))
        result)))

#+darwin
(defmethod push-modifier ((browser gtk-browser) event)
  (let* ((modifier-state (gdk:gdk-event-key-state event))
         (key-value (gdk:gdk-event-key-keyval event))
         (key-value-name (gdk:gdk-keyval-name key-value)))
    (when (member :control-mask modifier-state)
      (push :control-mask (modifiers browser)))
    (when (member :shift-mask modifier-state)
      (push :shift-mask (modifiers browser)))
    (when (or (string= key-value-name "Arabic_switch")
              (string= key-value-name "Alt_L")
              (string= key-value-name "Alt_R"))
      (push :mod1-mask (modifiers browser)))
    (when (and (member :mod2-mask modifier-state)
               (member :meta-mask modifier-state))
      (push :super-mask (modifiers browser))))
  (setf (modifiers browser) (delete-duplicates (modifiers browser))))

#+darwin
(defmethod pop-modifier ((browser gtk-browser) event)
  (let* ((modifier-state (gdk:gdk-event-key-state event))
         (key-value (gdk:gdk-event-key-keyval event))
         (key-value-name (gdk:gdk-keyval-name key-value)))
    (when (member :control-mask modifier-state)
      (alex:deletef (modifiers browser) :control-mask))
    (when (member :shift-mask modifier-state)
      (alex:deletef (modifiers browser) :shift-mask))
    (when (or (string= key-value-name "Arabic_switch")
              (string= key-value-name "Alt_L")
              (string= key-value-name "Alt_R"))
      (alex:deletef (modifiers browser) :mod1-mask))
    (when (and (member :mod2-mask modifier-state)
               (member :meta-mask modifier-state))
      (alex:deletef (modifiers browser) :super-mask))))

(declaim (ftype (function (list &optional gdk:gdk-event) list) translate-modifiers))
(defun translate-modifiers (modifier-state &optional event)
  "Return list of modifiers fit for `keymap:make-key'.
See `gtk-browser's `modifier-translator' slot."
  (declare (ignore event))
  (let ((plist '(:control-mask "control"
                 :mod1-mask "meta"
                 :shift-mask "shift"
                 :super-mask "super"
                 :hyper-mask "hyper")))
    (delete nil (mapcar (lambda (mod) (getf plist mod)) modifier-state))))

#+darwin
(defun key-event-modifiers (key-event)
  (declare (ignore key-event))
  (modifiers *browser*))

#-darwin
(defun key-event-modifiers (key-event)
  (gdk:gdk-event-key-state key-event))

;; REVIEW: Remove after upstream fix is merged in Quicklisp, see https://github.com/crategus/cl-cffi-gtk/issues/74.
;; Wait for https://github.com/Ferada/cl-cffi-gtk/issues/new.
(defun gdk-event-button-state (button-event)
  "Return BUTTON-EVENT modifiers as a `gdk-modifier-type', i.e. a list of keywords."
  (let ((state (gdk:gdk-event-button-state button-event)))
    (if (listp state)
        state
        (cffi:with-foreign-objects ((modifiers 'gdk:gdk-modifier-type))
          (setf (cffi:mem-ref modifiers 'gdk:gdk-modifier-type) state)
          (cffi:mem-ref modifiers 'gdk:gdk-modifier-type)))))

#+darwin
(defun button-event-modifiers (button-event)
  (declare (ignore button-event))
  (modifiers *browser*))

#-darwin
(defun button-event-modifiers (button-event)
  (gdk-event-button-state button-event))

(defmethod printable-p ((window gtk-window) event)
  "Return the printable value of EVENT."
  ;; Generate the result of the current keypress into the dummy
  ;; key-string-buffer (a GtkEntry that's never shown on screen) so that we
  ;; can collect the printed representation of composed keypress, such as dead
  ;; keys.
  (gtk:gtk-entry-im-context-filter-keypress (key-string-buffer window) event)
  (when (<= 1 (gtk:gtk-entry-text-length (key-string-buffer window)))
    (prog1
        (match (gtk:gtk-entry-text (key-string-buffer window))
          ;; Special cases: these characters are not supported as is in KEY values.
          ;; See `self-insert' for the reverse translation.
          (" " "space")
          ("-" "hyphen")
          (character character))
      (setf (gtk:gtk-entry-text (key-string-buffer window)) ""))))

(defmethod on-signal-key-press-event ((sender gtk-window) event)
  (let* ((keycode (gdk:gdk-event-key-hardware-keycode event))
         (keyval (gdk:gdk-event-key-keyval event))
         (keyval-name (gdk:gdk-keyval-name keyval))
         (character (gdk:gdk-keyval-to-unicode keyval))
         (printable-value (printable-p sender event))
         (key-string (or printable-value
                         (derive-key-string keyval-name character)))
         (modifiers (funcall (modifier-translator *browser*)
                             (key-event-modifiers event)
                             event)))
    (if modifiers
        (log:debug key-string keycode character keyval-name modifiers)
        (log:debug key-string keycode character keyval-name))
    (if key-string
        (progn
          (alex:appendf (key-stack *browser*)
                        (list (keymap:make-key :code keycode
                                               :value key-string
                                               :modifiers modifiers
                                               :status :pressed)))
          (funcall (input-dispatcher sender) event (active-buffer sender) sender printable-value))
        ;; Do not forward modifier-only to renderer.
        t)))

(defmethod on-signal-key-release-event ((sender gtk-window) event)
  "We don't handle key release events.
Warning: This behaviour may change in the future."
  (if (active-minibuffers sender)
      ;; Do not forward release event when minibuffer is up.
      t
      ;; Forward release event to the web view.
      nil))

(defmethod on-signal-button-press-event ((sender gtk-buffer) event)
  (let* ((button (gdk:gdk-event-button-button event))
         ;; REVIEW: No need to store X and Y?
         ;; (x (gdk:gdk-event-button-x event))
         ;; (y (gdk:gdk-event-button-y event))
         (window (find sender (window-list) :key #'active-buffer))
         (key-string (format nil "button~s" button))
         (modifiers (funcall (modifier-translator *browser*)
                             (button-event-modifiers event)
                             event)))
    (when key-string
      (alex:appendf (key-stack *browser*)
                          (list (keymap:make-key
                                 :value key-string
                                 :modifiers modifiers
                                 :status :pressed)))
      (funcall (input-dispatcher window) event sender window nil))))

(declaim (ftype (function (&optional buffer)) make-context))
(defun make-context (&optional buffer)
  (let* ((context (webkit:webkit-web-context-get-default))
         (cookie-manager (webkit:webkit-web-context-get-cookie-manager context)))
    (when (and buffer (not (str:emptyp (namestring (cookies-path buffer)))))
      (webkit:webkit-cookie-manager-set-persistent-storage
       cookie-manager
       (namestring (cookies-path buffer))
       :webkit-cookie-persistent-storage-text))
    context))

(defmethod initialize-instance :after ((buffer gtk-buffer) &key)
  (hooks:run-hook (buffer-before-make-hook *browser*) buffer)
  (setf (id buffer) (get-unique-buffer-identifier *browser*))
  (setf (gtk-object buffer)
        (make-instance 'webkit:webkit-web-view
                       ;; TODO: Should be :web-context, shouldn't it?
                       :context (make-context buffer)))
  (gobject:g-signal-connect
   (gtk-object buffer) "decide-policy"
   (lambda (web-view response-policy-decision policy-decision-type-response)
     (declare (ignore web-view))
     (on-signal-decide-policy buffer response-policy-decision policy-decision-type-response)))
  (gobject:g-signal-connect
   (gtk-object buffer) "load-changed"
   (lambda (web-view load-event)
     (declare (ignore web-view))
     (on-signal-load-changed buffer load-event)))
  (gobject:g-signal-connect
   (gtk-object buffer) "mouse-target-changed"
   (lambda (web-view hit-test-result modifiers)
     (declare (ignore web-view))
     (on-signal-mouse-target-changed buffer hit-test-result modifiers)))
  ;; Mouse events are captured by the web view first, so we must intercept them here.
  (gobject:g-signal-connect
   (gtk-object buffer) "button-press-event"
   (lambda (web-view event) (declare (ignore web-view))
     (on-signal-button-press-event buffer event)))
  ;; TODO: Capture button-release-event?
  ;; TLS certificate handling
  (gobject:g-signal-connect
   (gtk-object buffer) "load-failed-with-tls-errors"
   (lambda (web-view failing-uri certificate errors)
     (declare (ignore web-view errors))
     ;; TODO: Add hint on how to accept certificate to the HTML content.
     (on-signal-load-failed-with-tls-errors buffer certificate failing-uri)))
  ;; Modes might require that buffer exists, so we need to initialize them
  ;; after the view has been created.
  (initialize-modes buffer))

(defmethod on-signal-load-failed-with-tls-errors ((buffer gtk-buffer) certificate url)
  "Return nil to propagate further (i.e. raise load-failed signal), T otherwise."
  (let* ((context (webkit:webkit-web-view-web-context (gtk-object buffer)))
         (host (quri:uri-host (quri:uri url))))
    (when (and (certificate-whitelist buffer)
               (member-string host (certificate-whitelist buffer)))
      (webkit:webkit-web-context-allow-tls-certificate-for-host
       context
       (gobject:pointer certificate)
       host)
      (set-url url :buffer buffer)
      t)))

(defmethod on-signal-decide-policy ((buffer gtk-buffer) response-policy-decision policy-decision-type-response)
  (let ((is-new-window nil) (is-known-type t) (event-type nil)
        (navigation-action nil) (navigation-type nil)
        (mouse-button nil) (modifiers ())
        (url nil) (request nil))
    (match policy-decision-type-response
      (:webkit-policy-decision-type-navigation-action
       (setf navigation-type (webkit:webkit-navigation-policy-decision-navigation-type response-policy-decision)))
      (:webkit-policy-decision-type-new-window-action
       (setf navigation-type (webkit:webkit-navigation-policy-decision-navigation-type response-policy-decision))
       (setf is-new-window t))
      (:webkit-policy-decision-type-response
       (setf request (webkit:webkit-response-policy-decision-request response-policy-decision))
       (setf is-known-type
             (webkit:webkit-response-policy-decision-is-mime-type-supported
              response-policy-decision))))
    ;; Set Event-Type
    (setf event-type
          (match navigation-type
            (:webkit-navigation-type-link-clicked :link-click)
            (:webkit-navigation-type-form-submitted :form-submission)
            (:webkit-navigation-type-back-forward :backward-or-forward)
            (:webkit-navigation-type-reload :reload)
            (:webkit-navigation-type-form-resubmitted :form-resubmission)
            (:webkit-navigation-type-other :other)))
    ;; Get Navigation Parameters from WebKitNavigationAction object
    (when navigation-type
      (setf navigation-action (webkit:webkit-navigation-policy-decision-get-navigation-action
                               response-policy-decision))
      (setf request (webkit:webkit-navigation-action-get-request navigation-action))
      (setf mouse-button (format nil "button~d"
                                 (webkit:webkit-navigation-action-get-mouse-button
                                  navigation-action)))
      (setf modifiers (funcall (modifier-translator *browser*)
                               (webkit:webkit-navigation-action-get-modifiers navigation-action))))
    (setf url (webkit:webkit-uri-request-uri request))
    (if (or (null (hooks:handlers (request-resource-hook buffer)))
            (eq :forward (hooks:run-hook (request-resource-hook buffer)
                                         buffer
                                         :url url
                                         :keys (unless (uiop:emptyp mouse-button)
                                                 (list (keymap:make-key
                                                        :value mouse-button
                                                        :modifiers modifiers)))
                                         :event-type event-type
                                         :is-new-window is-new-window
                                         :is-known-type is-known-type)))
        ;; nil means "forward to renderer".
        nil
        t)))

(defmethod on-signal-load-changed ((buffer gtk-buffer) load-event)
  (let ((url (webkit:webkit-web-view-uri (gtk-object buffer))))
    (cond ((eq load-event :webkit-load-started)
           (echo "Loading: ~a." (url buffer)))
          ((eq load-event :webkit-load-redirected) nil)
          ;; TODO: load-committed is deprecated.  Only use load-status and load-finished.
          ((eq load-event :webkit-load-committed)
           (on-signal-load-committed buffer url))
          ((eq load-event :webkit-load-finished)
           (on-signal-load-finished buffer url)))))

(defmethod on-signal-mouse-target-changed ((buffer gtk-buffer) hit-test-result modifiers)
  (declare (ignore modifiers))
  (cond ((webkit:webkit-hit-test-result-link-uri hit-test-result)
         (push-url-at-point buffer (webkit:webkit-hit-test-result-link-uri hit-test-result)))
        ((webkit:webkit-hit-test-result-image-uri hit-test-result)
         (push-url-at-point buffer (webkit:webkit-hit-test-result-image-uri hit-test-result)))
        ((webkit:webkit-hit-test-result-media-uri hit-test-result)
         (push-url-at-point buffer (webkit:webkit-hit-test-result-media-uri hit-test-result)))))

(defmethod ffi-window-make ((browser gtk-browser))
  "Make a window."
  (make-instance *window-class*))

(defmethod ffi-window-to-foreground ((window gtk-window))
  "Show window in foreground."
  (gtk:gtk-window-present (gtk-object window))
  (setf (slot-value *browser* 'last-active-window) window))

(defmethod ffi-window-set-title ((window gtk-window) title)
  "Set the title for a window."
  (setf (gtk:gtk-window-title (gtk-object window)) title))

(defmethod ffi-window-active ((browser gtk-browser))
  "Return the window object for the currently active window."
  (setf (slot-value browser 'last-active-window)
        (or (find-if #'gtk:gtk-window-is-active (window-list) :key #'gtk-object)
            (slot-value browser 'last-active-window))))

(defmethod ffi-window-set-active-buffer ((window gtk-window) (buffer gtk-buffer))
  "Set BROWSER's WINDOW buffer to BUFFER. "
  (gtk:gtk-container-remove (box-layout window) (gtk-object (active-buffer window)))
  (gtk:gtk-box-pack-start (box-layout window) (gtk-object buffer) :expand t)
  (gtk:gtk-widget-show (gtk-object buffer))
  (setf (active-buffer window) buffer)
  buffer)

(defmethod ffi-window-set-minibuffer-height ((window gtk-window) height)
  (setf (gtk:gtk-widget-size-request (minibuffer-container window))
        (list -1 height)))

(defmethod ffi-buffer-make ((browser gtk-browser) &key title default-modes)
  "Make buffer with title TITLE and modes DEFAULT-MODES."
  (apply #'make-instance *buffer-class*
         (append (when title `(:title ,title))
                 (when default-modes `(:default-modes ,default-modes)))))

(defmethod ffi-buffer-delete ((buffer gtk-buffer))
  (gtk:gtk-widget-destroy (gtk-object buffer)))

(defmethod ffi-buffer-load ((buffer gtk-buffer) uri)
  (webkit:webkit-web-view-load-uri (gtk-object buffer) uri))

(defmethod ffi-buffer-evaluate-javascript ((buffer gtk-buffer) javascript &key callback)
  (webkit2:webkit-web-view-evaluate-javascript (gtk-object buffer)
                                               javascript
                                               callback
                                               #'javascript-error-handler))

(defmethod ffi-minibuffer-evaluate-javascript ((window gtk-window) javascript &key callback)
  (webkit2:webkit-web-view-evaluate-javascript (minibuffer-view window) javascript callback))

(defmethod ffi-buffer-enable-javascript ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-javascript
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(defmethod ffi-buffer-enable-javascript-markup ((buffer gtk-buffer) value)
  (setf (webkit:webkit-settings-enable-javascript-markup
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        value))

(defmethod ffi-buffer-set-proxy ((buffer gtk-buffer) &optional proxy-uri (ignore-hosts (list nil)))
  "Redirect network connections of BUFFER to proxy server PROXY-URI.
   Hosts in IGNORE-HOSTS (a list of strings) ignore the proxy.
   For the user-level interface, see `proxy-mode'.

   Note: WebKit supports three proxy 'modes': default (the system proxy),
   custom (the specified proxy) and none."
  (setf (proxy-uri buffer) proxy-uri)
  (setf (proxy-ignored-hosts buffer) ignore-hosts)
  (let* ((context (webkit:webkit-web-view-web-context (gtk-object buffer)))
         (settings (cffi:null-pointer))
         (mode :webkit-network-proxy-mode-no-proxy)
         (ignore-hosts (cffi:foreign-alloc :string
                                           :initial-contents ignore-hosts
                                           :null-terminated-p t)))
    (when proxy-uri
      (setf mode :webkit-network-proxy-mode-custom)
      (setf settings
            (webkit:webkit-network-proxy-settings-new
             proxy-uri
             ignore-hosts)))
    (cffi:foreign-free ignore-hosts)
    (webkit:webkit-web-context-set-network-proxy-settings
     context mode settings)))

(defmethod ffi-buffer-get-proxy ((buffer gtk-buffer))
  "Return the proxy URI and list of ignored hosts (a list of strings) as second value."
  (values (proxy-uri buffer)
          (proxy-ignored-hosts buffer)))

(defmethod ffi-generate-input-event ((window gtk-window) event)
  ;; The "send_event" field is used to mark the event as an "unconsumed"
  ;; keypress.  The distinction allows us to avoid looping indefinitely.
  (setf (gdk:gdk-event-button-send-event event) t)
  (gtk:gtk-main-do-event event))

(defmethod ffi-generated-input-event-p ((window gtk-window) event)
  (gdk:gdk-event-send-event event))

(defmethod ffi-within-renderer-thread ((browser gtk-browser) thunk)
  (declare (ignore browser))
  (gtk:within-gtk-thread
    (funcall thunk)))

(defmethod ffi-inspector-show ((buffer gtk-buffer))
  (setf (webkit:webkit-settings-enable-developer-extras
         (webkit:webkit-web-view-get-settings (gtk-object buffer)))
        t)
  (webkit:webkit-web-inspector-show
   (webkit:webkit-web-view-get-inspector (gtk-object buffer))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; See https://github.com/Ferada/cl-cffi-gtk/issues/37.
(in-package :gio)
(define-g-flags "GTlsCertificateFlags" g-tls-certificate-flags
   (:export t
    :type-initializer "g_tls_certificate_flags_get_type")
   (:unknown-ca 1)
   (:bad-identity 2)
   (:not-activated 4)
   (:expired 8)
   (:revoked 16)
   (:insecure 32)
   (:generic-error 64)
   (:validate-all 128))
