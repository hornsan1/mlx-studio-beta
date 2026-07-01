// StudioStrings.swift
// vMLXApp — i18n catalog for the active MLX Studio screens (REVIEW MED-11).
//
// These screens (Onboarding/SetupScreen + MLXStudio/MLXStudioScreens) were
// English-only — they bypassed the §349 L10n catalog. This file adds the
// missing entries so ja/ko/zh users see their language.
//
// TRANSLATION STATUS: en is authoritative; ja/ko/zh are initial drafts and
// should be confirmed by native reviewers before release. The L10nEntry type
// enforces that all four locales are present at compile time, so there are no
// silent English fallbacks. Product name "MLX Studio" is a proper noun and is
// intentionally left untranslated across locales.
//
// Call sites use `AppLocalePreference.current` (a global accessor) rather than
// `@Environment(\.appLocale)` so strings in static helpers / deeply-nested
// builders localize without threading Environment through every struct.

import Foundation

public extension L10n {

    /// Onboarding / first-run (SetupScreen.swift).
    enum Onboarding {
        public static let productName = L10nEntry(
            en: "MLX Studio", ja: "MLX Studio", ko: "MLX Studio", zh: "MLX Studio")
        public static let welcomeTitle = L10nEntry(
            en: "Local AI, ready to make something",
            ja: "ローカルAIで、何かを作り始めよう",
            ko: "로컬 AI로 무언가를 만들 준비 완료",
            zh: "本地 AI，随时开始创作")
        public static let welcomeBody = L10nEntry(
            en: "Set up one useful path now. You can keep the studio simple, then open the advanced lab when you need server controls, diagnostics, or model inspection.",
            ja: "まずは便利な使い方をひとつ設定しましょう。スタジオはシンプルなまま使い、サーバー制御・診断・モデル検査が必要になったら高度なラボを開けます。",
            ko: "지금 유용한 경로 하나를 설정하세요. 스튜디오를 단순하게 유지하다가 서버 제어, 진단, 모델 검사가 필요할 때 고급 랩을 열 수 있습니다.",
            zh: "先设置一条实用路径。你可以保持工作室简洁，等需要服务器控制、诊断或模型检查时再打开高级实验室。")
        public static let modeChoiceTitle = L10nEntry(
            en: "Choose how much studio you want up front",
            ja: "最初にどこまでスタジオを使うか選択",
            ko: "처음에 스튜디오를 얼마나 사용할지 선택",
            zh: "选择一开始想要多少工作室功能")
        public static let modeChoiceBody = L10nEntry(
            en: "Beginner keeps you in Chat, Create, Models, and Library. Advanced adds the server, diagnostics, and model lab surfaces.",
            ja: "ビギナーはチャット・作成・モデル・ライブラリのみ。アドバンスドではサーバー、診断、モデルラボの画面が追加されます。",
            ko: "초보자 모드는 채팅, 생성, 모델, 라이브러리만 제공합니다. 고급 모드는 서버, 진단, 모델 랩 화면을 추가합니다.",
            zh: "初级模式仅保留聊天、创作、模型和库。高级模式会增加服务器、诊断和模型实验室界面。")
        public static let pickResultTitle = L10nEntry(
            en: "Pick your first result",
            ja: "最初の成果を選ぶ",
            ko: "첫 결과를 선택하세요",
            zh: "选择你的第一个成果")
        public static let recommendedStarter = L10nEntry(
            en: "Recommended starter",
            ja: "おすすめのスターター",
            ko: "추천 스타터",
            zh: "推荐的入门模型")
        public static let alreadyHaveModels = L10nEntry(
            en: "Already have models?",
            ja: "すでにモデルをお持ちですか？",
            ko: "이미 모델이 있으신가요?",
            zh: "已经有模型了？")
        public static let advancedSetupTitle = L10nEntry(
            en: "Advanced Setup",
            ja: "詳細設定",
            ko: "고급 설정",
            zh: "高级设置")
        public static let advancedSetupBody = L10nEntry(
            en: "Point MLX Studio at your existing model folders, add authentication for gated repos, and decide whether to expose the local API immediately.",
            ja: "MLX Studio を既存のモデルフォルダに向け、ゲート付きリポジトリの認証を追加し、ローカルAPIをすぐに公開するかを決めます。",
            ko: "MLX Studio를 기존 모델 폴더로 지정하고, 게이트된 저장소 인증을 추가하고, 로컬 API를 즉시 노출할지 결정하세요.",
            zh: "将 MLX Studio 指向你现有的模型文件夹，为受限仓库添加身份验证，并决定是否立即公开本地 API。")
        public static let selected = L10nEntry(
            en: "Selected", ja: "選択済み", ko: "선택됨", zh: "已选择")

        // Interpolated (%d / %@) — same placeholder count across all locales.
        public static let firstRunStepFormat = L10nEntry(
            en: "First run — step %d of 3",
            ja: "初回起動 — ステップ %d / 3",
            ko: "첫 실행 — 3단계 중 %d단계",
            zh: "首次运行 — 第 %d 步，共 3 步")
        public static let finishOpensFormat = L10nEntry(
            en: "Finish opens %@",
            ja: "完了すると %@ が開きます",
            ko: "완료하면 %@ 이(가) 열립니다",
            zh: "完成后将打开 %@")
        public static let opensFormat = L10nEntry(
            en: "Opens %@", ja: "%@ を開きます", ko: "%@ 을(를) 엽니다", zh: "打开 %@")

        // Accessibility labels.
        public static let a11yHFToken = L10nEntry(
            en: "Onboarding Hugging Face token",
            ja: "オンボーディング Hugging Face トークン",
            ko: "온보딩 Hugging Face 토큰",
            zh: "引导 Hugging Face 令牌")
        public static let a11yReadyHandoff = L10nEntry(
            en: "Ready handoff",
            ja: "準備完了の引き継ぎ",
            ko: "준비 완료 핸드오프",
            zh: "就绪交接")
        public static let a11yFirstResultPath = L10nEntry(
            en: "First result path",
            ja: "最初の成果パス",
            ko: "첫 결과 경로",
            zh: "第一个成果路径")
        public static let a11yGoalRoutes = L10nEntry(
            en: "Goal routes",
            ja: "目標ルート",
            ko: "목표 경로",
            zh: "目标路径")
        public static let a11yOnboardingRouteFormat = L10nEntry(
            en: "Onboarding %@ route",
            ja: "オンボーディング %@ ルート",
            ko: "온보딩 %@ 경로",
            zh: "引导 %@ 路径")
    }
}

public extension L10n {
    /// Active MLX Studio surfaces (MLXStudioScreens.swift). Draft ja/ko/zh —
    /// native review pending (see file header). Proper nouns (vMLX, MLX
    /// Studio, HF, JANG, OpenAI, DeAlign, cURL, Hugging Face) left as-is.
    enum Studio {
        static let addFolder = L10nEntry(en: "Add Folder", ja: "フォルダを追加", ko: "폴더 추가", zh: "添加文件夹")
        static let advModelsCopyPath = L10nEntry(en: "Advanced Models Copy Path", ja: "詳細モデル パスをコピー", ko: "고급 모델 경로 복사", zh: "高级模型 复制路径")
        static let advModelsRunInspect = L10nEntry(en: "Advanced Models Run Inspect", ja: "詳細モデル 検査を実行", ko: "고급 모델 검사 실행", zh: "高级模型 运行检查")
        static let advanced = L10nEntry(en: "Advanced", ja: "詳細", ko: "고급", zh: "高级")
        static let artifactLedger = L10nEntry(en: "Artifact Ledger", ja: "成果物台帳", ko: "아티팩트 원장", zh: "工件账本")
        static let benchmark = L10nEntry(en: "Benchmark", ja: "ベンチマーク", ko: "벤치마크", zh: "基准测试")
        static let bestReadyAction = L10nEntry(en: "Best ready action", ja: "最適な次の操作", ko: "가장 적합한 준비된 작업", zh: "最佳就绪操作")
        static let browseModels = L10nEntry(en: "Browse Models", ja: "モデルを参照", ko: "모델 찾아보기", zh: "浏览模型")
        static let category = L10nEntry(en: "Category", ja: "カテゴリ", ko: "카테고리", zh: "类别")
        static let chatComposer = L10nEntry(en: "Chat composer", ja: "チャット作成欄", ko: "채팅 작성기", zh: "聊天编辑器")
        static let chatModelPicker = L10nEntry(en: "Chat Model Picker", ja: "チャットモデル選択", ko: "채팅 모델 선택기", zh: "聊天模型选择器")
        static let chatModel = L10nEntry(en: "Chat model", ja: "チャットモデル", ko: "채팅 모델", zh: "聊天模型")
        static let chat = L10nEntry(en: "Chat", ja: "チャット", ko: "채팅", zh: "聊天")
        static let checkingRuntimeCompat = L10nEntry(en: "Checking vMLX runtime compatibility", ja: "vMLX ランタイム互換性を確認中", ko: "vMLX 런타임 호환성 확인 중", zh: "正在检查 vMLX 运行时兼容性")
        static let chooseStarterModel = L10nEntry(en: "Choose a starter model", ja: "スターターモデルを選択", ko: "스타터 모델 선택", zh: "选择入门模型")
        static let clearIssues = L10nEntry(en: "Clear Issues", ja: "問題をクリア", ko: "문제 지우기", zh: "清除问题")
        static let clientHandshake = L10nEntry(en: "Client Handshake", ja: "クライアントハンドシェイク", ko: "클라이언트 핸드셰이크", zh: "客户端握手")
        static let configKeys = L10nEntry(en: "Config Keys", ja: "設定キー", ko: "구성 키", zh: "配置键")
        static let conversationRunway = L10nEntry(en: "Conversation runway", ja: "会話の残り容量", ko: "대화 여유 공간", zh: "对话余量")
        static let copyBrief = L10nEntry(en: "Copy Brief", ja: "概要をコピー", ko: "브리핑 복사", zh: "复制简报")
        static let copyCurl = L10nEntry(en: "Copy cURL", ja: "cURL をコピー", ko: "cURL 복사", zh: "复制 cURL")
        static let copyEndpoint = L10nEntry(en: "Copy Endpoint", ja: "エンドポイントをコピー", ko: "엔드포인트 복사", zh: "复制端点")
        static let copyHealth = L10nEntry(en: "Copy Health", ja: "ヘルスをコピー", ko: "상태 복사", zh: "复制健康信息")
        static let copyOutput = L10nEntry(en: "Copy Output", ja: "出力をコピー", ko: "출력 복사", zh: "复制输出")
        static let copyPath = L10nEntry(en: "Copy Path", ja: "パスをコピー", ko: "경로 복사", zh: "复制路径")
        static let copy = L10nEntry(en: "Copy", ja: "コピー", ko: "복사", zh: "复制")
        static let createFirstVisualHint = L10nEntry(en: "Create your first visual result and it will live here with its prompt, model, settings, and file.", ja: "最初のビジュアル成果を作成すると、プロンプト・モデル・設定・ファイルとともにここに保存されます。", ko: "첫 시각적 결과를 만들면 프롬프트, 모델, 설정, 파일과 함께 여기에 저장됩니다.", zh: "创建你的第一个视觉成果，它将连同提示词、模型、设置和文件一起保存在这里。")
        static let deAlignMascot = L10nEntry(en: "DeAlign mascot", ja: "DeAlign マスコット", ko: "DeAlign 마스코트", zh: "DeAlign 吉祥物")
        static let deleteChatSessionQ = L10nEntry(en: "Delete chat session?", ja: "チャットセッションを削除しますか？", ko: "채팅 세션을 삭제할까요?", zh: "删除聊天会话？")
        static let deleteChat = L10nEntry(en: "Delete chat", ja: "チャットを削除", ko: "채팅 삭제", zh: "删除聊天")
        static let deleteImageArtifactQ = L10nEntry(en: "Delete image artifact?", ja: "画像成果物を削除しますか？", ko: "이미지 아티팩트를 삭제할까요?", zh: "删除图像工件？")
        static let deleteImage = L10nEntry(en: "Delete image", ja: "画像を削除", ko: "이미지 삭제", zh: "删除图像")
        static let endpoint = L10nEntry(en: "Endpoint", ja: "エンドポイント", ko: "엔드포인트", zh: "端点")
        static let evidence = L10nEntry(en: "Evidence", ja: "エビデンス", ko: "증거", zh: "证据")
        static let exportReport = L10nEntry(en: "Export Report", ja: "レポートを書き出す", ko: "보고서 내보내기", zh: "导出报告")
        static let followUpPrompts = L10nEntry(en: "Follow-up prompts", ja: "フォローアップのプロンプト", ko: "후속 프롬프트", zh: "后续提示词")
        static let gated = L10nEntry(en: "Gated", ja: "ゲート付き", ko: "게이트됨", zh: "受限")
        static let hfAuth = L10nEntry(en: "HF auth", ja: "HF 認証", ko: "HF 인증", zh: "HF 认证")
        static let imageProvenance = L10nEntry(en: "Image provenance", ja: "画像の来歴", ko: "이미지 출처", zh: "图像来源")
        static let incidentBrief = L10nEntry(en: "Incident Brief", ja: "インシデント概要", ko: "인시던트 브리핑", zh: "事件简报")
        static let keepMoving = L10nEntry(en: "Keep moving", ja: "続ける", ko: "계속 진행", zh: "继续")
        static let latestImage = L10nEntry(en: "Latest image", ja: "最新の画像", ko: "최신 이미지", zh: "最新图像")
        static let level = L10nEntry(en: "Level", ja: "レベル", ko: "레벨", zh: "级别")
        static let localArtifactsBeforeInspect = L10nEntry(en: "Local artifacts before a deep inspect", ja: "詳細検査前のローカル成果物", ko: "심층 검사 전 로컬 아티팩트", zh: "深度检查前的本地工件")
        static let message = L10nEntry(en: "Message", ja: "メッセージ", ko: "메시지", zh: "消息")
        static let mlxJangHf = L10nEntry(en: "MLX/JANG/HF", ja: "MLX/JANG/HF", ko: "MLX/JANG/HF", zh: "MLX/JANG/HF")
        static let modelArchive = L10nEntry(en: "Model archive", ja: "モデルアーカイブ", ko: "모델 아카이브", zh: "模型归档")
        static let modelFilesNotDeleted = L10nEntry(en: "Model files and image outputs are not deleted.", ja: "モデルファイルと画像出力は削除されません。", ko: "모델 파일과 이미지 출력은 삭제되지 않습니다.", zh: "模型文件和图像输出不会被删除。")
        static let modelsChatsNotDeleted = L10nEntry(en: "Models, chats, and other image outputs are not deleted.", ja: "モデル・チャット・その他の画像出力は削除されません。", ko: "모델, 채팅 및 기타 이미지 출력은 삭제되지 않습니다.", zh: "模型、聊天和其他图像输出不会被删除。")
        static let newChat = L10nEntry(en: "New Chat", ja: "新しいチャット", ko: "새 채팅", zh: "新建聊天")
        static let new = L10nEntry(en: "New", ja: "新規", ko: "새로 만들기", zh: "新建")
        static let newestFirst = L10nEntry(en: "Newest first", ja: "新しい順", ko: "최신순", zh: "最新优先")
        static let nextMove = L10nEntry(en: "Next move", ja: "次の操作", ko: "다음 작업", zh: "下一步")
        static let noChatCapableModels = L10nEntry(en: "No chat-capable models", ja: "チャット対応モデルがありません", ko: "채팅 가능한 모델이 없습니다", zh: "没有支持聊天的模型")
        static let noImageYet = L10nEntry(en: "No image yet", ja: "画像はまだありません", ko: "아직 이미지가 없습니다", zh: "暂无图像")
        static let openCanvas = L10nEntry(en: "Open canvas", ja: "キャンバスを開く", ko: "캔버스 열기", zh: "打开画布")
        static let openChat = L10nEntry(en: "Open Chat", ja: "チャットを開く", ko: "채팅 열기", zh: "打开聊天")
        static let openCreate = L10nEntry(en: "Open Create", ja: "作成を開く", ko: "생성 열기", zh: "打开创作")
        static let open = L10nEntry(en: "Open", ja: "開く", ko: "열기", zh: "打开")
        static let openAILoopbackService = L10nEntry(en: "OpenAI-compatible loopback service", ja: "OpenAI 互換のループバックサービス", ko: "OpenAI 호환 루프백 서비스", zh: "OpenAI 兼容的回环服务")
        static let operatorChecklist = L10nEntry(en: "Operator Checklist", ja: "オペレーターチェックリスト", ko: "운영자 체크리스트", zh: "操作员清单")
        static let operatorLane = L10nEntry(en: "Operator lane", ja: "オペレーターレーン", ko: "운영자 레인", zh: "操作员通道")
        static let operatorSequence = L10nEntry(en: "Operator sequence", ja: "オペレーターシーケンス", ko: "운영자 시퀀스", zh: "操作员序列")
        static let operatorSignal = L10nEntry(en: "Operator signal", ja: "オペレーターシグナル", ko: "운영자 신호", zh: "操作员信号")
        static let orChooseStarterBelow = L10nEntry(en: "Or choose a recommended starter below.", ja: "または下のおすすめスターターから選択してください。", ko: "또는 아래 추천 스타터 중에서 선택하세요.", zh: "或从下方选择推荐的入门模型。")
        static let pinned = L10nEntry(en: "Pinned", ja: "ピン留め済み", ko: "고정됨", zh: "已置顶")
        static let preflightInspector = L10nEntry(en: "Preflight inspector", ja: "プリフライト検査", ko: "사전 점검 검사기", zh: "预检检查器")
        static let queue = L10nEntry(en: "Queue", ja: "キュー", ko: "대기열", zh: "队列")
        static let recentSessions = L10nEntry(en: "Recent sessions", ja: "最近のセッション", ko: "최근 세션", zh: "最近的会话")
        static let recentWork = L10nEntry(en: "Recent work", ja: "最近の作業", ko: "최근 작업", zh: "最近的工作")
        static let recoveryPath = L10nEntry(en: "Recovery Path", ja: "リカバリーパス", ko: "복구 경로", zh: "恢复路径")
        static let refresh = L10nEntry(en: "Refresh", ja: "更新", ko: "새로고침", zh: "刷新")
        static let resumeSession = L10nEntry(en: "Resume session", ja: "セッションを再開", ko: "세션 재개", zh: "恢复会话")
        static let reuseLane = L10nEntry(en: "Reuse lane", ja: "再利用レーン", ko: "재사용 레인", zh: "复用通道")
        static let reuseLatestPrompt = L10nEntry(en: "Reuse latest prompt", ja: "最新のプロンプトを再利用", ko: "최신 프롬프트 재사용", zh: "复用最新提示词")
        static let reuseLatest = L10nEntry(en: "Reuse Latest", ja: "最新を再利用", ko: "최신 재사용", zh: "复用最新")
        static let reveal = L10nEntry(en: "Reveal", ja: "Finder で表示", ko: "표시", zh: "在访达中显示")
        static let runHubSearch = L10nEntry(en: "Run Hub Search", ja: "Hub 検索を実行", ko: "허브 검색 실행", zh: "运行 Hub 搜索")
        static let runInspect = L10nEntry(en: "Run Inspect", ja: "検査を実行", ko: "검사 실행", zh: "运行检查")
        static let runtimeContract = L10nEntry(en: "Runtime Contract", ja: "ランタイム契約", ko: "런타임 계약", zh: "运行时约定")
        static let searchHuggingFace = L10nEntry(en: "Search Hugging Face", ja: "Hugging Face を検索", ko: "Hugging Face 검색", zh: "搜索 Hugging Face")
        static let searchLibrary = L10nEntry(en: "Search Library", ja: "ライブラリを検索", ko: "라이브러리 검색", zh: "搜索库")
        static let search = L10nEntry(en: "Search", ja: "検索", ko: "검색", zh: "搜索")
        static let studioMemoryA11y = L10nEntry(en: "Searchable studio memory for images, chats, models, and pinned sessions", ja: "画像・チャット・モデル・ピン留めセッションを検索できるスタジオメモリ", ko: "이미지, 채팅, 모델, 고정된 세션을 검색할 수 있는 스튜디오 메모리", zh: "可搜索的工作室记忆，涵盖图像、聊天、模型和置顶会话")
        static let serverEndpointStripCopy = L10nEntry(en: "Server endpoint strip Copy Endpoint", ja: "サーバーエンドポイント バー エンドポイントをコピー", ko: "서버 엔드포인트 표시줄 엔드포인트 복사", zh: "服务器端点栏 复制端点")
        static let serverPort = L10nEntry(en: "Server Port", ja: "サーバーポート", ko: "서버 포트", zh: "服务器端口")
        static let serverRuntimeCopy = L10nEntry(en: "Server runtime Copy Endpoint", ja: "サーバーランタイム エンドポイントをコピー", ko: "서버 런타임 엔드포인트 복사", zh: "服务器运行时 复制端点")
        static let serverToolbarCopy = L10nEntry(en: "Server toolbar Copy Endpoint", ja: "サーバーツールバー エンドポイントをコピー", ko: "서버 도구 모음 엔드포인트 복사", zh: "服务器工具栏 复制端点")
        static let sessionBrief = L10nEntry(en: "Session brief", ja: "セッション概要", ko: "세션 브리핑", zh: "会话简报")
        static let sessionContext = L10nEntry(en: "Session context", ja: "セッションコンテキスト", ko: "세션 컨텍스트", zh: "会话上下文")
        static let sessionTrail = L10nEntry(en: "Session trail", ja: "セッション履歴", ko: "세션 기록", zh: "会话轨迹")
        static let startServer = L10nEntry(en: "Start Server", ja: "サーバーを開始", ko: "서버 시작", zh: "启动服务器")
        static let stop = L10nEntry(en: "Stop", ja: "停止", ko: "중지", zh: "停止")
        static let streaming = L10nEntry(en: "Streaming", ja: "ストリーミング", ko: "스트리밍", zh: "流式传输")
        static let studioMemory = L10nEntry(en: "Studio memory", ja: "スタジオメモリ", ko: "스튜디오 메모리", zh: "工作室记忆")
        static let valuesClientsNeed = L10nEntry(en: "The values clients need before sending traffic to this local server.", ja: "このローカルサーバーにトラフィックを送る前にクライアントが必要とする値です。", ko: "이 로컬 서버로 트래픽을 보내기 전에 클라이언트에 필요한 값입니다.", zh: "客户端向此本地服务器发送流量前所需的值。")
        static let checksReadFolderHint = L10nEntry(en: "These checks read the selected folder directly so the operator can see whether the model is ready for validation, benchmark, or report export.", ja: "これらのチェックは選択したフォルダを直接読み取り、モデルが検証・ベンチマーク・レポート書き出しの準備ができているかを確認できます。", ko: "이 검사들은 선택한 폴더를 직접 읽어 모델이 검증, 벤치마크 또는 보고서 내보내기에 준비되었는지 운영자가 확인할 수 있게 합니다.", zh: "这些检查会直接读取所选文件夹，让操作员了解模型是否已准备好进行验证、基准测试或报告导出。")
        static let time = L10nEntry(en: "Time", ja: "時刻", ko: "시간", zh: "时间")
        static let transcript = L10nEntry(en: "Transcript", ja: "トランスクリプト", ko: "대화 기록", zh: "转录")
        static let tryFirstPrompt = L10nEntry(en: "Try a useful first prompt", ja: "便利な最初のプロンプトを試す", ko: "유용한 첫 프롬프트를 시도해 보세요", zh: "试试一个实用的初始提示词")
        static let validate = L10nEntry(en: "Validate", ja: "検証", ko: "검증", zh: "验证")
        static let vmlxRuntime = L10nEntry(en: "vMLX runtime", ja: "vMLX ランタイム", ko: "vMLX 런타임", zh: "vMLX 运行时")

        // Interpolated (%d / %@). Purely-numeric or value-join interpolations
        // (e.g. "\(count)", "\(family) - \(modality)") are locale-neutral and
        // intentionally left inline.
        static let turnsCountFormat = L10nEntry(en: "%d turns", ja: "%d ターン", ko: "%d 턴", zh: "%d 轮")
        static let compatibleResultsFormat = L10nEntry(en: "%d compatible results", ja: "互換性のある結果 %d 件", ko: "호환 결과 %d개", zh: "%d 个兼容结果")
        static let a11yOpenModelInModels = L10nEntry(en: "Open model %@ in Models", ja: "モデル %@ を「モデル」で開く", ko: "모델에서 %@ 열기", zh: "在“模型”中打开模型 %@")
        static let a11yRevealModel = L10nEntry(en: "Reveal model %@", ja: "モデル %@ を表示", ko: "모델 %@ 표시", zh: "显示模型 %@")
        static let a11yCopyModelPath = L10nEntry(en: "Copy model path %@", ja: "モデルパス %@ をコピー", ko: "모델 경로 %@ 복사", zh: "复制模型路径 %@")
        static let a11yExportModelReport = L10nEntry(en: "Export model report %@", ja: "モデルレポート %@ を書き出す", ko: "모델 보고서 %@ 내보내기", zh: "导出模型报告 %@")
        static let a11yDownloadAndChat = L10nEntry(en: "Download and Chat %@", ja: "%@ をダウンロードしてチャット", ko: "%@ 다운로드 후 채팅", zh: "下载并聊天 %@")
        static let a11yQueueDownload = L10nEntry(en: "Queue Download %@", ja: "%@ のダウンロードをキューに追加", ko: "%@ 다운로드 대기열에 추가", zh: "将 %@ 加入下载队列")
    }
}
