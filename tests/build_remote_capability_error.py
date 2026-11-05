"""Preserve an actionable capability error from the game's Deflect call."""
from pathlib import Path
import sys
root,out=Path(sys.argv[1]),Path(sys.argv[2])
source=(root/'exodus hub/modules/logic/remote.luau').read_text()
pre=r'''
local game={GetService=function() return {} end}
local function module()
'''
post=r'''
end
local remote=module()
local ability={Deflect=function() error("The current thread cannot access 'Instance' (lacking capability Plugin)") end}
assert(remote.setup({Utils={isActive=function() return true end},GameInfo={getDeflectAbility=function() return ability end}}))
local ok,reason=remote.fireParry(1)
assert(not ok and reason:find('Deflect do jogo:',1,true) and reason:find('lacking capability Plugin',1,true), 'error source and capability must be preserved')
print('Deflect capability diagnostic: PASS')
'''
out.write_text(pre+source+post)
