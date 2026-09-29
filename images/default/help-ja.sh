#!/usr/bin/env bash
# @trace spec:help-system-localization
# help-ja.sh — Tillandsias Forge ヘルプシステム
# 日本語版

cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                   Tillandsias Forge ヘルプ                    ║
╚════════════════════════════════════════════════════════════════╝

クイックヒント
──────────────
• `help` と入力してこのメッセージを再度表示
• Fish キーバインドを使用: Tab で自動補完、Ctrl+R で履歴検索
• ファイルプレビュー: bat <ファイル>
• ディレクトリ参照: eza --tree
• ファジー検索: fzf

エージェントと開発
──────────────────
Claude Code:
  • 開始: /claude (または単に 'claude')
  • 実行: /opsx (OpenSpec コマンド)
  • チャット: コード レビューをリクエスト、ボイラープレート生成、デバッグ

OpenCode:
  • 開始: /opencode (または 'opencode')
  • インテリジェント提案でコードを効率的に編集
  • 実行: opencode <コマンド> (例: opencode run)

Git 操作
  • クローン: git clone <repo>
  • コミット: git add . && git commit -m "メッセージ"
  • プッシュ: git push origin <ブランチ>
  • ステータス: git status
  • GitHub CLI: gh repo view, gh pr list, gh issue create

コンテナと環境
──────────────
現在のプロジェクト: ${TILLANDSIAS_PROJECT:-不明}
プロジェクト ディレクトリ: /home/forge/src/<プロジェクト>
ネットワーク: 飛び地のみ (インターネットなし)
認証情報: コンテナにはなし (git auth はミラー サービス経由)

コードの変更:
  ✓ すべてのコミットされていない作業は一時的 (停止時に失われる)
  ✓ 変更を永続するにはコミット: git commit
  ✓ リモートを更新するにはプッシュ: git push

トラブルシューティング
──────────────────────
問題: コマンドが見つかりません
  → インストール確認: which <コマンド>
  → コマンド一覧: ls -la /usr/local/bin/

問題: Git プッシュに失敗
  → 設定を確認: git config -l
  → git サービス再起動: 再接続
  → 認証情報を確認: gh auth status

問題: npm/cargo/pip インストール失敗
  → パッケージはプロキシ経由: HTTPS_PROXY env を確認
  → キャッシュクリア: rm -rf ~/.cache/tillandsias/<ツール>/
  → 再試行: npm install

問題: アクセス許可拒否
  → ユーザー確認: whoami
  → ファイル所有権: ls -l <ファイル>
  → 実行可能にする: chmod +x <ファイル>

便利なコマンド
──────────────
ファイル ナビゲーション:
  eza <dir>          ファイル一覧 (エレガント)
  eza --tree         ツリー ビュー
  tree               ディレクトリ ツリー
  cd /home/forge/src プロジェクト ルートへ

テキスト処理:
  bat <ファイル>     構文ハイライト付きプレビュー
  rg <パターン>      Ripgrep (高速検索)
  fd <パターン>      パターンでファイル検索
  fzf                ファジー検索ツール

システム情報:
  df -h              ディスク使用量
  du -sh <dir>       ディレクトリ サイズ
  ps aux             実行中のプロセス
  htop               インタラクティブ ビューア
  top                CPU/メモリ モニター

ドキュメント
──────────────
チートシート:
  ls /opt/cheatsheets/        利用可能なチートシート参照
  cat /opt/cheatsheets/INDEX.md

シェル学習:
  man <コマンド>     マニュアル ページ
  help <builtin>     Bash 組み込みヘルプ
  type <コマンド>    コマンド型を表示

さらに助けが必要?
  • 入力: /claude (Claude Code に質問)
  • 参照: /opt/cheatsheets/
  • 確認: git log --oneline (最近のコミット)

═══════════════════════════════════════════════════════════════════
q と入力して終了するか、コマンドを入力して続行します。
EOF
