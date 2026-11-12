# API interna do Exodus

Este documento descreve as interfaces atuais do hub. Os contratos de cada módulo são a fonte única das permissões. O resolvedor fica em `exodus hub/modules/logic/permissions.luau`; o manifesto de arquivos fica em `exodus hub/loader.luau`, que determina a ordem de inicialização automaticamente pelas dependências.

As decisões de composição, estados, animações, acessibilidade e performance da interface ficam em [`docs/UI.md`](UI.md). O `README.md` não é destino de documentação e permanece imutável.

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

Cada módulo carregado declara `__contract`. `provides` lista as funções exportadas, `data` lista tabelas públicas de somente leitura, `requires` mapeia aliases de `setup` para nomes de módulos, `requiresMethods` concede apenas os métodos necessários e `requiresData` concede campos de dados específicos. `requiresVersions`, quando usado, exige versões mínimas dos contratos. `bindCharacter` e `onBallSync` sinalizam ao loader as integrações correspondentes.

Não existe mais tabela central `POLICIES`: os próprios contratos definem as capacidades. `Permissions.validate` registra e valida métodos, dados e dependências; `Permissions.resolve` verifica os provedores e as versões, montando visões restritas; `Permissions.wrap` entrega apenas os métodos e as cópias imutáveis dos dados declarados pelo consumidor. `Permissions.policy(nome)` continua fornecendo um resumo das permissões efetivas.

Para adicionar uma dependência, declare-a em `requires` e liste exclusivamente os métodos necessários em `requiresMethods` ou os dados em `requiresData`. Para adicionar um módulo, inclua o arquivo no manifesto do loader e declare as dependências nos consumidores. O loader carrega e valida todos os módulos antes de inicializar e usa a ordem topológica das dependências; ciclos e referências a módulos inexistentes são rejeitados. Se não puder obter uma revisão identificada por SHA nem um conjunto local completo, a inicialização falha em vez de executar a branch remota sem fixação. O loader também monta explicitamente os vínculos de personagem para o módulo `character`.

## Estado e compatibilidade

Os nomes de funções existentes foram mantidos. Os módulos carregados continuam acessíveis em `_G.Exodus.Modules` e `_G.Exodus.Context`; informações de estado e diagnóstico são publicadas em `_G.Exodus`. Esses objetos globais expõem referências diretas e as permissões aplicam-se às visões entregues aos módulos: elas não constituem uma barreira de segurança contra outros códigos no mesmo ambiente.

`utils.getConfig()` e `utils.getConfigSnapshot()` retornam cópias da configuração; os snapshots de tabelas usam cópia com detecção de ciclos, sem expor referências internas profundas. `utils.setConfig` ignora patches sem alteração, evitando notificações e gravações redundantes. `utils.getConfigValue(chave)` busca um valor. Para alterar configurações, use `utils.setConfig(patch)` e as regras de `config`, em vez de modificar cópias. `utils.observeConfig` e `utils.observeSpam` retornam conexões que devem ser desconectadas durante a limpeza.

`gameinfo.getSnapshotAt(tempo)` retorna uma leitura de estado da bola; `gameinfo.getSnapshot(tempo)` é o alias compatível e aceita tanto chamada com ponto quanto com dois argumentos. Os consumidores devem usar `gameinfo.isSnapshotValid` antes de depender da leitura. O loader envia eventos de sincronização aos módulos que declaram `onBallSync`; a aceitação e a ordem dos pacotes ficam em `gameinfo.applyPacket`. `character` organiza as vinculações dos módulos que declaram `bindCharacter`.

## Raios e conexão com o jogo

`gameinfo.getDeflectRangeParameters()` fornece o raio-base, o limite de bônus e o incremento de resiliência. `gameinfo.getPlayerDeflectRange` e `getPlayerRawRadius` leem o alcance de jogadores; `getDeflectWindow`, `getDeflectGeometry` e `getProjectedDeflectRadius` calculam janelas e distâncias. Esses valores têm finalidades diferentes e não devem ser substituídos uns pelos outros sem rever o comportamento.

Os identificadores de habilidades, eventos e caixas ficam em `GAME_IDS`, em `gameinfo.luau`. O mesmo módulo localiza os recursos do jogo, expõe o alvo informado pelo jogo ao atualizador e fornece as operações para abertura de caixas; `remote` despacha habilidades. A interface não precisa conhecer os identificadores nem carregar diretamente a rede de caixas. Alterações futuras na estrutura do jogo podem exigir atualização desse adaptador.

## Ritmo do Spam

`gameinfo.getMinimumSpamInterval()` informa o intervalo mínimo entre tentativas configurado no adaptador do jogo; `getAutoSpamDelay()` informa uma espera adicional quando os dados necessários estiverem disponíveis. O Spam aplica o intervalo mínimo nos modos CPS, CPF e Auto. Nos modos com taxa definida, mantém no máximo 0,2 segundo de atraso para compensar progressivamente, sem enviar tentativas juntas. Caso a taxa pedida ultrapasse o intervalo mínimo, a taxa efetiva é limitada por ele. O envio e a aceitação pelo servidor são coisas distintas.

## CPS do AutoParry

Cada módulo contabiliza suas próprias solicitações de clique, independentemente do resultado do remote. O AutoParry registra o instante de cada solicitação que faz, sem token nem observador no `remote`; solicitações do Spam não entram nessa medição. O CPS do AutoParry é o inverso do intervalo entre as duas últimas solicitações.

O fator da janela é configurado em `AutoParryWindowFactor`, com padrão `0,3` e limite `0,35`. Ele não aumenta com CPS; o AutoParry registra apenas as solicitações aceitas que ele próprio fez. `autoparry.getStatus()` expõe `cps`, `windowFactor` e os limites em `cpsGate`.

## Desempenho e atualização

Os loops de reação continuam orientados por `Heartbeat`/`PostSimulation`, mas chamadas repetidas de UI, sincronização e recursos opcionais são limitadas ao intervalo útil. A inicialização baixa os módulos em paralelo; a atualização automática só aplica uma revisão quando o manifesto tem produto, schema e SHA válidos e quando o jogo está fora de uma janela ativa de clash.

## Verificação de contratos

A suíte `exodus hub/indeed/tests/test_api_contracts.py`, executada pelo workflow existente, audita exportações, dependências, dados declarados, hooks e ciclos. Ela complementa a validação de runtime feita por `permissions.luau`; não substitui testes dentro do jogo.
