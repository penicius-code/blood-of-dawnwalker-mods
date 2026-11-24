#!/usr/bin/env python3
"""lualint: static checks for Dawnwalker UE4SS Lua mods (stdlib only, no lua.exe needed).

Checks the crash patterns learned while building these mods:
  ERROR SYNTAX            unbalanced blocks (function/if/do ... end, repeat ... until) or brackets, bad strings/comments
  ERROR HOOK-GAME         RegisterHook("/Game/...") fails in this UE4SS build
  ERROR LOADASSET         bare LoadAsset(...) silently loads nothing; use ksl:LoadAsset_Blocking(...)
  WARN  SCAN-IN-LOOP      FindFirstOf/FindAllOf reachable from a loop callback (34-44 ms per call on the game thread)
  WARN  ASYNC-GAMETHREAD  LoopAsync below 100 ms whose callback calls ExecuteInGameThread, or a second LoopAsync next to
                          one below 100 ms (WolfForm 0.1.1). NOTE for 100 ms+ or a non-literal interval (not seen to crash)
  NOTE  DELAY-API         ExecuteWithDelay / LoopInGameThreadWithDelay / ExecuteInGameThreadWithDelay (suspected, not proven)
  WARN  CACHED-UOBJECT    a function stores a FindFirstOf/FindAllOf/Pawn/PlayerController result in a file-level local
                          (engine singletons GameEngine / Engine / GameInstance are allowed)
  WARN  IFACE-CALL        pawn:HasMatchingGameplayTag() (interface call on an actor; go through the ASC)

NOTE findings show in CLI runs only; the editor hook mode reports ERROR and WARN.
Calibrated 2026-10-09 on 608 .lua files of installed mods: 0 errors.
Not covered: tag-container edits, pcall coverage, property writes during loading.
The call graph is approximate: it follows bare and Module.name calls, not methods or functions passed around in tables.

Suppress a reviewed finding with a comment on the flagged line:  -- lint: ok   or   -- lint: ok CACHED-UOBJECT

Usage:
  python tools\\lualint.py <file|dir> ...       findings as path:line: LEVEL RULE message; exit 1 if any ERROR
  python tools\\lualint.py --summary <dir> ...  counts per rule and per file only
  python tools\\lualint.py --hook               PostToolUse hook mode (reads the hook JSON on stdin)
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict

WORKSPACE = os.environ.get("LUALINT_WORKSPACE", os.getcwd())  # hook mode only: root that holds HOOK_DIRS
HOOK_DIRS = ("created", "modified")
SKIP_DIRS = {"release", "shelved", "Retexture", ".git"}
HOOK_MAX_FINDINGS = 20

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}
LOOP_FUNCS = {"LoopAsync", "LoopInGameThreadAfterFrames", "LoopInGameThreadWithDelay"}
DELAY_FUNCS = {"ExecuteWithDelay", "LoopInGameThreadWithDelay", "ExecuteInGameThreadWithDelay"}
SCAN_FUNCS = {"FindFirstOf", "FindAllOf"}
UOBJECT_SOURCES = {"FindFirstOf", "FindAllOf", "GetPlayerController", "K2_GetPawn"}
SINGLETON_CLASSES = {"GameEngine", "Engine", "GameInstance"}  # may be cached (Hard rules)
FAST_LOOP_MS = 100  # LoopAsync -> ExecuteInGameThread at 100 ms+ has not crashed so far
BLOCK_OPENERS = {"function", "if", "do", "repeat"}
BRACKETS = {"(": ")", "[": "]", "{": "}"}
CLOSERS = {")": "(", "]": "[", "}": "{"}
MULTI_OPS = ("...", "..", "==", "~=", "<=", ">=", "::", "//", "<<", ">>")

LONG_OPEN = re.compile(r"\[(=*)\[")
NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUM_RE = re.compile(r"0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
SUPPRESS_RE = re.compile(r"lint:\s*ok\b([A-Z\-, ]*)")


class LexError(Exception):
    def __init__(self, line, msg):
        super().__init__(msg)
        self.line = line
        self.msg = msg


class Tok:
    __slots__ = ("kind", "val", "line")

    def __init__(self, kind, val, line):
        self.kind = kind  # name, kw, str, num, op
        self.val = val
        self.line = line


class Finding:
    __slots__ = ("level", "rule", "line", "msg")

    def __init__(self, level, rule, line, msg):
        self.level = level
        self.rule = rule
        self.line = line
        self.msg = msg


def tokenize(src):
    """Return (tokens, comments_by_line)."""
    toks = []
    comments = defaultdict(list)
    i, n, line = 0, len(src), 1
    if src.startswith("#"):  # shebang
        i = src.find("\n")
        i = n if i < 0 else i
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if src.startswith("--", i):
            m = LONG_OPEN.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LexError(line, "unfinished long comment")
                text = src[i:j + len(close)]
                comments[line].append(text)
                line += text.count("\n")
                i = j + len(close)
                continue
            j = src.find("\n", i)
            j = n if j < 0 else j
            comments[line].append(src[i:j])
            i = j
            continue
        if c == "[":
            m = LONG_OPEN.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LexError(line, "unfinished long string")
                text = src[m.end():j]
                toks.append(Tok("str", text, line))
                line += src[i:j + len(close)].count("\n")
                i = j + len(close)
                continue
        if c in "\"'":
            start_line = line
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    if j + 1 < n and src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if src[j] == "\n":
                    raise LexError(start_line, "unfinished string")
                j += 1
            if j >= n:
                raise LexError(start_line, "unfinished string")
            toks.append(Tok("str", src[i + 1:j], start_line))
            i = j + 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = NUM_RE.match(src, i)
            toks.append(Tok("num", m.group(), line))
            i = m.end()
            continue
        if c.isalpha() or c == "_":
            m = NAME_RE.match(src, i)
            w = m.group()
            toks.append(Tok("kw" if w in KEYWORDS else "name", w, line))
            i = m.end()
            continue
        for op in MULTI_OPS:
            if src.startswith(op, i):
                toks.append(Tok("op", op, line))
                i += len(op)
                break
        else:
            toks.append(Tok("op", c, line))
            i += 1
    return toks, comments


class Structure:
    """Block/bracket matching plus function ownership, from one pass over the tokens."""

    def __init__(self, toks):
        self.toks = toks
        self.match = {}  # opener index -> closer index (blocks and brackets)
        self.owner = [None] * len(toks)  # token index -> innermost function id (None = file level)
        self.inner = [None] * len(toks)  # token index -> innermost open bracket char, or None
        self.funcs = []  # dicts: start, end, parent, name
        self.error = None  # (line, msg)
        self._parse()

    def _parse(self):
        toks = self.toks
        stack = []  # (value, index)
        fstack = []
        bstack = []
        for i, t in enumerate(toks):
            self.owner[i] = fstack[-1] if fstack else None
            self.inner[i] = bstack[-1] if bstack else None
            v = t.val
            if t.kind == "kw" and v in BLOCK_OPENERS:
                stack.append((v, i))
                if v == "function":
                    fid = len(self.funcs)
                    self.funcs.append({"start": i, "end": None,
                                       "parent": fstack[-1] if fstack else None, "name": None})
                    fstack.append(fid)
            elif t.kind == "kw" and v in ("end", "until"):
                want = ("repeat",) if v == "until" else ("function", "if", "do")
                if not stack or stack[-1][0] not in want:
                    got = "'%s' opened at line %d" % (stack[-1][0], toks[stack[-1][1]].line) if stack else "nothing open"
                    self.error = (t.line, "unexpected '%s' (%s)" % (v, got))
                    return
                opener, oi = stack.pop()
                self.match[oi] = i
                if opener == "function":
                    fid = fstack.pop()
                    self.funcs[fid]["end"] = i
            elif t.kind == "op" and v in BRACKETS:
                stack.append((v, i))
                bstack.append(v)
            elif t.kind == "op" and v in CLOSERS:
                if not stack or stack[-1][0] != CLOSERS[v]:
                    got = "'%s' opened at line %d" % (stack[-1][0], toks[stack[-1][1]].line) if stack else "nothing open"
                    self.error = (t.line, "unexpected '%s' (%s)" % (v, got))
                    return
                _, oi = stack.pop()
                bstack.pop()
                self.match[oi] = i
        if stack:
            v, oi = stack[-1]
            closer = "until" if v == "repeat" else BRACKETS.get(v, "end")
            self.error = (toks[oi].line, "'%s' never closed (missing '%s')" % (v, closer))


def is_call(toks, i):
    """toks[i] is a name used as a call: name( / name"str" / name{...}."""
    if i + 1 >= len(toks):
        return False
    nx = toks[i + 1]
    return (nx.kind == "op" and nx.val in ("(", "{")) or nx.kind == "str"


def prev_val(toks, i, k=1):
    return toks[i - k].val if i - k >= 0 else None


def call_name(toks, i):
    """Callable name at a call site: 'f' for f(), 'M.f' for M.f(), None for methods."""
    p = prev_val(toks, i)
    if p == ":":
        return None
    if p == "." and i >= 2 and toks[i - 2].kind == "name" and prev_val(toks, i, 3) not in (".", ":"):
        return toks[i - 2].val + "." + toks[i].val
    if p == ".":
        return None
    return toks[i].val


class Linter:
    def __init__(self, src):
        self.src = src.lstrip("\ufeff")
        self.findings = []

    def add(self, level, rule, line, msg):
        self.findings.append(Finding(level, rule, line, msg))

    def run(self):
        try:
            self.toks, self.comments = tokenize(self.src)
        except LexError as e:
            self.add("ERROR", "SYNTAX", e.line, e.msg)
            return self.filtered()
        self.st = Structure(self.toks)
        if self.st.error:
            self.add("ERROR", "SYNTAX", *self.st.error)
        self.token_rules()
        if not self.st.error:
            self.name_functions()
            self.flow_rules()
            self.cache_rule()
        return self.filtered()

    def filtered(self):
        out = []
        comments = getattr(self, "comments", {})
        for f in self.findings:
            ok = False
            for text in comments.get(f.line, ()):
                m = SUPPRESS_RE.search(text)
                if m:
                    rules = {r.strip() for r in re.split(r"[ ,]+", m.group(1)) if r.strip()}
                    ok = not rules or f.rule in rules
            if not ok:
                out.append(f)
        out.sort(key=lambda f: (f.line, f.rule))
        return out

    # --- rules that only need tokens -------------------------------------------------------------
    def token_rules(self):
        toks = self.toks
        for i, t in enumerate(toks):
            if t.kind != "name":
                continue
            v = t.val
            if v == "RegisterHook" and is_call(toks, i) and prev_val(toks, i) not in (".", ":"):
                arg = toks[i + 2] if toks[i + 1].val == "(" and i + 2 < len(toks) else toks[i + 1]
                if arg.kind == "str" and arg.val.startswith("/Game/"):
                    self.add("ERROR", "HOOK-GAME", t.line,
                             "RegisterHook on a Blueprint function (%s) fails in this UE4SS build; hook a native function" % arg.val)
            elif v == "LoadAsset" and is_call(toks, i) and prev_val(toks, i) not in (".", ":"):
                self.add("ERROR", "LOADASSET", t.line,
                         "UE4SS LoadAsset() loads nothing here; use ksl:LoadAsset_Blocking(ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path)))")
            elif v in DELAY_FUNCS and is_call(toks, i) and prev_val(toks, i) not in (".", ":"):
                self.add("NOTE", "DELAY-API", t.line,
                         "%s is a suspected crasher in this UE4SS build; prefer one LoopInGameThreadAfterFrames(1) loop with an os.clock() gate" % v)
            elif v == "HasMatchingGameplayTag" and prev_val(toks, i) == ":" and i >= 2:
                recv = toks[i - 2]
                if recv.kind == "name" and re.search(r"pawn|player|character", recv.val, re.I):
                    self.add("WARN", "IFACE-CALL", t.line,
                             "%s:HasMatchingGameplayTag() is an interface call on an actor and fails; use the AbilitySystemComponent" % recv.val)

    # --- function names, call graph, loop reachability -------------------------------------------
    def name_functions(self):
        toks = self.toks
        self.by_name = defaultdict(list)
        for fid, f in enumerate(self.st.funcs):
            i = f["start"]
            name = None
            if i + 1 < len(toks) and toks[i + 1].kind == "name":
                parts, j = [toks[i + 1].val], i + 2
                while j + 1 < len(toks) and toks[j].val in (".", ":") and toks[j + 1].kind == "name":
                    if toks[j].val == ":":
                        parts = None
                        break
                    parts.append(toks[j + 1].val)
                    j += 2
                if parts:
                    name = ".".join(parts[-2:]) if len(parts) > 1 else parts[0]
            elif prev_val(toks, i) == "=" and i >= 2 and toks[i - 2].kind == "name":
                name = toks[i - 2].val
                if prev_val(toks, i, 3) == "." and i >= 4 and toks[i - 4].kind == "name":
                    name = toks[i - 4].val + "." + name
            f["name"] = name
            if name:
                self.by_name[name].append(fid)

    def calls_in(self, start, end):
        toks = self.toks
        out = set()
        for i in range(start, end + 1):
            if toks[i].kind == "name" and is_call(toks, i):
                n = call_name(toks, i)
                if n:
                    out.add(n)
        return out

    def reachable(self, root_spans, root_names):
        """Spans (start, end) reachable from loop roots through named functions."""
        seen_f = set()
        spans = list(root_spans)
        queue = list(root_names)
        for s, e in root_spans:
            queue.extend(self.calls_in(s, e))
        while queue:
            name = queue.pop()
            for fid in self.by_name.get(name, ()):
                if fid in seen_f:
                    continue
                seen_f.add(fid)
                f = self.st.funcs[fid]
                spans.append((f["start"], f["end"]))
                queue.extend(self.calls_in(f["start"], f["end"]))
        return spans

    def loop_roots(self, loop_names):
        """[(loop_token_index, root_spans, root_names)] for each loop call site."""
        toks = self.toks
        out = []
        for i, t in enumerate(toks):
            if t.kind != "name" or t.val not in loop_names or prev_val(toks, i) in (".", ":"):
                continue
            if i + 1 >= len(toks) or toks[i + 1].val != "(":
                continue
            close = self.st.match.get(i + 1)
            if close is None:
                continue
            spans, names = [], []
            j = i + 2
            while j < close:
                tj = toks[j]
                if tj.kind == "kw" and tj.val == "function":
                    end = self.st.match.get(j, close)
                    spans.append((j, end))
                    j = end + 1
                    continue
                if tj.kind == "name" and toks[j - 1].val in ("(", ",") and toks[j + 1].val in (",", ")"):
                    names.append(tj.val)
                j += 1
            out.append((i, spans, names))
        return out

    def flow_rules(self):
        toks = self.toks
        reported = set()
        for li, spans, names in self.loop_roots(LOOP_FUNCS):
            loop = toks[li]
            for s, e in self.reachable(spans, names):
                for k in range(s, e + 1):
                    t = toks[k]
                    if t.kind == "name" and t.val in SCAN_FUNCS and is_call(toks, k) and k not in reported:
                        reported.add(k)
                        self.add("WARN", "SCAN-IN-LOOP", t.line,
                                 "%s runs inside the %s loop at line %d (34-44 ms per call); throttle it or re-resolve through live references"
                                 % (t.val, loop.val, loop.line))
        async_sites = self.loop_roots({"LoopAsync"})
        fast = [self.is_fast_loop(li) for li, _, _ in async_sites]
        for idx, (li, spans, names) in enumerate(async_sites):
            if idx == 1:
                self.add("WARN" if any(fast) else "NOTE", "ASYNC-GAMETHREAD", toks[li].line,
                         "second LoopAsync in this file (first at line %d); the Lua state is shared between threads, use one game-thread loop"
                         % toks[async_sites[0][0]].line)
            for s, e in self.reachable(spans, names):
                if "ExecuteInGameThread" in self.calls_in(s, e):
                    self.add("WARN" if fast[idx] else "NOTE", "ASYNC-GAMETHREAD", toks[li].line,
                             "LoopAsync callback calls ExecuteInGameThread (WolfForm 0.1.1 crashed at 50 ms); prefer LoopInGameThreadAfterFrames(1) with an os.clock() gate")
                    break

    def is_fast_loop(self, li):
        """LoopAsync(<literal below FAST_LOOP_MS>, ...)."""
        arg = self.toks[li + 2] if li + 2 < len(self.toks) else None
        try:
            return arg is not None and arg.kind == "num" and float(arg.val) < FAST_LOOP_MS
        except ValueError:
            return False

    # --- UObjects stored in file-level locals ----------------------------------------------------
    def local_names_after(self, i):
        toks = self.toks
        names = []
        j = i + 1
        if j < len(toks) and toks[j].val == "function":
            j += 1
        while j < len(toks) and toks[j].kind == "name":
            names.append(toks[j].val)
            if j + 1 < len(toks) and toks[j + 1].val == ",":
                j += 2
            else:
                break
        return names

    def cache_rule(self):
        toks = self.toks
        file_locals = set()
        func_locals = defaultdict(list)  # fid -> [(index, name)]
        for fid, f in enumerate(self.st.funcs):
            p = next((k for k in range(f["start"], f["end"]) if toks[k].val == "("), None)
            o = self.st.match.get(p) if p is not None else None
            if o is not None:
                for k in range(p + 1, o):
                    if toks[k].kind == "name":
                        func_locals[fid].append((f["start"], toks[k].val))
        for i, t in enumerate(toks):
            if t.kind == "kw" and t.val in ("local", "for"):
                owner = self.st.owner[i]
                if t.val == "local":
                    names = self.local_names_after(i)
                else:
                    names = []
                    j = i + 1
                    while j < len(toks) and toks[j].val not in ("in", "="):
                        if toks[j].kind == "name":
                            names.append(toks[j].val)
                        j += 1
                if owner is None and t.val == "local":
                    file_locals.update(names)
                elif owner is not None:
                    func_locals[owner].extend((i, n) for n in names)
        if not file_locals:
            return
        for i, t in enumerate(toks):
            if t.kind != "name" or t.val not in file_locals:
                continue
            owner = self.st.owner[i]
            if owner is None or i + 1 >= len(toks) or toks[i + 1].val != "=":
                continue
            if prev_val(toks, i) in (".", ":", "local", ",") or self.st.inner[i] is not None:
                continue
            shadowed, fid = False, owner
            while fid is not None and not shadowed:
                shadowed = any(n == t.val and k < i for k, n in func_locals[fid])
                fid = self.st.funcs[fid]["parent"]
            if shadowed:
                continue
            j, depth, src = i + 2, 0, None
            while j < len(toks):
                tj = toks[j]
                if depth == 0 and tj.line != t.line and j > i + 2 and toks[j - 1].val not in ("(", ",", "and", "or", "="):
                    break
                if tj.val in BRACKETS:
                    depth += 1
                elif tj.val in CLOSERS:
                    depth -= 1
                    if depth < 0:
                        break
                if tj.kind == "name" and tj.val in UOBJECT_SOURCES:
                    arg = toks[j + 2] if j + 2 < len(toks) and toks[j + 1].val == "(" else None
                    if not (arg is not None and arg.kind == "str" and arg.val in SINGLETON_CLASSES):
                        src = tj.val
                elif tj.kind == "name" and tj.val == "Pawn" and prev_val(toks, j) == ".":
                    src = ".Pawn"
                if tj.kind == "kw" and tj.val == "function":
                    break
                j += 1
            if src:
                self.add("WARN", "CACHED-UOBJECT", t.line,
                         "'%s' is a file-level local holding a %s result; UObjects freed on load/death crash IsValid(). Re-resolve every tick"
                         % (t.val, src))


def lint_source(src):
    return Linter(src).run()


def lint_file(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return lint_source(fh.read())


def iter_lua(paths):
    for p in paths:
        if os.path.isfile(p):
            yield p
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for f in sorted(files):
                if f.lower().endswith(".lua"):
                    yield os.path.join(root, f)


def format_findings(path, findings):
    return ["%s:%d: %s %s %s" % (path, f.line, f.level, f.rule, f.msg) for f in findings]


def in_hook_scope(path):
    p = os.path.normcase(os.path.abspath(path))
    if not p.endswith(".lua"):
        return False
    for d in HOOK_DIRS:
        base = os.path.normcase(os.path.join(WORKSPACE, d)) + os.sep
        if p.startswith(base):
            return True
    return False


def hook_main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input") or {}
        tool_response = data.get("tool_response") or {}
        path = tool_input.get("file_path") or tool_response.get("filePath")
        if not path or not in_hook_scope(path) or not os.path.isfile(path):
            return 0
        findings = [f for f in lint_file(path) if f.level != "NOTE"]
        if not findings:
            return 0
        rel = os.path.relpath(path, WORKSPACE)
        lines = format_findings(rel, findings[:HOOK_MAX_FINDINGS])
        if len(findings) > HOOK_MAX_FINDINGS:
            lines.append("... %d more (run python tools\\lualint.py %s)" % (len(findings) - HOOK_MAX_FINDINGS, rel))
        text = "lualint (crash-pattern check):\n" + "\n".join(lines)
        if any(f.level == "ERROR" for f in findings):
            out = {"decision": "block", "reason": text}
        else:
            text += "\nWarnings: fix them, or add '-- lint: ok RULE' on the line if reviewed and fine."
            out = {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}
        sys.stdout.write(json.dumps(out))
    except Exception:
        pass  # a lint bug must never block editing
    return 0


def cli_main(argv):
    summary = "--summary" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__)
        return 2
    by_rule, by_file, errors, files = Counter(), Counter(), 0, 0
    for path in iter_lua(paths):
        files += 1
        findings = lint_file(path)
        for f in findings:
            by_rule["%s %s" % (f.level, f.rule)] += 1
            by_file[path] += 1
            errors += f.level == "ERROR"
        if not summary:
            for line in format_findings(path, findings):
                print(line)
    if summary:
        for k, v in sorted(by_rule.items()):
            print("%5d  %s" % (v, k))
        for k, v in by_file.most_common(15):
            print("%5d  %s" % (v, k))
    print("%d files, %d findings, %d errors" % (files, sum(by_rule.values()), errors))
    return 1 if errors else 0


if __name__ == "__main__":
    if "--hook" in sys.argv:
        sys.exit(hook_main())
    sys.exit(cli_main(sys.argv[1:]))
