#!/usr/bin/env python3
"""Generate a polished Simplified-Chinese localization for NeoFreeBird 7.3.0.

Reads en.lproj/Localizable.strings from the tweak bundle, keeps the existing
zh_CN translation as the base, applies corrections/terminology overrides, then
writes both zh-Hans.lproj (modern iOS) and zh_CN.lproj (legacy) as binary
plists.  Also writes a complete RenameWords.strings for the "Restore Twitter
terminology" feature.

Usage:
    python3 build_zh.py /path/to/BHTwitter.bundle
"""
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# key -> improved zh-Hans value
OVERRIDES = {
    "COOL_KIDS_SECTION_HEADER_TITLE": "大佬们",
    "AUTO_STREAM_TIMELINE_TITLE": "时间线自动刷新",
    "NFB_STREAM_MENU_TITLE": "时间线自动刷新（流式）",
    "NFB_STREAM_STATE_ON": "流式刷新中",

    "TAB_BAR_THEMING_TITLE": "经典标签栏",
    "TAB_BAR_THEMING_DETAIL": "将你的强调色应用到当前选中的标签项。",
    "RESTORE_TAB_LABELS_TITLE": "标签栏文字",
    "CUSTOM_TAB_BAR_OPTION_TITLE": "编辑导航栏",
    "CUSTOM_TAB_BAR_SETTINGS_NAVIGATION_TITLE": "自定义导航栏",
    "CUSTOM_TAB_BAR_RESET_MESSAGE": "你确定要将导航栏恢复为默认状态吗？",
    "CUSTOM_TAB_BAR_GRID_DETAIL": "点按目的地可添加或移除。拖动下方栏可重新排序。",

    "HIDE_QUICK_COMPOSE_TITLE": "隐藏快速发布",
    "HIDE_QUICK_COMPOSE_DETAIL": "从导航栏中移除快速发布按钮（仅限 Liquid Glass）。",
    "HIDE_PREMIUM_OFFER_TITLE": "不显示 Blue 订阅提示",
    "HIDE_PROMOTED_DETAIL": "移除所有广告。",
    "HIDE_VERIFIED_TWEETS_DETAIL": "在时间线和回复中隐藏已认证账号的推文，"
                                   "除非作者在同一串推文中回复过，或你关注了该账号。",
    "HIDE_BLUE_VERIFIED_DETAIL": "隐藏推文上的付费认证标记（不含品牌或政府账号）。",
    "HIDE_BLOCKED_RETWEETS_DETAIL": "隐藏已屏蔽你的账号的转推。",

    "REPLY_SORTING_DETAIL": "隐藏推文对话中的回复排序按钮。",
    "REPLY_IN_WEBVIEW_DETAIL": "回复发送失败时的备用方案：改为在 x.com 网页端回复，"
                               "而不是在 App 内回复。",
    "NO_FOCUS_LOST_DETAIL": "阻止 Twitter 检测到你切换到了其他 App，"
                            "这样你在推文串中的阅读位置就不会丢失。",
    "NO_TAB_BAR_HIDING_TITLE": "始终显示导航栏",
    "NO_TAB_BAR_HIDING_DETAIL": "滚动时不要隐藏导航栏。",

    "DISABLE_RTL_DETAIL": "即使是习惯从右到左阅读的语言，也强制使用从左到右的布局。",
    "DISABLE_MEDIA_CAROUSEL_TITLE": "关闭媒体轮播",
    "DISABLE_AUTO_TRANSLATE_TITLE": "关闭自动翻译",
    "DISABLE_IMMERSIVE_SCROLL_TITLE": "关闭视频流滑动",
    "DISABLE_VIDEO_DOCKING_TITLE": "关闭视频停靠",

    "COPY_PROFILE_INFO_MENU_OPTION_4": "复制网站",
    "CUSTOM_SEND_SOUND_DEFAULT": "未选择自定义音效",
    "CUSTOM_SEND_SOUND_TITLE": "导入发送音效",
    "CUSTOM_SEND_SOUND_FAILED_TITLE": "发送音效导入失败",
    "CUSTOM_SEND_SOUND_TOO_LONG": "你选择的音效太长了，长度不能超过 7 秒。",
    "CUSTOM_FONTS_TUT_ALERT_MESSAGE": "还没有自定义字体。请先从 App Store 安装 iFont 应用。",

    "STRIP_TRACKING_PARAMS_DETAIL": "从你打开的链接中移除 utm_ 及其他跟踪参数。",
    "MODERN_SETTINGS_MEDIA_TITLE": "照片与视频",
    "MODERN_SETTINGS_APPEARANCE_SUBTITLE": "用主题、自定义 App 图标、字体等，"
                                           "把 Twitter 打造成你的专属样式。",
    "MODERN_SETTINGS_BRANDING_SUBTITLE": "调整 Twitter 品牌还原的程度。",
    "MODERN_SETTINGS_PRESETS_SUBTITLE": "应用一组预设设置，或导出、导入你自己的设置。",
    "MODERN_SETTINGS_LAYOUT_SUBTITLE": "锁定 App、让导航栏保持可见等。",

    "FETCHING_PROGRESS_TITLE": "稍等一下…",
    "RESTORE_TWEET_LABELS_DETAIL": "显示推文是从哪个客户端发布的。",
    "THEME_SETTINGS_NAVIGATION_DETAIL": "选择 Twitter 的主题色，只有你自己能看到。",
    "TWEET_TO_IMAGE_DETAIL": "长按分享按钮，即可将推文导出为图片。",
    "UPLOAD_FULL_HD_VIDEOS_DETAIL": "解锁以 1080p 上传视频。",
    "USE_TENOR_GIFS_DETAIL": "用 Tenor GIF 替代 Twitter 的 GIF（GIPHY），Tenor 的选择更多。",
    "SQUARE_AVATARS_DETAIL": "让所有人的头像都变成方形，就像旧版 Twitter 的品牌账号那样。",
    "SHOW_UNROUNDED_COUNTS_DETAIL": "显示粉丝、关注和推文的精确数字，"
                                    "而不是四舍五入到最近的千或百万。",
    "PADLOCK_DETAIL": "打开 Twitter 时需要 Face ID 或密码。",
    "SETTINGS_IMPORT_SUCCESS_MESSAGE": "已应用 %ld 项设置。重启 App 后全部生效。",
    "SETTINGS_RESET_SUCCESS_MESSAGE": "所有设置已恢复。重启 App 后生效。",
    "LEGACY_LOGIN_INFO_LABEL": "使用用户名和密码登录。\n\n"
                               "不支持 Google 和 Apple 登录。如果你的账号使用其中之一，"
                               "请先为账号设置密码。",
}

RENAME_WORDS = {
    "premium": "blue",
    "Premium": "Blue",
    "X": "Twitter",
    "已发帖": "已发推",
    "已转帖": "已转推",
    "发帖": "发推",
    "帖子": "推文",
    "贴文": "推文",
    "正在发送帖子": "正在发送推文",
    "正在转帖": "正在转推",
    "转帖": "转推",
}

PLACEHOLDER = re.compile(r"%(\d+\$)?[@dulfspxX]+|%lld|%ld|%lu|%@")


def load_strings(path):
    with open(path, "rb") as fh:
        return plistlib.load(fh)


def placeholders(s):
    return sorted(re.findall(r"%(\d+\$)?(?:lld|ld|lu|@|d|u|f|s|p|x|X)", s))


def main():
    bundle = sys.argv[1] if len(sys.argv) > 1 else \
        "/tmp/x1239nfb/Payload/Twitter.app/BHTwitter.bundle"
    en = load_strings(os.path.join(bundle, "en.lproj/Localizable.strings"))
    try:
        base = load_strings(os.path.join(bundle, "zh_CN.lproj/Localizable.strings"))
    except FileNotFoundError:
        base = {}

    zh = {}
    for key, en_val in en.items():
        if key in OVERRIDES:
            zh[key] = OVERRIDES[key]
        elif key in base and base[key].strip():
            zh[key] = base[key]
        else:
            zh[key] = en_val  # should not happen; print a warning below

    missing = [k for k in en if k not in zh or not zh[k].strip()]
    bad_fmt = [(k, en[k], zh.get(k, "")) for k in en
               if placeholders(en[k]) != placeholders(zh.get(k, ""))]
    if missing:
        print("WARN missing:", missing)
    if bad_fmt:
        print("WARN placeholder mismatch:")
        for k, a, b in bad_fmt:
            print("  ", k, a, "=>", b)

    for lproj in ("zh-Hans.lproj", "zh_CN.lproj"):
        out = os.path.join(HERE, lproj)
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "Localizable.strings"), "wb") as fh:
            plistlib.dump(zh, fh, fmt=plistlib.FMT_BINARY, sort_keys=True)
        with open(os.path.join(out, "RenameWords.strings"), "wb") as fh:
            plistlib.dump(RENAME_WORDS, fh, fmt=plistlib.FMT_BINARY, sort_keys=True)

    print(f"wrote {len(zh)} keys to zh-Hans.lproj and zh_CN.lproj")
    if bad_fmt:
        sys.exit(1)


if __name__ == "__main__":
    main()
