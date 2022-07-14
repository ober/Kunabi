;; -*- Gerbil -*-
;;; © jfournier
;;; aws cloudtrail parser
package: kunabi
namespace: kunabi

(export main memo-cid rpc-db-connect db-init server)

(def nil '#(nil))

(import
  :gerbil/gambit
  :gerbil/gambit/os
  :gerbil/gambit/threads
  :std/logger
  :std/actor
  :std/db/leveldb
  :std/db/lmdb
  :std/debug/heap
  :std/debug/memleak
  :std/format
  :std/generic/dispatch
  :std/iter
  :std/misc/list
  :std/misc/lru
  :std/net/address
  :std/net/httpd
  :std/pregexp
  :std/srfi/1
  :std/srfi/95
  :std/sugar
  :std/text/json
  :std/text/zlib
  "~/kunabi/src/proto.ss"
  )

;;(import (rename-in :gerbil/gambit/os (current-time builtin-current-time)))
(def (get-lmdb key)
  (let (txn (lmdb-txn-begin env))
    (try
     (let* ((bytes (lmdb-get txn db key))
	    (val (if bytes
		   (call-with-input-u8vector (uncompress bytes) read-json)
		   nil)))
       (lmdb-txn-commit txn)
       val)
     (catch (e)
       (lmdb-txn-abort txn)
       (display e)
       (displayln "error kunabi-store-get: key:" key)
       ;;(raise e)
       ))))

(def (rpc-db-connect addr)
  (let (rpcd (start-rpc-server! proto: (rpc-cookie-proto)))
    (rpc-connect rpcd 'kunabi-store addr)))

(def (dp val)
  (if (getenv "DEBUG" #f)
    (displayln val)))

(def (db-open)
  (dp "in db-open")
  (cond
   ((equal? db-type lmdb:)
    (lmdb-open-db env "kunabi-store"))
   ((equal? db-type leveldb:)
    (unless (file-exists? db-dir)
      (create-directory* db-dir))
    (let ((location (format "~a/records" db-dir)))
      (leveldb-open location (leveldb-options
			      block-size: (def-num (getenv "k_block_size" #f))
			      write-buffer-size: (def-num (getenv "k_write_buffer_size" #f))
			      lru-cache-capacity: (def-num (getenv "k_lru_cache_capacity" #f))))))
   ((equal? db-type rpc:)
    (rpc-db-connect rpc-db-addr))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (memo-cid convo)
  (let ((cid 0))
    (if (hash-key? hc-hash convo)
      (begin ;; we are a cache hit
	(set! cid (hash-get hc-hash convo)))
      (begin ;; no hash entry
	(inc-hc)
	(db-batch wb convo HC)
	(db-batch wb (format "~a" HC) convo)
	;;(displayln "HC is " HC)
	(set! cid HC)
	(hash-put! hc-hash convo cid)
	(hash-put! hc-hash cid convo)))
    cid))


(def (def-num num)
  (if (string? num)
    (string->number num)
    num))

(def (db-init)
  (dp "in db-init")
  (cond
   ((equal? db-type lmdb:)
    (displayln "db-init lmdb noop"))
   ((equal? db-type leveldb:)
    (leveldb-writebatch))
   ((equal? db-type rpc:)
    (displayln "db-init rpc noop"))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2)))
  )

(def max-lru-size (or (getenv "LRU" #f) 10000))
(def use-write-backs #t)
(def lru-hits 0)
(def lru-misses 0)

(def db-dir (or (getenv "KUNABI" #f) ".")) ;;(format "~a/kunabi-db/" (user-info-home (user-info (user-name))))))

(def db-type lmdb:) ;;leveldb
(def rpc-db-addr "127.0.0.1:9999")

(def (want-db)
  "foo")

(setenv "GERBIL_HOME" (format "~a/gerbil" (user-info-home (user-info (user-name)))))


(def hc-hash (make-hash-table))
(def lru-miss-table (make-hash-table))
(def hc-lru (make-lru-cache (def-num max-lru-size)))
(def vpc-totals (make-hash-table))

(def records (db-open))
(def env records)
(def wb (db-init))
(def db wb)
(def HC 0)

(def write-back-count 0)


(def max-wb-size 1000)
;;(if (equal? db-type rpc:)
;; 		   1000
;; 		   200000))

(def indices-hash (make-hash-table))

(def (leveldb-set)
  (equal? db-type leveldb:))


(def (db-write db wb)
  (dp "in db-write")
  (cond
   ((equal? db-type lmdb:)
    (displayln "db-write wb lmdb: noop"))
   ((equal? db-type leveldb:)
    (leveldb-write db wb))
   ((equal? db-type rpc:)
    (displayln "db-write noop for rpc"))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (db-close db)
  (dp "in db-close")
  (cond
   ((equal? db-type lmdb:)
    (displayln "db-close lmdb:"))
   ((equal? db-type leveldb:)
    (leveldb-close db))
   ((equal? db-type rpc:)
    (displayln "db-close noop for rpc"))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (db-key? db2 key)
  (dp (format "in db-key? db2: ~a key: ~a" db2 key))
  (cond
   ((equal? db-type lmdb:)
    (or (get-lmdb key) #f))
   ((equal? db-type leveldb:)
    (leveldb-key? db2 (format "~a" key)))
   ((equal? db-type rpc:)
    (or (rpc-db-get key) #f))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (db-get db key)
  (dp (format "db-get: ~a" key))
  (cond
   ((equal? db-type lmdb:)
    (get-lmdb key))
   ((equal? db-type rpc:)
    (rpc-db-ref key))
   ((equal? db-type leveldb:)
    (let ((ret (leveldb-get db (format "~a" key))))
      (if (u8vector? ret)
	(u8vector->object ret)
	"N/A")))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (db-batch batch key value)
  ;;  (if (table? value)
  ;;    (displayln "db-batch:got table in value key:" key " value hash:"  (hash->list value)))
  ;;  (dp (format "db-batch: key: ~a value: ~a" key value))
  (cond
   ((equal? db-type lmdb:)
    (put-lmdb key value))
   ((equal? db-type rpc:)
    (rpc-db-update! key value))
   ((equal? db-type leveldb:)
    (unless (string? key) (dp (format "key: ~a val: ~a" (type-of key) (type-of value))))
    (leveldb-writebatch-put wb key (object->u8vector value)))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (db-put db2 key value)
  ;;  (dp (format "db-put: key: ~a val: ~a" key value))
  (cond
   ((equal? db-type lmdb:)
    (put-lmdb key value))
   ((equal? db-type rpc:)
    (rpc-db-put! key value))
   ((equal? db-type leveldb:)
    (leveldb-put db2 key (object->u8vector value)))
   (else
    (displayln "Unknown db-type: " db-type)
    (exit 2))))

(def (usage)
  AQA  (displayln "Usage: get-tags <verb>")
  (displayln "Verbs:")
  (displayln "	kunabi ct <directory> <write-back-entries> => Load all files in dir. ")
  (displayln "	kunabi le => List all event names. ")
  (displayln "	kunabi lec => List all Error Codes")
  (displayln "	kunabi read <file> => read in ct file")
  (displayln "	kunabi lip => List all source ips")
  (displayln "	kunabi ln => List all user names. ")
  (displayln "	kunabi lr => List all Regions")
  (displayln "	kunabi ls => list all records")
  (displayln "	kunabi lsv => list all vpc records")
  (displayln "	kunabi se <event name> => list all records of type event name")
  (displayln "	kunabi sec <error coded> => list all records of error code")
  (displayln "	kunabi sip <ip address> => list all records from ip address")
  (displayln "	kunabi sn <user name> => list all records for user name")
  (displayln "	kunabi sr <Region name> => list all records for region name")
  (displayln "  vpc -------------")
  (displayln "  kunabi lvf <vpc file> => load vpc file")
  (exit 2))

;; opens of db files

(def (main . args)
  (if (null? args)
    (usage))
  ;;(displayln "arg length " (length args))
  (let ((argc (length args))
	(verb (car args)))
    (cond
     ((string=? verb "ls")
      (want-db)
      (list-records))
     ((string=? verb "lsv")
      (want-db)(list-vpc-records))
     ((string=? verb "lvf")
      (want-db) (read-vpc-file (nth 1 args)))
     ((string=? verb "se")
      (want-db) (search-event (nth 1 args)))
     ((string=? verb "sr")
      (want-db) (search-event (nth 1 args)))
     ((string=? verb "sip")
      (want-db) (search-event (nth 1 args)))
     ((string=? verb "sn")
      (want-db) (search-event (nth 1 args)))
     ((string=? verb "summary")
      (want-db) (summary (nth 1 args)))
     ((string=? verb "sec")
      (want-db) (search-event (nth 1 args)))
     ((string=? verb "lec")
      (want-db) (list-index-entries "I-errors"))
     ((string=? verb "read")
      (want-db) (read-ct-file (nth 1 args)))
     ((string=? verb "ln")
      (want-db) (list-index-entries "I-users"))
     ((string=? verb "le")
      (want-db) (list-index-entries "I-events"))
     ((string=? verb "lr")
      (want-db) (list-index-entries "I-aws-region"))
     ((string=? verb "lip")
      (want-db) (list-source-ips))
     ((string=? verb "rah")
      (want-db) (resolve-all-hosts))
     ((string=? verb "rpc")
      (rpc))
     ((string=? verb "web")
      (web))
     ((string=? verb "summaries")
      (want-db) (summary-by-ip))
     ((string=? verb "vpc")
      (cond
       ((= argc 2)
	(load-vpc (nth 1 args)))
       ((= argc 3)
	(set! max-wb-size (string->number (nth 2 args)))
	(load-vpc (nth 1 args)))))
     ((string=? verb "ct")
      (cond
       ((= argc 2)
	(load-ct (nth 1 args)))
       ((= argc 3)
	(set! max-wb-size (string->number (nth 2 args)))
	(load-ct (nth 1 args)))
       (else
	(usage))))
     ((string=? verb "new") (display "new called"))
     (else
      (displayln "No verb matching " verb)
      (exit 2)))
    ))

(def (load-ct dir)
  ;;(##gc-report-set! #t)
  (dp (format "load-ct: ~a" dir))
  ;;  (spawn watch-heap!)
  (load-indices-hash)
  (displayln "load-ct post load-indices-hash")
  (let* ((files 0)
	 (rows 0)
	 (mod 1)
	 (etime 0)
	 (btime (time->seconds (current-time)))
	 (total-count 0)
	 (ct-files
	  (find-files dir
		      (lambda (filename)
			(and (equal? (path-extension filename) ".gz")
			     (not (equal? (path-strip-directory filename) ".gz"))))))
	 (file-count (length ct-files)))
    (for-each
      (lambda (x)
	(read-ct-file x)
	(flush-all?))
      ct-files)
    (hash-for-each
     (lambda (k v)
       (if (> v 1)
	 (displayln k ":" v)))
     lru-miss-table)
    (flush-indices-hash)
    (db-write records wb)
    (db-close records)))

(def (file-already-processed? file)
  (dp "in file-already-processed?")
  (let* ((short (get-short file))
	 (seen (db-key? records (format "F-~a" short))))
    seen))

(def (add-to-index index entry)
  (dp (format "in add-to-index index: ~a entry: ~a" index entry))
  (let ((index-in-global-hash? (hash-key? indices-hash index)))
    (dp (format  "index-in-global-hash? ~a ~a" index-in-global-hash? index))
    (if index-in-global-hash?
      (new-index-entry index entry)
      (begin
	(dp (format "ati: index not in global hash for ~a. adding" index))
	(hash-put! indices-hash index (hash))
	(let ((have-db-entry-for-index (db-key? records (format "I-~a" index))))
	  (displayln (format "have-db-entry-for-index: ~a key: I-~a" have-db-entry-for-index index))
	  (if have-db-entry-for-index
	    (update-db-index index entry)
	    (new-db-index index entry)))))))

(def (new-index-entry index entry)
  "Add entry to index in global hash"
  (dp (format "new-index-entry: ~a ~a" index entry))
  (unless (hash-key? (hash-get indices-hash index) entry)
    (hash-put! (hash-get indices-hash index) entry #t)))

(def (new-db-index index entry)
  "New index, with entry to db"
  (dp (format "new-db-index: ~a ~a" index entry))
  (let ((current (make-hash-table)))
    (hash-put! current entry #t)
    (hash-put! indices-hash index current)
    (db-batch wb (format "I-~a" index) current)))

(def (update-db-index index entry)
  "Fetch the index from db, then add our new entry, and save."
  (dp (format "update-db-index: ~a ~a" index entry))
  ;; (let ((current (db-get records (format "I-~a" index))))
  ;;   (hash-put! current entry #t)
  ;;   (hash-put! indices-hash index current)
  ;;   (displayln (format "- ~a:~a" index entry) " length hash: " (hash-length current))
  ;;   (format "I-~a" index) current))
  (rpc-db-update! index entry))

(def (mark-file-processed file)
  (dp "in mark-file-processed")
  (let ((short (get-short file)))
    (format "marking ~A~%" file)
    (db-put records (format "F-~a" short) "t")))

(def (nth n l)
  (if (or (> n (length l)) (< n 0))
    (error "Index out of bounds.")
    (if (eq? n 0)
      (car l)
      (nth (- n 1) (cdr l)))))

(def (read-ct-file file)
  (dp (format "read-ct-file: ~a" file))
  (unless (file-already-processed? file)
    (let ((lru-hits-begin lru-hits)
	  (lru-misses-begin lru-misses)
	  (btime (time->seconds (current-time)))
	  (count 0)
	  (pool []))
      (dp (format "read-ct-file: ~a" file))
      (dp (memory-usage))
      (call-with-input-file file
	(lambda (file-input)
	  (let ((mytables (hash-ref
			   (read-json
			    (open-input-string
			     (bytes->string
			      (uncompress file-input))))
			   'Records)))
	    (for-each
	      (lambda (row)
		(set! count (+ count 1))
		(rpc-process-row row))
	      mytables)
	    ;;(for-each
	    ;;(lambda (t)
	    ;;(thread-join! t))
	    ;;pool)
	    )))
      (mark-file-processed file)
      (displayln "rps: "
		 (float->int (/ count (- (time->seconds (current-time)) btime))))
      (print-lru-stats lru-hits-begin lru-misses-begin))))

(def (number-only val)
  (cond ((string? val)
	 (number->string val))
	((number? val)
	 val)))

(def (print-lru-stats begin-hits begin-misses)
  (let* ((lru-hits-file (- lru-hits begin-hits))
	 (lru-misses-file (- lru-misses begin-misses))
	 (lru-totals (+ lru-hits-file lru-misses-file))
	 (lru-hit-percent 0)
	 (lru-miss-percent 0))
    (when (> lru-totals 0)
      (set! lru-hit-percent (float->int (* (/ lru-hits-file lru-totals) 100)))
      (set! lru-miss-percent (float->int (* (/ lru-misses-file lru-totals) 100)))
      (displayln
       " lru % used: "
       (float->int (* (/ (lru-cache-size hc-lru) (def-num max-lru-size)) 100))
       " lru misses: " lru-misses-file
       " lru hits: " lru-hits-file
       " hit %: " lru-hit-percent
       " miss %: " lru-miss-percent))))




(def (get-short str)
  (cond
   ((string-rindex str #\_)
    => (lambda (ix)
	 (cond
	  ((string-index str #\. ix)
	   => (lambda (jx)
		(substring str (1+ ix) jx)))
	  (else #f))))
   (else str)))

(def (my-type-of obj)
  (cond
   ((table? obj)
    (format "is a table"))
   ((list? obj)
    (format "is a list"))
   ((string? obj)
    (format "is a string"))
   ((char? obj)
    (format "is a char"))
   ((procedure? obj)
    (format "is a procedure"))
   ((u8vector? obj)
    (format "is a u8vector"))
   ((number? obj)
    (format "is a number"))
   ((real? obj)
    (format "is a real"))
   ((symbol? obj)
    (format "is a symbol"))
   ((vector? obj)
    (format "is a vector"))
   ;;((negative? obj)
   ;;   (format "is a negative"))
   ;;((zero? obj)
   ;;   (displayln (format "is a zero"))
   ((keyword? obj)
    (format "is a keyword"))
   ((boolean? obj)
    (format "is a boolean"))
   ((positive? obj)
    (format "is a positive"))
   ((object? obj)
    (format "is a object"))
   ((object? obj)
    (format "is a object"))
   ((true? obj)
    (format "is a true"))
   ((exception? obj)
    (format "is an exception"))
   ((null? obj)
    (format "is a null"))
   (else
    (format "is UNKNOWN: ~a " obj))))

(define 101-fields (list
		    'awsRegion
		    'eventID
		    'eventName
		    'eventSource
		    'eventTime
		    'eventType
		    'recipientAccountId
		    'requestID
		    'requestParameters
		    'responseElements
		    'sourceIPAddress
		    'userAgent
		    'userIdentity))


(def (getf field row)
  (hash-get row field))

(def (get-val hcn)
  "Derefernce if a valid key in db. otherwise return"
  (dp (format "get-val: ~a string?:~a number?~a" hcn (string? hcn) (number? hcn)))
  (let* ((ret "N/A")
	 (hcn-safe (format "~a" hcn))
	 (in-lru (lru-cache-get hc-lru hcn-safe)))
    (cond
     ((table? hcn)
      (set! ret hcn))
     ((void? hcn)
      (set! ret 0))
     ((lru-cache-get hc-lru hcn-safe)
      (dp "in-lru")
      (set! ret in-lru))
     ((and (string=? "0" hcn-safe))
      (dp "hcn is 0")
      (set! ret "0"))
     ((db-key? records hcn-safe)
      (let ((db-val (db-get records hcn-safe)))
	(dp (format "db-val: ~a ~a" db-val hcn-safe) )
	(set! ret db-val)
	(lru-cache-put! hc-lru hcn-safe db-val)
	))
     (else
      (dp (format "get-val: unknown hcn pattern: ~a" hcn-safe))))
    ret))

(def (miss-add val)
  (if (hash-key? lru-miss-table val)
    (hash-put! lru-miss-table val (+ 1 (hash-get lru-miss-table val)))
    (hash-put! lru-miss-table val 1))
  (set! lru-misses (+ lru-misses 1)))

(def (add-val val)
  "Convert an object to an index id.
  If hash, return 0, as we can't handle those yet"
  (cond
   ((boolean? val)
    0)
   ((void? val)
    0)
   ((table? val)
    (dp (format "Can't have table as key: ~a"  (hash->list val)))
    0)
   ((string? val)
    (let ((hc-lru-entry (lru-cache-get hc-lru val))
	  (hcn 0))
      (if hc-lru-entry
	(begin ;; in cache
	  (set! lru-hits (+ lru-hits 1))
	  (set! hcn hc-lru-entry))
	(begin ;; lru miss. if in db, fetch, push onto lru, if not, add to db, push to lru
	  (dp (format "add-val: ~a " val))
	  (miss-add val)
	  ;;(displayln val)
	  (set! hcn (add-val-db-lru val))))
      hcn))
   (else
    (begin
      (dp (type-of val))
      (dp (my-type-of val))
      0))))

(def (add-val-db-lru val)
  (let ((seen (db-key? records val))
	(hcn 0))
    (if seen
      (set! hcn (db-get records val))
      (begin ;; not seen. need to bump HC and use new HC
	(dp (format "db miss: ~a" val))
	(inc-hc)
	(set! hcn HC)
	(db-batch wb val HC)
	(db-batch wb (format "~a" HC) val)))
    (lru-cache-put! hc-lru val hcn)
    hcn))

(def (add-val-db val)
  (set! db-type lmdb:)
  (displayln "add-val-db: val: " val " db-type: " db-type)
  (let ((seen (db-key? records val))
	(hcn 0))
    (if seen
      (set! hcn (db-get records val))
      (begin ;; not seen. need to bump HC and use new HC
	(inc-hc)
	(set! hcn HC)
	(db-batch wb val HC)
	))
    hcn))


(def (flush-all?)
  (dp (format "write-back-count && max-wb-size ~a ~a" write-back-count max-wb-size))
  (if (> write-back-count max-wb-size)
    (begin
      (displayln "writing.... " write-back-count)
      ;;(type-of (car (##process-statistics)))
      (time (flush-indices-hash))
      (time (db-write records wb))
      (set! write-back-count 0))))

(def (get-next-id max)
  (let ((maxid (1+ max)))
    (if (db-key? records (format "~a" maxid))
      (get-next-id maxid)
      maxid)))

(def (inc-hc)
  ;; increment HC to next free id.
  (set! HC (get-next-id HC))
  (db-put records "HC" (format "~a" HC)))

(def (indices-report)
  (let ((total 0))
    (hash-for-each
     (lambda (k v)
       (let ((count (hash-length v)))
	 (displayln k ":" count " v: " v " first:" (hash-keys v))
	 (set! total (+ total count))))
     indices-hash)
    (displayln "idicies count total: " total)))

(def (load-indices-hash)
  (dp (format "in load-indices-hash: INDICES:~a" (db-key? records "INDICES")))
  (inc-hc)
  (if (= (hash-length indices-hash) 0)
    (let ((has-key (db-key? records "INDICES")))
      (displayln "has-key " has-key)
      (if has-key
	(begin ;; load it up.
	  (dp (format "load-indices-hash records has no INDICES entry"))
	  (let ((indices (db-get records "INDICES")))
	    (dp (hash->list indices))
	    (for-each
	      (lambda (index)
		(displayln (format "index: ~a" index))
		(let ((index-int (db-get records index)))
		  (hash-put! indices-hash index index-int)))
	      indices)))))
    (displayln "No INDICES entry. skipping hash loading")))

(def (flush-indices-hash)
  (let ((indices (make-hash-table)))
    (for-each
      (lambda (index)
	(db-batch wb (format "I-~a" index) (hash-get indices-hash index))
	(hash-put! indices index #t))
      (hash-keys indices-hash))
    (db-put records "INDICES" indices)))

(def (flush-vpc-totals)
  (for-each
    (lambda (cid)
      (db-batch wb (format "~a" cid) (hash-get vpc-totals cid)))
    (hash-keys vpc-totals)))

(def (list-records)
  (def itor (leveldb-iterator records))
  (leveldb-iterator-seek-first itor)
  (while (leveldb-iterator-valid? itor)
    (let ((val (u8vector->object (leveldb-iterator-value itor)))
	  (key (leveldb-iterator-key itor)))
      (print-record val)
      (leveldb-iterator-next itor)))
  (leveldb-iterator-close itor))

(def (list-vpc-records)
  (def itor (leveldb-iterator records))
  (leveldb-iterator-seek-first itor)
  (while (leveldb-iterator-valid? itor)
    (begin
      (print-record
       (leveldb-iterator-value itor))
      (leveldb-iterator-next itor)))
  (leveldb-iterator-close itor))

(def (list-index-entries idx)
  (if (db-key? records idx)
    (let ((entries (hash-keys (db-get records idx))))
      (if (list? entries)
	(for-each
	  (lambda (x)
	    (displayln x))
	  (sort! entries eq?))
	(begin
	  (displayln "did not get list back from entries")
	  (my-type-of entries))))
    (displayln "no idx found for " idx)))

(def (resolve-records ids)
  (if (list? ids)
    (begin
      (displayln "| date                 | name      | user   |  source | hostname| type| request| user-agent| error-code | error-messages |")
      (displayln "|----------------------+-----------+-------------------+--------------+------------+--------------------+----------------------+------------+---------------|")
      (for-each
	(lambda (id)
	  (let ((id2 (get-val id)))
	    ;;	    (displayln "resolve-records: id: " id " id2: " (hash->list id2))
	    (if (table? id2)
	      (print-record id2))))
	ids))))

(def (get-host-name ip)
  (if (pregexp-match "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" ip)
    (let ((lookup (host-info ip)))
      (if (host-info? lookup)
	(let ((lookup-name (host-info-name lookup)))
	  lookup-name)))
    ip))

(def (print-record row)
  (if (table? row)
    (let-hash row
      (displayln "|"
		 .event-time
		 "|"
		 (get-val-t .?event-name)
		 "|"
		 (get-val-t .?user)
		 "|"
		 (get-val-t .?event-source)
		 "|"
		 (get-val-t .?source-ip-address)
		 "|"
		 (get-val-t .?event-type)
		 "|"
		 (get-val-t .?request-parameters)
		 "|"
		 (get-val-t .?user-agent)
		 "|"
		 (get-val-t .?error-code)
		 "|"
		 (get-val-t .?error-message)
		 "|"
		 ))))

(def (stringify-hash h)
  (let ((results '()))
    (if (table? h)
      (begin
	(hash-for-each
	 (lambda (k v)
	   (set! results (append results (list (format " ~a->" k) (format "~a	" v)))))
	 h)
	(append-strings results))
      ;;	(pregexp-replace "\n" (append-strings results) "\t"))
      "N/A")))

(def (search-event look-for)
  (dp (format "look-for: ~a" look-for))
  (let ((index-name (format "I-~a" look-for)))
    (if (db-key? records index-name)
      (let ((matches (hash-keys (db-get records index-name))))
	;;	(displayln matches)
	(resolve-records matches))
      (displayln "Could not find entry in indices-db for " look-for))))

(def (flatten x)
  (cond ((null? x) '())
	((pair? x) (append (flatten (car x)) (flatten (cdr x))))
	(else (list x))))

(def (process-vpc-row row)
  (with ([ date
	   version
	   account_id
	   interface-id
	   srcaddr
	   dstaddr
	   srcport
	   dstport
	   protocol
	   packets
	   bytez
	   start
	   end
	   action
	   status
	   ] (string-split row #\space))
    (let* ((convo (format "C-~a-~a-~a-~a-~a" srcaddr srcport dstaddr dstport protocol))
	   (cid (memo-cid convo)))
      (add-bytez cid bytez)
      )))

(def (add-bytez cid bytez)
  (if (hash-key? vpc-totals cid)
    (begin ;; we have this key, let's update total
      (let ((total (hash-get vpc-totals cid)))
	(hash-put! vpc-totals cid (+ (def-num total) (def-num bytez)))))
    (begin ;; new entry to be created and total
      (hash-put! vpc-totals cid bytez))))


(def (read-vpc-file file)
  (let ((count 0)
	(bundle 100000)
	(btime 0)
	(etime 0)
	)
    (unless (file-already-processed? file)
      (begin
	(call-with-input-file file
	  (lambda (file-input)
	    (let ((data (time (bytes->string (uncompress file-input)))))
	      (for-each
		(lambda (row)
		  (set! count (1+ count))
		  (if (= (modulo count bundle) 0)
		    (begin
		      (set! etime (time->seconds (current-time)))
		      (display #\return)
		      (displayln (format "rps: ~a count:~a" (float->int (/ bundle (- etime btime))) count))
		      (set! btime (time->seconds (current-time)))))
		  (process-vpc-row row))
		(time (string-split data #\newline))))))
	))
    count))

(def (load-vpc dir)
  (displayln "load-vpc: dir: " dir)
  (let ((files 0)
	(rows 0)
	(btime 0)
	(total-count 0)
	(etime 0))
    (for-each
      (lambda (x)
	(displayln ".+")
	(let* ((btime (time->seconds (current-time)))
	       (rows (read-vpc-file x))
	       (etime (time->seconds (current-time))))
	  (displayln "rows: " rows)
	  (set! total-count (+ total-count rows))
	  (set! files (+ files 1))
	  (mark-file-processed x)
	  (flush-vpc-totals)
	  ))
      (find-files dir
		  (lambda (filename)
		    (and (equal? (path-extension filename) ".gz")
			 (not (equal? (path-strip-directory filename) ".gz"))))))
    (flush-vpc-totals)
    (db-write records wb)
    (db-close records)
    (displayln "Total: " total-count)))

(def (summary-by-ip)
  (for-each
    (lambda (x)
      (summary x)
      (displayln ""))
    (sort! (hash-keys (db-get records "I-source-ip-address")) eq?)))

(def (ip? x)
  (pregexp-match "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}" x))

(def (add-host-ent ip)
  (displayln ip)
  (if (ip? ip)
    (let* ((idx (format "H-~a" ip))
	   (lookup (host-info ip))
	   (resolved? (db-key? records idx)))
      (unless resolved?
	(if (host-info? lookup)
	  (let ((lookup-name (host-info-name lookup)))
	    (unless (string=? lookup-name ip)
	      (db-put records (format "H-~a" ip) lookup-name))))))))

(def (resolve-all-hosts)
  (let ((threads []))
    (for-each
      (lambda (x)
	(add-host-ent x))
      (hash-keys (db-get records "I-source-ip-address")))))

(def (list-source-ips)
  (for-each
    (lambda (x)
      (let ((hname (format "H-~a" x)))
	(if (db-key? records hname)
	  (displayln (format "~a: ~a" x (db-get records hname))))))
    (sort! (hash-keys (db-get records "I-source-ip-address")) eq?)))

(def (find-user ui)
  (let ((username ""))
    (when (table? ui)
      (let-hash
	  ui
	(let ((type (hash-get ui 'type)))
	  (if type
	    (cond
	     ((string=? "IAMUser" type)
	      (set! username .userName))
	     ((string=? "AWSAccount" type)
	      (set! username (format "~a-~a" .accountId .principalId)))
	     ((string=? "AssumedRole" type)
	      (if (hash-key? ui 'sessionContext)
		(let-hash
		    .sessionContext
		  (let-hash
		      .sessionIssuer
		    (set! username .userName)))
		(begin ;; not found
		  (displayln "could not find username. " (hash->list ui)))))
	     ((string=? "AWSService" type)
	      (set! username (hash-get ui 'invokedBy)))
	     ((string=? "Root" type)
	      (set! username (format "~a invokedBy: ~a" (hash-get ui 'userName) (hash-get ui 'invokedBy))))
	     ((string=? "FederatedUser" type)
	      (let-hash ui
		(let-hash .sessionContext
		  (set! username (hash-ref .sessionIssuer 'userName)))))
	     (else
	      (set! username (format "Unknown Type: ~a" (stringify-hash ui)))))
	    (displayln "error: type :" type " not found in ui" (stringify-hash ui))))))
    username))

(def vpc-fields '(
		  bytez
		  date
		  dstaddr
		  dstport
		  endf
		  interface-id
		  packets
		  protocol
		  srcaddr
		  srcport
		  start
		  status
		  action
		  ))

(def (search-event-obj look-for)
  (let ((index-name (format "I-~a" look-for)))
    (if (db-key? records index-name)
      (let ((matches (hash-keys (db-get records index-name))))
	(resolve-records matches))
      (displayln "Could not find entry in indices-db for " look-for))))

(def (find-files path
		 (pred? true)
		 recurse?: (recurse? true)
		 follow-symlinks?: (follow-symlinks? #f))
  (with-list-builder (collect!)
		     (walk-filesystem-tree! path
					    (λ (file) (when (pred? file) (collect! file)))
					    recurse?: recurse?
					    follow-symlinks?: follow-symlinks?)))

(def (walk-filesystem-tree!
      path
      visit
      recurse?: (recurse? true)
      follow-symlinks?: (follow-symlinks? #f))
  (visit path)
  (when (and (ignore-errors (path-is-directory? path follow-symlinks?))
	     (recurse? path))
    (for-each!
     (directory-files path)
     (λ (name) (walk-filesystem-tree!
		(path-expand name path) visit
		recurse?: recurse? follow-symlinks?: follow-symlinks?)))))

(defalias λ lambda)

(defrules ignore-errors ()
  ((_ form ...) (with-catch (λ (_) #f) (λ () form ...))))

(def (for-each! list fun)
  (match list
    ([elem . more] (fun elem) (for-each! more fun))
    (_ (void))))

(defrules with-list-builder ()
  ((_ (c r) body1 body+ ...) (call-with-list-builder (λ (c r) body1 body+ ...)))
  ((_ (c) body1 body+ ...) (with-list-builder (c _) body1 body+ ...)))

(def (subpath top . sub-components)
  (path-expand (string-join sub-components "/") top))

(def (path-is-symlink? path)
  (equal? 'symbolic-link (file-info-type (file-info path #f))))

(def (path-is-not-symlink? path)
  (not (path-is-symlink? path)))

(def (path-is-file? path (follow-symlinks? #f))
  (equal? 'regular (file-info-type (file-info path follow-symlinks?))))

(def (path-is-directory? path (follow-symlinks? #f))
  (equal? 'directory (file-info-type (file-info path follow-symlinks?))))

(def (float->int num)
  (inexact->exact
   (round num)))

(def (inc-hash hashy key)
  (dp (format "~a:~a" (hash->list hashy) key))
  (if (hash-key? hashy key)
    (hash-put! hashy key (+ 1 (hash-get hashy key)))
    (hash-put! hashy key 1)))

(def (summary key)
  (let ((sum (hash)))
    (for-each
      (lambda (i)
	(if (db-key? records (format "~a" i))
	  (let ((row (u8vector->object (leveldb-get records (format "~a" i)))))
	    (if (table? row)
	      (let-hash row
		(dp (format "~a" (hash->list row)))
		(inc-hash sum (get-val .event-name))
		(inc-hash sum (get-val .event-type))
		(inc-hash sum (get-val .user))
		(inc-hash sum (get-val .source-ip-address))
		(inc-hash sum (get-val .error-message))
		(inc-hash sum (get-val .error-code))
		(inc-hash sum (get-val .aws-region))
		)))
	  (displayln "No index for " i)))
      ;;  (sort! (hash-keys (db-get records (format "I-~a" key))) string<?))
      (hash-keys (db-get records (format "I-~a" key))))
    (display  (format " ~a: " key))
    (if (ip? key) (display (db-get records (format "H-~a" key))))
    (hash-for-each
     (lambda (k v)
       (display (format " ~a:~a " k v)))
     sum)))


(def (web)
  (let* ((address "127.0.0.1:8080")
	 (httpd (start-http-server! address mux: (make-default-http-mux default-handler))))
    (http-register-handler httpd "/names" names-handler)
    (thread-join! httpd)))

(def (names-handler req res)
  (let* ((content-type
	  (assget "Content-Type" (http-request-headers req)))
	 (headers
	  (if content-type
	    [["Content-Type" . content-type]]
	    [])))
    (http-response-write res 200 headers
			 (http-request-body req))))

(def (default-handler req res)
  (http-response-write res 404 '(("Content-Type" . "text/plain"))
		       "these aren't the droids you are looking for.\n"))


;; RPC method here
;; cribbed from kunabi-storec.ss
;; (def (rpc-db-connect addr)
;;   (let (rpcd (start-rpc-server! proto: (rpc-cookie-proto)))
;;     (rpc-connect rpcd 'kunabi-store addr)))


(def (rpc-db-get key)
  (dp (format "rpc-db-get: ~a: " key))
  (!!kunabi-store.get records key))

(def (rpc-process-row row)
  (dp (format "rpc-process-row: ~a: " row))
  (!!kunabi-store.process-row records row))

;;    (if val
;;      (if (string? val)
;;	(string->json-object val)
;;	val))))

(def (rpc-db-ref key)
  (dp (format "rpc-db-ref: ~a" key))
  (let* ((val ""))
    (try
     (let ((test-val (!!kunabi-store.ref records key)))
       (set! val test-val)) ;; (string->json-object test-val)))
     (catch (e)
       (set! val #f)))
    val))

(def (rpc-db-put! key val)
  (if (table? val)
    (let ((size (hash-length val)))
      (when (> size 10000)
	(dp (format "key: ~a val length: ~a" key size)))))
  (!!kunabi-store.put! records key val)) ;;(json-object->string val)))

(def (rpc-db-update! key val)
  (dp (format "rpc-db-update! key: ~a val: ~a" key (if (table? val) (hash-length val) val)))
  (!!kunabi-store.update! records key val))

(def (rpc-db-remove! key)
  (!!kunabi-store.remove! records key))

;; ;; rpc server

(def (server rpcd env)
  (def db (lmdb-open-db env "kvstore"))
  (def nil '#(nil))

  (def (process-row row)
    (dp (format "process-row: row: ~a" (hash->list row)))
    (let-hash row
      (let*
	  ((user (find-user .?userIdentity))
	   (req-id (number->string (add-val-db (or .?requestID .?eventID)))))
	(displayln "got row: " row))))
  ;;    (h (hash
  ;; 	 (aws-region (add-val .?awsRegion))
  ;; 	 (error-code (add-val .?errorCode))
  ;; 	 (error-message (add-val .?errorMessage))
  ;; 	 (event-id .?eventID)
  ;; 	 (event-name (add-val .?eventName))
  ;; 	 (event-source (add-val .?eventSource))
  ;; 	 (event-time .?eventTime)
  ;; 	 (event-type (add-val .?eventType))
  ;; 	 (recipient-account-id (add-val .?recipientAccountId))
  ;; 	 (request-parameters .?requestParameters)
  ;; 	 (user (add-val user))
  ;; 	 (response-elements .?responseElements)
  ;; 	 (source-ip-address (add-val .?sourceIPAddress))
  ;; 	 (user-agent (add-val .?userAgent))
  ;; 	 (user-identity .?userIdentity))))

  ;; (set! write-back-count (+ write-back-count 1))
  ;; (dp (format "process-row: doing db-batch on req-id: ~a on hash ~a" req-id (hash->list h)))
  ;; (spawn
  ;;  (lambda ()
  ;;    (db-batch wb req-id h)
  ;;    (dp (format "------------- end of batch of req-id on hash ----------"))
  ;;    (when (string? .?errorCode)
  ;;      (begin
  ;; 	 (add-to-index "errors" .?errorCode)
  ;; 	 (add-to-index .?errorCode req-id)))
  ;;    (add-to-index "source-ip-address" .sourceIPAddress)
  ;;    (add-to-index .sourceIPAddress req-id)
  ;;    (add-to-index "users" user)
  ;;    (add-to-index user req-id)
  ;;    (add-to-index "events" .eventName)
  ;;    (add-to-index .eventName req-id)
  ;;    (add-to-index "aws-region" .awsRegion)
  ;;    (add-to-index .awsRegion req-id)))))))

  (def wb (leveldb-writebatch))


  (def (get key)
    (dp (format  "get: ~a" key))
    (cond
     ((equal? db-type lmdb:)
      (get-lmdb key))
     ((equal? db-type leveldb:)
      (displayln "stub for get in get for leveldb: " key))))
  ;;(get-leveldb key))

  (def (put! key val)
    (dp (format "put!: ~a ~a" key val))
    (cond
     ((equal? db-type lmdb:)
      (put-lmdb key val))
     ((equal? db-type leveldb:)
      (put-leveldb key val))))

  (def (update! key val)
    (cond
     ((equal? db-type lmdb:)
      (update-lmdb key val))
     ((equal? db-type leveldb:)
      (update-leveldb key val))))

  (def (remove! key)
    (cond
     ((equal? db-type lmdb:)
      (remove-lmdb key))
     ((equal? db-type leveldb:)
      (remove-leveldb key))))

  (def (get-leveldb key)
    (displayln "get-leveldb: " key))
  ;; (try
  ;;  (let* ((bytes (leveldb-get db (format "~a" key)))
  ;; 	    (val (if (u8vector? bytes)
  ;; 		   (u8vector->object bytes)
  ;; 		   nil)))
  ;;    val)
  ;;  (catch (e)
  ;;    (raise e))))

  (def (put-leveldb key val)
    (displayln "put-leveldb: " key " " val))
  ;; (try
  ;;  (leveldb-put db key (object->u8vector val))
  ;;  (catch (e)
  ;;    (raise e))))

  (def (update-leveldb key val)
    (put-leveldb key val))

  (def (remove-leveldb key)
    (dp (format "remove-leveldb: ~a" key)))

  (def (update-lmdb key val)
    (let* ((txn (lmdb-txn-begin env))
	   (bytes (lmdb-get txn db key))
	   (current (if bytes
		      (call-with-input-u8vector (uncompress bytes) read-json)
		      nil))
	   (new (if (table? current)
		  (hash-put! current val #t)))
	   (final (compress (call-with-output-u8vector [] (cut write-json new <>)))))
      ;;(bytes (call-with-output-u8vector [] (cut write-json val <>)))
      ;; (bytes (compress bytes))
      (try
       (lmdb-put txn db key final)
       (lmdb-txn-commit txn)
       (catch (e)
	 (lmdb-txn-abort txn)
	 (raise e)))))

  (def (remove-lmdb key)
    (displayln "remove! key:" key)
    (let (txn (lmdb-txn-begin env))
      (try
       (lmdb-del txn db key)
       (lmdb-txn-commit txn)
       (catch (e)
	 (lmdb-txn-abort txn)
	 (raise e)))))

  (rpc-register rpcd 'kunabi-store)

  (while #t
    (<-
     ((!kunabi-store.get key k)
      (try
       (let ((val (get key)))
	 (if (eq? val nil)
	   #f
	   val)
	 (!!value val k))
       (catch (e)
	 (log-error "kunabi-store.get" e)
	 (!!error (error-message e) k))))

     ((!kunabi-store.ref key k)
      (try
       (let (val (get key))
	 (if (eq? val nil)
	   (!!error "No object associated with key" k)
	   (!!value val k))
         (catch (e)
	   (log-error "kunabi-store.ref" e)
           ))))
	   ;;(!!error (error-message e) k)))))

     ;; ((!kunabi-store.process-row row k)
     ;;  (try
     ;;   (let (val (process-row row))
     ;; 	 (if (eq? val nil)
     ;; 	   (!!error "Error on process-row call" k)
     ;; 	   (!!value val k)))
     ;;   (catch (e)
     ;; 	 (log-error "kunabi-store.process-row" e)
     ;; 	 (!!error (error-message e) k))))

     ((!kunabi-store.update! key val k)
      (try
       (put! key val)
       (!!value (void) k)
       (catch (e)
	 (displayln "error kunabi-store-update: key:" key " val:" val)
	 (log-error "kunabi-store.update!" e)
	 (!!error (error-message e) k))))

     ((!kunabi-store.put! key val k)
      (try
       (put! key val)
       (!!value (void) k)
       (catch (e)
	 (displayln "error kunabi-store-put: key:" key " val:" val)
	 (log-error "kunabi-store.put!" e)
	 (!!error (error-message e) k))))

     ((!kunabi-store.remove! key k)
      (try
       (remove! key)
       (!!value (void) k)
       (catch (e)
	 (log-error "kunabi-store.remove!" e)
	 (!!error (error-message e) k))))
     (what
      (warning "Unexpected message: ~a " what)))))

(def (rpc . args)
  (try
   (start-logger!)
   (let* ((rpcd (start-rpc-server! "127.0.0.1:9999" proto: (rpc-cookie-proto)))
	  (env (lmdb-open "./kunabi-store" mapsize: 100000000000)))
     (spawn server rpcd env)
     (thread-join! rpcd))
   (catch (uncaught-exception? exn)
     (display-exception (uncaught-exception-reason exn) (current-error-port)))))

(def (get-val-t val)
  (let ((res (get-val val)))
    (if (table? res)
      (hash->list res)
      res)))