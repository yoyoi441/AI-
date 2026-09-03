using System;
using System.Collections.Generic;
using System.Globalization;

namespace TokenMihariban.Models;

/// <summary>
/// Hand-maintained ja/en translation table, ported 1:1 from the Mac app's `L` table
/// (same keys) so wording stays consistent across every platform.
/// </summary>
public static class L
{
    private static readonly Dictionary<string, (string Ja, string En)> Table = new()
    {
        // Common
        ["usageSuffix"] = ("使用状況", "Usage"),
        ["resetIn"] = ("リセットまで", "Reset in"),
        ["waiting"] = ("待機中", "Waiting"),
        ["remaining"] = ("残り", "left"),
        ["noData"] = ("データなし", "No data"),
        ["time"] = ("時間", "Time"),
        ["hourLabel"] = ("時刻", "Hour"),
        ["tokenLabel"] = ("トークン", "Tokens"),
        ["noActiveBlock"] = ("アクティブな5時間ブロックはありません", "No active 5-hour block"),
        ["tokenEstimateNote"] = ("トークンの目安は自己ベース(過去最大ブロック)または設定の手動値です。公式の上限ではありません。", "The token target is either your own historical max block or a manually-set value in Settings — not an official limit."),
        ["tokenEstimateLowConfidenceNoteFormat"] = ("トークンの目安はまだ{0}件のブロックしか観測しておらず、参考程度の数値です。手動で目安を設定するとより安定します。", "This target is based on only {0} observed block(s) so far — treat it as a rough reference. Set a manual target in Settings for something more stable."),
        ["tokenTargetUnset"] = ("トークン(目安未設定)", "Tokens (no target set)"),
        ["usedTokensNoTarget"] = ("使用: {0} トークン(目安未設定)", "Used: {0} tokens (no target set)"),
        ["today"] = ("本日", "Today"),
        ["totalTokensFormat"] = ("合計 {0} トークン", "Total {0} tokens"),
        ["estimatedCostFormat"] = ("概算コスト: {0}", "Est. cost: {0}"),
        ["unpricedModelWarning"] = ("料金表未登録のモデルがあり、概算コストに含まれていません", "Some models aren't in the pricing table and are excluded from this total"),
        ["modelBreakdownLineFormat"] = ("・{0}: {1}", "• {0}: {1}"),
        ["projectBreakdownHeader"] = ("プロジェクト別", "By Project"),
        ["moreProjectsFormat"] = ("他{0}件", "+{0} more"),
        ["hourlyChartTitle"] = ("本日の時間帯別使用量", "Today's hourly usage"),
        ["last7DaysFormat"] = ("直近7日間: {0} トークン", "Last 7 days: {0} tokens"),
        ["codexNoData"] = ("Codexの利用状況データがまだありません", "No Codex usage data yet"),
        ["codexOfficialNote"] = ("利用率・リセット時刻はOpenAIから直接取得した値です(推定ではありません)。", "Usage % and reset time come directly from OpenAI (not estimated)."),
        ["perDaysFormat"] = ("{0}日ごと", "every {0}d"),
        ["perHoursFormat"] = ("{0}時間ごと", "every {0}h"),
        ["refresh"] = ("更新", "Refresh"),
        ["settingsEllipsis"] = ("設定...", "Settings..."),
        ["quit"] = ("終了", "Quit"),
        ["alreadyRunningTitle"] = ("すでに起動しています", "Already Running"),
        ["alreadyRunningMessage"] = ("アプリはすでに起動しています。タスクトレイのアイコンをご確認ください。", "The app is already running. Check its icon in the system tray."),

        // Settings tabs
        ["generalTab"] = ("全般", "General"),
        ["appearanceTab"] = ("見た目", "Appearance"),
        ["displayItemsTab"] = ("表示項目", "Display Items"),
        ["tokenTargetTab"] = ("トークン目安", "Token Target"),
        ["deviceSyncTab"] = ("端末間同期", "Device Sync"),
        ["exportTab"] = ("エクスポート", "Export"),

        // Export tab
        ["exportHeader"] = ("使用量データの書き出し", "Export Usage Data"),
        ["exportStartDateLabel"] = ("開始日", "Start Date"),
        ["exportEndDateLabel"] = ("終了日", "End Date"),
        ["exportFormatLabel"] = ("形式", "Format"),
        ["exportButton"] = ("書き出す…", "Export…"),
        ["exportNote"] = ("指定した期間のClaude Code・Codexの利用イベントを1行ずつ書き出します。経費精算や自己分析にご利用ください。概算コストはClaude Codeのみ、料金表に登録済みのモデルのみ算出されます。", "Exports one row per Claude Code/Codex usage event in the selected date range — useful for expense reports or your own analysis. Estimated cost is calculated only for Claude Code calls using a model listed in the pricing table."),
        ["exportFailed"] = ("書き出しに失敗しました", "Export failed"),
        ["exportSucceededFormat"] = ("{0}件のイベントを書き出しました", "Exported {0} events"),

        // General tab
        ["launchAtLogin"] = ("ログイン時に自動で常駐起動する", "Launch automatically at login"),
        ["launchAtLoginNote"] = ("オフにすると、スタートメニューなどから自分で起動したときだけ動きます。", "When off, the app only runs when you launch it yourself."),
        ["launchHeader"] = ("起動", "Launch"),
        ["rescanIntervalFormat"] = ("念のための再スキャン間隔: {0}秒", "Fallback rescan interval: {0}s"),
        ["rescanNote"] = ("ログの更新は基本的にファイル変更の監視で即時反映されます。これは取りこぼし時の保険としての再スキャン間隔です。", "Log updates normally show up instantly via file-change watching. This interval is just a safety net in case an update is missed."),
        ["rescanHeader"] = ("データの再読み込み", "Data Refresh"),
        ["updatesHeader"] = ("更新", "Updates"),
        ["currentVersionFormat"] = ("現在のバージョン: {0}", "Current version: {0}"),
        ["automaticUpdateCheck"] = ("起動時に自動で更新を確認する", "Automatically Check for Updates at Launch"),
        ["automaticUpdateCheckNote"] = ("新しいバージョンが見つかった場合は、インストール前に確認します。", "When a new version is found, the app asks before installing it."),
        ["checkForUpdates"] = ("更新を確認", "Check for Updates"),
        ["checkingForUpdates"] = ("更新を確認しています…", "Checking for updates…"),
        ["upToDate"] = ("最新版を使用しています", "You're using the latest version"),
        ["updateAvailableFormat"] = ("新しいバージョン {0} があります。ダウンロードして更新しますか？", "Version {0} is available. Download and install it now?"),
        ["downloadingUpdate"] = ("更新をダウンロードしています…", "Downloading update…"),
        ["updateFailedFormat"] = ("更新の確認またはダウンロードに失敗しました。\n{0}", "Couldn't check for or download the update.\n{0}"),
        ["updateDialogTitle"] = ("アプリの更新", "App Update"),
        ["updateRestartNote"] = ("更新ファイルを起動すると、このアプリを終了します。更新後に再度起動してください。", "The app will close after launching the updater. Start it again after installation."),
        ["languageHeader"] = ("言語", "Language"),
        ["languagePickerLabel"] = ("表示言語", "Display Language"),

        // Device sync
        ["deviceSyncHeader"] = ("別端末と使用量を同期", "Sync Usage with Other Devices"),
        ["syncUnavailable"] = ("このビルドでは端末間同期を利用できません。", "Device sync is unavailable in this build."),
        ["syncUnavailableNote"] = ("Firebase設定を含む公式リリース版を使用してください。ローカルの使用量表示は引き続き利用できます。", "Use an official release that includes Firebase configuration. Local usage monitoring still works."),
        ["copy"] = ("コピー", "Copy"),
        ["copied"] = ("コピーしました", "Copied"),
        ["pairingCodeNoteWindows"] = ("このコードをMac版または別のWindows版の「端末間同期」に入力すると、各端末の使用量が合算表示されます。", "Enter this code in Device Sync on a Mac or another Windows PC to combine usage."),
        ["syncNow"] = ("今すぐ同期", "Sync Now"),
        ["syncing"] = ("同期しています…", "Syncing…"),
        ["syncComplete"] = ("同期処理が完了しました。", "Sync completed."),
        ["syncFailed"] = ("同期できませんでした。通信状態を確認して、もう一度お試しください。", "Sync failed. Check your connection and try again."),
        ["unpairWindows"] = ("このPCの同期を解除", "Unpair This PC"),
        ["createNewCode"] = ("新しいペアリングコードを作成", "Create a New Pairing Code"),
        ["createNewCodeNote"] = ("最初の端末ではこちらを選び、表示されたコードをもう一方の端末へ入力してください。", "Choose this on the first device, then enter the displayed code on your other device."),
        ["joinExistingHeader"] = ("既存のコードで参加する", "Join an Existing Group"),
        ["connect"] = ("接続", "Connect"),
        ["invalidPairingCode"] = ("16文字のペアリングコードを入力してください。ハイフンは省略できます。", "Enter the 16-character pairing code. Hyphens are optional."),
        ["enterCodeNoteWindows"] = ("別のMacまたはWindows版に表示されている16文字のコードを入力します。", "Enter the 16-character code shown on another Mac or Windows PC."),
        ["pairingConnecting"] = ("安全な接続を準備しています…", "Preparing a secure connection…"),
        ["pairingFailed"] = ("接続できませんでした。コード、通信状態、Firebase設定を確認してください。", "Couldn't connect. Check the code, connection, and Firebase configuration."),
        ["syncPrivacyHeader"] = ("同期されるデータ", "Data That Is Synced"),
        ["syncPrivacyNote"] = ("同期を有効にした場合のみ、匿名認証された参加端末間で直近9日分のトークン使用イベント（日時、モデル、トークン数、セッションID、プロジェクトパス）をFirebase経由で共有します。Anthropic・OpenAIのログイン情報やAPIキーは送信しません。", "Only after you enable sync, anonymously authenticated member devices share the last nine days of token usage events (time, model, token counts, session ID, and project path) through Firebase. Anthropic/OpenAI credentials and API keys are never uploaded."),

        // Appearance tab
        ["displayStyle"] = ("表示スタイル", "Display Style"),
        ["styleAppliesNote"] = ("タスクトレイのポップアップに反映されます。", "Applies to the tray popup."),
        ["styleHeader"] = ("スタイル", "Style"),
        ["claudeColorLabel"] = ("Claude Codeの色", "Claude Code Color"),
        ["codexColorLabel"] = ("Codexの色", "Codex Color"),
        ["gradientToggle"] = ("グラデーションにする", "Use Gradient"),
        ["colorHeader"] = ("カラー", "Color"),
        ["colorFooterNote"] = ("表示スタイル・グラデーションの有無はClaude・Codex共通です。色だけ別々に設定できます。", "Display style and gradient apply to both Claude and Codex. Only the colors can be set separately."),
        ["previewTimeDuration"] = ("2時間30分", "2h 30m"),
        ["previewHeader"] = ("プレビュー", "Preview"),
        ["menuBarMetricPickerLabel"] = ("タスクトレイアイコンの表示内容", "Tray Icon Shows"),
        ["menuBarMetricTime"] = ("残り時間", "Time Remaining"),
        ["menuBarMetricTokenUsage"] = ("トークン使用率", "Token Usage"),
        ["menuBarMetricHeader"] = ("タスクトレイアイコン", "Tray Icon"),
        ["menuBarMetricNote"] = ("タスクトレイの円グラフ・バーが何を表しているかを選べます。「残り時間」は現在のブロック(Claude)・期間(Codex)がリセットされるまでの経過割合、「トークン使用率」はトークン使用量の割合です。", "Choose what the tray icon's ring/bar represents. \"Time Remaining\" is how far through the current block (Claude) or window (Codex) you are until it resets. \"Token Usage\" is the share of tokens used."),

        // Usage alerts
        ["dailyTargetGaugeCaption"] = ("本日の目安", "Today's Target"),
        ["customWindowGaugeCaptionFormat"] = ("指定時間 {0}", "{0} Window"),
        ["notificationsToggle"] = ("目安を超えたら通知する", "Notify When Target Is Exceeded"),
        ["notificationsNote"] = ("Claude Code・Codexそれぞれの「本日の目安」「指定時間内の目安」を超えたときに通知します。1日1回・各項目ごとに一度だけ通知します。", "Notifies once per day, per item, when Claude Code's or Codex's \"today\" or \"custom window\" targets are exceeded."),
        ["notificationExceededTitleFormat"] = ("{0}の使用量が目安を超えました", "{0} usage exceeded your target"),
        ["notificationExceededBodyFormat"] = ("{0}: {1} / {2} トークン", "{0}: {1} / {2} tokens"),
        ["notificationPaceWarningTitleFormat"] = ("{0}がまもなく目安に達します", "{0} is about to hit its target"),
        ["notificationPaceWarningBodyFormat"] = ("このペースだとあと約{0}分で目安({1}トークン)に到達する見込みです", "At this pace, it'll reach the {1} token target in about {0} more minutes"),
        ["dailyTargetSectionHeader"] = ("本日のトークン目安", "Today's Token Target"),
        ["customWindowSectionHeader"] = ("指定時間内のトークン目安", "Custom Window Token Target"),
        ["customWindowRangeLabel"] = ("集計する時間帯", "Time Range to Track"),
        ["customWindowStartLabel"] = ("開始", "Start"),
        ["customWindowEndLabel"] = ("終了", "End"),
        ["claudeDailyTargetPlaceholder"] = ("空欄 = 無効(Claude Code)", "Blank = off (Claude Code)"),
        ["codexDailyTargetPlaceholder"] = ("空欄 = 無効(Codex)", "Blank = off (Codex)"),
        ["claudeWindowTargetPlaceholder"] = ("空欄 = 無効(Claude Code)", "Blank = off (Claude Code)"),
        ["codexWindowTargetPlaceholder"] = ("空欄 = 無効(Codex)", "Blank = off (Codex)"),
        ["dailyTargetNote"] = ("本日の合計トークン数(カレンダー日で日付が変わるとリセット)が、ここで設定した目安を超えたら赤色になり、通知がオンなら通知します。空欄なら無効です。", "When today's total tokens (resets when the calendar date changes) exceed this target, the gauge turns red and — if notifications are on — you're notified. Blank disables it."),
        ["customWindowNote"] = ("下で指定した時間帯(毎日リセット)に使ったトークン数が、ここで設定した目安を超えたら赤色になり、通知がオンなら通知します。空欄なら無効です。1時間単位の集計のため多少の誤差があります。", "When tokens used during the time range below (resets daily) exceed this target, the gauge turns red and — if notifications are on — you're notified. Blank disables it. Tallied in hourly buckets, so there's some margin of error."),

        // Provider visibility + target enable toggles
        ["providersHeader"] = ("表示するサービス", "Services to Show"),
        ["providersNote"] = ("オフにしたサービスは、ポップアップ・タスクトレイアイコンから非表示になります。設定自体は残ります。", "A service you turn off is hidden from the popup and the tray icon. Its settings are kept, just not shown."),
        ["showClaudeProviderToggle"] = ("Claude Codeを表示", "Show Claude Code"),
        ["showCodexProviderToggle"] = ("Codexを表示", "Show Codex"),
        ["dailyTargetEnabledToggle"] = ("本日のトークン目安を使う", "Use Today's Token Target"),
        ["windowTargetEnabledToggle"] = ("指定時間内のトークン目安を使う", "Use Custom Window Token Target"),

        // Display items tab
        ["itemTimeGauge"] = ("5時間ブロックの時間ゲージ", "5-hour block time gauge"),
        ["itemTokenGauge"] = ("トークン使用ゲージ", "Token usage gauge"),
        ["itemTodaySummary"] = ("本日の合計トークン数", "Today's total tokens"),
        ["itemEstimatedCost"] = ("概算コスト", "Est. cost"),
        ["estimatedCostExplainer"] = ("もし従量課金だったらこのくらいの価値の作業をしています(実際の請求額ではありません)", "Roughly how much this work would cost if billed pay-as-you-go (not an actual charge)"),
        ["itemModelBreakdown"] = ("モデル別内訳", "Per-model breakdown"),
        ["itemProjectBreakdown"] = ("プロジェクト別内訳", "Per-project breakdown"),
        ["itemHourlyChart"] = ("時間帯別の棒グラフ", "Hourly bar chart"),
        ["itemLast7Days"] = ("直近7日間の合計", "Last 7 days' total"),
        ["displayItemsHeaderMac"] = ("ポップアップに表示する項目", "Items shown in the popup"),
        ["displayItemsFooterMac"] = ("Claude CodeとCodex両方に共通の設定です。", "Applies to both Claude Code and Codex."),

        // Token target tab
        ["tokenTargetPlaceholderMac"] = ("空欄 = 自己ベース(過去最大ブロック)で自動計算", "Blank = auto-calculated from your own historical max block"),
        ["tokenTargetNoteMac"] = ("実際のプラン上限を把握している場合のみ入力してください。Anthropicは正式な上限を公開していないため、空欄のままなら過去最大ブロックのトークン数を目安として使います。85%を超えると警告色(赤)になります。", "Only enter a value if you actually know your plan's limit. Anthropic doesn't publish an official limit, so leaving this blank uses your historical max block as the target. Turns red past 85%."),
        ["tokenTargetHeaderMac"] = ("1ブロックあたりの目安トークン数(Claude Code)", "Target tokens per block (Claude Code)"),
        ["tokenTargetFooterCodexNote"] = ("Codexは利用率(%)とリセット時刻をOpenAI側から直接取得しているため、この設定は不要です。", "Codex gets its usage % and reset time directly from OpenAI, so this setting isn't needed for it."),

        ["settingsTitle"] = ("設定", "Settings"),
        ["done"] = ("完了", "Done"),

        ["totalTokensPlainFormat"] = ("{0} トークン", "{0} tokens"),

        // Gauge style labels
        ["styleBar"] = ("バー", "Bar"),
        ["styleRing"] = ("円グラフ", "Ring"),
    };

    public static string String(string key, AppLanguage lang)
    {
        if (!Table.TryGetValue(key, out var entry)) return key;
        return lang == AppLanguage.Japanese ? entry.Ja : entry.En;
    }

    public static string String(string key, AppLanguage lang, params object[] args)
    {
        return string.Format(CultureInfo.CurrentCulture, String(key, lang), args);
    }
}
