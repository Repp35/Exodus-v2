"""Build a loader BallSync delivery test with out-of-order packets."""
from pathlib import Path
import sys
root=Path(sys.argv[1]); out=Path(sys.argv[2])
source=(root/'exodus hub/loader.luau').read_text(encoding='utf-8')
start=source.index('local function bindRuntime(loaded, log)')
end=source.index('\n-- interface', start)
source=source[start:end]
pre=r'''
local scheduled={}
local task={defer=function(fn) table.insert(scheduled,fn) end}
local function flush() while #scheduled>0 do local fn=table.remove(scheduled,1); fn() end end
local MODULE_ORDER={'utils','gameinfo','autoparry','autoclash'}
local MODULE_BY_NAME={gameinfo={path='gameinfo'},remote={path='remote'},autoparry={path='autoparry'},autoclash={path='autoclash'}}
local function contractOf(module) return module.__contract or {} end
local function printRawError(name, message) error(name..': '..tostring(message)) end
local HttpService={JSONDecode=function() return nil end}
local serverSequence=10
local providerData={TargetPlayerID=42,Teleported=false}
local info={
    getSyncSequence=function() return serverSequence end,
    getSyncData=function() return providerData end,
    applySync=function(data) return data or providerData end,
    installBallWatcher=function() return true end,
    decodeBallPacket=function(packet)
        local flags=buffer.readu8(packet,0)
        return {Sequence=buffer.readu16(packet,1),Teleported=bit32.btest(flags,1),TargetPlayerID=buffer.readf64(packet,55)}
    end,
}
local receiver
local remote={getRemote=function() return {} end,initParry=function() return true end,
    bindBallSync=function(fn) receiver=fn; return true end, startMaintenance=function() return true end}
local utils={trackGlobal=function() end,isActive=function() return true end}
local events,parryEvents={},{}
local clash={__contract={onBallSync=true},onBallSync=function(data) table.insert(events,{seq=data.Sequence,target=data.TargetPlayerID,tele=data.Teleported}) end}
local parry={__contract={onBallSync=true},onBallSync=function(data) table.insert(parryEvents,{seq=data.Sequence or data.TeleportSequence,tele=data.Teleported,target=data.TargetPlayerID}) end}
local function packet(seq,target,tele)
    local b=buffer.create(92);buffer.writeu8(b,0,tele and 1 or 0);buffer.writeu16(b,1,seq);buffer.writef64(b,55,target);return b
end
'''
post=r'''
local result=assert(bindRuntime({utils=utils,gameinfo=info,remote=remote,autoparry=parry,autoclash=clash}))
assert(result.ballSync and receiver)
-- Three transitions arriving before the deferred refresh must each be delivered.
receiver(packet(11,42,false)); receiver(packet(12,7,false)); receiver(packet(13,42,false))
assert(#events==3 and events[1].seq==11 and events[2].seq==12 and events[3].seq==13, 'target events coalesced')
assert(#parryEvents==3 and parryEvents[1].target==42 and parryEvents[2].target==7 and parryEvents[3].target==42, 'parry target transitions coalesced')
serverSequence=13;providerData={TargetPlayerID=42,Teleported=false};flush()
assert(#events==4 and events[4].target==42, 'deferred provider state missing')
-- A stale teleport must not tell either subscriber to reset.
receiver(packet(12,7,true)); assert(#parryEvents==4 and parryEvents[4].tele==false, 'stale teleport was delivered')
serverSequence=14;providerData={TargetPlayerID=42,Teleported=true};receiver(packet(14,42,true))
assert(#parryEvents==5 and parryEvents[5].tele and parryEvents[5].seq==14, 'fresh teleport missing')
flush()
assert(#parryEvents==6 and parryEvents[6].tele, 'post-teleport refresh missing')
print('Loader BallSync delivery scenarios: PASS')
'''
out.write_text(pre+source+post,encoding='utf-8')
