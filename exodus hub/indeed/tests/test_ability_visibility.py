"""Ensure ability controls recover when the mode notification is missed."""
import re
import unittest
from test_raw_target_parry import ROOT, run_lua

class AbilityVisibility(unittest.TestCase):
    def test_mode_change_event_and_poll_recover_visibility(self):
        source=(ROOT.parent / 'front/controllers/floating.luau').read_text()
        update=source[source.index('  local lastAbilityMode'):source.index('  if not UIState.desktop and config.ClashBallVisible')]
        start=source.index('    refreshAbilities = function()')
        end=source.index('\n    end,',start)
        refresh=source[start:end].replace('    refreshAbilities = function()', 'local function refreshAbilities()')+'\nend\n'
        refresh=re.sub(r'([A-Za-z_][\w.]*) \+= ([^;\n]+?)(?=;|\n| end)',lambda m:f'{m[1]} = {m[1]} + ({m[2]})',refresh)
        run_lua('''
local enabled=true; local signal,heartbeat; local count=0
local GameInfo={areAbilitiesEnabled=function() return enabled end,observeAbilityMode=function(fn) signal=fn; return {} end}
local UIState={desktop=false}; local context={pages={refresh=function() count=count+1 end},refs={darkBall={},jumpBall={},upDashBall={}},services={RunService={Heartbeat={Connect=function(_,fn) heartbeat=fn; return {} end}}}}
local function trackConn(c) return c end
''' + update + refresh + '''
refreshAbilities(); assert(count==1 and context.refs.upDashBall.Visible)
enabled=false; signal(); assert(count==2 and not context.refs.upDashBall.Visible)
enabled=true; heartbeat(.24); assert(not context.refs.upDashBall.Visible)
heartbeat(.02); assert(context.refs.upDashBall.Visible and count==3,'missed event left ability hidden')
heartbeat(.25); assert(count==3,'unchanged mode rebuilt rows')
enabled=false; heartbeat(.25); assert(not context.refs.upDashBall.Visible)
''')

if __name__ == '__main__': unittest.main()
