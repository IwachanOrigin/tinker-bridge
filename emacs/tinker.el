;;; tinker.el --- WSL remote file editing via tinker-bridge -*- lexical-binding: t -*-

;;; Commentary:
;; WSL状のファイルをWindows側のemacsから編集するためのパッケージ

;;; Code:

;; -----------------
;; Custome variable
;; -----------------

(defgroup tinker nil
  "WSL remote file editing via tinker-bridge"
  :group 'files)

(defcustom tinker-host "127.0.0.1"
  "tinker-bridge のホスト名またはIPアドレス"
  :type 'string
  :group 'tinker)

(defcustom tinker-port 7070
  "tinker-bridge が listen する TCP ポート番号"
  :type 'integer
  :group 'tinker)

(defcustom tinker-bridge-executable "tinker-bridge"
  "tinker-bridge バイナリのパス. nilなら自動起動しない"
  :type 'string
  :group 'tinker)

;; -----------------
;; internal variable
;; -----------------

(defvar tinker--connection nil
  "tinker-bridgeへのtcp ネットワークプロセス")

(defvar tinker--request-id 0
  "リクエストIDのカウンタ")

(defvar tinker--pending-requests (make-hash-table : test 'equal)
  "id -> callback の対応表. レスポンス待ちリクエストを管理する")

(defvar tinker--recv-buffer ""
  "受信途中のデータを蓄積するバッファ")

(defvar-local tinker-remote-path nil
  "このバッファが対応するwsl上のファイルパス")

;; -----------------
;; 接続管理
;; -----------------

(defun tinker--connect ()
  "tinker-bridge に TCP 接続する. すでに接続済みなら何もしない"
  (when (or (null tinker--connection)
            (not (process-live-p tinker--connectin)))
    (message "tinker: connecting to %s:%d..." tinker-host tinker-port)
    (setq tinker--recv-buffer "")
    (setq tinker--connection
          (make-network-process
           :name "tinker-bridge"
           :host tinker-host
           :service tinker-port
           :coding 'utf-8
           :filter #'tinker--filter
           :sentinel #'tinker--sentinel
           :nowait nil))
    (message "tinker: connected.")))

(defun tinker--sentinel (_proc event)
  "接続状態の変化を処理する"
  (message "tinker: connection event: %s" (string-trim event))
  (when (string-match-p "\\(closed\\|failed\\|broken\\)" event)
    (setq tinker--connection nil)
    (clrhash tinker--pending-requests)
    (setq tinker--recv-buffer "")))

(provide 'tinker)

;;; tinker.el ends here
