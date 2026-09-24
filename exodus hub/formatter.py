# [[ formatter ppzudo ]]

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path


TITLE_RE = re.compile(r"^--\s*\[\[.*?\]\]\s*$")
PLAIN_SECTION_RE = re.compile(r"^--\s*(\S+)\s*$")
BRACKET_SECTION_RE = re.compile(r"^--\s*\[\s*(\S+)\s*\]\s*$")
DECORATED_SECTION_RE = re.compile(r"^--\s*=+\s*(\S+)\s*=+\s*--\s*$")
SECTION_PATTERNS = (
    DECORATED_SECTION_RE,
    BRACKET_SECTION_RE,
    PLAIN_SECTION_RE,
)
SECTION_PART_RE = re.compile(r"[/-]")
LOCAL_TABLE_RE = re.compile(r"^\s*(?:local\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*\{")


def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def valid_section(value: str) -> bool:
    value = normalize(value)
    if not value or len(value) > 36 or " " in value:
        return False
    if value.endswith((".", ",", ":", ";", "!", "?")):
        return False

    parts = SECTION_PART_RE.split(value)
    return bool(parts) and all(
        part
        and part[0].isalpha()
        and all(char.isalnum() for char in part[1:])
        for part in parts
    )


def section_from_comment(line: str) -> str | None:
    stripped = line.strip()
    if TITLE_RE.fullmatch(stripped):
        return None

    for pattern in SECTION_PATTERNS:
        match = pattern.fullmatch(stripped)
        if match:
            value = normalize(match.group(1))
            if valid_section(value):
                return f"-- {value}"
            return None

    return None


def strip_inline_comment(line: str) -> str:
    result = []
    quote = None
    escaped = False
    index = 0

    while index < len(line):
        char = line[index]

        if quote:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char in {'"', "'"}:
            quote = char
            result.append(char)
            index += 1
            continue

        if char == "-" and index + 1 < len(line) and line[index + 1] == "-":
            break

        result.append(char)
        index += 1

    return "".join(result).rstrip()


def collect_lines(source: str) -> list[str]:
    result = []

    for line in source.splitlines():
        stripped = line.strip()

        if stripped.startswith("--"):
            section = section_from_comment(line)
            if section:
                result.append(line[: len(line) - len(line.lstrip())] + section)
            continue

        line = strip_inline_comment(line)
        if line.strip():
            result.append(line.rstrip())

    return result


def brace_delta(line: str) -> int:
    delta = 0
    quote = None
    escaped = False
    index = 0

    while index < len(line):
        char = line[index]

        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char in {'"', "'"}:
            quote = char
        elif char == "-" and index + 1 < len(line) and line[index + 1] == "-":
            break
        elif char == "{":
            delta += 1
        elif char == "}":
            delta -= 1

        index += 1

    return delta


def is_section(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("-- ") and not stripped.startswith("-- [[")


def add_table_spacing(lines: list[str]) -> list[str]:
    result = []
    depth = 0
    table_depth = None

    for index, line in enumerate(lines):
        stripped = line.strip()
        starts_table = table_depth is None and LOCAL_TABLE_RE.match(line)
        if starts_table:
            table_depth = depth

        before = depth
        result.append(line.rstrip())
        depth += brace_delta(line)

        if table_depth is not None and before > table_depth and depth <= table_depth:
            table_depth = None
            next_index = index + 1
            while next_index < len(lines) and not lines[next_index].strip():
                next_index += 1
            if next_index >= len(lines) or not is_section(lines[next_index]):
                if result[-1] != "":
                    result.append("")

    return result


def add_section_spacing(lines: list[str]) -> list[str]:
    result = []
    depth = 0
    table_depth = None
    table_has_section = False

    for line in lines:
        if table_depth is None and LOCAL_TABLE_RE.match(line):
            table_depth = depth
            table_has_section = False

        if is_section(line):
            inside_table = table_depth is not None and depth > table_depth
            if inside_table:
                if table_has_section and result and result[-1] != "":
                    result.append("")
                table_has_section = True
            elif result and result[-1] != "":
                result.append("")

        result.append(line)
        depth += brace_delta(line)

        if table_depth is not None and depth <= table_depth:
            table_depth = None
            table_has_section = False

    return result


def collapse_empty_lines(lines: list[str]) -> list[str]:
    result = []

    for line in lines:
        if line == "" and result and result[-1] == "":
            continue
        result.append(line)

    return result


def add_final_return_spacing(lines: list[str]) -> None:
    for index in range(len(lines) - 1, -1, -1):
        if re.match(r"^return(?:\s|$)", lines[index].strip()):
            if index and lines[index - 1] != "":
                lines.insert(index, "")
            return


def normalized_title(file_name: str) -> str:
    return Path(file_name).stem.lower().strip() or "arquivo"


def format_source(source: str, file_name: str) -> str:
    lines = collect_lines(source)
    lines = add_section_spacing(lines)
    lines = add_table_spacing(lines)
    lines = collapse_empty_lines(lines)
    title = f"-- [[ {normalized_title(file_name)} ]]"
    result = [title, ""] + lines
    add_final_return_spacing(result)
    return "\n".join(result).rstrip() + "\n"


def find_stylua() -> str:
    stylua = shutil.which("stylua")
    if not stylua:
        raise RuntimeError("StyLua não encontrado. Instale o StyLua e tente novamente.")
    return stylua


def run_stylua(path: Path) -> None:
    subprocess.run(
        [find_stylua(), "--indent-width", "4", "--column-width", "1000", str(path)],
        check=True,
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Uso: python {Path(sys.argv[0]).name} <script.luau>")
        return 1

    input_path = Path(sys.argv[1])
    if not input_path.is_file():
        print(f"Arquivo não encontrado: {input_path}")
        return 1
    if input_path.suffix.lower() not in {".lua", ".luau"}:
        print("Erro: o arquivo precisa ser .lua ou .luau.")
        return 1

    output_path = input_path.with_name(f"{input_path.stem}_formatted{input_path.suffix}")

    try:
        source = input_path.read_text(encoding="utf-8")
        output_path.write_text(
            format_source(source, input_path.name),
            encoding="utf-8",
            newline="\n",
        )
        run_stylua(output_path)
        formatted = output_path.read_text(encoding="utf-8")
        output_path.write_text(
            format_source(formatted, input_path.name),
            encoding="utf-8",
            newline="\n",
        )
    except UnicodeDecodeError:
        print("Erro: o arquivo não está em UTF-8.")
        return 1
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Erro: {error}")
        return 1

    print(f"Formatado: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

