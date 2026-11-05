"""Read the real cooldown bar's fraction and its game's LastCooldown."""
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
source = (root / 'exodus hub/modules/logic/gameinfo.luau').read_text()
source = source[source.index('function GameInfo.getDeflectUICooldown()'):source.index('function GameInfo.getDeflectServerEvents()')]
pre = '''local GameInfo={}
local ability={LastCooldown=0.6,Interface={UIAbilityCooldown={Size={Y={Scale=0.5}}}}}
local function locateDeflectAbility() return ability end
'''
post = '''
assert(math.abs(GameInfo.getDeflectUICooldown() - 0.3)<1e-8, "fractional UI duration")
ability.Interface.UIAbilityCooldown.Size.Y.Scale=0
assert(GameInfo.getDeflectUICooldown()==0, "empty bar should be ready")
ability.Interface.UIAbilityCooldown.Size.Y.Scale=0/0
assert(GameInfo.getDeflectUICooldown()==nil, "invalid bar must not be used")
ability.Interface.UIAbilityCooldown=nil
assert(GameInfo.getDeflectUICooldown()==nil, "missing bar must not be guessed")
print('Deflect UI cooldown: PASS')
'''
output.write_text(pre + source + post)
