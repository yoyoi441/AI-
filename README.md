# トークン見張り番

Claude CodeとCodexが端末内に保存したローカルログを読み取り、トークン使用量を
見やすく表示する常駐アプリです。Windows版とmacOS版を同じGitHub Releaseから
配布します。

## 主な機能

- Claude Code / Codexの本日の合計トークン数
- タスクトレイ／メニューバー上の使用率表示
- ClaudeとCodexがある場合は、両方のリングを表示
- モデル別・プロジェクト別の内訳
- 時間帯別グラフと直近7日間の合計
- 使用量の目安と通知
- CSV / JSON書き出し
- アプリ内からGitHub Releasesの更新を確認・インストール
- 任意の端末間同期（Firebase匿名認証・参加端末限定アクセス）
- 日本語・英語表示

## ダウンロード

[Releases](https://github.com/yoyoi441/AI-/releases)から利用中のOS向けファイルを
ダウンロードしてください。

- Windows: `TokenMiharibanSetup.exe`
- macOS: `TokenMihariban-macOS.zip`（Apple Silicon / Intel共通）

現在のプレビュー版は未署名です。Windows SmartScreenやmacOS Gatekeeperの警告が
表示される場合があります。

## 動作環境

- Windows 10 / 11（64ビット）
- macOS 14以降（Apple Silicon / Intel）
- Claude CodeまたはCodex CLIを同じ端末で使用していること

読み取るログは次の通りです。

- `~/.claude/projects`
- `~/.codex/sessions`

## アプリ内更新

設定の「更新を確認」から最新のGitHub Releaseを確認します。Windows版は
インストーラーを起動し、macOS版は新しいアプリを検証して現在のアプリと置き換えます。
GitHubが公開するSHA-256ダイジェストがある場合は、インストール前に照合します。

## 端末間同期

設定の「端末間同期」で16文字のペアリングコードを共有すると、直近9日分の
Claude Code / Codex使用イベントをWindows版とmacOS版で合算できます。コードは
約80ビットのランダム値で、表示時は`ABCD-EFGH-JKLM-NPQR`のように区切られます。

同期を有効にした端末はFirebase Authenticationへ匿名でサインインします。Firestoreでは
ペアリングコードを知って参加処理を完了した端末ごとにメンバー情報を作成し、Security Rulesで
メンバー以外の読取り・書込み、同期グループの一覧取得、不正なトークン値を拒否します。

有効化後に同期対象となる項目は日時、モデル、トークン数、セッションID、プロジェクトパスです。
Anthropic・OpenAIのログイン情報やAPIキーは同期対象にしません。

## Windows版の開発

Visual Studio 2022の「.NETデスクトップ開発」ワークロード、または.NET 8 SDKが必要です。

```powershell
dotnet run --project TokenMihariban/TokenMihariban.csproj
```

インストーラーは`dotnet publish`後、Inno Setup 6で
`installer/TokenMihariban.iss`をコンパイルします。

## macOS版の開発

Xcodeで`macOS/TokenMihariban.xcodeproj`を開き、`ClaudeUsage`ターゲットをビルドします。
Firebase同期を有効にする開発ビルドでは、
`macOS/TokenMihariban/GoogleService-Info.plist`を追加してください。このファイルは
Git管理対象外です。Swift Packageから`FirebaseAuth`と`FirebaseFirestore`を使用します。

## Firebase同期のセットアップ

1. Firebase ConsoleのAuthenticationで「匿名」プロバイダを有効にします。
2. `firebase deploy --only firestore:rules,firestore:indexes`で`firestore.rules`を配備します。
3. Windows用のWeb APIキーとProject IDをGitHub Actionsの
   `FIREBASE_API_KEY`、`FIREBASE_PROJECT_ID`へ登録します。
4. macOS用`GoogleService-Info.plist`をBase64化し、
   `FIREBASE_GOOGLE_SERVICE_INFO_B64`へ登録します。

FirebaseのクライアントAPIキーはアプリ設定を識別する値で、データへの権限そのものでは
ありません。データ保護はAuthenticationと`firestore.rules`で行います。ルールを配備する前に
同期設定入りのアプリを公開しないでください。

## プライバシー

同期を設定していない場合、Firebase Authenticationへの接続や利用状況の送信は行いません。
Windowsの匿名認証更新トークンはWindows DPAPIで現在のユーザー用に暗号化し、macOSでは
Firebase AuthがKeychainへ保存します。ローカルJSONLログは
集計のために読み取るだけで、元ファイルを書き換えません。アプリ内更新の確認時には
GitHub APIへ現在のバージョン確認を行います。
