# PicoClawをWSLにインストールしてみた - 対応ログ

## 環境

- OS: Windows 11 + WSL2 (Ubuntu 24.04)
- ネットワーク: Tailscale経由で外部公開
- Docker: WSL2内で動作
- LLMプロバイダー: 智譜AI (zhipu / glm-5)

---

## 1. PicoClawのビルドと起動

### クローンとビルド

```bash
git clone https://github.com/sipeed/picoclaw.git
cd picoclaw
go build ./...
```

### 設定ファイルの作成

```bash
mkdir -p ~/.picoclaw
cp config/config.example.json ~/.picoclaw/config.json
```

`~/.picoclaw/config.json` を編集してプロバイダーとチャネルを設定。

### Docker Composeで起動

```bash
docker compose --profile gateway up -d --build
```

- `picoclaw-gateway` がゲートウェイとして常駐起動
- 設定ファイルは `~/.picoclaw/config.json` をマウント

---

## 2. LINE公式アカウントチャネルの追加

PicoClawにはLINEチャネルが未実装だったため、自作で追加した。

### 実装内容

- `pkg/channels/line.go` — LINEチャネル本体（約600行）
- `pkg/config/config.go` — `LINEConfig` 構造体追加
- `pkg/channels/manager.go` — LINE初期化ブロック追加
- `config/config.example.json` — LINE設定セクション追加
- `.env.example` — LINE環境変数追加

### 主な機能

- HTTP Webhookでメッセージ受信（MaixCamチャネルのパターンを参考）
- HMAC-SHA256によるWebhook署名検証（X-Line-Signature）
- Reply Token（無料）優先 → Push APIフォールバック
- テキスト・画像・音声メッセージ対応
- 外部SDKなし（標準ライブラリのみ）

### LINE Developers Consoleでの設定

1. LINE公式アカウント作成 → Messaging APIチャネル作成
2. Channel SecretとChannel Access Tokenを取得
3. Webhook URLを設定: `https://<ホスト名>:18791/webhook/line`
4. 「Webhookの利用」をオンに

### config.jsonへの設定追加

```json
{
  "channels": {
    "line": {
      "enabled": true,
      "channel_secret": "YOUR_CHANNEL_SECRET",
      "channel_access_token": "YOUR_CHANNEL_ACCESS_TOKEN",
      "webhook_host": "0.0.0.0",
      "webhook_port": 18791,
      "webhook_path": "/webhook/line",
      "allow_from": []
    }
  }
}
```

### docker-compose.ymlの変更

LINEのWebhookポートを公開する必要がある:

```yaml
picoclaw-gateway:
  ports:
    - "18791:18791"
```

### トラブルシューティング

#### 502 Bad Gateway

**原因**: docker-compose.ymlにポート18791のマッピングがなかった。
**対処**: `ports: - "18791:18791"` を追加。

#### config.jsonがディレクトリになる

**原因**: Dockerがマウント先にファイルが存在しない場合、ディレクトリとして作成してしまう。
**対処**: `rm -rf config/config.json` で削除し、マウントパスを `~/.picoclaw/config.json` に変更。

#### curl で接続できない (000)

**原因**: コンテナが古いイメージ（LINE実装前）で動作していた。
**対処**: `docker compose --profile gateway up -d --build` でリビルド。

---

## 3. グループチャット対応（メンション＆引用返信）

### メンション検知

LINEのグループチャットではメンションされた時だけ応答するようにした。

**問題**: LINE公式アカウントの場合、mentionメタデータにbotのuserIdが含まれないことがある。

**解決**: 3段階のメンション検知を実装:
1. mentionメタデータのuserIdで判定
2. mentionメタデータのテキストがdisplayNameと一致するか
3. メッセージテキストに `@displayName` が含まれるか（フォールバック）

Bot情報は `/v2/bot/info` APIから取得:
```
bot_user_id=Uxxxxxxxx
basic_id=@300ygaze
display_name=組合アシスタント
```

### 引用返信

LINE Messaging APIの `quoteToken` を使用して、元メッセージを引用する形で返信。

### ローディングアニメーション

処理中にローディングアニメーションを表示:
- エンドポイント: `POST /v2/bot/chat/loading/start`
- `loadingSeconds`: 5〜60秒の範囲
- **注意**: 1対1チャットでのみ有効（グループチャットでは表示されない）
- **注意**: userID（U始まり）を指定する必要がある（groupIDではない）

---

## 4. Google Driveアクセス（rcloneスキル）

Google Drive APIを直接実装する代わりに、rcloneをスキルとして活用する方式を採用。

### メリット

- 実装量が圧倒的に少ない（SKILL.md 1ファイル + Dockerfileに1行追加）
- OAuthトークンの自動更新をrcloneが処理
- Google Drive以外（OneDrive, S3等）にも対応可能

### セットアップ手順

#### 1. rcloneのインストール

Dockerfile:
```dockerfile
RUN apk add --no-cache ca-certificates tzdata rclone
```

Windows側（OAuth認証用）:
```powershell
winget install Rclone.Rclone
```

#### 2. OAuth認証

Windows側でrclone authorizeを実行（ブラウザが必要）:

```powershell
rclone.exe authorize drive
```

ブラウザが開くのでGoogleアカウントでログイン → トークンが出力される。

#### 3. rclone.confの作成

```bash
mkdir -p ~/.config/rclone
```

`~/.config/rclone/rclone.conf`:
```ini
[gdrive]
type = drive
scope = drive
root_folder_id = <特定フォルダのID>
token = {"access_token":"...","refresh_token":"...","expiry":"..."}
```

`root_folder_id` を指定すると、特定のフォルダをルートとしてアクセスできる。

フォルダIDの取得:
```bash
rclone lsjson gdrive: --dirs-only --max-depth 1 | python3 -c "
import sys,json
[print(f['ID']) for f in json.load(sys.stdin) if f['Name']=='共同作業場']
"
```

#### 4. docker-compose.ymlへの追加

```yaml
volumes:
  - ~/.config/rclone/rclone.conf:/root/.config/rclone/rclone.conf:ro
```

#### 5. スキルファイルの作成

`skills/gdrive/SKILL.md` を作成。エージェントにrcloneコマンドの使い方を教える。

スキルはDocker volume内の `workspace/skills/` に配置すれば永続化される:

```bash
docker cp skills/gdrive/SKILL.md picoclaw-gateway:/root/.picoclaw/workspace/skills/gdrive/SKILL.md
```

#### 6. ワークスペース制限の解除

デフォルトでは `restrict_to_workspace: true` により、execツールがワークスペース外のパス（`/tmp/`等）を含むコマンドをブロックする。rcloneは `/tmp/` へのダウンロード等が必要なため、設定で制限を解除する:

```json
{
  "agents": {
    "defaults": {
      "restrict_to_workspace": false
    }
  }
}
```

コード改変は不要。READMEのセキュリティセクションに記載あり。

---

## 5. OSSへのコントリビューション

### Issue作成

LINE対応について、まずIssueを立てた:
- https://github.com/sipeed/picoclaw/issues/146

### PR作成

LINE関連の変更だけをクリーンに分離してPRを作成:

```bash
# 現在の変更をstash
git stash --include-untracked

# フィーチャーブランチ作成
git checkout -b feat/line-channel

# LINE関連ファイルだけ適用
# (stashから新規ファイルを取り出し、既存ファイルはEditで変更)

# forkにプッシュ
git remote add fork https://github.com/ex-takashima/picoclaw.git
git push -u fork feat/line-channel

# PR作成
gh pr create --repo sipeed/picoclaw --head ex-takashima:feat/line-channel
```

- https://github.com/sipeed/picoclaw/pull/147

**注意点**: 行末コード（CRLF/LF）の差異で全ファイルが変更として表示される場合、手動でLINE関連の変更だけを適用する必要があった。

### コンフリクト解消

PRを出した後、upstreamのmainブランチが更新されてコンフリクトが発生。`pkg/config/config.go` にupstreamで追加された `HeartbeatConfig` と、こちらの `LINEConfig` が同じ箇所に挿入されていたため、両方を残す形でマージ解消した。

### CI対応

CIで2つの問題が発生:

1. **fmt-check失敗**: 行末コード（CRLF→LF）の問題。`gofmt -w` で修正。
2. **test失敗**: upstreamで `NewWebSearchTool` のシグネチャが変更されていたが、テストが追随していなかった（upstream既存バグ）。テストを新しいシグネチャに合わせて修正。

初回コントリビューターのため、GitHub Actionsの実行にはメンテナーの承認（Approve and run）が必要だった。

### マージ

メンテナー @yinwm がCIを承認・実行し、PR #147 がマージされた。コミットメッセージに `Closes #146` を含めていたため、Issue #146 も自動クローズされた。

---

## まとめ

| 項目 | 内容 |
|------|------|
| プラットフォーム | WSL2 + Docker |
| LLMプロバイダー | 智譜AI (glm-5) |
| チャネル | LINE公式アカウント, Discord |
| 追加機能 | Google Drive連携 (rclone) |
| 外部への公開 | Tailscale |
| コントリビューション | Issue #146, PR #147 (マージ済み) |
