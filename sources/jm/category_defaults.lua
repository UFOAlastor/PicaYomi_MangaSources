-- 2026-10-19 /categories 的公开分类快照。
-- 首次安装且接口不可用时兜底; 结构与接口一致, 共用解析和跳转逻辑。
return {
    categories = {
        { name = "最新A漫", slug = "" },
        { name = "同人", slug = "doujin" },
        { name = "單本", slug = "single" },
        { name = "短篇", slug = "short" },
        { name = "其他類", slug = "another" },
        { name = "韓漫", slug = "hanman" },
        { name = "English Manga", slug = "meiman" },
        { name = "Cosplay", slug = "another_cosplay" },
        { name = "3D", slug = "3D" },
        { name = "禁漫漢化組", slug = "禁漫漢化組" },
    },
    blocks = {
        { title = "主題A漫", content = {
            "劇情向", "校園", "純愛", "人妻", "師生", "近親", "百合", "YAOI",
            "性轉", "NTR", "偽娘", "癡女", "全彩", "女性向",
        } },
        { title = "角色 / 扮演", content = {
            "蘿莉", "禦姐", "熟女", "正太", "巨乳", "貧乳", "女王", "教師",
            "女僕", "護士", "泳裝", "眼鏡", "連褲襪", "其他制服", "兔女郎",
        } },
        { title = "特殊PLAY", content = {
            "群交", "足交", "SM", "肛交", "阿黑顏", "藥物", "扶他", "調教",
            "野外露出", "催眠", "自慰", "觸手", "獸交",
        } },
        { title = "其他", content = { "CG集", "重口", "獵奇", "非H", "血腥暴力" } },
    },
}
