;; -*- Gerbil -*-
;;; © jfournier
;;; aws cloudtrail parser

(import
  :gerbil/gambit
  :gerbil/gambit/os
  :gerbil/gambit/threads
  :std/actor
  :std/db/dbi
  :std/db/postgresql
  :std/db/postgresql-driver
  :std/db/leveldb
  :std/debug/heap
  :std/debug/memleak
  :std/format
  :std/generic/dispatch
  :std/iter
  :std/logger
  :std/misc/list
  :std/misc/threads
  :std/misc/queue
  :std/net/address
  :std/net/httpd
  :std/pregexp
  :std/srfi/1
  :std/srfi/95
  :std/sugar
  :std/text/json
  :std/text/yaml
  :std/text/zlib
  :ober/oberlib)

(declare (not optimize-dead-definitions))

(def version "0.07")

(export #t)

(def db-type leveldb:)
(def nil '#(nil))
(def program-name "kunabi")
(def config-file "~/.kunabi.yaml")

(def use-write-backs #t)

(def hc-hash (make-hash-table))

(def wb (db-init))
(def db (db-open))

(def HC 0)
(def write-back-count 0)
(def max-wb-size (def-num (getenv "k_max_wb" 100000)))
(def tmax (def-num (getenv "tmax" 12)))
(def indices-hash (make-hash-table))

(def (load-config)
  (let ((config (hash)))
    (hash-for-each
     (lambda (k v)
       (hash-put! config (string->symbol k) v))
     (car (yaml-load config-file)))
    config))

(def (ls)
  (list-records))

(def (list-records)
  "Print all records"
  (let (itor (leveldb-iterator db))
    (leveldb-iterator-seek-first itor)
    (let lp ()
      (leveldb-iterator-next itor)
      (let ((key (bytes->string (leveldb-iterator-key itor)))
            (val (u8vector->object (leveldb-iterator-value itor))))
        (if (table? val)
          (displayln (format "k: ~a v: ~a" key (hash->list val)))
          (displayln (format "k: ~a v: ~a" key val))))
      (when (leveldb-iterator-valid? itor)
        (lp)))))

;; readers


(def (get-by-key key)
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek itor (format "~a" key))
    (let lp ((res '()))
      (if (leveldb-iterator-valid? itor)
        (if (pregexp-match key (bytes->string (leveldb-iterator-key itor)))
          (begin
            (set! res (cons (u8vector->object (leveldb-iterator-value itor)) res))
            (leveldb-iterator-next itor)
            (lp res))
          res)
        res))))

(def (uniq-by-prefix key)
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek itor (format "~a" key))
    (let lp ((res '()))
      (if (leveldb-iterator-valid? itor)
        (if (pregexp-match key (bytes->string (leveldb-iterator-key itor)))
          (begin
            (set! res (cons (nth 2 (pregexp-split ":" (bytes->string (leveldb-iterator-key itor)))) res))
            (leveldb-iterator-next itor)
            (lp res))
          res)
        res))))

(def (ln)
  (let (users (unique! (sort! (uniq-by-prefix "user") eq?)))
    (for-each displayln users)))

(def (lev)
  (let (events (unique! (sort! (uniq-by-prefix "event-name") eq?)))
    (for-each displayln events)))

(def (match-key key)
  (resolve-records (get-by-key key)))

(def (se event)
  (search-event event))

(def (sr event)
  (search-event event))

(def (sip event)
  (search-event event))

(def (sn event)
  (search-event event))

(def (sec event)
  (search-event event))

;; (def (lec)
;;   (list-index-entries "I-errors"))

(def (st)
  (displayln "Totals: "
             " records: " (countdb)
             " users: " (count-index "I-users")
             " errors: " (count-index "I-errors")
             " regions: " (count-index "I-aws-region")
             " events: " (count-index "I-events")
             " files: " (count-index "I-files")
             ))

(def (read file)
  (read-ct-file file))

;; (def (lr)
;;   "List regions"
;;   (list-index-entries "I-aws-region"))

(def (source-ips)
  (list-source-ips))

(def (ct file)
  (load-ct file))

(def (find-ct-files dir)
  (find-files
   dir
	 (lambda (filename)
		 (and (equal? (path-extension filename) ".gz")
			    (not (equal? (path-strip-directory filename) ".gz"))))))

(def (load-ct dir)
  "Entry point for processing cloudtrail files"
  (dp (format ">-- load-ct: ~a" dir))
  (spawn watch-heap!)
  (let* ((count 0)
	       (ct-files (find-ct-files "."))
         (pool []))
    (for (file ct-files)
      (cond-expand
        (gerbil-smp
         (while (< tmax (length (all-threads)))
           (displayln "sleeping")
           (thread-sleep! .05))
         (let ((thread (spawn (lambda () (read-ct-file file)))))
           (set! pool (cons thread pool))))
        (else
         (read-ct-file file)))
      (flush-all?)
      (set! count 0))
    (cond-expand (gerbil-smp (for-each thread-join! pool)))
    (db-write)
    (db-close)))

(def (file-already-processed? file)
  (dp "in file-already-processed?")
  (let* ((short (get-short file))
         (seen (db-key? (format "F-~a" short))))
    seen))

(def (mark-file-processed file)
  (dp "in mark-file-processed")
  (let ((short (get-short file)))
    (format "marking ~A~%" file)
    (db-batch (format "F-~a" short) "t")))

(def (load-ct-file file)
  (hash-ref
	 (read-json
		(open-input-string
		 (bytes->string
			(uncompress file))))
	 'Records))

(def (read-ct-file file)
  (ensure-db)
  (dp (format "read-ct-file: ~a" file))
  (unless (file-already-processed? file)
    (let ((btime (time->seconds (current-time)))
	        (count 0))
      (dp (memory-usage))
      (call-with-input-file file
	      (lambda (file-input)
	        (let ((mytables (load-ct-file file-input)))
            (for-each
              (lambda (row)
                (set! count (+ count 1))
                (process-row row))
              mytables))
          (mark-file-processed file)))

      (let ((delta (- (time->seconds (current-time)) btime)))
        (displayln
         "rps: " (float->int (/ count delta ))
         " size: " count
         " delta: " delta
         " threads: " (length (all-threads)))))))

(def (number-only obj)
  (if (number? obj)
    obj
    (string->number obj)))

(def (get-short str)
  (cond
   ((string-rindex str #\_)
    =>
    (lambda (ix)
      (cond
       ((string-index str #\. ix)
	      =>
        (lambda (jx)
	        (substring str (1+ ix) jx)))
       (else #f))))
   (else str)))

(def (flush-all?)
  (dp (format "write-back-count && max-wb-size ~a ~a" write-back-count max-wb-size))
  (if (> write-back-count max-wb-size)
    (begin
      (displayln "writing.... " write-back-count)
      (leveldb-write db wb)
      (set! write-back-count 0))))

(def (get-last-key)
  "Get the last key for use in compaction"
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek-last itor)
    (let lp ()
      (leveldb-iterator-prev itor)
      (if (leveldb-iterator-valid? itor)
        (bytes->string (leveldb-iterator-key itor))
        (lp)))))

(def (get-first-key)
  "Get the last key for use in compaction"
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek-first itor)
    (let lp ()
      (leveldb-iterator-next itor)
      (if (leveldb-iterator-valid? itor)
        (bytes->string (leveldb-iterator-key itor))
        (lp)))))

(def (get-next-id max)
  (let ((maxid (1+ max)))
    (if (db-key? (format "~a" maxid))
      (get-next-id (* 2 maxid))
      maxid)))

(def (inc-hc)
  "increment HC to next free id."
  (let ((next (get-next-id HC)))
    (set! HC next)
    (db-batch "HC" (format "~a" HC))))

(def (indices-report)
  (let ((total 0))
    (hash-for-each
     (lambda (k v)
       (let ((count (hash-length v)))
	       (displayln k ":" count " v: " v " first:" (hash-keys v))
	       (set! total (+ total count))))
     indices-hash)
    (displayln "indicies count total: " total)))


(def (count-index idx)
  (if (db-key? idx)
    (let* ((entries (hash-keys (db-get idx)))
           (count (length entries)))
      count)))

;; (def (list-index-entries idx)
;;   (if (db-key? idx)
;;     (let ((entries (hash-keys (db-get idx))))
;;       (if (list? entries)
;; 	      (for-each displayln (sort! entries eq?))
;; 	      (begin
;; 	        (displayln "did not get list back from entries")
;; 	        (type-of entries))))
;;     (displayln "no idx found for " idx)))

(def (resolve-records ids)
  (when (list? ids)
    (let ((outs [[ "Date" "Name" "User" "Source" "Hostname" "Type" "Request" "User Agent" "Error Code" "Error Message" ]]))
      (for (id ids)
        (let ((id2 (db-get id)))
          (when (table? id2)
            (let-hash id2
              (set! outs (cons [
                                .?time
		                            .?en
		                            .?user
		                            .?es
		                            .?sia
		                            .?et
		                            .?rp
		                            .?ua
		                            .?ec
		                            .?em
                                ] outs))))))
      (style-output outs "org-mode"))))

(def (get-host-name ip)
  (if (pregexp-match "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" ip)
    (let ((lookup (host-info ip)))
      (if (host-info? lookup)
	      (let ((lookup-name (host-info-name lookup)))
	        lookup-name)))
    ip))

(def (search-event look-for)
  (dp (format "look-for: ~a" look-for))
  (let ((index-name (format "I-~a" look-for)))
    (if (db-key? index-name)
      (let ((matches (hash-keys (db-get index-name))))
	      (resolve-records matches))
      (displayln "Could not find entry in indices-db for " look-for))))

;;;;;;;;;; vpc stuff


(def (ip? x)
  (pregexp-match "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" x))

(def (add-host-ent ip)
  (displayln ip)
  (if (ip? ip)
    (let* ((idx (format "H-~a" ip))
           (lookup (host-info ip))
           (resolved? (db-key? idx)))
      (unless resolved?
        (when (host-info? lookup)
          (let ((lookup-name (host-info-name lookup)))
            (unless (string=? lookup-name ip)
              (db-batch (format "H-~a" ip) lookup-name))))))))

(def (resolve-all-hosts)
  (let ((threads [])
        (entries (hash-keys (db-get "I-source-ip-address"))))
    (for (entry entries)
      (add-host-ent entry))))

(def (list-source-ips)
  (let (entries (sort! (hash-keys (db-get "I-source-ip-address")) eq?))
    (for (entry entries)
      (let ((hname (format "H-~a" entry)))
        (if (db-key? hname)
          (displayln (format "~a: ~a" entry (db-get hname))))))))

(def (find-user ui)
  (let ((username ""))
    (when (table? ui)
      (let-hash ui
        (let ((type (hash-get ui 'type)))
          (if type
            (cond
             ((string=? "SAMLUser" type)
              (set! username .userName))
             ((string=? "IAMUser" type)
              (set! username .userName))
             ((string=? "AWSAccount" type)
              (set! username (format "~a" .?principalId)))
             ((string=? "AssumedRole" type)
              (if (hash-key? ui 'sessionContext)
                (when (table? .?sessionContext)
                  (let-hash
                      .?sessionContext
                    (when (table? .?sessionIssuer)
                      (let-hash
                          .?sessionIssuer
                        (set! username .userName)))))
                (begin
                  (displayln (format "Fall thru find-user ~a~%" (hash->list ui)))
                  (set! username .principalId)))) ;; not found go with this for now.
             ((string=? "AWSService" type)
              (set! username (hash-get ui 'invokedBy)))
             ((string=? "Root" type)
              (set! username (format "~a invokedBy: ~a" (hash-get ui 'userName) (hash-get ui 'invokedBy))))
             ((string=? "FederatedUser" type)
              (when (table? .?sessionContext)
                (let-hash .?sessionContext
                  (when (table? .?sessionIssuer)
                    (set! username (hash-ref .?sessionIssuer 'userName))))))
             (else
              (set! username (format "Unknown Type: ~a" (hash->str ui)))))
            (displayln "error: type :" type " not found in ui" (hash->str ui))))))
    username))

(def (search-event-obj look-for)
  (let ((index-name (format "I-~a" look-for)))
    (if (db-key? index-name)
      (let ((matches (hash-keys (db-get index-name))))
        (resolve-records matches))
      (displayln "Could not find entry in indices-db for " look-for))))

(def (process-row row)
  (dp (format "process-row: row: ~a" (hash->list row)))
  (let-hash row
    (let*
        ((user (find-user .?userIdentity))
         (req-id (or .?requestID .?eventID))
         (epoch (date->epoch2 .?eventTime))
         (h (hash
             (ar .?awsRegion)
             (ec .?errorCode)
             (em .?errorMessage)
             (eid .?eventID)
             (en  .?eventName)
             (es .?eventSource)
             (time .?eventTime)
             (et .?eventType)
             (rid .?recipientAccountId)
             (rp .?requestParameters)
             (user user)
             (re .?responseElements)
             (sia .?sourceIPAddress)
             (ua .?userAgent)
             (ui .?userIdentity))))

      (set! write-back-count (+ write-back-count 1))
      (db-batch req-id h)
      (when (string? user)
        (db-batch (format "user:~a:~a" user epoch) req-id))
      (when (string? .?eventName)
        (db-batch (format "event-name:~a:~a" .?eventName epoch) req-id))
      (when (string? .?errorCode)
        (db-batch (format "errorCode:~a:~a" .errorCode epoch) req-id))
      )))

;; db stuff

(def (db-batch key value)
  (unless (string? key) (dp (format "key: ~a val: ~a" (type-of key) (type-of value))))
  (leveldb-writebatch-put wb key (object->u8vector value)))

(def (db-put key value)
  (dp (format "<----> db-put: key: ~a val: ~a" key value))
  (leveldb-put db key (object->u8vector value)))

(def (ensure-db)
  (unless db
    (set! db (db-open))))

(def (db-open)
  (dp ">-- db-open")
  (let ((db-dir (or (getenv "kunabidb" #f) (format "~a/kunabi-db/" (user-info-home (user-info (user-name)))))))
    (dp (format "db-dir is ~a" db-dir))
    (unless (file-exists? db-dir)
      (create-directory* db-dir))
    (let ((location (format "~a/records" db-dir)))
      (leveldb-open location (leveldb-options
                              paranoid-checks: #t
                              max-open-files: (def-num (getenv "k_max_files" #f))
                              bloom-filter-bits: (def-num (getenv "k_bloom_bits" #f))
                              compression: #t
                              block-size: (def-num (getenv "k_block_size" #f))
                              write-buffer-size: (def-num (getenv "k_write_buffer" (* 1024 1024 16)))
                              lru-cache-capacity: (def-num (getenv "k_lru_cache" 10000)))))))

(def (def-num num)
  (if (string? num)
    (string->number num)
    num))

(def (db-get key)
  (dp (format "db-get: ~a" key))
  (let ((ret (leveldb-get db (format "~a" key))))
    (if (u8vector? ret)
      (u8vector->object ret)
      "N/A")))

(def (db-key? key)
  (dp (format ">-- db-key? with ~a" key))
  (leveldb-key? db (format "~a" key)))

(def (db-write)
  (dp "in db-write")
  (leveldb-write db wb))

(def (db-close)
  (dp "in db-close")
  (leveldb-close db))

(def (db-init)
  (dp "in db-init")
  (leveldb-writebatch))

;; leveldb stuff
(def (get-leveldb key)
  (displayln "get-leveldb: " key)
  (try
   (let* ((bytes (leveldb-get db (format "~a" key)))
          (val (if (u8vector? bytes)
                 (u8vector->object bytes)
                 nil)))
     val)
   (catch (e)
     (raise e))))

(def (remove-leveldb key)
  (dp (format "remove-leveldb: ~a" key)))

(def (compact)
  "Compact some stuff"
  (let* ((itor (leveldb-iterator db))
         (first (get-first-key))
         (last (get-last-key)))
    (displayln "First: " first " Last: " last)
    (leveldb-compact-range db first last)))

(def (count-key key)
  "Get a count of how many records are in db"
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek-first itor)
    (let lp ((count 0))
      (leveldb-iterator-next itor)
      (if (leveldb-iterator-valid? itor)
        (begin
          (if (pregexp-match key (bytes->string (leveldb-iterator-key itor)))
            (begin
              (displayln (format "Found one ~a" (bytes->string (leveldb-iterator-key itor))))
              (lp (1+ count)))
            (lp count)))
        count))))

(def (countdb)
  "Get a count of how many records are in db"
  (let ((itor (leveldb-iterator db)))
    (leveldb-iterator-seek-first itor)
    (let lp ((count 1))
      (leveldb-iterator-next itor)
      (if (leveldb-iterator-valid? itor)
        (lp (1+ count))
        count))))

(def (repairdb)
  "Repair the db"
  (let ((db-dir (format "~a/kunabi-db/" (user-info-home (user-info (user-name))))))
    (leveldb-repair-db (format "~a/records" db-dir))))