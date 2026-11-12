# Arquitetura e padrões da UI

Este documento descreve a interface do Exodus v2. O objetivo é manter a UI
leve, previsível e visualmente consistente sem mover lógica de gameplay para a
camada de apresentação.

`README.md` é imutável; decisões e instruções de manutenção da UI pertencem a
este diretório e a `AGENTS.md`.

## Limite de responsabilidade

`exodus hub/modules/front/ui.luau` é o compositor da interface. Ele cria os
elementos, traduz interações em chamadas dos módulos recebidos pelo contrato e
renderiza estado de configuração/telemetria. Ele não deve descobrir remotes,
calcular regras de parry ou decidir como uma habilidade funciona.

Os módulos de suporte têm limites claros:

| Área | Responsabilidade |
| --- | --- |
| `config.luau` | validação e registro dos valores configuráveis; não cria elementos visuais. |
| `uiconfig.luau` | catálogo declarativo de toggles e componentes das páginas. |
| `ui.luau` | composição, apresentação, entrada, transições e limpeza da UI. |
| `utils` | estado persistido, observadores e ciclo de vida da sessão. |
| `gameinfo` | dados e APIs específicas do jogo consumidas pela telemetria. |
| `autospam` | status do clash consumido pelos indicadores da UI. |

O contrato público continua sendo `ExodusUI.setup(deps)`. A UI deve receber
dependências pelo loader e não acessar módulos de lógica por caminhos globais.

## Resultado da auditoria

Os problemas de maior impacto encontrados e tratados no rework foram:

- feedback visual inconsistente entre botões, cartões, campos e navegação;
- encerramento e troca de página baseados em tempos fixos, sujeitos a callbacks
  obsoletos durante cliques rápidos;
- loops de partículas, telemetria e utilitários sem um token comum de rebuild;
- dois Heartbeats independentes lendo a mesma telemetria;
- escala mínima permissiva demais, overlays sem margem de viewport e título sem
  hierarquia clara;
- ausência de tratamento consistente de foco, seleção e movimento reduzido;
- toggles que podiam permanecer ligados na configuração depois de uma falha de
  inicialização do recurso;
- estado visual de mini-controles que não acompanhava `Visible`/configuração em
  todos os modos de jogo.

As correções foram mantidas dentro do compositor da UI e dos testes/documentos
correspondentes; os contratos dos módulos de lógica não foram ampliados.

## Sistema visual

Os tokens ficam em `CONFIG` no topo de `ui.luau`:

- `COLORS` define superfícies, contraste, bordas, foco e estados ativos;
- `MOTION` define as durações `FAST`, `CONTROL`, `STANDARD`, `PANEL` e
  `SLOW`;
- dimensões de painel, cartões, margens e escala responsiva ficam no mesmo
  bloco para que mudanças de layout sejam revisáveis em um único lugar.

Cartões usam `cardFrame`, controles compactos usam `makeBtn` e estados
`OFF/ON` usam `createOffOnCard`. Componentes novos devem reutilizar esses
primitivos em vez de criar cores, raios e durações isolados.

## Estados e transições

O fluxo visual do painel é:

```text
hidden -> opening -> open -> minimizing -> minimized
                         \-> closing -> stopped
```

O estado de fechamento é terminal para aquela instância. O cleanup só pode
destruir a árvore depois dos tweens de saída; `createTweenGroup` aguarda os
eventos `Tween.Completed` dos elementos participantes. A navegação de páginas
usa a mesma regra e invalida callbacks antigos com `pageGeneration`.

Toggles seguem o fluxo `intent -> setConfig -> side effect -> visual`. Quando
um side effect retorna `false`, a configuração é revertida para `false` e o
controle não fica visualmente ligado enquanto a funcionalidade está
indisponível.

## Movimento e acessibilidade

`detectReducedMotion` consulta a preferência disponível em
`UserGameSettings` de forma protegida. Quando a preferência está ativa,
`twPlay` usa duração zero e o fluxo de partículas/gradientes contínuos é
desabilitado. A UI não depende de cor sozinha: textos `ON/OFF`, estados
desabilitados e indicadores de foco permanecem explícitos.

Controles `TextButton` recebem `Selectable`, anel de foco e estados de hover,
pressão e seleção. Campos `TextBox` recebem o mesmo tratamento de foco. A
entrada global ignora caixas de texto focadas e as conexões são rastreadas
para serem removidas durante o cleanup.

## Performance

- A telemetria de distância e viagem compartilha um único `Heartbeat` e um
  cache de snapshot/status limitado a 50 ms.
- Quando ambos os indicadores estão ocultos, o Heartbeat retorna sem acessar
  o jogo ou formatar texto.
- Partículas e gradientes infinitos não são criados com movimento reduzido.
- Resize observa somente mudanças de viewport/câmera; a escala é aplicada
  aos três layers da UI.
- Atualizações de texto usam `setTextIfChanged`, evitando reatribuições e
  trabalho de layout desnecessários.
- Tweens são usados em propriedades de composição e transparência; loops de
  renderização não são introduzidos para efeitos visuais.

## Responsividade

O painel mantém dimensões de design e recebe uma `UIScale` limitada por
`MIN_SCALE`, evitando tanto uma UI ilegível quanto um painel que estoura a
tela em resoluções pequenas. A escala acompanha a câmera atual, inclusive
quando `workspace.CurrentCamera` é substituída. Cards e páginas têm rolagem
local para conteúdo que ultrapassa a altura disponível.

## Validação

As verificações estáticas em `exodus hub/indeed/tests` cobrem os contratos e
regressões de runtime. Para a UI, valide também no Roblox:

1. abertura, minimização, reabertura, reload e fechamento;
2. cliques repetidos durante troca de página e alteração de configurações;
3. teclado/gamepad, foco de campos e arraste em desktop/mobile;
4. movimento reduzido, viewport pequeno e troca de câmera;
5. indisponibilidade de dados de jogo e falha de criação de rede.

Não há runtime Roblox no ambiente de desenvolvimento local; portanto a suíte
estática não substitui esse smoke test dentro do jogo.
