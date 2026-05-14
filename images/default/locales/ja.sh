#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-ja
# Tillandsias Forge — 日本語ロケールパッケージ
# entrypoint.sh と forge-welcome.sh によってロケール検出後にソースされます。
# 衝突を避けるために L_ を接頭辞とします。

# ── entrypoint.sh ────────────────────────────────────────────
L_INSTALLING_OPENCODE="OpenCode をインストール中..."
L_INSTALLED_OPENCODE="  OpenCode 準備完了: %s"
L_WARN_OPENCODE="  警告: OpenCode バイナリが存在しますが、--version は何も返しませんでした。"
L_INSTALLING_CLAUDE="Claude Code をインストール中..."
L_INSTALLED_CLAUDE="  Claude Code 準備完了: %s"
L_WARN_CLAUDE="  警告: Claude Code バイナリが存在しますが、--version は何も返しませんでした。"
L_CLAUDE_NOT_FOUND="  インストール後に Claude Code バイナリが見つかりません。"
L_INSTALL_FAILED_CLAUDE="  エラー: npm install に失敗しました。詳細は上記の出力を参照してください。"
L_INSTALLING_OPENSPEC="OpenSpec をインストール中..."
L_INSTALLED_OPENSPEC="  ✓ OpenSpec がインストールされました"
L_OPENSPEC_NOT_FOUND="  ✗ インストール後に OpenSpec バイナリが見つかりません"
L_OPENSPEC_FAILED="  [共通] 警告: 品質低下 — OpenSpec 不可、/opsx コマンドは機能しません"
L_RETRY_HINT="再試行: コンテナを再起動してください"
L_CLEAR_CACHE_CLAUDE="キャッシュをクリア: rm -rf ~/.cache/tillandsias/claude/"
L_CLEAR_CACHE_OPENCODE="キャッシュをクリア: rm -rf ~/.cache/tillandsias/opencode/"
L_OPENCODE_INSTALL_FAILED="エラー: OpenCode をインストールできませんでした。"
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="プロジェクト:"
L_BANNER_AGENT="エージェント:"
L_BANNER_MODE_MAINTENANCE="モード:    メンテナンス"
L_AGENT_NOT_AVAILABLE="Claude Code が利用できません。bash を起動します。"
L_OPENCODE_NOT_AVAILABLE="OpenCode が利用できません。bash を起動します。"
L_UNKNOWN_AGENT="不明なエージェント '%s' です。bash を起動します。"

# ── CA / プロキシ警告 ──────────────────────────────────────
L_WARN_CA_INSTALL="警告: CA 証明書をインストールできませんでした — プロキシ HTTPS キャッシュが機能しない可能性があります"
L_WARN_CA_UPDATE="警告: CA 信頼ストアを更新できませんでした"

# ── Git ミラーメッセージ ───────────────────────────────────────
L_WARN_PUSH_URL="警告: プッシュ URL を設定できませんでした — git push が機能しない可能性があります"
L_GIT_CLONE_FAILED="エラー: git サービスからプロジェクトをクローンできませんでした。"
L_GIT_CLONE_HINT="git サービスが実行されていない可能性があります。ターミナルにドロップします。"
L_GIT_EPHEMERAL="永続するには、すべての変更をコミットする必要があります。コミットされていない作業は停止時に失われます。"

# ── 認証 / 初期化警告 ────────────────────────────────────
L_WARN_GH_AUTH="警告: gh auth setup-git に失敗しました — git push が認証されない可能性があります"
L_WARN_OPENSPEC_INIT="警告: OpenSpec 初期化に失敗しました — /opsx コマンドが機能しない可能性があります"

# ── インストーラー終了警告 ────────────────────────────────────
L_WARN_OPENCODE_EXIT="警告: OpenCode インストーラーがコード で終了しました"
L_WARN_OPENCODE_UPDATE_EXIT="警告: OpenCode アップデートがコード で終了しました"

# ── 更新メッセージ ───────────────────────────────────────────
L_UPDATING_CLAUDE="Claude Code を更新中..."
L_UPDATING_OPENCODE="OpenCode を更新中..."

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="プロジェクト"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="マウント"
L_WELCOME_PROJECT_AT="→ プロジェクト /home/forge/src/%s"
L_WELCOME_SECURITY="セキュリティ"
L_WELCOME_NETWORK="ネットワーク"
L_WELCOME_NETWORK_DESC="飛び地のみ (インターネットなし、プロキシ経由のパッケージ)"
L_WELCOME_CREDENTIALS="認証情報"
L_WELCOME_CREDENTIALS_DESC="なし (ミラーサービス経由の git 認証)"
L_WELCOME_CODE="コード"
L_WELCOME_CODE_DESC="git ミラーからクローン (コミットされていない作業は一時的)"
L_WELCOME_SERVICES="サービス"
L_WELCOME_PROXY_DESC="キャッシュ HTTP/S プロキシ (許可されたドメイン)"
L_WELCOME_GIT_DESC="git ミラー + リモートへの自動プッシュ"
L_WELCOME_INFERENCE_DESC="ollama (ローカル LLM)"

# ── ヒント (回転表示、ログイン時に表示) ──────────────────
L_TIP_1="help を入力して Fish シェルについて詳しく知る"
L_TIP_2="mc で Midnight Commander を試す"
L_TIP_3="eza --tree でファイルを閲覧"
L_TIP_4="Tab キーで自動補完候補を表示"
L_TIP_5="Ctrl+R で履歴を検索"
L_TIP_6="z <部分名> でスマート ディレクトリ ジャンプ"
L_TIP_7="bat <ファイル> でファイル プレビュー"
L_TIP_8="fd <パターン> でファイルを素早く検索"
L_TIP_9="fzf でファジー検索"
L_TIP_10="htop でプロセスを表示"
L_TIP_11="tree でディレクトリツリーを表示"
L_TIP_12="vim または nano でファイルを編集"
L_TIP_13="Fish は入力時に有効なコマンドを緑で強調表示"
L_TIP_14="Fish は履歴から提案 — → を押して受け入れる"
L_TIP_15=".. を使用してディレクトリを上に移動"
L_TIP_16="ll でファイルを詳細に一覧表示"
L_TIP_17="bash を入力すると、いつでも bash に切り替え"
L_TIP_18="zsh を入力すると、いつでも zsh に切り替え"
L_TIP_19="git status で git ステータスを確認"
L_TIP_20="GitHub CLI: gh repo view, gh pr list"

# ── チートシート ────────────────────────────────────────
# 注: チートシート ポインタは現在 forge-welcome.sh にハード コードされており、
# ロケール変数を使用しません。完全にロケール対応のバナーにする場合は、
# 今後のローカライズのために保持されます。
L_WELCOME_CHEATSHEETS="📚 チートシート"

# ── エラーメッセージ (lib-localized-errors.sh) ──────────────
L_ERROR_CONTAINER_FAILED="エラー: コンテナを起動できませんでした"
L_ERROR_CONTAINER_HINT="コンテナを再起動するか、ログで詳細を確認してください。"

L_ERROR_IMAGE_MISSING="エラー: コンテナ イメージが見つかりません"
L_ERROR_IMAGE_HINT="イメージをリビルドするか、存在することを確認してください。ディスク容量を確認してください。"

L_ERROR_NETWORK="エラー: ネットワーク エラー"
L_ERROR_NETWORK_HINT="プロキシ設定 (HTTPS_PROXY env) を確認し、ネットワーク サービスが実行されていることを確認してください。"

L_ERROR_GIT_CLONE="エラー: Git クローンに失敗しました"
L_ERROR_GIT_HINT="認証情報、SSH キーを確認するか、git サービスを再起動してください。git config を確認してください。"

L_ERROR_AUTH="エラー: 認証に失敗しました"
L_ERROR_AUTH_HINT="'gh auth login' で認証情報を再設定するか、git config を確認してください。"
