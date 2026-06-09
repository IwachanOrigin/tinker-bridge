;;; tinker.el --- WSL remote file editing via tinker-bridge -*- lexical-binding: t -*-

;;; Commentary:
;; WSL状のファイルをWindows側のemacsから編集するためのパッケージ

;;; Code:

(require 'project)
(require 'cl-lib)
(require 'subr-x)

;; -----------------
;; Custome variable
;; -----------------

(defgroup tinker nil
  "WSL remote file editing via tinker-bridge."
  :group 'files)

(defcustom tinker-host "127.0.0.1"
  "tinker-bridge のホスト名またはIPアドレス."
  :type 'string
  :group 'tinker)

(defcustom tinker-port 7070
  "tinker-bridge が listen する TCP ポート番号."
  :type 'integer
  :group 'tinker)

;; -----------------
;; internal variable
;; -----------------

(defvar tinker--connection nil
  "tinker-bridgeへのtcp ネットワークプロセス.")

(defvar tinker--request-id 0
  "リクエストIDのカウンタ.")

(defvar tinker--pending-requests (make-hash-table :test 'equal)
  "id -> callback の対応表.レスポンス待ちリクエストを管理する.")

(defvar tinker--recv-buffer ""
  "受信途中のデータを蓄積するバッファ.")

(defvar-local tinker-remote-path nil
  "このバッファが対応するwsl上のファイルパス.")

;; -----------------
;; 接続管理
;; -----------------

(defun tinker--connect ()
  "tinker-bridge に TCP 接続する.すでに接続済みなら何もしない."
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
  "接続状態の変化を処理する."
  (message "tinker: connection event: %s" (string-trim event))
  (when (string-match-p "\\(closed\\|failed\\|broken\\)" event)
    (setq tinker--connection nil)
    (clrhash tinker--pending-requests)
    (setq tinker--recv-buffer "")))

(defun tinker--filter (_proc data)
  "受信データを処理する。\\n区切りでJSONを切り出してディスパッチ."
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

(defun tinker--make-request (op path &optional content)
  "リクエスト用ハッシュテーブルを生成する."
  (setq tinker--request-id (1+ tinker--request-id))
  (let ((h (make-hash-table :test 'equal)))
    (puthash "id"   tinker--request-id h)
    (puthash "op"   op                 h)
    (puthash "path" path               h)
    (when content (puthash "content" content h))
    h))

(defun tinker--send (op path &optional content callback)
  "OP/PATH/CONTENT を JSON で送信し、CALLBACK を登録する."
  (tinker--connect)
  (let* ((req      (tinker--make-request op path content))
         (id       (gethash "id" req))
         (json-str (concat (json-serialize req) "\n")))
    (when callback
      (puthash id callback tinker--pending-requests))
    (process-send-string tinker--connection json-str)))

;; -----------------
;; ファイル一覧
;; -----------------

;;;###autoload
(defun tinker-list (path)
  "WSL上のPATHのファイル一覧を取得してバッファへ表示する."
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
  "WSL上のPATHをEmacsバッファとして開く."
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
                            (let ((buffer-file-name path))
                              (set-auto-mode))
                            ;; ローカル変数にパスを記録
                            (setq-local tinker-remote-path path)
                            (tinker-mode 1)))
                        (switch-to-buffer buf)
                        (message "tinker: opened %s" path))
                    (message "tinker: read error: %s" (alist-get 'error res))))))

(defun tinker--get-or-create-buffer (path)
  "PATHに対応するバッファを取得または新規作成."
  (let ((bufname (format "*tinker:%s*" (file-name-nondirectory path))))
    (or (get-buffer bufname)
        (generate-new-buffer bufname))))

;; -----------------
;; ファイルを保存
;; -----------------

;;;###autoload
(defun tinker-save-buffer ()
  "現在のバッファをWSL上のtinker-remote-pathに保存する."
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
  "現在のtinkerバッファを閉じる。未保存なら確認する."
  (interactive)
  (when (and (buffer-modified-p)
             (not (y-or-n-p "未保存の変更があります。閉じますか?")))
    (user-error "キャンセルしました"))
  (kill-buffer (current-buffer)))

;; -----------------
;; C-x C-s をtinkerバッファでフック
;; -----------------

(defun tinker--save-hook ()
  "tinker-remote-pathが設定されていれば、tinker-save-buffer を使う."
  (when (and (boundp 'tinker-remote-path) tinker-remote-path)
    (tinker-save-buffer)
    t)) ; non-nil を返すとsave-bufferをキャンセル

;; -----------------
;; 接続の切断
;; -----------------

;;;###autoload
(defun tinker-disconnect ()
  "tinker-bridge との接続を切断する."
  (interactive)
  (when (and tinker--connection (process-live-p tinker--connection))
    (delete-process tinker--connection)
    (setq tinker--connection nil)
    (message "tinker: disconnected.")))

;; -----------------
;; project.elのバックエンド
;; -----------------

(defvar tinker--projects (make-hash-table :test 'equal)
  "root-path -> ファイルリストのキャッシュ")

(cl-defstruct tinker-project root files)

(defun tinker-open-project (root)
  "WSL上のROOTをプロジェクトとして開き、project.elに登録する."
  (interactive "sWSL project root: ")
  (tinker--send "open-project" root nil
                (lambda (res)
                  (if (not (eq (alist-get 'ok res) t))
                      (message "tinker: open-project error: %s" (alist-get 'error res))
                    (let* ((raw (alist-get 'content res))
                           (files (json-parse-string raw :array-type 'list))
                           (proj (make-tinker-project :root root :files files)))
                      (puthash root proj tinker--projects)
                      ;; project.elのリストへ登録
                      (message "tinker: project opened %s (%d files)" root (length files))
                      ;; ファイル選択UIを起動
                      (tinker--project-find-file proj))))))

(defun tinker--project-find-file (proj)
  "PROJ のファイル一覧から選択してファイルを開く."
  (let* ((root (tinker-project-root proj))
         (files (tinker-project-files proj))
         (selected (completing-read
                    (format "[tinker] %s: " (file-name-nondirectory root))
                    files nil t)))
    (when selected
      (tinker-find-file (concat root "/" selected)))))

;;;###autoload
(defun tinker-project-find-file ()
  "現在のtinkerプロジェクトからファイルを選択して開く."
  (interactive)
  (if (hash-table-empty-p tinker--projects)
      (call-interactively #'tinker-open-project)
    (let* ((roots (hash-table-keys tinker--projects))
           (root  (if (= (length roots) 1)
                      (car roots)
                    (completing-read "Project: " roots nil t)))
           (proj  (gethash root tinker--projects)))
      (tinker--project-find-file proj))))

;; -----------------
;; キーマップ
;; -----------------

(defvar tinker-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-s") #'tinker-save-buffer)
    (define-key map (kbd "C-x k") #'tinker-close-buffer)
    map)
  "tinker バッファ用キーマップ.")

(defvar tinker-global-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t o") #'tinker-open-project)
    (define-key map (kbd "C-c t f") #'tinker-project-find-file)
    (define-key map (kbd "C-c t l") #'tinker-list)
    (define-key map (kbd "C-c t q") #'tinker-disconnect)
    map)
  "tinker グローバルキーマップ.")

;; -----------------
;; マイナーモード(tinkerバッファに自動付与)
;; -----------------

(define-minor-mode tinker-mode
  "tinker-bridge経由でWSLファイルを編集するマイナーモード."
  :lighter " Tinker"
  :keymap tinker-mode-map
  (if tinker-mode
      (add-hook 'write-file-functions #'tinker--save-hook nil t)
    (remove-hook 'write-file-functions #'tinker--save-hook t)))

(define-minor-mode tinker-global-mode
  "tinker グローバルキーバインドを有効にするモード"
  :lighter ""
  :global t
  :keymap tinker-global-map)

;; -----------------
;; tinker . 通知受信サーバ(TCP: 7071)
;; -----------------

(defcustom tinker-notify-port 7071
  "WSL側tinkerコマンドからの通知を受け付けるTCPポート番号."
  :type 'integer
  :group 'tinker)

(defvar tinker--notify-server nil
  "通知受信用TCPサーバプロセス.")

(defvar tinker--notify-recv-buffer ""
  "通知受信途中データの蓄積バッファ.")

(defun tinker--notify-filter (_proc data)
  "WSLからの通知を受け取りopen-projectを実行する."
  (setq tinker--notify-recv-buffer
        (concat tinker--notify-recv-buffer data))
  (while (string-match "\n" tinker--notify-recv-buffer)
    (let* ((pos (match-beginning 0))
           (line (substring tinker--notify-recv-buffer 0 pos)))
      (setq tinker--notify-recv-buffer
            (substring tinker--notify-recv-buffer (1+ pos)))
      (unless (string-empty-p line)
        (let* ((msg  (json-parse-string line :object-type 'alist))
               (op   (alist-get 'op msg))
               (path (alist-get 'path msg)))
          (when (and (equal op "open-project") path)
            (message "tinker: open-project request from WSL: %s" path)
            ;;
            (select-frame-set-input-focus (selected-frame))
            (when (fboundp 'w32-focus-frame)
              (w32-focus-frame (selected-frame)))
            (tinker-open-project path)))))))

(defun tinker-start-notify-server ()
  "WSLからの通知を受け付けるTCPサーバを起動する"
  (interactive)
  (when (and tinker--notify-server
             (process-live-p tinker--notify-server))
    (delete-process tinker--notify-server))
  (setq tinker--notify-recv-buffer "")
  (setq tinker--notify-server
        (make-network-process
         :name     "tinker-notify"
         :server   t
         :host     "0.0.0.0"
         :service  tinker-notify-port
         :coding   'utf-8
         :filter   #'tinker--notify-filter
         :sentinel (lambda (proc e)
                     (message "tinker-notify: %s" (string-trim e))
                     ;; 子プロセス接続時にフィルターを設定
                     (when (string-match-p "open" e)
                       (set-process-filter proc #'tinker--notify-filter)))))
  (message "tinker: notify server listening on :%d" tinker-notify-port))

(defun tinker-stop-notify-server ()
  "通知サーバを停止する."
  (interactive)
  (when (and tinker--notify-server
             (process-live-p tinker--notify-server))
    (delete-process tinker--notify-server)
    (setq tinker--notify-server nil)
    (message "tinker: notify server stopped.")))

(provide 'tinker)

;;; tinker.el ends here
