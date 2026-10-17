# Exodus v2

Hub Luau dividido em módulos de interface (`modules/front`), lógica (`modules/logic`) e integridade (`modules/security`). O `loader.luau` usa a cópia local quando encontra todos os módulos em uma pasta compatível com `LOCAL_ROOTS`; caso contrário, obtém uma revisão fixa pelo SHA do ramo `main` e baixa os módulos. As configurações da interface permanecem em `uiconfig.luau`; cada módulo declara suas dependências em `__contract` quando aplicável.

## Verificação local

Execute `exodus hub/indeed/stylua --check "exodus hub"` para conferir a formatação e use `luau-compile --null` em cada `.luau` para confirmar a compilação. Os testes em `tests/` exercitam a inicialização do loader, a cadência CPS/CPF, a recuperação de BallSync e a sequência de alvos do Auto Clash em serviços simulados. Os scripts em `indeed` são ferramentas de diagnóstico para o ambiente do jogo e não são carregados pelo manifesto.

O funcionamento dos remotes, da interface e dos recursos de executor exige Roblox e um ambiente compatível. O smoke test substitui a interface e a configuração dependente de `EnumItem` por stubs; não valida a jogabilidade.

Veja `REWORK.md` para os defeitos confirmados e os limites da verificação.
