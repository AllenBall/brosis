#!/usr/bin/env python3
"""shell 脚本里 `$VAR` 紧跟非 ASCII 字符的地方必须写 `${VAR}`（发布闸门第 0c 步）。

为什么需要它（2026-09-15）：macOS 27 的 /bin/bash 3.2 会把 `"$IDENTITY（Team ID …）"` 里
全角括号的**首字节**吃进变量名，`set -u` 下报 `IDENTITY�: unbound variable`，不开 `-u` 时
输出乱码。四个脚本里有 44 处中文标点紧跟变量，肉眼漏了一处（`$VERSION。`），
所以用机器扫，而不是指望下一个人更细心。

    python3 app/Support/check_shell_braces.py app/build_app.sh dist/build_dmg.sh …
"""
import re
import sys

PATTERN = re.compile(r"\$[A-Za-z_][A-Za-z_0-9]*(?=[^\x00-\x7F])")


def main(paths):
    bad = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                for match in PATTERN.finditer(line):
                    bad.append(f"{path}:{number}: {match.group(0)} 后面紧跟非 ASCII，写成 ${{{match.group(0)[1:]}}}")
    for item in bad:
        print(item)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
