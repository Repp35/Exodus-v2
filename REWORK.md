# Revisão do Exodus v2

Base: commit `363ccbbcd9f8943d1594d3842071881c0b526109`. Todos os 15 arquivos Luau do projeto foram compilados com `luau-compile`, e os contratos e caminhos dos 12 módulos do manifesto foram conferidos. A lista abaixo registra os defeitos confirmados nesta revisão, sem afirmar que não existam outros defeitos dependentes do jogo.

## Defeitos encontrados e corrigidos

1. **Loader não compilava.** O callback de BallSync usava `...` dentro de uma função aninhada. Luau devolvia `Cannot use '...' outside of a vararg function` na linha 397 do arquivo original. O primeiro argumento agora é capturado na função variádica e passado à chamada de JSON.
2. **Seleção da API de rede interrompida por lacunas.** O vetor de APIs opcionais era percorrido com `ipairs`, que termina no primeiro `nil`; um executor que oferecesse apenas `http_request` ou `syn.request` era rejeitado. Cada opção agora ocupa um slot estável e conserva a prioridade declarada.
3. **Resposta HTTP incorreta podia ser compilada como módulo.** A validação original rejeitava somente códigos a partir de 400. Redirecionamentos, respostas sem status e códigos inválidos podiam chegar ao compilador. Agora somente 2xx são aceitos; erros transitórios de rede entram nas tentativas limitadas.
4. **SHA remoto não era validado como identificador de commit.** Qualquer string não vazia recebida da API compunha URLs. Agora são exigidos 40 caracteres hexadecimais.
5. **A cópia atualizada era ignorada pelo loader.** Mesmo com todos os módulos no pacote extraído, o loader buscava os módulos do `main` remoto. Agora escolhe uma raiz local somente quando o conjunto inteiro do manifesto existe nela e carrega esse conjunto de modo consistente. Mantém o carregamento remoto quando a cópia local não está completa.
6. **Falha de rede impedia o uso de uma cópia local.** A resolução do SHA era obrigatória mesmo para módulos presentes no disco. O modo local completo dispensa essa requisição, e o preflight aceita as APIs de arquivo quando não há API HTTP.
7. **Carregamento paralelo podia esperar indefinidamente.** O contador de downloads não tinha prazo. Agora a espera tem limite de 30 segundos e retorna erro identificável.
8. **Remotes ainda ausentes abortavam o início.** A busca inicial do remote de parry e de BallSyncData era tratada como requisito de inicialização. Esses recursos podem aparecer mais tarde; a manutenção periódica os procura e vincula depois, e o status inicial registra sua disponibilidade.
9. **Busca por BallSyncData podia saltar candidatos existentes.** A lista tinha entradas opcionais e era percorrida com `ipairs`; um primeiro `nil` escondia os caminhos seguintes. A iteração agora examina os candidatos presentes.
10. **Cache da habilidade Deflect era sempre invalidado.** A habilidade era uma tabela, mas o cache exigia `Parent`, propriedade usada para `Instance`. A validação agora considera a interface da tabela e evita repetição da busca e do `require`.
11. **Configuração aceitava schema desconhecido e defaults inválidos.** O registro dos módulos agora verifica tipos suportados e valida cada valor padrão antes de adicionar suas chaves ao registro.
12. **Falha transitória no armazenamento de diagnóstico bloqueava novas tentativas.** O estado `initialized` permanecia verdadeiro após indisponibilidade de pasta, leitura ou APIs de arquivo. Essas falhas agora permitem nova tentativa; a marca de escrita pendente só é liberada após a gravação.
13. **Raiz alternativa da verificação de integridade tinha chave errada.** Quando apenas `Exodus.Modules` fosse encontrado, o snapshot tentava verificar a string `"Exodus.Modules"` como chave de `_G`, causando falso positivo. O snapshot guarda o objeto dono e a chave reais.
14. **Diagnóstico de BallSync apontava para o módulo errado.** A referência `MODULE_BY_NAME.GameInfo` não existia porque o manifesto usa `gameinfo`; a mensagem agora apresenta o caminho correto.
15. **Código Luau inteiro tinha formatação inconsistente.** Os 15 arquivos Luau foram padronizados com StyLua; os scripts de diagnóstico permanecem fora do carregamento do hub.
16. **BallSyncData emitia avisos repetidos para eventos sem tabela.** O callback assumia que todo evento trazia a tabela de sync e registrava `payload BallSync inválido` para sinais, bytes ou JSON em argumentos posteriores. Agora procura tabelas e JSON em todos os argumentos, consulta `BallReplicator.syncData` quando necessário e tenta uma releitura após os demais callbacks. Erros reais da chamada ainda são registrados.
17. **Auto Clash descartava o alvo do evento.** `GameInfo.getTargetId()` podia devolver `-1`, valor verdadeiro em Luau, impedindo o fallback para `data.TargetPlayerID`. O Auto Clash agora normaliza primeiro os IDs recebidos no evento e só consulta GameInfo se faltarem.
18. **O snapshot substituía o histórico de troca de alvos.** A cada Heartbeat, `snapshot.targetId` podia sobrescrever `R.lastTarget`, que deveria representar o último evento de sync. Um snapshot atrasado quebrava a sequência necessária para ativar o retorno. O histórico de eventos agora só é alterado pelo callback de BallSync.
19. **Um atributo atrasado podia ocultar o alvo sincronizado.** `GameInfo` priorizava `Workspace.GameBallTarget` mesmo quando o sync trazia `TargetPlayerID` ou `HighlightTargetPlayerID`. A tabela de sync agora tem prioridade; o atributo é fallback, inclusive quando ainda não há tabela.

## Verificação

- O loader original falha em `luau-compile --null` com o erro de varargs; o loader corrigido e todos os demais arquivos compilam.
- `stylua --check` passou para todos os arquivos Luau.
- Um teste de inicialização com serviços Luau simulados passou para os modos remoto e local. O teste substitui a interface e o registro de configuração dependente de `EnumItem`; ele verifica o fluxo do loader e a inicialização dos demais módulos, não a experiência real no Roblox.
- A integridade do ZIP gerado foi conferida após o empacotamento.

Ainda é necessário executar no Roblox com o executor e o jogo de destino para validar interface, eventos, habilidades, animações e temporização em tempo real. Nenhum teste fora desse ambiente pode demonstrar equivalência completa de comportamento.

O agendador de spam foi simplificado: CPS usa uma única fase fracionária acumulada (`rate * dt`), CPF calcula diretamente os cliques do quadro, e ambos enviam os pedidos sem uma fila e um segundo acumulador. O serviço de entrada é resolvido uma vez por módulo. Não há teto nem descarte de cliques; taxas extremas ainda podem sobrecarregar o cliente. Como os envios acontecem no callback de renderização, vários cliques de um mesmo quadro são enviados em sequência, sujeitos à resolução temporal do executor.

O teste `tests/build_spam_smoke.py` verifica 23,5 CPS em 120 quadros, 7.500 CPS sem teto, CPF 10 com compensação a 60 e 30 FPS, desligamento e reutilização do serviço de entrada.

O teste `tests/build_ballsync_smoke.py` verifica sincronização recebida diretamente, embrulhada em `syncData` e recuperada do `BallReplicator` após um evento sem tabela.

O teste `tests/build_autoclash_smoke.py` verifica a sequência `eu → parceiro → eu` com `getTargetId() == -1` e um snapshot atrasado entre os eventos. O código original falha nesse teste; a versão corrigida arma o retorno ao jogador.
