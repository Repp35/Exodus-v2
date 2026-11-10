# API interna do Exodus

Este documento descreve as interfaces atuais do hub. O registro de referência de permissões fica em `exodus hub/modules/logic/permissions.luau`; a lista e a ordem de carregamento dos arquivos ficam no manifesto de `exodus hub/loader.luau`.

## Responsabilidades

| Módulo | Responsabilidade |
| --- | --- |
| `permissions` | Valida contratos, controla quais métodos cada módulo recebe e monta dependências. |
| `config`, `uiconfig` | Validação, valores padrão e definições dos controles da interface. |
| `utils` | Estado da sessão, configuração, observadores, conexões e diagnósticos. |
| `gameinfo` | Informações do jogo, habilidade, estado da bola, geometria e eventos de sincronização. |
| `clashstats` | Estado, métricas e registros de cada clash; recebe somente o contexto do jogo e os serviços de diagnóstico. |
| `remote` | Chamadas às habilidades obtidas por `gameinfo`. |
| `autoparry`, `autospam`, `spam` | Regras de parry, decisão do confronto e envio repetido; as métricas do clash ficam em `clashstats`. |
| `dash`, `movement` | Detecção de dash e ações de movimento. |
| `autodark`, `autofierce`, `autojump`, `autodash`, `camera` | Recursos adicionais. |
| `character` | Vincula e desvincula os módulos quando o personagem muda. |
| `ui` | Interface e controles de usuário. |
| `loader`, `updater` | Inicialização e atualização da sessão. |

## Contrato de um módulo

Cada módulo carregado declara `__contract`. O campo `provides` lista funções obrigatórias, `requires` mapeia nomes usados no `setup` para módulos do registro e `requiresMethods` lista métodos obrigatórios das dependências. `requiresVersions`, quando usado, informa versões mínimas dos contratos. `bindCharacter` e `onBallSync` sinalizam ao loader as integrações correspondentes.

As funções e dados permitidos para cada módulo continuam definidos por `POLICIES`. `Permissions.validate` verifica o módulo e seu contrato; `Permissions.resolve` monta as dependências e verifica métodos e versões; `Permissions.wrap` produz uma visão somente de leitura com as permissões do consumidor. `Permissions.policy(nome)` retorna um resumo das permissões.

Para adicionar uma dependência, registre o acesso em `POLICIES` e declare-a em `requires` e, quando aplicável, em `requiresMethods`. Para adicionar um módulo, inclua-o no manifesto do loader, na política e nos contratos de seus consumidores. O loader carrega os módulos antes de executar os `setup` na ordem do manifesto; considere essa ordem quando o `setup` chamar imediatamente outro módulo.

## Estado e compatibilidade

Os nomes de funções existentes foram mantidos. Os módulos carregados continuam acessíveis em `_G.Exodus.Modules` e `_G.Exodus.Context`; informações de estado e diagnóstico são publicadas em `_G.Exodus`. Esses objetos globais expõem referências diretas e as permissões aplicam-se às visões entregues aos módulos: elas não constituem uma barreira de segurança contra outros códigos no mesmo ambiente.

`utils.getConfig()` e `utils.getConfigSnapshot()` retornam cópias da configuração; `utils.getConfigValue(chave)` busca um valor. Para alterar configurações, use `utils.setConfig(patch)` e as regras de `config`, em vez de modificar cópias. `utils.observeConfig` e `utils.observeSpam` retornam conexões que devem ser desconectadas durante a limpeza.

`gameinfo.getSnapshotAt(tempo)` retorna uma leitura de estado da bola; os consumidores devem usar `gameinfo.isSnapshotValid` antes de depender dela. O loader envia eventos de sincronização aos módulos que declaram `onBallSync`. `character` organiza as vinculações dos módulos que declaram `bindCharacter`.

## Raios e conexão com o jogo

`gameinfo.getDeflectRangeParameters()` fornece o raio-base, o limite de bônus e o incremento de resiliência. `gameinfo.getPlayerDeflectRange` e `getPlayerRawRadius` leem o alcance de jogadores; `getDeflectWindow`, `getDeflectGeometry` e `getProjectedDeflectRadius` calculam janelas e distâncias. Esses valores têm finalidades diferentes e não devem ser substituídos uns pelos outros sem rever o comportamento.

Os identificadores de habilidades, eventos e caixas ficam em `GAME_IDS`, em `gameinfo.luau`. O mesmo módulo localiza os recursos do jogo, expõe o alvo informado pelo jogo ao atualizador e fornece as operações para abertura de caixas; `remote` despacha habilidades. A interface não precisa conhecer os identificadores nem carregar diretamente a rede de caixas. Alterações futuras na estrutura do jogo podem exigir atualização desse adaptador.

## Ritmo do Spam

`gameinfo.getMinimumSpamInterval()` informa o intervalo mínimo entre tentativas configurado no adaptador do jogo; `getAutoSpamDelay()` informa uma espera adicional quando os dados necessários estiverem disponíveis. O Spam aplica o intervalo mínimo nos modos CPS, CPF e Auto. Nos modos com taxa definida, mantém no máximo 0,2 segundo de atraso para compensar progressivamente, sem enviar tentativas juntas. Caso a taxa pedida ultrapasse o intervalo mínimo, a taxa efetiva é limitada por ele. O envio e a aceitação pelo servidor são coisas distintas.

## CPS do AutoParry

`remote.fireParry` aceita um token privado fornecido somente ao `autoparry`. O AutoParry envia esse token e o módulo `remote` notifica apenas envios aceitos com a mesma assinatura; chamadas do Spam não possuem o token e não entram nessa medição. O CPS do AutoParry é o inverso do intervalo entre os dois últimos envios assinados.

O fator da janela começa em 0,8. Até 2 CPS ele permanece em 0,8; entre 2 e 2,5 CPS o fator sobe progressivamente até 1; a partir de 2,5 CPS fica em 1. Um intervalo acima de 0,5 segundo elimina o bônus no próximo clique. `autoparry.getStatus()` expõe `cps`, `windowFactor` e os limites em `cpsGate`.
