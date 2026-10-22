using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace VrcTool
{
    /// <summary>界面语言。中文是源语言（XAML 里写的中文即 key），其余语言通过查表翻译。</summary>
    public enum UiLang
    {
        English = 0,
        ChineseSimplified = 1,
        Japanese = 2,
        Korean = 3,
        Russian = 4,
        Spanish = 5
    }

    /// <summary>
    /// 轻量本地化：以 XAML 里的中文字符串为 key 查表替换。
    ///
    /// 为什么不用 .resx + x:Static：项目里界面文字是直接写在 XAML 的 Text/Content 上的，
    /// 改成资源绑定要动上千行且容易漏。这里在窗口加载后遍历可视树做替换，
    /// 新增语言只要往表里加一列，新增文案只要加一行。
    ///
    /// 0.0.2-beta 覆盖导航、页面标题、主要按钮、设置项和常见状态；其余文案暂保持中文，
    /// 后续版本继续补充。
    /// </summary>
    internal static class Localization
    {
        public static UiLang Current = UiLang.ChineseSimplified;

        private static readonly Dictionary<string, string[]> Table =
            new Dictionary<string, string[]>(StringComparer.Ordinal);

        /// <summary>语言代码，用于持久化。</summary>
        public static string Code(UiLang lang)
        {
            switch (lang)
            {
                case UiLang.English: return "en";
                case UiLang.Japanese: return "ja";
                case UiLang.Korean: return "ko";
                case UiLang.Russian: return "ru";
                case UiLang.Spanish: return "es";
                default: return "zh-CN";
            }
        }

        public static UiLang Parse(string code)
        {
            switch ((code ?? "").Trim().ToLowerInvariant())
            {
                case "en": return UiLang.English;
                case "ja": return UiLang.Japanese;
                case "ko": return UiLang.Korean;
                case "ru": return UiLang.Russian;
                case "es": return UiLang.Spanish;
                default: return UiLang.ChineseSimplified;
            }
        }

        public static string DisplayName(UiLang lang)
        {
            switch (lang)
            {
                case UiLang.English: return "English";
                case UiLang.Japanese: return "日本語";
                case UiLang.Korean: return "한국어";
                case UiLang.Russian: return "Русский";
                case UiLang.Spanish: return "Español";
                default: return "简体中文";
            }
        }

        /// <summary>翻译一条文案；表里没有就原样返回。</summary>
        public static string T(string zh)
        {
            if (string.IsNullOrEmpty(zh)) return zh;
            if (Current == UiLang.ChineseSimplified) return zh;
            string[] row;
            if (!Table.TryGetValue(zh, out row) || row == null) return zh;
            int idx = (int)Current - 1;   // 表中不含中文列
            if (idx < 0 || idx >= row.Length) return zh;
            string s = row[idx];
            return string.IsNullOrEmpty(s) ? zh : s;
        }

        /// <summary>把 root 下所有文字替换成当前语言。</summary>
        public static void Apply(DependencyObject root)
        {
            if (root == null) return;
            try
            {
                Walk(root, 0);
            }
            catch (Exception ex)
            {
                DriverManager.Log("本地化遍历失败: " + ex.Message);
            }
        }

        private static void Walk(DependencyObject node, int depth)
        {
            if (node == null || depth > 60) return;

            // 逐类型取文字
            TextBlock tb = node as TextBlock;
            if (tb != null && !string.IsNullOrEmpty(tb.Text))
            {
                string t = T(tb.Text);
                if (t != tb.Text) tb.Text = t;
            }

            ContentControl cc = node as ContentControl;
            if (cc != null)
            {
                string s = cc.Content as string;
                if (!string.IsNullOrEmpty(s))
                {
                    string t = T(s);
                    if (t != s) cc.Content = t;
                }
            }

            HeaderedContentControl hcc = node as HeaderedContentControl;
            if (hcc != null)
            {
                string hs = hcc.Header as string;
                if (!string.IsNullOrEmpty(hs))
                {
                    string t = T(hs);
                    if (t != hs) hcc.Header = t;
                }
            }

            // 占位提示
            ToolTip tt = node as ToolTip;
            if (tt != null)
            {
                string s = tt.Content as string;
                if (!string.IsNullOrEmpty(s))
                {
                    string t = T(s);
                    if (t != s) tt.Content = t;
                }
            }

            // 子节点
            int n = 0;
            try { n = VisualTreeHelper.GetChildrenCount(node); } catch { n = 0; }
            for (int i = 0; i < n; i++)
            {
                DependencyObject child = null;
                try { child = VisualTreeHelper.GetChild(node, i); } catch { }
                if (child != null) Walk(child, depth + 1);
            }

            // 逻辑树里可能还有未实体化的项（例如未展开的 ComboBox、折叠的卡片）
            foreach (object child in LogicalTreeHelper.GetChildren(node))
            {
                DependencyObject dep = child as DependencyObject;
                if (dep != null && !ReferenceEquals(dep, node)) Walk(dep, depth + 1);
            }
        }

        /// <summary>表格：key 是中文原文，依次为 英文 / 日文 / 韩文 / 俄文 / 西班牙文。</summary>
        private static void Add(string zh, string en, string ja, string ko, string ru, string es)
        {
            Table[zh] = new string[] { en, ja, ko, ru, es };
        }

        static Localization()
        {
            // ---------------- 导航
            Add("一键完成", "One-click", "ワンクリック", "원클릭", "Один клик", "Un clic");
            Add("运维", "Operations", "運用", "운영", "Обслуживание", "Operación");
            Add("安装", "Install", "インストール", "설치", "Установка", "Instalar");
            Add("卸载", "Uninstall", "アンインストール", "제거", "Удаление", "Desinstalar");
            Add("诊断", "Diagnose", "診断", "진단", "Диагностика", "Diagnóstico");
            Add("优选流程", "Workflow", "ワークフロー", "워크플로", "Процедуры", "Flujo");
            Add("全量扫描", "Full scan", "全範囲スキャン", "전체 스캔", "Полное сканирование", "Escaneo completo");
            Add("延迟实测", "Latency test", "遅延測定", "지연 측정", "Измерение задержки", "Medir latencia");
            Add("下载测速", "Speed test", "速度測定", "속도 측정", "Тест скорости", "Medir velocidad");
            Add("清单选用", "Pick from list", "一覧から選択", "목록에서 선택", "Выбор из списка", "Elegir de la lista");
            Add("内核与代理", "Kernel & proxy", "カーネルとプロキシ", "커널 및 프록시", "Ядра и прокси", "Núcleo y proxy");
            Add("内核", "Kernel", "カーネル", "커널", "Ядра", "Núcleo");
            Add("订阅", "Subscription", "購読", "구독", "Подписка", "Suscripción");
            Add("节点", "Nodes", "ノード", "노드", "Узлы", "Nodos");
            Add("设置", "Settings", "設定", "설정", "Настройки", "Ajustes");
            Add("清理缓存", "Clear cache", "キャッシュ削除", "캐시 정리", "Очистить кэш", "Limpiar caché");
            Add("自动优选·标准", "Auto · standard", "自動最適化・標準", "자동 최적화·표준", "Авто · стандарт", "Auto · estándar");
            Add("自动优选·快速", "Auto · fast", "自動最適化・高速", "자동 최적화·빠름", "Авто · быстро", "Auto · rápido");

            // ---------------- 通用按钮与状态
            Add("开启", "Start", "開始", "시작", "Запустить", "Iniciar");
            Add("关闭", "Stop", "停止", "중지", "Остановить", "Detener");
            Add("重启", "Restart", "再起動", "재시작", "Перезапустить", "Reiniciar");
            Add("更新内核", "Update", "更新", "업데이트", "Обновить", "Actualizar");
            Add("停止", "Stop", "停止", "중지", "Остановить", "Detener");
            Add("开始", "Start", "開始", "시작", "Начать", "Iniciar");
            Add("完成", "Done", "完了", "완료", "Готово", "Hecho");
            Add("失败", "Failed", "失敗", "실패", "Ошибка", "Error");
            Add("出错", "Error", "エラー", "오류", "Ошибка", "Error");
            Add("已停止", "Stopped", "停止中", "중지됨", "Остановлено", "Detenido");
            Add("运行中", "Running", "実行中", "실행 중", "Работает", "En ejecución");
            Add("无响应", "No response", "応答なし", "응답 없음", "Нет ответа", "Sin respuesta");
            Add("最小", "Min", "最小", "최소", "Мин", "Mín");
            Add("平均", "Avg", "平均", "평균", "Сред", "Med");
            Add("最大", "Max", "最大", "최대", "Макс", "Máx");
            Add("丢包", "Loss", "損失", "손실", "Потери", "Pérdida");
            Add("抖动", "Jitter", "揺らぎ", "지터", "Джиттер", "Jitter");
            Add("中位", "Median", "中央値", "중앙값", "Медиана", "Mediana");
            Add("成功/总", "OK / total", "成功/合計", "성공/전체", "Успех/всего", "Éxito/total");
            Add("本次延迟", "Latency", "今回の遅延", "이번 지연", "Задержка", "Latencia");
            Add("IP 地址", "IP address", "IP アドレス", "IP 주소", "IP-адрес", "Dirección IP");
            Add("说明", "Note", "説明", "설명", "Примечание", "Nota");
            Add("组", "Group", "グループ", "그룹", "Группа", "Grupo");

            // ---------------- 页面标题与区块
            Add("这一步会做什么", "What this step does", "この手順の内容", "이 단계에서 하는 일", "Что делает этот шаг", "Qué hace este paso");
            Add("运行日志", "Run log", "実行ログ", "실행 로그", "Журнал", "Registro");
            Add("实时 IP 结果", "Live IP results", "リアルタイム IP 結果", "실시간 IP 결과", "Результаты IP", "Resultados IP");
            Add("程序目录", "Program folder", "プログラムフォルダー", "프로그램 폴더", "Папка программы", "Carpeta del programa");
            Add("数据目录", "Data folder", "データフォルダー", "데이터 폴더", "Папка данных", "Carpeta de datos");
            Add("打开数据目录", "Open data folder", "データを開く", "데이터 폴더 열기", "Открыть папку данных", "Abrir carpeta de datos");
            Add("导出诊断包", "Export diagnostics", "診断パッケージ出力", "진단 패키지 내보내기", "Экспорт диагностики", "Exportar diagnóstico");

            // ---------------- 内核页
            Add("winws（DPI 伪装）", "winws (DPI desync)", "winws（DPI 偽装）", "winws (DPI 위장)", "winws (обход DPI)", "winws (elusión DPI)");
            Add("mihomo（代理内核）", "mihomo (proxy kernel)", "mihomo（プロキシ）", "mihomo (프록시 커널)", "mihomo (прокси)", "mihomo (proxy)");
            Add("一键诊断", "Diagnose all", "一括診断", "일괄 진단", "Диагностика", "Diagnóstico rápido");
            Add("迁移旧服务", "Migrate legacy service", "旧サービス移行", "레거시 서비스 마이그레이션", "Перенос старой службы", "Migrar servicio heredado");
            Add("打开内核日志", "Open kernel log", "カーネルログ", "커널 로그 열기", "Журнал ядер", "Abrir registro");
            Add("刷新状态", "Refresh", "状態更新", "상태 새로고침", "Обновить", "Actualizar");

            // ---------------- 订阅页
            Add("导入 / 更新", "Import / update", "読み込み / 更新", "가져오기 / 갱신", "Импорт / обновить", "Importar / actualizar");
            Add("打开订阅目录", "Open folder", "フォルダーを開く", "폴더 열기", "Открыть папку", "Abrir carpeta");
            Add("重启 mihomo 使其生效", "Restart mihomo to apply", "mihomo を再起動して反映", "mihomo 재시작하여 적용", "Перезапустить mihomo", "Reiniciar mihomo");
            Add("订阅组", "Subscription group", "購読グループ", "구독 그룹", "Группа подписки", "Grupo de suscripción");
            Add("（尚未导入）", "(not imported)", "（未読み込み）", "(가져오지 않음)", "(не импортировано)", "(sin importar)");

            // ---------------- 节点页
            Add("TUN 模式", "TUN mode", "TUN モード", "TUN 모드", "Режим TUN", "Modo TUN");
            Add("代理模式", "Proxy mode", "プロキシモード", "프록시 모드", "Режим прокси", "Modo proxy");
            Add("测全部延迟", "Test all latency", "全遅延測定", "전체 지연 측정", "Измерить всё", "Medir todo");
            Add("当前节点", "Current node", "現在のノード", "현재 노드", "Текущий узел", "Nodo actual");

            // ---------------- Ping 页
            Add("Ping（经节点）", "Ping (via nodes)", "Ping（ノード経由）", "Ping (노드 경유)", "Ping (через узлы)", "Ping (por nodos)");
            Add("目标", "Target", "ターゲット", "대상", "Цель", "Objetivo");
            Add("每节点次数", "Tries per node", "ノードごとの回数", "노드당 시도", "Попыток на узел", "Intentos por nodo");
            Add("开始 Ping", "Start ping", "Ping 開始", "Ping 시작", "Начать ping", "Iniciar ping");

            // ---------------- 设置页
            Add("外观", "Appearance", "外観", "모양", "Внешний вид", "Apariencia");
            Add("窗口", "Window", "ウィンドウ", "창", "Окно", "Ventana");
            Add("界面缩放", "UI scale", "UI スケール", "UI 배율", "Масштаб", "Escala");
            Add("语言", "Language", "言語", "언어", "Язык", "Idioma");
            Add("跟随系统（推荐）", "System default", "システムに従う", "시스템 설정", "Как в системе", "Según el sistema");
            Add("浅色", "Light", "ライト", "라이트", "Светлая", "Claro");
            Add("深色", "Dark", "ダーク", "다크", "Тёмная", "Oscuro");
            Add("记住窗口大小和位置", "Remember window size and position", "ウィンドウの位置とサイズを記憶", "창 크기와 위치 기억", "Запоминать размер и позицию", "Recordar tamaño y posición");
            Add("最小化时缩到托盘", "Minimize to tray", "最小化でトレイへ", "최소화 시 트레이로", "Сворачивать в трей", "Minimizar a la bandeja");
            Add("程序启动时自动开启上次用的内核", "Start last used kernel with the app", "前回のカーネルを自動起動", "이전 커널 자동 시작", "Запускать ядро при старте", "Iniciar el núcleo anterior");
            Add("第二个选项默认关闭：没勾选时，打开本程序不会自动拉起任何内核。", "Off by default: with it unchecked, launching the app starts no kernel.", "既定ではオフ。チェックしない限りカーネルは起動しません。", "기본값은 꺼짐이며, 선택하지 않으면 커널을 시작하지 않습니다.", "По умолчанию выключено: без флажка ядра не запускаются.", "Desactivado por defecto: sin marcar, no se inicia ningún núcleo.");

            // ---------------- 应用更新
            Add("应用更新", "App update", "アプリの更新", "앱 업데이트", "Обновление", "Actualización");
            Add("当前版本", "Current version", "現在のバージョン", "현재 버전", "Текущая версия", "Versión actual");
            Add("检查更新", "Check for updates", "更新を確認", "업데이트 확인", "Проверить обновления", "Buscar actualizaciones");
            Add("下载并安装", "Download and install", "ダウンロードしてインストール", "다운로드 및 설치", "Скачать и установить", "Descargar e instalar");

            // ---------------- 常见代码内文案
            Add("发现更新", "Update available", "アップデートがあります", "업데이트 발견", "Доступно обновление", "Actualización disponible");
            Add("发现可用更新：", "Available updates:", "利用可能な更新:", "사용 가능한 업데이트:", "Доступные обновления:", "Actualizaciones disponibles:");
            Add("要现在更新吗？", "Update now?", "今すぐ更新しますか？", "지금 업데이트할까요?", "Обновить сейчас?", "¿Actualizar ahora?");
            Add("是", "Yes", "はい", "예", "Да", "Sí");
            Add("否", "No", "いいえ", "아니요", "Нет", "No");
            Add("确定", "OK", "OK", "확인", "ОК", "Aceptar");
            Add("取消", "Cancel", "キャンセル", "취소", "Отмена", "Cancelar");
            Add("检查失败：", "Check failed: ", "確認に失敗: ", "확인 실패: ", "Ошибка проверки: ", "Error de comprobación: ");
        }
    }
}
