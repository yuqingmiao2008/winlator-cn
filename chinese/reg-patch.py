#!/usr/bin/env python3
"""
reg-patch.py - 向 Wine 前缀的 system.reg 注入中文字体注册与字体替换项

用法: reg-patch.py <system.reg 路径> [更多 system.reg 路径...]

功能:
 1. 在 [Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts] 注册随包注入的 Noto Sans CJK SC
 2. 在 [Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes] 将
    SimSun / Microsoft YaHei / SimHei / KaiTi / FangSong 等替换为 Noto Sans CJK SC
    (上游模板把 "MS Shell Dlg" 指向 SimSun, 没有 SimSun -> Noto 的替换, 中文界面会显示成方块)

修复说明 (相对旧版):
 - 旧版用 line.endswith("]") 判断段头, 但 Wine 写出的段头形如
   "[Software\\\\...\\\\Fonts] 1791642768" (后面带时间戳), 条件永远为假, 整个补丁从未生效
 - 旧版在遍历过程中修改文本却仍用原始偏移切片, 即使放宽段头判断也会错位损坏注册表
 现按"行列表"处理: 先按段头切成段, 只改目标段, 再整体拼回, 不依赖偏移。幂等 (重复运行 0 处更新)。
"""
import re
import sys

FONTS_SECTION = r"Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
SUBST_SECTION = r"Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"

FONT_ENTRIES = [
    ("Noto Sans CJK SC (TrueType)", "NotoSansCJKsc-Regular.otf"),
    ("Noto Sans CJK SC Bold (TrueType)", "NotoSansCJKsc-Bold.otf"),
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

# Wine 段头: [键路径] 时间戳 (时间戳可能缺失); 紧随其后可能有一行 "#time=..." 元数据
HEADER_RE = re.compile(r"^\[(?P<name>[^\]]+)\](?:[ \t]+\d+)?[ \t]*\r?\n?$")


def upsert(section_lines, name, value):
    """在段内设置 "name"="value" (已存在则替换, 不存在则插到元数据行之后)。返回 (新行列表, 描述|None)"""
    wanted = f'"{name}"="{value}"'
    pat = re.compile(r'^"%s"=' % re.escape(name))
    eol = "\r\n" if section_lines and section_lines[0].endswith("\r\n") else "\n"
    for i, line in enumerate(section_lines[1:], start=1):
        if pat.match(line):
            if line.rstrip("\r\n") == wanted:
                return section_lines, None
            return section_lines[:i] + [wanted + eol] + section_lines[i + 1:], f"~= {name}"
    # 插入位置: 段头之后、"#time=" 元数据行之后 (保持 Wine 注册表文件格式)
    at = 1
    while at < len(section_lines) and section_lines[at].startswith("#"):
        at += 1
    return section_lines[:at] + [wanted + eol] + section_lines[at:], f"+= {name}"


def patch(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        lines = f.read().splitlines(keepends=True)

    # 按段头切段: [(header 匹配结果|None, 行列表)], 第一段 (文件头) 的 header 为 None
    sections = []
    for line in lines:
        m = HEADER_RE.match(line)
        if m:
            sections.append([m.group("name"), [line]])
        elif sections:
            sections[-1][1].append(line)
        else:
            sections.append([None, [line]])

    changed = []
    for sec in sections:
        name, body = sec
        if name == FONTS_SECTION:
            for font_name, font_file in FONT_ENTRIES:
                body, c = upsert(body, font_name, font_file)
                if c:
                    changed.append(f"Fonts {c}")
        elif name == SUBST_SECTION:
            for sub_name, target in SUBSTITUTES:
                body, c = upsert(body, sub_name, target)
                if c:
                    changed.append(f"Subst {c}")
        sec[1] = body

    if changed:
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
            f.write("".join("".join(body) for _, body in sections))
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
