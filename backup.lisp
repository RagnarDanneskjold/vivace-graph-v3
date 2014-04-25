(in-package :graph-db)

(defgeneric backup (object location &key include-deleted-p))

(defmethod backup :around ((node node) location &key include-deleted-p)
  (when (or include-deleted-p (not (deleted-p node)))
    (call-next-method)))

(defmethod backup ((v vertex) (stream stream) &key include-deleted-p)
  (declare (ignore include-deleted-p))
  (let ((plist
         (list :v
               (type-of v)
               (when (slot-boundp v 'data)
                 (data v))
               :id (id v)
               :revision (revision v)
               :deleted-p (deleted-p v))))
    (let ((*print-pretty* nil))
      (format stream "~S~%" plist))))

(defmethod backup ((e edge) (stream stream) &key include-deleted-p)
  (declare (ignore include-deleted-p))
  (let ((plist
         (list :e
               (type-of e)
               (from e)
               (to e)
               (weight e)
               (when (slot-boundp e 'data)
                 (data e))
               :id (id e)
               :revision (revision e)
               :deleted-p (deleted-p e))))
    (let ((*print-pretty* nil))
      (format stream "~S~%" plist))))

(defmethod backup ((graph graph) location &key include-deleted-p)
  (ensure-directories-exist location)
  (let ((count 0))
    (with-open-file (out location :direction :output)
      ;; The :LAST-TXN-ID record should come first so
      ;; SNAPSHOT-FILE-TXN-ID can find it as the first record.
      (let ((*print-pretty* nil))
        (format out "~S~%"
                (multiple-value-call 'list
                  :last-txn-id (get-txn-id))))
      (map-vertices (lambda (v)
                      (init-node-data v :graph graph)
                      (incf count)
                      (backup v out))
                    graph :include-deleted-p include-deleted-p)
      (map-edges (lambda (e)
                   (init-node-data e :graph graph)
                   (incf count)
                   (backup e out))
                 graph :include-deleted-p include-deleted-p)
      (values count location))))

(defmethod check-data-integrity ((graph graph) &key include-deleted-p)
  (let ((*cache-enabled* nil))
    (let ((problems nil) (count 0))
      (map-vertices (lambda (v)
                      (incf count)
                      (when (= 0 (mod count 1000))
                        (format t ".")
                        (force-output))
                      (handler-case
                          (init-node-data v :graph graph)
                        (error (c)
                          (push (cons (string-id v) c) problems))))
                    graph :include-deleted-p include-deleted-p)
      (map-edges (lambda (e)
                      (incf count)
                      (when (= 0 (mod count 1000))
                        (format t ".")
                        (force-output))
                   (handler-case
                       (init-node-data e :graph graph)
                     (error (c)
                       (push (cons (string-id e) c) problems))))
                 graph :include-deleted-p include-deleted-p)
      (terpri)
      problems)))

(defun transform-to-byte-vector (seq)
  (make-array (length seq)
              :element-type '(unsigned-byte 8)
              :initial-contents (map 'list 'identity seq)))

(defmethod restore ((graph graph) location &key package-name)
  (let ((*package* (find-package package-name)))
    (let ((file location) (start (get-universal-time)) (count 0))
      (unless (probe-file file)
        (error "~S does not exist." file))
      (let ((*readtable* (copy-readtable)))
        (local-time:enable-read-macros)
        (with-open-file (in file)
          (do ((plist (read in nil :eof) (read in nil :eof)))
              ((eq plist :eof))
            (incf count)
            (when (= 0 (mod count 100))
              (log:info "~A RESTORED ~A NODES" (current-thread) count))
            (case (car plist)
              (:v (progn
                    (setf (nth 4 plist) (transform-to-byte-vector (nth 4 plist)))
                    (apply '%%unsafe-make-vertex (rest plist))))
              (:e (progn
                    (setf (nth 2 plist) (transform-to-byte-vector (nth 2 plist)))
                    (setf (nth 3 plist) (transform-to-byte-vector (nth 3 plist)))
                    (setf (nth 7 plist) (transform-to-byte-vector (nth 7 plist)))
                    (apply '%%unsafe-make-edge (rest plist))))
              (:last-txn-id
               ;; Do nothing; this record is separately read by
               ;; SNAPSHOT-FILE-TXN-ID
               )
              (otherwise
               (log:error "RESTORE: Unknown input: ~S" plist))))))
      (dbg "RESTORE TOOK ~A SECONDS" (- (get-universal-time) start))
      (values graph
              (- (get-universal-time) start)))))

(defun restore-helper (mbox package-name)
  (let ((*package* (if package-name
                       (find-package package-name)
                       *package*)))
    (let ((*readtable* (copy-readtable)) (count 0))
      (local-time:enable-read-macros)
      (loop
         for plist = (sb-concurrency:receive-message mbox)
         until (eql plist :quit)
         do
         (incf count)
         (when (= 0 (mod count 100))
           (log:info "~A RESTORED ~A NODES" (current-thread) count))
         (case (car plist)
           (:v (progn
                 (setf (nth 4 plist) (transform-to-byte-vector (nth 4 plist)))
                 (apply 'make-vertex (rest plist))))
           (:e (progn
                 (setf (nth 2 plist) (transform-to-byte-vector (nth 2 plist)))
                 (setf (nth 3 plist) (transform-to-byte-vector (nth 3 plist)))
                 (setf (nth 7 plist) (transform-to-byte-vector (nth 7 plist)))
                 (apply 'make-edge (rest plist))))
           (otherwise
            (log:error "RESTORE: Unknown input: ~S" plist)))))))

(defmethod restore-experimental ((graph graph) location &key (max-threads 1)
                                 package-name)
  (let ((file location) (threads nil) (gate (sb-concurrency:make-gate :open nil))
        (restore-mboxes (make-list max-threads :initial-element
                                   (sb-concurrency:make-mailbox)))
        (start (get-universal-time)))
    (unless (probe-file file)
      (error "~S does not exist." file))
    (let ((*readtable* (copy-readtable)))
      (local-time:enable-read-macros)
      (dotimes (i max-threads)
        (push (sb-thread:make-thread
               'restore-helper
               :arguments (list (nth i restore-mboxes) package-name))
              threads))
      (with-open-file (in file)
        (do ((plist (read in nil :eof) (read in nil :eof)))
            ((eq plist :eof))
          (when (eql (car plist) :e)
            (when (not (sb-concurrency:gate-open-p gate))
              (loop until (every 'sb-concurrency:mailbox-empty-p restore-mboxes)
                 do (sleep 1))
              (sb-concurrency:open-gate gate)))
          (let ((mbox (nth (mod (sxhash (second plist)) max-threads)
                           restore-mboxes)))
            (sb-concurrency:send-message mbox plist))))
      (loop until (every 'sb-concurrency:mailbox-empty-p restore-mboxes)
         do (sleep 1))
      (dotimes (i max-threads)
        (log:info "Sending :QUIT to ~A" (nth i restore-mboxes))
        (sb-concurrency:send-message (nth i restore-mboxes) :quit))
      (loop until (notany 'thread-alive-p threads) do (sleep 1))
      (dbg "RESTORE TOOK ~A SECONDS" (- (get-universal-time) start))
      graph)))

