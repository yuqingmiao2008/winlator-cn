#!/usr/bin/env python3
"""
reg-patch.py - 向 Wine 前缀的 system.reg 注入中文字体注册与字体替换项

用法: reg-patch.py <system.reg 路径> [更多 system.reg 路径...]

功能:
 1. 在 [Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts] 注册 Noto Sans CJK SC
 2. 在 [Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes] 将
    SimSun / Microsoft YaHei / SimHei / KaiTi / FangSong 等替换为 Noto Sans CJK SC
 3. 将默认 ANSI/系统代码页字体在中文环境下的显示交给 Noto 字体
"""
import re
import sys

FONTS_SECTION = r"Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
SUBST_SECTION = r"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"

FONT_ENTRIES = [
    ('"Noto Sans CJK SC (TrueType)"', '"NotoSansCJKsc-Regular.otf"'),
    ('"Noto Sans CJK SC Bold (TrueType)"', '"NotoSansCJKsc-Bold.otf"'),
]

SUBSTITUTES = [
    ("SimSun", "Noto Sans CJK SC"),
    ("NSimSun", "Noto Sans CJK SC"),
    ("SimHei", "Noto Sans CJK SC"),
    ("Microsoft YaHei", "Noto Sans CJK SC"),
    ("Microsoft YaHei UI", "Noto Sans CJK SC"),
    ("KaiTi", "Noto Sans CJK SC"),
    ("FangSong", "Noto Sans CJK SC"),
    ("Microsoft JhengHei", "Noto Sans CJK SC"),
    ("Microsoft JhengHei UI", "Noto Sans CJK SC"),
    ("MingLiU", "Noto Sans CJK SC"),
    ("PMingLiU", "Noto Sans CJK SC"),
    ("MS Shell Dlg", "Noto Sans CJK SC"),
    ("MS Shell Dlg 2", "Noto Sans CJK SC"),
    ("Tahoma", "Noto Sans CJK SC"),
    ("Segoe UI", "Noto Sans CJK SC"),
]


def split_sections(text):
    """返回 [(header_line_start, header_line, end_pos), ...] 及各段内容范围"""
    sections = []
    lines = text.split("\n")
    pos = 0
    current = None
    for i, line in enumerate(lines):
        if line.startswith("[") and line.rstrip().endswith("]"):
            if current:
                current[2] = pos
                sections.append(current)
            current = [pos, line, None]
        pos += len(line) + 1
    if current:
        current[2] = pos
        sections.append(current)
    return sections


def patch(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()

    changed = []

    for start, header, end in split_sections(text):
        # 段头形如: [Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts] 1712345678
        m = re.match(r"^\[([^\]]+)\]", header)
        if not m:
            continue
        sec = m.group(1)
        body = text[start:end]
        new_body = body

        if sec == FONTS_SECTION:
            for key, val in FONT_ENTRIES:
                name = key.strip('"')
                if name not in body:
                    # 插到段头之后（第一行末尾）
                    nl = body.find("\n")
                    new_body = body[: nl + 1] + f"{key}={val}\n" + body[nl + 1 :]
                    changed.append(f"Fonts += {name}")
                    body = new_body
        elif sec == SUBST_SECTION:
            for name, target in SUBSTITUTES:
                pat = re.compile(r'^"%s"=' % re.escape(name), re.M)
                if pat.search(body):
                    # 已存在 -> 替换目标
                    new_body = re.sub(
                        r'^"%s"=.*$' % re.escape(name),
                        f'"{name}"="{target}"',
                        body,
                        flags=re.M,
                    )
                    if new_body != body:
                        changed.append(f"Subst ~= {name}")
                    body = new_body
                else:
                    nl = body.find("\n")
                    body = body[: nl + 1] + f'"{name}"="{target}"\n' + body[nl + 1 :]
                    changed.append(f"Subst += {name}")

        if body != new_body or body != text[start:end]:
            text = text[:start] + body + text[end:]

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    return changed


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for path in sys.argv[1:]:
        try:
            changes = patch(path)
            print(f"[reg-patch] {path}: {len(changes)} 处更新")
            for c in changes[:8]:
                print(f"    - {c}")
        except FileNotFoundError:
            print(f"[reg-patch] 跳过不存在的文件: {path}")


if __name__ == "__main__":
    main()
