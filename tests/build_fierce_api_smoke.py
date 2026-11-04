"""Generate tests for GameInfo's Fierce Deflect ability lookup and activation."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / "exodus hub/modules/logic/gameinfo.luau").read_text()
source = source[source.index("function GameInfo.getFierceDeflectAbility()"):source.index("function GameInfo.getDashAbility()")]
pre = '''local GameInfo={}
local sent=0; local eventId
local ability={SendEvent=function(_,id) sent+=1; eventId=id end,IsAvailable=function() return true end,IsOwnerAlive=function() return true end}
local clientAbilities={Abilities={[19]=ability}}
local function locateDeflectAbility() end
'''
post = '''
assert(GameInfo.getFierceDeflectAbility()==ability)
assert(GameInfo.activateFierceDeflect(ability) and sent==1 and eventId==2.4141700243704228e76,"wrong ability activation")
ability.IsAvailable=function() return false end
assert(not GameInfo.activateFierceDeflect(ability) and sent==1,"must not send unavailable ability")
ability.IsAvailable=function() return true end; ability.IsOwnerAlive=function() return false end
assert(not GameInfo.activateFierceDeflect(ability) and sent==1,"must not send while dead")
clientAbilities.Abilities[19]=nil
assert(not GameInfo.activateFierceDeflect(ability) and sent==1,"must not send unequipped ability")
print("Fierce Deflect game API: PASS")
'''
output.write_text(pre + source + post)
