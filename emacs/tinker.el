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

(defvar tinker--pending-requests (make-hash-table :test 'equal)
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
            (not (process-live-p tinker--connection)))
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

(defun tinker--filter (_proc data)
  "受信データを処理する。\\n区切りでJSONを切り出してディスパッチ"
  (setq tinker--recv-buffer (concat tinker--recv-buffer data))
  (while (string-match "\n" tinker--recv-buffer)
    (let* ((pos (match-beginning 0))
           (line (substring tinker--recv-buffer 0 pos)))
      (setq tinker--recv-buffer (substring tinker--recv-buffer (1+ pos)))
      (tinker--dispatch (json-parse-string line :object-type 'alist)))))

(defun tinker--dispatch (response)
  "レスポンスを対応するコールバックへ渡す"
  (let* ((id (alist-get 'id response))
         (callback (gethash id tinker--pending-requests)))
    (when callback
      (remhash id tinker--pending-requests)
      (funcall callback response))))

;; -----------------
;; リクエスト送信
;; -----------------

(defun tinker--send (op path &optional content callback)
  "OP/PATH/CONTENT を JSON で送信し、CALLBACK を登録する"
  (tinker--connect)
  (setq tinker--request-id (1+ tinker--request-id))
  (let* ((id tinker--request-id)
         (req (let ((h (make-hash-table :test 'equal)))
                (puthash "id"    id   h)
                (puthash "op"    op   h)
                (puthash "path"  path h)
                (when content (puthash "content" content h))
                h))
         (json-str (concat (json-serialize req) "\n")))
    (when callback
      (puthash id callback tinker--pending-requests))
    (process-send-string tinker--connection json-str)))

;; -----------------
;; ファイル一覧
;; -----------------

;;;###autoload
(defun tinker-list (path)
  "WSL上のPATHのファイル一覧を取得してバッファへ表示する"
  (interactive "sWSL path: ")
  (tinker--send "list" path nil
                (lambda (res)
                       (if (eq (alist-get 'ok res) t)
                           (let* ((raw (alist-get 'content res))
                                  (entries (json-parse-string raw :array-type 'list
                                                              :object-type 'alist))
                                  (buf (get-buffer-create "*tinker-list*")))
                             (with-current-buffer buf
                               (read-only-mode -1)
                               (erase-buffer)
                               (insert (format "Directory: %s\n\n" path))
                               (dolist (entry entries)
                                 (let ((name (alist-get 'name entry))
                                       (type (alist-get 'type entry)))
                                   (insert (format " [%s] %s\n"
                                                   (if (equal type "dir") "d" "f")
                                                   name))))
                               (read-only-mode 1)
                               (goto-char (point-min)))
                             (display-buffer buf))
                         (message "tinker-list error: %s" (alist-get 'error res))))))

;; -----------------
;; ファイルを開く(open / read)
;; -----------------

;;;###autoload
(defun tinker-find-file (path)
  "WSL上のPATHをEmacsバッファとして開く"
  (interactive "sWSL file path: ")
  (tinker--send "read" path nil
                (lambda (res)
                  (if (eq (alist-get 'ok res) t)
                      (let ((buf (tinker--get-or-create-buffer path)))
                        (with-current-buffer buf
                          (let ((inhibit-read-only t))
                            (erase-buffer)
                            (insert (alist-get 'content res))
                            (set-buffer-modified-p nil)
                            (goto-char (point-min))
                            ;; ファイル名からメジャーモードを推定
                            (let ((auto-mode-alist auto-mode-alist))
                              (set-auto-mode))
                            ;; ローカル変数にパスを記録
                            (setq-local tinker-remote-path path)))
                        (switch-to-buffer buf)
                        (message "tinker: opened %s" path))
                    (message "tinker: read error: %s" (alist-get 'error res))))))

(defun tinker--get-or-create-buffer (path)
  "PATHに対応するバッファを取得または新規作成"
  (let ((bufname (format "*tinker:%s*" (file-name-nondirectory path))))
    (or (get-buffer bufname)
        (generate-new-buffer bufname))))

;; -----------------
;; ファイルを保存
;; -----------------

;;;###autoload
(defun tinker-save-buffer ()
  "現在のバッファをWSL上のtinker-remote-pathに保存する"
  (interactive)
  (unless tinker-remote-path
    (user-error "このバッファはtinkerで開かれていません"))
  (let ((path tinker-remote-path)
        (content (buffer-string)))
    (tinker--send "write" path content
                  (lambda (res)
                    (if (eq (alist-get 'ok res) t)
                        (progn
                          (set-buffer-modified-p nil)
                          (message "tinker: saved %s" path))
                      (message "tinker: write error: %s" (alist-get 'error res)))))))

;; -----------------
;; バッファを閉じる(close)
;; -----------------

;;;###autoload
(defun tinker-close-buffer ()
  "現在のtinkerバッファを閉じる。未保存なら確認する"
  (interactive)
  (when (and (buffer-modified-p)
             (not (y-or-n-p "未保存の変更があります。閉じますか？")))
    (user-error "キャンセルしました"))
  (kill-buffer (current-buffer)))

;; -----------------
;; C-x C-s をtinkerバッファでフック
;; -----------------

(defun tinker--save-hook ()
  "tinker-remote-pathが設定されていれば、tinker-save-buffer を使う"
  (when (and (boundp 'tinker-remote-path) tinker-remote-path)
    (tinker-save-buffer)
    t)) ; non-nil を返すとsave-bufferをキャンセル

;; -----------------
;; 接続の切断
;; -----------------

;;;###autoload
(defun tinker-disconnect ()
  "tinker-bridge との接続を切断する"
  (interactive)
  (when (and tinker--connection (process-live-p tinker--connection))
    (delete-process tinker--connection)
    (setq tinker--connection nil)
    (message "tinker: disconnected.")))

;; -----------------
;; キーマップ
;; -----------------

(defvar tinker-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-s") #'tinker-save-buffer)
    (define-key map (kbd "C-x k") #'tinker-close-buffer)
    map)
  "tinker バッファ用キーマップ")

;; -----------------
;; マイナーモード(tinkerバッファに自動付与)
;; -----------------

(define-minor-mode tinker-mode
  "tinker-bridge経由でWSLファイルを編集するマイナーモード"
  :lighter " Tinker"
  :keymap tinker-mode-map
  (if tinker-mode
      (add-hook 'write-file-functions #'tinker--save-hook nil t)
    (remove-hook 'write-file-functions #'tinker--save-hook t)))

(provide 'tinker)

;;; tinker.el ends here
