#!/usr/bin/env bash
# @trace spec:shell-prompt-localization-ja
# Tillandsias Forge — 日本語ロケールパッケージ
# entrypoint.sh と forge-welcome.sh によってロケール検出後にソースされます。
# 衝突を避けるために L_ を接頭辞とします。

# ── entrypoint.sh ────────────────────────────────────────────
L_BANNER_FORGE="tillandsias forge"
L_BANNER_PROJECT="プロジェクト:"
L_BANNER_AGENT="エージェント:"

# ── forge-welcome.sh ──────────────────────────────────────────
L_WELCOME_TITLE="🌱 Tillandsias Forge"
L_WELCOME_PROJECT="プロジェクト"
L_WELCOME_FORGE="Forge"
L_WELCOME_MOUNTS="マウント"
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

# ── Agent onboarding ──────────────────────────
L_AGENT_ONBOARDING="🤖 エージェントオンボーディング"
L_AGENT_ONBOARDING_HINT="初回ガイドは cat $TILLANDSIAS_CHEATSHEETS/welcome/readme-discipline.md"
