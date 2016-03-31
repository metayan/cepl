(in-package :cepl.gpu-buffers)

;;;--------------------------------------------------------------
;;; BUFFERS ;;;
;;;---------;;;

;; [TODO] Should buffers have pull-g and push-g? of course! do it :)

(defmethod free ((object gpu-buffer))
  (free-buffer object))

(defun blank-buffer-object (buffer)
  (setf (gpu-buffer-id buffer) 0)
  (setf (gpu-buffer-format buffer) nil)
  (setf (gpu-buffer-managed buffer) nil)
  buffer)

(defun free-buffer (buffer)
  (with-foreign-object (id :uint)
    (setf (mem-ref id :uint) (gpu-buffer-id buffer))
    (blank-buffer-object buffer)
    (%gl:delete-buffers 1 id)))

(defun free-buffers (buffers)
  (with-foreign-object (id :uint (length buffers))
    (loop :for buffer :in buffers :for i :from 0 :do
       (setf (mem-aref id :uint i) (gpu-buffer-id buffer))
       (blank-buffer-object buffer))
    (%gl:delete-buffers 1 id)))

;; [TODO] This needs a rework given how gl targets operate
(let ((buffer-id-cache nil)
      (buffer-target-cache nil))
  (defun bind-buffer (buffer buffer-target)
    (let ((id (gpu-buffer-id buffer)))
      (unless (and (eq id buffer-id-cache)
                   (eq buffer-target buffer-target-cache))
        (cl-opengl-bindings:bind-buffer buffer-target id)
        (setf buffer-target-cache id)
        (setf buffer-target-cache buffer-target))))
  (defun force-bind-buffer (buffer buffer-target)
    "Binds the specified opengl buffer to the target"
    (let ((id (gpu-buffer-id buffer)))
      (cl-opengl-bindings:bind-buffer buffer-target id)
      (setf buffer-id-cache id)
      (setf buffer-target-cache buffer-target)))
  (defun unbind-buffer ()
    (cl-opengl-bindings:bind-buffer :array-buffer 0)
    (setf buffer-id-cache 0)
    (setf buffer-target-cache :array-buffer)))

(defmacro with-buffer ((var-name buffer &optional (buffer-target :array-buffer))
		       &body body)
  `(let* ((,var-name ,buffer))
     (unwind-protect (progn (bind-buffer ,var-name ,buffer-target)
			    ,@body)
       (unbind-buffer ,var-name))))

(defun gen-buffer ()
  (car (gl:gen-buffers 1)))

(defun make-gpu-buffer-from-id (gl-object &key initial-contents
					    (buffer-target :array-buffer)
					    (usage :static-draw)
					    (managed nil))
  (declare (symbol buffer-target usage))
  (init-gpu-buffer-from-id
   (make-uninitialized-gpu-buffer) gl-object initial-contents
   buffer-target usage managed))

(defun init-gpu-buffer-from-id (new-buffer gl-object initial-contents
				buffer-target usage managed)
  (declare (symbol buffer-target usage))
  (setf (gpu-buffer-id new-buffer) gl-object
	(gpu-buffer-managed new-buffer) managed
	(gpu-buffer-format new-buffer) nil)
  (if initial-contents
      (buffer-data new-buffer initial-contents buffer-target usage)
      new-buffer))

(defun make-gpu-buffer (&key initial-contents
			  (buffer-target :array-buffer)
			  (usage :static-draw)
			  (managed nil))
  (declare (symbol buffer-target usage))
  (cepl.memory::if-context
   (init-gpu-buffer-from-id
    %pre% (gen-buffer) initial-contents buffer-target usage managed)
   (make-uninitialized-gpu-buffer)))


(defun make-managed-gpu-buffer (&key initial-contents
				  (buffer-target :array-buffer)
				  (usage :static-draw))
  (cepl.memory::if-context
   (init-gpu-buffer-from-id %pre% (gen-buffer) initial-contents
			    buffer-target usage t)
   (%make-gpu-buffer :id 0 :format '(:uninitialized) :managed nil)))

(defun buffer-data-raw (data-pointer data-type data-byte-size
                        buffer buffer-target usage &optional (byte-offset 0))
  (let ((data-type (safer-gl-type data-type)))
    (bind-buffer buffer buffer-target)
    (%gl:buffer-data buffer-target data-byte-size
                     (cffi:inc-pointer data-pointer byte-offset)
                     usage)
    (setf (gpu-buffer-format buffer) `((,data-type ,data-byte-size 0)))
    buffer))

(defun buffer-data (buffer c-array buffer-target usage
                    &key
		      (offset 0)
		      (size (cepl.c-arrays::c-array-byte-size c-array)))
  (let ((data-type (element-type c-array)))
    (buffer-data-raw (pointer c-array) data-type size buffer buffer-target usage
                     (* offset (element-byte-size c-array)))))

;; [TODO] doesnt check for overflow off end of buffer
(defun buffer-sub-data (buffer c-array byte-offset buffer-target
                        &key (safe t))
  (let ((byte-size (cepl.c-arrays::c-array-byte-size c-array)))
    (when (and safe (loop for format in (gpu-buffer-format buffer)
                       when (and (< byte-offset (third format))
                                 (> (+ byte-offset byte-size)
                                    (third format)))
                       return t))
      (error "The data you are trying to sub into the buffer crosses the boundaries specified in the buffer's format. If you want to do this anyway you should set :safe to nil, though it is not advised as your buffer format would be invalid"))
    (bind-buffer buffer buffer-target)
    (%gl:buffer-sub-data buffer-target
                         byte-offset
                         byte-size
                         (pointer c-array)))
  buffer)

(defun multi-buffer-data (buffer c-arrays buffer-target usage)
  (let* ((c-array-byte-sizes (loop for c-array in c-arrays
				collect
				  (cepl.c-arrays::c-array-byte-size c-array)))
         (total-size (apply #'+ c-array-byte-sizes)))
    (bind-buffer buffer buffer-target)
    (buffer-data buffer (first c-arrays) buffer-target usage
                 :size total-size)
    (setf (gpu-buffer-format buffer)
          (loop :for c-array :in c-arrays
             :for size :in c-array-byte-sizes
             :with offset = 0
             :collect (list (element-type c-array) size offset)
             :do (buffer-sub-data buffer c-array offset
                                  buffer-target :safe nil)
             (setf offset (+ offset size)))))
  buffer)

(defun buffer-reserve-block-raw (buffer size-in-bytes buffer-target
                                 usage)
  (bind-buffer buffer buffer-target)
  (%gl:buffer-data buffer-target size-in-bytes
                   (cffi:null-pointer) usage)
  buffer)

(defun buffer-reserve-block (buffer type dimensions buffer-target usage)
  (let ((type (safer-gl-type type)))
    (bind-buffer buffer buffer-target)
    (unless dimensions (error "dimensions are not optional when reserving a buffer block"))
    (let* ((dimensions (if (listp dimensions) dimensions (list dimensions)))
           (byte-size (cepl.c-arrays::gl-calc-byte-size type dimensions)))
      (buffer-reserve-block-raw buffer
                                byte-size
                                buffer-target
                                usage)
      (setf (gpu-buffer-format buffer) `((,type ,byte-size ,0))))
    buffer))

(defun buffer-reserve-blocks (buffer types-and-dimensions
                              buffer-target usage)
  (let ((total-size-in-bytes 0))
    (setf (gpu-buffer-format buffer)
          (loop :for (type dimensions) :in types-and-dimensions :collect
             (let ((type (safer-gl-type type)))
               (progn (let ((size-in-bytes (cepl.c-arrays::gl-calc-byte-size
					    type dimensions)))
                        (incf total-size-in-bytes size-in-bytes)
                        `(,type ,size-in-bytes ,total-size-in-bytes))))))
    (buffer-reserve-block-raw buffer total-size-in-bytes buffer-target usage))
  buffer)

;;---------------------------------------------------------------

(defun safer-gl-type (type)
  "In some cases cl-opengl doesnt like certain types. :ushort is the main case
as it prefers :unsigned-short. This function fixes this"
  (if (eq type :ushort)
      :unsigned-short
      type))
