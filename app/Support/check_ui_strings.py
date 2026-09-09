#!/usr/bin/env python3
"""界面文案漏翻检查（发布闸门第 0b 步）。

为什么需要它：`L("中文", "English")` 这种行内写法，编译器只保证**已经包起来**的
字面量两种语言都在，对**忘了包**的那一句一个字都保证不了。2026-09-09 首次全量
转换 500 处，就漏了 18 处——全是同一个 alert 里 messageText 翻了、按钮没翻这种，
肉眼复查根本挡不住。所以兜底放在这里，而不是指望下一个人更细心。

扫的是「一看就是给用户看的」赋值点：alert 按钮与文案、控件标题、菜单项、
状态标签。这些位置上出现裸的中文字面量就报错。

**不扫**自检、CLI、探针与 detail/日志：按项目约定它们保持中文（面向开发排障），
翻译反而会让日志和解释它们的笔记对不上号。

    python3 app/Support/check_ui_strings.py app/Sources/brosis
"""
import os
import re
import sys

# 这些文件整份跳过：面向开发者的输出，中文是有意为之。
SKIP_FILES = ("SelfCheck.swift", "AXProbe.swift", "OCRDump.swift", "SelfTest.swift",
              "AdapterVectors.swift", "main.swift")

# 只有这些赋值 / 构造位置算「用户可见」。
USER_FACING = re.compile(
    r"""(addButton\(withTitle:|messageText\s*=|informativeText\s*=
        |NSMenuItem\(title:|NSButton\(title:|checkboxWithTitle:
        |labelWithString:|wrappingLabelWithString:|placeholderString\s*=
        |window\.title\s*=|\.stringValue\s*=|lastAction\s*=|lastActionNote\s*=
        |panel\.prompt\s*=|panel\.message\s*=|toolTip\s*=)""",
    re.VERBOSE)

CJK = re.compile(r"[一-鿿]")
# 行内已经有 L( 或 LOnOff( 就算包过了。这是行级近似：一行里既有包好的又有裸的
# 会漏报，但那种写法本身就该拆行，实测没有。
WRAPPED = re.compile(r"\bL\(|\bLOnOff\(")
COMMENT = re.compile(r"^\s*(//|/\*|\*)")


def scan(root):
    problems = []
    for dirpath, _, filenames in os.walk(root):
        for name in sorted(filenames):
            if not name.endswith(".swift") or name.endswith(SKIP_FILES):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, 1):
                    if COMMENT.match(line):
                        continue
                    if not USER_FACING.search(line):
                        continue
                    if not CJK.search(line):
                        continue
                    if WRAPPED.search(line):
                        continue
                    problems.append((path, number, line.strip()))
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "app/Sources/brosis"
    problems = scan(root)
    if not problems:
        print("界面文案检查：没有裸的中文字面量")
        return 0
    print("ERROR: 这些用户可见的位置还是裸中文，没有包成 L(\"中文\", \"English\")：",
          file=sys.stderr)
    for path, number, text in problems:
        print("  %s:%d  %s" % (path, number, text[:100]), file=sys.stderr)
    print("\n共 %d 处。面向开发者的输出（自检 / CLI / 日志 detail）不该出现在这里；"
          "如果确实是开发者文案，把它挪出上面那几种赋值位置。" % len(problems),
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
