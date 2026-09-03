import Foundation

/// The two UI languages this app supports. Stored per-device (not synced across
/// paired devices via Firestore, unlike appearance) since display language is a
/// personal/device preference, not part of "look and feel" the user opts to mirror.
public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case japanese = "ja"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }
}

/// A small hand-maintained translation table instead of Xcode's String Catalogs:
/// keeps every string's ja/en pair in one auditable place and works identically in
/// the main apps and the widget extensions (which read the language from the same
/// App Group container as everything else — see `SnapshotStore`).
public enum L {
    private static let table: [String: (ja: String, en: String)] = [
        // MARK: Common
        "usageSuffix": ("使用状況", "Usage"),
        "resetIn": ("リセットまで", "Reset in"),
        "waiting": ("待機中", "Waiting"),
        "remaining": ("残り", "left"),
        "noData": ("データなし", "No data"),
        "time": ("時間", "Time"),
        "hourLabel": ("時刻", "Hour"),
        "tokenLabel": ("トークン", "Tokens"),
        "noActiveBlock": ("アクティブな5時間ブロックはありません", "No active 5-hour block"),
        "tokenEstimateNote": ("トークンの目安は自己ベース(過去最大ブロック)または設定の手動値です。公式の上限ではありません。", "The token target is either your own historical max block or a manually-set value in Settings — not an official limit."),
        "tokenEstimateLowConfidenceNoteFormat": ("トークンの目安はまだ%d件のブロックしか観測しておらず、参考程度の数値です。手動で目安を設定するとより安定します。", "This target is based on only %d observed block(s) so far — treat it as a rough reference. Set a manual target in Settings for something more stable."),
        "tokenTargetUnset": ("トークン(目安未設定)", "Tokens (no target set)"),
        "usedTokensNoTarget": ("使用: %@ トークン(目安未設定)", "Used: %@ tokens (no target set)"),
        "today": ("本日", "Today"),
        "totalTokensFormat": ("合計 %@ トークン", "Total %@ tokens"),
        "estimatedCostFormat": ("概算コスト: %@", "Est. cost: %@"),
        "unpricedModelWarning": ("料金表未登録のモデルがあり、概算コストに含まれていません", "Some models aren't in the pricing table and are excluded from this total"),
        "modelBreakdownLineFormat": ("・%@: %@", "• %@: %@"),
        "projectBreakdownHeader": ("プロジェクト別", "By Project"),
        "moreProjectsFormat": ("他%d件", "+%d more"),
        "hourlyChartTitle": ("本日の時間帯別使用量", "Today's hourly usage"),
        "last7DaysFormat": ("直近7日間: %@ トークン", "Last 7 days: %@ tokens"),
        "codexNoData": ("Codexの利用状況データがまだありません", "No Codex usage data yet"),
        "codexOfficialNote": ("利用率・リセット時刻はOpenAIから直接取得した値です(推定ではありません)。", "Usage % and reset time come directly from OpenAI (not estimated)."),
        "ollamaLocalFormat": ("ローカル: %@ トークン（料金0円）", "Local: %@ tokens (no usage fee)"),
        "ollamaCloudFormat": ("クラウド: %@ トークン", "Cloud: %@ tokens"),
        "ollamaNoTargetCaption": ("本日合計（目安未設定）", "Today (no target set)"),
        "ollamaNoData": ("まだOllamaの利用データがありません。設定の監視URLをOllama対応アプリに指定してください。", "No Ollama usage data yet. Set an Ollama-compatible client to one of the monitoring URLs shown in Settings."),
        "ollamaCloudCostNote": ("Ollama Cloudの公開単価による概算です。実際の請求額・残高ではありません。", "Estimated from Ollama Cloud's public token rates; this is not your billed amount or balance."),
        "perDaysFormat": ("%d日ごと", "every %dd"),
        "perHoursFormat": ("%d時間ごと", "every %dh"),
        "refresh": ("更新", "Refresh"),
        "settingsEllipsis": ("設定...", "Settings..."),
        "quit": ("終了", "Quit"),

        // MARK: Settings tabs (Mac)
        "generalTab": ("全般", "General"),
        "appearanceTab": ("見た目", "Appearance"),
        "displayItemsTab": ("表示項目", "Display Items"),
        "tokenTargetTab": ("トークン目安", "Token Target"),
        "deviceSyncTab": ("端末間同期", "Device Sync"),
        "exportTab": ("エクスポート", "Export"),

        // MARK: Export tab
        "exportHeader": ("使用量データの書き出し", "Export Usage Data"),
        "exportStartDateLabel": ("開始日", "Start Date"),
        "exportEndDateLabel": ("終了日", "End Date"),
        "exportFormatLabel": ("形式", "Format"),
        "exportButton": ("書き出す…", "Export…"),
        "exportNote": ("指定した期間のClaude Code・Codex・Ollamaの利用イベントを1行ずつ書き出します。Ollamaはローカル／クラウドも区別します。概算コストは公開単価が登録済みのモデルのみ算出されます。", "Exports one row per Claude Code, Codex, and Ollama usage event in the selected date range, including local/cloud Ollama source. Estimated cost is calculated only for models with a known public token rate."),
        "exportFailed": ("書き出しに失敗しました", "Export failed"),
        "exportSucceededFormat": ("%d件のイベントを書き出しました", "Exported %d events"),

        // MARK: General tab
        "launchAtLogin": ("ログイン時に自動で常駐起動する", "Launch automatically at login"),
        "launchAtLoginNote": ("オフにすると、Finderやターミナルから自分で起動したときだけ動きます。", "When off, the app only runs when you launch it yourself from Finder or the terminal."),
        "launchHeader": ("起動", "Launch"),
        "rescanIntervalFormat": ("念のための再スキャン間隔: %d秒", "Fallback rescan interval: %ds"),
        "rescanNote": ("ログの更新は基本的にファイル変更の監視で即時反映されます。これは取りこぼし時の保険としての再スキャン間隔です。", "Log updates normally show up instantly via file-change watching. This interval is just a safety net in case an update is missed."),
        "rescanHeader": ("データの再読み込み", "Data Refresh"),
        "updatesHeader": ("更新", "Updates"),
        "currentVersionFormat": ("現在のバージョン: %@", "Current version: %@"),
        "automaticUpdateCheck": ("起動時に自動で更新を確認する", "Automatically Check for Updates at Launch"),
        "automaticUpdateCheckNote": ("新しいバージョンが見つかった場合は、インストール前に確認します。", "When a new version is found, the app asks before installing it."),
        "ollamaMonitoringHeader": ("Ollama監視", "Ollama Monitoring"),
        "ollamaMonitoringToggle": ("Ollamaのローカル・クラウド使用量を監視する", "Monitor local and cloud Ollama usage"),
        "ollamaMonitoringRunning": ("監視中", "Monitoring"),
        "ollamaMonitoringStarting": ("監視を開始しています…", "Starting monitoring…"),
        "ollamaMonitoringStopped": ("停止中", "Stopped"),
        "ollamaMonitoringFailedFormat": ("監視を開始できません: %@", "Couldn't start monitoring: %@"),
        "ollamaLocalProxyFormat": ("ローカル／:cloud用: %@", "Local / :cloud endpoint: %@"),
        "ollamaCloudProxyFormat": ("Ollama Cloud直結用: %@", "Direct Ollama Cloud endpoint: %@"),
        "ollamaMonitoringNote": ("利用するOllama対応アプリの接続先（OLLAMA_HOST）を上のURLに変更すると集計されます。通常はローカル／:cloud用を選びます。プロンプトと回答本文は保存せず、モデル名・トークン数・処理時間のみ記録します。", "Set an Ollama-compatible client's endpoint (OLLAMA_HOST) to one of the URLs above. The local / :cloud endpoint is the normal choice. Prompt and response text is never stored; only model name, token counts, and duration are recorded."),
        "checkForUpdates": ("更新を確認", "Check for Updates"),
        "checkingForUpdates": ("更新を確認しています…", "Checking for updates…"),
        "upToDate": ("最新バージョンです。", "You are up to date."),
        "updateAvailableFormat": ("新しいバージョン %@ があります。ダウンロードして更新しますか？", "Version %@ is available. Download and install it now?"),
        "downloadingUpdate": ("更新をダウンロードしています…", "Downloading update…"),
        "updateFailedFormat": ("更新に失敗しました: %@", "Update failed: %@"),
        "installUpdate": ("更新する", "Install Update"),
        "cancel": ("キャンセル", "Cancel"),
        "languageHeader": ("言語", "Language"),
        "languagePickerLabel": ("表示言語", "Display Language"),

        // MARK: Appearance tab
        "displayStyle": ("表示スタイル", "Display Style"),
        "styleAppliesNote": ("メニューバーとウィジェットの両方に反映されます。", "Applies to both the menu bar and the widget."),
        "styleHeader": ("スタイル", "Style"),
        "claudeColorLabel": ("Claude Codeの色", "Claude Code Color"),
        "codexColorLabel": ("Codexの色", "Codex Color"),
        "ollamaColorLabel": ("Ollamaの色", "Ollama Color"),
        "gradientToggle": ("グラデーションにする", "Use Gradient"),
        "colorHeader": ("カラー", "Color"),
        "colorFooterNote": ("表示スタイル・グラデーションの有無は全サービス共通です。色はClaude・Codex・Ollamaで別々に設定できます。", "Display style and gradient apply to all providers. Claude, Codex, and Ollama colors can be set separately."),
        "previewTimeDuration": ("2時間30分", "2h 30m"),
        "previewHeader": ("プレビュー", "Preview"),
        "menuBarMetricPickerLabel": ("メニューバーアイコンの表示内容", "Menu Bar Icon Shows"),
        "menuBarMetricTime": ("残り時間", "Time Remaining"),
        "menuBarMetricTokenUsage": ("トークン使用率", "Token Usage"),
        "menuBarMetricHeader": ("メニューバーアイコン", "Menu Bar Icon"),
        "menuBarMetricNote": ("メニューバーの円グラフ・バーが何を表しているかを選べます。「残り時間」は現在のブロック(Claude)・期間(Codex)がリセットされるまでの経過割合、「トークン使用率」はトークン使用量の割合です。", "Choose what the menu bar's ring/bar represents. \"Time Remaining\" is how far through the current block (Claude) or window (Codex) you are until it resets. \"Token Usage\" is the share of tokens used."),
        "widgetContentHeader": ("ウィジェット(小)", "Widget (Small)"),
        "widgetProviderPickerLabel": ("表示するサービス", "Service to Show"),
        "widgetMetricPickerLabel": ("表示内容", "Shows"),
        "widgetContentNote": ("ホーム画面の小サイズウィジェットに表示するサービスと内容を選べます。中・大サイズのウィジェットは両方のサービスを常に表示するため対象外です。", "Choose which service and metric the small home screen widget shows. Medium/Large widgets always show both services, so this doesn't apply to them."),
        "liveActivityToggle": ("ロック画面 / Dynamic Islandに表示", "Show on Lock Screen / Dynamic Island"),
        "liveActivityNote": ("Claude Codeのブロックが進行中の間、ロック画面やDynamic Islandに残り時間・トークン使用量を表示します。", "While a Claude Code block is active, shows remaining time and token usage on the Lock Screen and in the Dynamic Island."),

        // MARK: Usage alerts (daily / custom-window targets + notifications)
        "dailyTargetGaugeCaption": ("本日の目安", "Today's Target"),
        "customWindowGaugeCaptionFormat": ("指定時間 %@", "%@ Window"),
        "notificationsToggle": ("目安を超えたら通知する", "Notify When Target Is Exceeded"),
        "notificationsNote": ("Claude Code・Codex・Ollamaの目安を超えたときに、1日1回・各項目ごとに通知します。Ollamaは本日の目安に対応します。", "Notifies once per day, per item, when a Claude Code, Codex, or Ollama target is exceeded. Ollama supports the daily target."),
        "notificationExceededTitleFormat": ("%@の使用量が目安を超えました", "%@ usage exceeded your target"),
        "notificationExceededBodyFormat": ("%@: %@ / %@ トークン", "%@: %@ / %@ tokens"),
        "notificationPaceWarningTitleFormat": ("%@がまもなく目安に達します", "%@ is about to hit its target"),
        "notificationPaceWarningBodyFormat": ("このペースだとあと約%d分で目安(%@トークン)に到達する見込みです", "At this pace, it'll reach the %2$@ token target in about %1$d more minutes"),
        "receiveRemoteNotificationsToggle": ("他の端末からの通知を受け取る", "Receive Notifications From Other Devices"),
        "receiveRemoteNotificationsNote": ("Macなど他の端末でClaude Code・Codexの応答が完了したときの通知を、この端末にも表示します。オフにするとこの端末では表示されません(他の端末の通知には影響しません)。", "Shows a notification on this device when Claude Code or Codex finishes responding on another paired device (e.g. your Mac). Turning this off only affects this device."),
        "dailyTargetSectionHeader": ("本日のトークン目安", "Today's Token Target"),
        "customWindowSectionHeader": ("指定時間内のトークン目安", "Custom Window Token Target"),
        "customWindowRangeLabel": ("集計する時間帯", "Time Range to Track"),
        "customWindowStartLabel": ("開始", "Start"),
        "customWindowEndLabel": ("終了", "End"),
        "claudeDailyTargetPlaceholder": ("空欄 = 無効(Claude Code)", "Blank = off (Claude Code)"),
        "codexDailyTargetPlaceholder": ("空欄 = 無効(Codex)", "Blank = off (Codex)"),
        "ollamaDailyTargetPlaceholder": ("空欄 = 目安なし(Ollama)", "Blank = no target (Ollama)"),
        "claudeWindowTargetPlaceholder": ("空欄 = 無効(Claude Code)", "Blank = off (Claude Code)"),
        "codexWindowTargetPlaceholder": ("空欄 = 無効(Codex)", "Blank = off (Codex)"),
        "dailyTargetNote": ("本日の合計トークン数(カレンダー日で日付が変わるとリセット)が、ここで設定した目安を超えたら赤色になり、通知がオンなら通知します。空欄なら無効です。", "When today's total tokens (resets when the calendar date changes) exceed this target, the gauge turns red and — if notifications are on — you're notified. Blank disables it."),
        "customWindowNote": ("下で指定した時間帯(毎日リセット)に使ったトークン数が、ここで設定した目安を超えたら赤色になり、通知がオンなら通知します。空欄なら無効です。1時間単位の集計のため多少の誤差があります。", "When tokens used during the time range below (resets daily) exceed this target, the gauge turns red and — if notifications are on — you're notified. Blank disables it. Tallied in hourly buckets, so there's some margin of error."),

        // MARK: Provider visibility + target enable toggles (settings declutter)
        "providersHeader": ("表示するサービス", "Services to Show"),
        "providersNote": ("オフにしたサービスは、メニューバー/アプリ画面・メニューバーアイコンから非表示になります。設定自体は残ります。", "A service you turn off is hidden from the menu bar/app screen and the menu bar icon. Its settings are kept, just not shown."),
        "showClaudeProviderToggle": ("Claude Codeを表示", "Show Claude Code"),
        "showCodexProviderToggle": ("Codexを表示", "Show Codex"),
        "showOllamaProviderToggle": ("Ollamaを表示", "Show Ollama"),
        "dailyTargetEnabledToggle": ("本日のトークン目安を使う", "Use Today's Token Target"),
        "windowTargetEnabledToggle": ("指定時間内のトークン目安を使う", "Use Custom Window Token Target"),

        // MARK: Display items tab
        "itemTimeGauge": ("5時間ブロックの時間ゲージ", "5-hour block time gauge"),
        "itemTokenGauge": ("トークン使用ゲージ", "Token usage gauge"),
        "itemTodaySummary": ("本日の合計トークン数", "Today's total tokens"),
        "itemEstimatedCost": ("概算コスト", "Est. cost"),
        "estimatedCostExplainer": ("もし従量課金だったらこのくらいの価値の作業をしています(実際の請求額ではありません)", "Roughly how much this work would cost if billed pay-as-you-go (not an actual charge)"),
        "itemModelBreakdown": ("モデル別内訳", "Per-model breakdown"),
        "itemProjectBreakdown": ("プロジェクト別内訳", "Per-project breakdown"),
        "itemHourlyChart": ("時間帯別の棒グラフ", "Hourly bar chart"),
        "itemLast7Days": ("直近7日間の合計", "Last 7 days' total"),
        "displayItemsHeaderMac": ("メニューバーに表示する項目", "Items shown in the menu bar"),
        "displayItemsFooterMac": ("Claude Code・Codex・Ollamaに共通の設定です。Ollamaのモデル別内訳は将来の設定追加に備えて内部に保持しますが、現在は1つのリングに集約します。", "Applies to Claude Code, Codex, and Ollama. Ollama's per-model data is retained for a future setting, but is currently combined into one ring."),
        "displayItemsHeaderIOS": ("表示項目", "Display Items"),

        // MARK: Sync tab / section
        "firebaseNotConfigured": ("Firebaseが未設定です", "Firebase is not configured"),
        "firebaseNotConfiguredNoteMac": ("GoogleService-Info.plistをアプリに組み込むまで、端末間同期は無効です(Mac単体としてはこれまで通り動作します)。", "Cross-device sync stays disabled until GoogleService-Info.plist is added to the app (the Mac app keeps working standalone as before)."),
        "copied": ("コピーしました", "Copied"),
        "copy": ("コピー", "Copy"),
        "pairingCodeNoteMac": ("このコードをWindows版または別のMacの「端末間同期」に入力すると、各端末の使用量が合算表示されます。", "Enter this code in Device Sync on Windows or another Mac to combine usage across devices."),
        "pairingCodeHeader": ("ペアリングコード", "Pairing Code"),
        "unpairMac": ("このMacの同期を解除", "Unpair this Mac"),
        "unpairIOS": ("この端末の同期を解除", "Unpair this device"),
        "createNewCode": ("新しいペアリングコードを作成", "Create a new pairing code"),
        "createNewCodeNote": ("最初の端末ではこちらを選んでください。表示されたコードを他の端末に入力してもらいます。", "Choose this on your first device. Enter the code it shows on your other devices."),
        "startNewHeader": ("新しく始める", "Start Fresh"),
        "codePlaceholderMac": ("例: AB12-CD34-EF56-GH78", "e.g. AB12-CD34-EF56-GH78"),
        "codePlaceholderIOS": ("Macに表示されているコード", "Code shown on the Mac app"),
        "connect": ("接続", "Connect"),
        "enterCodeNoteMac": ("別のMacまたはWindows版の「端末間同期」に表示されているコードを入力してください。", "Enter the code shown in Device Sync on another Mac or Windows PC."),
        "enterCodeNoteIOS": ("Mac版の「設定」→「端末間同期」に表示されているコードを入力してください。", "Enter the code shown in the Mac app's Settings → Device Sync."),
        "joinExistingHeader": ("既存のコードで参加する", "Join an Existing Group"),
        "invalidPairingCode": ("16文字のペアリングコードを入力してください。ハイフンは省略できます。", "Enter the 16-character pairing code. Hyphens are optional."),
        "pairingConnecting": ("安全な接続を準備しています…", "Preparing a secure connection…"),
        "pairingFailed": ("接続できませんでした。コード、通信状態、Firebase設定を確認してください。", "Couldn't connect. Check the code, connection, and Firebase configuration."),
        "deviceSyncHeaderIOS": ("端末間同期", "Device Sync"),
        "syncPrivacyHeader": ("同期されるデータ", "Data That Is Synced"),
        "syncPrivacyNote": ("同期を有効にした場合のみ、参加端末間で直近9日分の日時・モデル・トークン数・接続先区分などを共有します。プロンプト・回答本文・ログイン情報・APIキーは送信しません。", "Only after you enable sync, member devices share the last nine days of usage metadata such as time, model, token counts, and source. Prompts, responses, credentials, and API keys are never uploaded."),

        // MARK: Settings sync preference (iOS)
        "syncWithMacToggle": ("Macと見た目・表示項目を同期する", "Sync appearance & display items with Mac"),
        "syncWithMacNote": ("オンにすると、ここの色・スタイル・表示項目の設定はMac側の値で自動的に上書きされます。オフなら、この端末だけの独自設定になります。", "When on, the color/style/display-item settings here are automatically overwritten with the Mac's values. When off, this device keeps its own independent settings."),
        "appearanceHeaderIOS": ("見た目", "Appearance"),
        "appearanceFooterIOS": ("「Macと同期する」がオンのときは、ここで変更してもMac側の値で上書きされます。", "While \"Sync with Mac\" is on, changes here get overwritten by the Mac's values."),

        // MARK: Token target tab/section
        "tokenTargetPlaceholderMac": ("空欄 = 自己ベース(過去最大ブロック)で自動計算", "Blank = auto-calculated from your own historical max block"),
        "tokenTargetNoteMac": ("実際のプラン上限を把握している場合のみ入力してください。Anthropicは正式な上限を公開していないため、空欄のままなら過去最大ブロックのトークン数を目安として使います。85%を超えると警告色(赤)になります。", "Only enter a value if you actually know your plan's limit. Anthropic doesn't publish an official limit, so leaving this blank uses your historical max block as the target. Turns red past 85%."),
        "tokenTargetHeaderMac": ("1ブロックあたりの目安トークン数(Claude Code)", "Target tokens per block (Claude Code)"),
        "tokenTargetFooterCodexNote": ("Codexは利用率(%)とリセット時刻をOpenAI側から直接取得しているため、この設定は不要です。", "Codex gets its usage % and reset time directly from OpenAI, so this setting isn't needed for it."),
        "tokenTargetHeaderIOS": ("Claude Codeのトークン目安", "Claude Code Token Target"),
        "tokenTargetFooterIOS": ("空欄なら自己ベース(過去最大ブロック)で自動計算します。Codexは公式の利用率をそのまま使うため設定不要です。", "Blank auto-calculates from your own historical max block. Codex uses its official usage % directly, so no setting is needed for it."),
        "tokenTargetPlaceholderIOS": ("空欄 = 自動計算", "Blank = auto-calculated"),

        // MARK: iOS pairing banner / navigation
        "notPaired": ("端末が未ペアリングです", "Device not paired"),
        "notPairedNoteIOS": ("右上の設定から、Mac版に表示されているペアリングコードを入力してください。", "Enter the pairing code shown in the Mac app from Settings in the top right."),
        "settingsTitle": ("設定", "Settings"),
        "done": ("完了", "Done"),

        // MARK: Widget
        "widgetDaysFormat": ("%d日", "%dd"),
        "todayTokFormat": ("本日 %@ tok", "Today %@ tok"),
        "estimatedCostWidgetFormat": ("概算 $%.2f", "Est. $%.2f"),
        "totalTokensPlainFormat": ("%@ トークン", "%@ tokens"),

        // MARK: Gauge style labels
        "styleBar": ("バー", "Bar"),
        "styleRing": ("円グラフ", "Ring"),
    ]

    public static func string(_ key: String, lang: AppLanguage) -> String {
        guard let entry = table[key] else { return key }
        return lang == .japanese ? entry.ja : entry.en
    }

    public static func string(_ key: String, lang: AppLanguage, args: [CVarArg]) -> String {
        String(format: string(key, lang: lang), arguments: args)
    }
}

/// Adopted by SwiftUI views that need translated text: implement `lang` (typically
/// backed by `@AppStorage("appLanguage")`) and get `t(_:)` for free. `@MainActor`
/// because every SwiftUI `View` is implicitly main-actor-isolated under Swift 6
/// strict concurrency, and a nonisolated protocol requirement can't be satisfied by
/// an isolated conforming property.
@MainActor
public protocol LocalizedView {
    var lang: AppLanguage { get }
}

public extension LocalizedView {
    func t(_ key: String) -> String { L.string(key, lang: lang) }
    func t(_ key: String, _ args: CVarArg...) -> String { L.string(key, lang: lang, args: args) }
}

/// UserDefaults key for the language preference, shared by both apps' Settings UIs.
public enum AppLanguagePreference {
    public static let storageKey = "appLanguage"

    public static func resolve(from raw: String?) -> AppLanguage {
        raw.flatMap(AppLanguage.init(rawValue:)) ?? .japanese
    }
}
