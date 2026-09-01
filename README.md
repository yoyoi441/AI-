# トークン見張り番 — Windows

Claude Code と Codex がPC内に保存したローカルログを読み取り、トークン使用量を
Windowsのタスクトレイに表示する常駐アプリです。データは外部へ送信しません。

## 主な機能

- Claude Code / Codex の本日の合計トークン数
- タスクトレイ上のトークン使用率表示（初期設定）
- モデル別・プロジェクト別の内訳
- 時間帯別グラフと直近7日間の合計
- 使用量の目安と通知
- CSV / JSON 書き出し
- 日本語・英語表示

## 動作環境

- Windows 10 / 11（64ビット）
- Claude Code または Codex CLIを同じPCで使用していること

インストーラー版には.NET 8ランタイムを同梱するため、利用者が.NETを別途
インストールする必要はありません。

## 開発・実行

Visual Studio 2022の「.NET デスクトップ開発」ワークロード、または.NET 8 SDKが
必要です。

```powershell
dotnet run --project TokenMihariban/TokenMihariban.csproj
```

起動後はタスクトレイ（隠れているインジケーターを含む）にアイコンが現れます。
左クリックで使用状況、右クリックで更新・設定・終了を開きます。

ログがまだ存在しない場合は「データなし」と表示されます。読み取る場所は次の通りです。

- `%USERPROFILE%\.claude\projects`
- `%USERPROFILE%\.codex\sessions`

## 配布用インストーラー

```powershell
dotnet publish -c Release -p:PublishProfile=win-x64
```

続いてInno Setup 6で `installer/TokenMihariban.iss` をコンパイルします。完成物は
`installer/Output/TokenMiharibanSetup.exe` です。

## プライバシー

このWindows版に端末間同期・Firebase・利用状況の送信機能はありません。ローカルの
JSONLログは集計のために読み取るだけで、元ファイルを書き換えません。設定は
`%APPDATA%\TokenMihariban\settings.json` に保存されます。

## 現在の確認状況

Windows 10 / 11の実機で、起動・トレイ表示・ログ集計・エクスポートを確認中です。
プレビュー版は未署名のため、Windowsの警告が表示される場合があります。
