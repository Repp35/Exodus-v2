# Exodus v3

Remake do Exodus Hub para o jogo que fornece `GameBall`, `BallReplicator` e `ClientAbilities` em `ReplicatedStorage.TS`. O hub inclui Auto Parry, Auto Clash com detecção de dash, Auto Dark, Auto Jump, Up Dash, spam manual, Anti AFK, Auto Spin e controles móveis.

## Instalação

Execute o loader no cliente Roblox:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Repp35/Exodus-v2/main/exodus%20hub/loader.luau"))()
```

O loader usa um checkout local completo quando disponível; caso contrário, carrega todos os módulos de um único commit do GitHub. Para escolher o commit, defina `_G.EXODUS_REVISION` com o SHA completo antes de executá-lo. A persistência de configuração requer as APIs de arquivo e pasta do executor.

## Controles

Abra o painel pelo botão **E**. F9 interrompe o spam e reinicia o estado de parry/clash; F alterna o spam manual. As teclas, os mini controles, a janela do parry e as taxas são configuráveis no painel. As preferências são salvas em `Exodus Hub/config.json` quando o executor disponibiliza as APIs de arquivo, incluindo as configurações compatíveis do v2.

CPS é a taxa por segundo. CPF usa uma base fixa de 60 FPS, como no v2: `0.36 CPF` equivale a `21.6 CPS`. As taxas são limitadas a 120 CPS ou 4 CPF. O envio é limitado por frame e descarta atrasos acumulados, portanto FPS muito baixo pode reduzir a taxa efetiva em vez de gerar uma rajada inesperada.

## Funcionamento

Os eventos recebidos são enfileirados; um único ciclo processa entradas, sincronização, personagem, clash, movimento, spam e parry em ordem definida. Pacotes de bola com sequência antiga são ignorados, respeitando a volta de 65535 para 0. Spam automático e manual compartilham o mesmo emissor; o parry automático não compete com ele. Auto Spin mantém uma solicitação por vez e ignora respostas de modos cancelados. Ao fechar ou reiniciar, as conexões são encerradas e as respostas pendentes deixam de produzir ações.

As decisões são determinísticas para a mesma sequência de entradas, horários e estado do jogo. A rede, o FPS, a física, o executor e mudanças nas APIs do jogo são externos ao hub e podem alterar os dados recebidos ou a execução do servidor.
