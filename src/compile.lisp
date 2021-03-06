(in-package :css)

(defvar *ignore-namespaces* T
  "ignore tag name spaces when matching, for now the parser
   doesnt support parsing namespaced tags, so lets ignore tag namespaces")

(defun attrib-includes? (node attrib value)
  (member value
          (cl-ppcre:split "\\s+" (get-attribute node attrib))
          :test #'string-equal))

(defun make-or-matcher (forms)
  (let ((matchers (mapcar (lambda (f) (make-matcher-aux f)) forms)))
    (lambda (%node%)
      "or-matcher"
      (iter (for matcher in matchers)
            (thereis (funcall matcher %node%))))))

(defun make-and-matcher (forms  )
  (let ((matchers (mapcar (lambda (f) (make-matcher-aux f)) forms)))
    (lambda (%node%)
      "and-matcher"
      (iter (for matcher in matchers)
            (always (funcall matcher %node%))))))

(defun make-class-matcher ( class )
  (lambda (%node%)
    "class-matcher"
    (attrib-includes? %node% "class" class)))

(defun make-hash-matcher ( id )
  (lambda (%node%)
    "hash-matcher"
    (string-equal (get-attribute %node% "id") id)))

(defun make-elt-matcher ( tag )
  (lambda (%node%)
    "elt-matcher"
    (let* ((match-to (if *ignore-namespaces*
                        (cl-ppcre:split ":" (tag-name %node%) :limit 2)
                        (list (tag-name %node%))))
           (match-to (or (second match-to) (first match-to))))
    (string-equal match-to tag))))

(defun make-attrib-matcher ( attrib match-type match-to   )
  "attrib-matcher"
  (lambda (%node%)
    (case match-type
      (:equals (string-equal (get-attribute %node% attrib) match-to))
      (:includes (attrib-includes? %node% attrib match-to))
      (:dashmatch (member match-to
                          (cl-ppcre:split "-" (get-attribute %node% attrib))
                          :test #'string-equal))
      (:begins-with (alexandria:starts-with-subseq
                     match-to
                     (get-attribute %node% attrib)
                     :test #'char-equal))
      (:ends-with (alexandria:ends-with-subseq
                   match-to
                   (get-attribute %node% attrib)
                   :test #'char-equal))
      (:substring (search match-to (get-attribute %node% attrib)
                          :test #'string-equal ))
      (:exists (get-attribute %node% attrib)))))



(defun make-immediate-child-matcher (parent-matcher child-matcher)
  (lambda (%node%)
    (and (funcall child-matcher %node%)
         (parent-element %node%)
         (funcall parent-matcher (parent-element %node%)))))

(defun make-child-matcher (parent-matcher child-matcher  )
  (lambda (%node%)
    (and (funcall child-matcher %node%)
         (iter (for n in (parent-elements %node%))
           ;; the root is/could be document node
           ;; we can really only test on elements, so
           ;; this seems pretty valid, solves github issue:5
           (when (element-p n)
             (thereis (funcall parent-matcher n)))))))

(defun make-immediatly-preceded-by-matcher (this-matcher sibling-matcher  )
  (lambda (%node%)
    (and (funcall this-matcher %node%)
         (previous-sibling %node%)
         (funcall sibling-matcher (previous-sibling %node%)))))

(defun make-preceded-by-matcher (this-matcher sibling-matcher  )
  (lambda (%node%)
    (and (funcall this-matcher %node%)
         (iter (for n initially (previous-sibling %node%)
                    then (previous-sibling n))
               (while n)
               (thereis (funcall sibling-matcher n))))))

(defun make-pseudo-matcher (pseudo submatcher)
  (lambda (%node%) (funcall pseudo %node% submatcher)))

(defun make-nth-pseudo-matcher (pseudo mul add)
  (lambda (%node%) (funcall pseudo %node% mul add)))

(defun make-matcher-aux (tree)
  (ecase (typecase tree
           (atom tree)
           (list (car tree)))
    (:or (make-or-matcher (rest tree)  ))
    (:and (make-and-matcher (rest tree)  ))
    (:class (make-class-matcher (second tree)  ))
    (:hash (make-hash-matcher (second tree)  ))
    (:element (make-elt-matcher (second tree)  ))
    (:everything (lambda (%node%) (declare (ignore %node%)) T))
    (:attribute
       (let ((attrib (second tree)))
         (ecase (length tree)
           (2 (make-attrib-matcher attrib :exists nil  ))
           (3 (destructuring-bind (match-type match-to) (third tree)
                (make-attrib-matcher attrib match-type match-to  ))))))
    (:immediate-child
       (make-immediate-child-matcher
        (make-matcher-aux (second tree))
        (make-matcher-aux (third tree))
        ))
    (:child
       (make-child-matcher
        (make-matcher-aux (second tree))
        (make-matcher-aux (third tree))
        ))
    (:immediatly-preceded-by
       (make-immediatly-preceded-by-matcher
        (make-matcher-aux (third tree))
        (make-matcher-aux (second tree))
        ))
    (:preceded-by
       (make-preceded-by-matcher
        (make-matcher-aux (third tree))
        (make-matcher-aux (second tree))
        ))
    (:pseudo
       (destructuring-bind (pseudo name &optional subselector) tree
         (declare (ignore pseudo ))
         (make-pseudo-matcher
          (fdefinition (intern (string-upcase name) :pseudo))
          (when subselector
            (make-matcher-aux subselector  ))
          )))
    (:nth-pseudo
       (destructuring-bind (pseudo name mul add) tree
         (declare (ignore pseudo ))
         (make-nth-pseudo-matcher
          (fdefinition (intern (string-upcase name) :pseudo))
          mul add  )))))

(defun make-node-matcher (expression)
  (make-matcher-aux
   (typecase expression
     (string (parse-results expression))
     (list expression))))

(defun compile-css-node-matcher (inp)
  "Given a string, returns a matcher-function of a single node that will tell
   you whether or not the node matches"
  (typecase inp
    ((or string list) (make-node-matcher inp))
    (function inp)))

(defun %node-matches? (node inp)
  (funcall (compile-css-node-matcher inp) node))

(defun node-matches? (node inp)
  "Given a node and a CSS selector, see if the given node matches that selector"
  (%node-matches? node inp))

(define-compiler-macro node-matches? (node inp &environment e)
  `(%node-matches?
    ,node
    ,(if (constantp inp e)
         `(load-time-value (compile-css-node-matcher ,inp))
         inp)))

(defgeneric %do-query (matcher node &key first?)
  (:documentation "matches selector inp against the node
    if first? is T then return the first matching node"))

(defun %query (inp &optional (trees buildnode:*document*))
  (let* ((matcher (compile-css-node-matcher inp)))
    ;; ensure that queries on a list dont return the items in that list
    (iter
      (for tree in (alexandria:ensure-list trees))
      (appending (%do-query matcher tree)))))

(defun %query1 (inp &optional (trees buildnode:*document*))
  (let* ((matcher (compile-css-node-matcher inp)))
    ;; ensure that queries on a list dont return the items in that list
    (iter
     (for tree in (alexandria:ensure-list trees))
     (thereis (%do-query matcher tree :first? t)))))

(defun query (inp &optional (trees buildnode:*document*))
  "Given a css selector, attempt to find the matching nodes in the passed in
   dom-trees (defaults to the document)"
  (%query inp trees))

(defun query1 (inp &optional (trees buildnode:*document*))
  "Given a css selector, attempt to find the first matching node in
   the passed in dom-trees (defaults to the document)"
  (%query1 inp trees))

(define-compiler-macro query (inp &optional (trees 'buildnode:*document*) &environment e)
  `(%query
    ,(if (constantp inp e)
         `(load-time-value (compile-css-node-matcher ,inp))
         inp)
    ,trees))

(define-compiler-macro query1 (inp &optional (trees 'buildnode:*document*)
                                   &environment e)
  `(%query1
    ,(if (constantp inp e)
         `(load-time-value (compile-css-node-matcher ,inp))
         inp)
    ,trees))
