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
        [
            find_stylua(),
            "--syntax",
            "Luau",
            "--collapse-simple-statement",
            "Always",
            "--column-width",
            "120",
            "--indent-type",
            "Tabs",
            "--indent-width",
            "4",
            str(path),
        ],
        check=True,
    )


MAX_COMPACT_LINE = 200
MAX_COMPACT_STATEMENTS = 4
BLOCK_WORD_RE = re.compile(r"\b(?:if|then|elseif|else|end|for|while|repeat|until|function|do)\b")
IF_HEADER_RE = re.compile(r"^if\b.*\bthen\s*$")
ELSEIF_HEADER_RE = re.compile(r"^elseif\b.*\bthen\s*$")
ASSIGNMENT_RE = re.compile(
    r"^(?:local\s+)?[A-Za-z_][A-Za-z0-9_]*(?:(?:\s*\.\s*|\s*:\s*)[A-Za-z_][A-Za-z0-9_]*|\s*\[[^\]\n]+\])*"
    r"(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*\s*(?:[+\-*/%^]?=)\s*\S"
)
CALL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:(?:\.|:)[A-Za-z_][A-Za-z0-9_]*|\s*\[[^\]\n]+\])*\s*\(")
RETURN_RE = re.compile(r"^(?:return|break|continue)(?:\s|$)")
CONTINUATION_START_RE = re.compile(r"^(?:and|or|not)\b|^[+*/%^~=<>.,]")


def mask_literals(line: str) -> str:
    chars = list(line)
    index = 0

    while index < len(line):
        if line[index] in {'"', "'"}:
            quote = line[index]
            end = index + 1
            while end < len(line):
                if line[end] == "\\":
                    end += 2
                    continue
                if line[end] == quote:
                    end += 1
                    break
                end += 1
            for offset in range(index, min(end, len(line))):
                chars[offset] = " "
            chars[index] = "x"
            index = end
            continue

        if line[index] == "[":
            opening = re.match(r"\[(=*)\[", line[index:])
            if opening:
                closing = "]" + opening.group(1) + "]"
                content_start = index + opening.end()
                close_at = line.find(closing, content_start)
                end = len(line) if close_at < 0 else close_at + len(closing)
                for offset in range(index, end):
                    chars[offset] = " "
                chars[index] = "x"
                index = end
                continue

        index += 1

    return "".join(chars)


def simple_statement(line: str) -> bool:
    code = mask_literals(line).strip()
    if not code or ";" in code or BLOCK_WORD_RE.search(code) or CONTINUATION_START_RE.search(code):
        return False
    if not (ASSIGNMENT_RE.match(code) or CALL_RE.match(code) or RETURN_RE.match(code)):
        return False
    if code.endswith(("=", ",", ".", "+", "-", "*", "/", "..", "and", "or", "not")):
        return False

    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for char in code:
        if char in "([{":
            stack.append(char)
        elif char in ")]}":
            if not stack or stack.pop() != pairs[char]:
                return False
    return not stack


def line_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip(" \t"))]


def compact_if_at(lines: list[str], start: int) -> list[str] | None:
    opening = lines[start]
    indent = line_indent(opening)
    if not IF_HEADER_RE.fullmatch(mask_literals(opening).strip()):
        return None

    branches = [(opening.strip(), [])]
    current = branches[-1][1]
    saw_else = False
    end_index = None

    for index in range(start + 1, len(lines)):
        line = lines[index]
        stripped = mask_literals(line).strip()
        current_indent = line_indent(line)

        if not stripped:
            continue

        if current_indent == indent:
            if stripped == "end":
                end_index = index
                break
            if stripped == "else" or ELSEIF_HEADER_RE.fullmatch(stripped):
                if saw_else or (stripped == "else" and index == start + 1):
                    return None
                if stripped == "else":
                    saw_else = True
                branches.append((line.strip(), []))
                current = branches[-1][1]
                continue
            return None

        current.append(line)

    if end_index is None or len(branches) < 1:
        return None

    body_indent = indent + "\t"
    compact_branches = []
    for header, body in branches:
        if not body or len(body) > MAX_COMPACT_STATEMENTS:
            return None
        if any(line_indent(item) != body_indent or not simple_statement(item) for item in body):
            return None
        statements = "; ".join(item.strip() for item in body)
        compact_branches.append((header, statements))

    output = []
    for index, (header, statements) in enumerate(compact_branches):
        line = indent + header + " " + statements
        if index == len(compact_branches) - 1:
            line += " end"
        if len(line.expandtabs(4)) > MAX_COMPACT_LINE:
            return None
        output.append(line)

    return output


def compact_simple_if_blocks(source: str) -> str:
    lines = source.splitlines()
    while True:
        candidates = [
            (len(line_indent(line).expandtabs(4)), index)
            for index, line in enumerate(lines)
            if IF_HEADER_RE.fullmatch(mask_literals(line).strip())
        ]
        changed = False
        for _, start in sorted(candidates, reverse=True):
            replacement = compact_if_at(lines, start)
            if replacement is not None:
                index = start + 1
                while index < len(lines):
                    stripped = mask_literals(lines[index]).strip()
                    if line_indent(lines[index]) == line_indent(lines[start]) and stripped == "end":
                        break
                    index += 1
                lines[start : index + 1] = replacement
                changed = True
                break
        if not changed:
            break
    return "\n".join(lines).rstrip() + "\n"


def compact_statement_runs(source: str) -> str:
    lines = source.splitlines()
    result = []
    index = 0

    while index < len(lines):
        line = lines[index]
        indent = line_indent(line)
        if not indent or not simple_statement(line):
            result.append(line)
            index += 1
            continue

        run = [line.strip()]
        cursor = index + 1
        while cursor < len(lines) and len(run) < MAX_COMPACT_STATEMENTS:
            candidate = lines[cursor]
            if line_indent(candidate) != indent or not simple_statement(candidate):
                break
            proposed = indent + "; ".join(run + [candidate.strip()])
            if len(proposed.expandtabs(4)) > MAX_COMPACT_LINE:
                break
            run.append(candidate.strip())
            cursor += 1

        if len(run) > 1:
            result.append(indent + "; ".join(run))
            index = cursor
        else:
            result.append(line)
            index += 1

    return "\n".join(result).rstrip() + "\n"


def compact_blocks(source: str) -> str:
    return compact_statement_runs(compact_simple_if_blocks(source))


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
        formatted = format_source(formatted, input_path.name)
        formatted = compact_blocks(formatted)
        output_path.write_text(
            formatted,
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
