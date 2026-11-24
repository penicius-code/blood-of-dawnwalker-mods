"""Tests for lualint. Run: python tools\\test_lualint.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lualint import lint_source  # noqa: E402


def rules(src):
    return [(f.rule, f.line) for f in lint_source(src)]


def rule_names(src):
    return {f.rule for f in lint_source(src)}


def levels(src):
    return [(f.rule, f.level) for f in lint_source(src)]


class Syntax(unittest.TestCase):
    def test_clean_file(self):
        src = 'local function f(a)\n  if a then return 1 elseif a == 2 then return 2 else return 3 end\nend\n' \
              'for i = 1, 3 do f(i) end\nwhile false do end\nrepeat local x = 1 until true\n'
        self.assertEqual(rules(src), [])

    def test_missing_end(self):
        self.assertEqual(rules('local function f()\n  if x then\n    y()\nend\n'), [("SYNTAX", 1)])

    def test_extra_end(self):
        self.assertEqual(rules('local x = 1\nend\n'), [("SYNTAX", 2)])

    def test_bracket_mismatch(self):
        self.assertIn("SYNTAX", rule_names('print((1)\n'))

    def test_keywords_in_strings_and_comments_ignored(self):
        src = ('local s = "end function if"\nlocal t = \'do end\'\n-- end end end\n'
               '--[[ function if do\n end ]]\nlocal l = [==[ end ]] function ]==]\n')
        self.assertEqual(rules(src), [])

    def test_unfinished_string(self):
        self.assertEqual(rules('local s = "abc\nprint(s)\n'), [("SYNTAX", 1)])

    def test_unfinished_long_comment(self):
        self.assertIn("SYNTAX", rule_names('--[[ never closed\nprint(1)\n'))

    def test_escaped_quote(self):
        self.assertEqual(rules('local s = "a \\" end"\n'), [])


class HardRules(unittest.TestCase):
    def test_hook_game(self):
        self.assertEqual(rules('RegisterHook("/Game/_Dawnwalker/X.X_C:Foo", function() end)\n'), [("HOOK-GAME", 1)])

    def test_hook_script_ok(self):
        self.assertEqual(rules('RegisterHook("/Script/DogwoodCombat.PlayerCombatComponent:OnDodge", function() end)\n'), [])

    def test_loadasset(self):
        self.assertEqual(rules('local a = LoadAsset("/Game/X")\n'), [("LOADASSET", 1)])

    def test_loadasset_blocking_ok(self):
        self.assertEqual(rules('local a = ksl:LoadAsset_Blocking(ref)\nlocal b = obj.LoadAsset(x)\n'), [])

    def test_delay_api(self):
        self.assertEqual(rules('ExecuteWithDelay(100, function() end)\n'), [("DELAY-API", 1)])

    def test_iface_call(self):
        self.assertEqual(rules('local ok = pawn:HasMatchingGameplayTag(tag)\n'), [("IFACE-CALL", 1)])

    def test_iface_on_asc_ok(self):
        self.assertEqual(rules('local ok = asc:HasMatchingGameplayTag(tag)\n'), [])


class LoopRules(unittest.TestCase):
    def test_scan_in_anonymous_loop(self):
        src = 'LoopAsync(100, function()\n  local pc = FindFirstOf("PlayerController")\n  return false\nend)\n'
        self.assertEqual(rules(src), [("SCAN-IN-LOOP", 2)])

    def test_scan_through_named_functions(self):
        src = ('local function resolve()\n  return FindAllOf("Character")\nend\n'
               'local function tick()\n  local all = resolve()\nend\n'
               'LoopInGameThreadAfterFrames(1, function()\n  tick()\nend)\n')
        self.assertEqual(rules(src), [("SCAN-IN-LOOP", 2)])

    def test_scan_named_callback_and_module_function(self):
        src = ('local M = {}\nfunction M.find()\n  return FindFirstOf("X")\nend\n'
               'local function tick()\n  M.find()\nend\nLoopAsync(50, tick)\n')
        self.assertEqual(rules(src), [("SCAN-IN-LOOP", 3)])

    def test_scan_outside_loop_ok(self):
        src = 'RegisterKeyBind(Key.F4, function()\n  local pc = FindFirstOf("PlayerController")\nend)\n'
        self.assertEqual(rules(src), [])

    def test_async_gamethread_fast(self):
        src = 'LoopAsync(50, function()\n  ExecuteInGameThread(function() end)\n  return false\nend)\n'
        self.assertEqual(levels(src), [("ASYNC-GAMETHREAD", "WARN")])

    def test_async_gamethread_slow_is_note(self):
        src = 'LoopAsync(100, function()\n  ExecuteInGameThread(function() end)\n  return false\nend)\n'
        self.assertEqual(levels(src), [("ASYNC-GAMETHREAD", "NOTE")])

    def test_async_gamethread_expr_is_note(self):
        src = 'LoopAsync(INTERVAL, function()\n  ExecuteInGameThread(function() end)\nend)\n'
        self.assertEqual(levels(src), [("ASYNC-GAMETHREAD", "NOTE")])

    def test_two_loopasync(self):
        src = 'LoopAsync(50, function() return false end)\nLoopAsync(1000, function() return false end)\n'
        self.assertEqual(levels(src), [("ASYNC-GAMETHREAD", "WARN")])

    def test_two_slow_loopasync_is_note(self):
        src = 'LoopAsync(500, function() return false end)\nLoopAsync(1000, function() return false end)\n'
        self.assertEqual(levels(src), [("ASYNC-GAMETHREAD", "NOTE")])

    def test_delay_api_is_note(self):
        self.assertEqual(levels('ExecuteInGameThreadWithDelay(10, function() end)\n'), [("DELAY-API", "NOTE")])


class CacheRule(unittest.TestCase):
    def test_cached_pawn(self):
        src = 'local cachedPawn = nil\nlocal function tick()\n  cachedPawn = FindFirstOf("PlayerController").Pawn\nend\n'
        self.assertEqual(rules(src), [("CACHED-UOBJECT", 3)])

    def test_shadowed_local_ok(self):
        src = 'local pawn = nil\nlocal function tick()\n  local pawn\n  pawn = GetPlayerController().Pawn\nend\n'
        self.assertEqual(rules(src), [])

    def test_param_shadow_ok(self):
        src = 'local pc\nlocal function f(pc)\n  pc = FindFirstOf("PlayerController")\nend\n'
        self.assertEqual(rules(src), [])

    def test_non_uobject_ok(self):
        src = 'local count = 0\nlocal function tick()\n  count = count + 1\nend\n'
        self.assertEqual(rules(src), [])

    def test_table_field_ok(self):
        src = 'local pawn\nlocal function f()\n  return { pawn = GetPlayerController().Pawn }\nend\n'
        self.assertEqual(rules(src), [])

    def test_engine_singleton_ok(self):
        src = 'local engine = nil\nlocal function f()\n  engine = FindFirstOf("GameEngine")\nend\n'
        self.assertEqual(rules(src), [])

    def test_file_level_assignment_ok(self):
        src = 'local cdo = StaticFindObject("/Script/Engine.Default__GameplayStatics")\n'
        self.assertEqual(rules(src), [])


class Suppression(unittest.TestCase):
    def test_lint_ok(self):
        self.assertEqual(rules('local a = LoadAsset("/Game/X") -- lint: ok\n'), [])

    def test_lint_ok_named_rule(self):
        self.assertEqual(rules('ExecuteWithDelay(1, function() end) -- lint: ok DELAY-API\n'), [])

    def test_lint_ok_other_rule_still_reports(self):
        self.assertEqual(rules('ExecuteWithDelay(1, function() end) -- lint: ok LOADASSET\n'), [("DELAY-API", 1)])


if __name__ == "__main__":
    unittest.main(verbosity=1)
