(in-package :space-gpu)
(in-readtable fn:fn-reader)

;; ok so we need to make spaces available on the gpu
;; this is going to require two passes when compiling, one to get
;; all the flow information, the second to compile the new result

;; we are going to mock this out here.

;; lets have a type to represent a space

(varjo::def-v-type-class space-g (varjo::v-type)
  ((varjo::core :initform nil :reader varjo::core-typep)
   (varjo::glsl-string :initform "#<space>" :reader varjo::v-glsl-string)))

;; a name for the space
(defvar *current-space* (gensym "current-space"))

;; and let's make the 'in macro that uses it

(varjo:v-defmacro in (space &body body)
  `(let ((,*current-space* ,space))
     ,@body))

;; and a cpu version for formatting

(defmacro in (space &body body)
  (declare (ignore space))
  `(progn ,@body))

;; now we need positions

(varjo::def-v-type-class pos4 (varjo::v-vec4)
  ((varjo::core :initform nil :reader varjo::core-typep)
   (varjo::glsl-string :initform "#<pos4>" :reader varjo::v-glsl-string)))

(varjo:v-defmacro p! (v)
  `(%p! ,v ,*current-space*))

(varjo:v-defun %p! (v s) "#<pos4(~a, ~a)>" (:vec4 space-g) pos4)

;;----------------------------------------------------------------------

;; now lets define the real compiler pass

(defun ast-space (node)
  (get-var *current-space* node))

(defun cross-space-form-p (node)
  (and (ast-typep node 'pos4)
       (let ((origin (first (val-origins node))))
	 (and (ast-kindp origin '%p!)
	      (not (eq (ast-space node) (ast-space origin)))))))

(defun p!-form-p (node)
  (ast-kindp node '%p!))

(defun in-form-p (node)
  (and (ast-kindp node 'let)
       (dbind (args . body) (ast-args node)
	 (declare (ignore body))
	 (eq (caar args) *current-space*))))

(defun cross-space->matrix-multiply (node env)
  (labels ((name! ()
	     (symb 'transform-
		   (setf (gethash 'count env)
			 (1+ (gethash 'count env -1))))))
    (let* ((transforms
	     (or (gethash 'transforms env)
		 (setf (gethash 'transforms env)
		       (make-hash-table :test #'equal))))
	   (node-space (ast-space node))
	   (origin-space (ast-space (first (val-origins node)))))
      (unless node-space
	(error 'spaces::position->no-space :start-space origin-space))
      (let* ((key (concatenate 'string (v-glsl-name node-space)
			       (v-glsl-name origin-space)))
	     (var-name (or (gethash key transforms)
			   (setf (gethash key transforms) (name!))))
	     (from-name (aref (first (flow-id-origins (flow-ids node-space)
						      t node))
			      1))
	     (to-name (aref (first (flow-id-origins (flow-ids origin-space)
						    t node))
			    1)))
	(set-uniform var-name :mat4 env)
	(set-arg-val var-name `(spaces:get-transform ,from-name ,to-name) env)
	(ast~ node `(* ,var-name ,node))))))

(defun p!->v! (node)
  (ast~ node (first (ast-args node))))

(defun in-form->progn (node env)
  (dbind (((% space-form)) . body) (ast-args node)
    (declare (ignore %))
    (let* ((origin (val-origins space-form))
	   (uniform-name (aref (first origin) 1)))
      (remove-uniform uniform-name env)
      (ast~ node `(progn ,@body)))))

(def-compile-pass space-pass
    :ast-filter λ(or (cross-space-form-p _)
		     (p!-form-p _)
		     (in-form-p _))
    :ast-transform
    (lambda (node env)
      (cond
	((cross-space-form-p node) (cross-space->matrix-multiply node env))
	((p!-form-p node) (p!->v! node))
	((in-form-p node) (in-form->progn node env)))))


(cgl::defun-g blerp ((vert :vec4) &uniform (s space-g) (w space-g))
  (in s
    (in w (p! vert))
    0)
  (in s vert)
  (values vert (base-vectors:v! 1 0 0 0)))
