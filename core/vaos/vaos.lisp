(in-package :cepl.vaos)

;; [TODO] The terminology in here seems inconsistant, need to
;; nail this down

;;--------------------------------------------------------------
;; VAOS ;;
;;------;;

(defun free-vao (vao)
  (with-foreign-object (id :uint)
    (setf (mem-ref id :uint) vao)
    (%gl:delete-vertex-arrays 1 id)))

;; [TODO] would a unboxed lisp array be faster?
(defun free-vaos (vaos)
  (with-foreign-object (id :uint (length vaos))
    (loop :for vao :in vaos :for i :from 0 :do
       (setf (mem-aref id :uint i) vao))
    (%gl:delete-vertex-arrays 1 id)))

;; [TODO] Vao changes the inhabitants of :vertex-array etc
;;        this should be undone
(defun bind-vao (vao)
  (gl:bind-vertex-array vao))

(defun unbind-vao ()
  (gl:bind-vertex-array 0))

(defmacro with-vao-bound (vao &body body)
  `(unwind-protect
	(progn (bind-vao ,vao)
	       ,@body)
     (unbind-vao)))

(defun suitable-array-for-index-p (array)
  (and (eql (length (gpu-buffer-arrays (gpu-array-buffer array))) 1)
       (1d-p array)
       (find (element-type array) '(:uint8 :ushort :uint :unsigned-short
                                    :unsigned-int))))

(defun make-vao (gpu-arrays &optional index-array)
  (let ((gpu-arrays (listify gpu-arrays)))
    (make-vao-from-id
     (progn (assert (and (every #'1d-p gpu-arrays)
                         (or (null index-array)
                             (suitable-array-for-index-p
                              index-array))))
            (gl:gen-vertex-array))
     gpu-arrays index-array)))

(defgeneric make-vao-from-id (gl-object gpu-arrays &optional index-array))

(defmethod make-vao-from-id (gl-object (gpu-arrays list) &optional index-array)
  "makes a vao using a list of gpu-arrays as the source data
   (remember that you can also use gpu-sub-array here if you
   need a subsection of a gpu-array).
   You can also specify an index-array which will be used as
   the indicies when rendering"
  (unless (and (every #'1d-p gpu-arrays)
               (or (null index-array) (suitable-array-for-index-p
                                       index-array))))
  (let ((element-buffer (when index-array (gpu-array-buffer index-array)))
        (vao gl-object)
        (attr 0))
    (bind-vao vao)
    (loop :for gpu-array :in gpu-arrays :do
       (let* ((buffer (gpu-array-buffer gpu-array))
	      (elem-type (gpu-array-bb-element-type gpu-array))
	      (offset (gpu-array-bb-offset-in-bytes-into-buffer gpu-array)))
         (cepl.gpu-buffers::force-bind-buffer buffer :array-buffer)
         (incf attr (gl-assign-attrib-pointers
		     (if (listp elem-type) (second elem-type) elem-type)
		     attr offset))))
    (when element-buffer
      (cepl.gpu-buffers::force-bind-buffer element-buffer :element-array-buffer))
    (bind-vao 0)
    vao))
