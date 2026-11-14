# Análise e reconstrução da UI

## Diagnóstico da versão original

Análise de código da revisão `b6bbee3` de `Repp35/Exodus-v2`. Não havia captura de tela, place de teste ou runner Roblox no repositório; a identidade e os fluxos foram reconstruídos a partir das propriedades e callbacks reais da UI.

O arquivo `modules/front/ui.luau` original tinha 3.278 linhas. Seu `setup` exigia Utils, UIConfig, Controls, GameInfo, AutoSpam e Dumper. Funções de UI também executavam anti AFK, loops de crates, alterações de configurações e telemetria de combate. Não era possível usar a biblioteca em outro hub sem trazer essas dependências.

Havia um catálogo `Components` com implementações pequenas de botão, input, toggle, dropdown e slider, além de outro conjunto de construtores especializados para as páginas. Os dois caminhos possuíam estruturas e comportamentos próprios. Cartões de 48/64/118 px eram escalados por 1,06; coordenadas, alturas acumuladas e tamanhos de canvas eram calculados manualmente. Algumas colunas usavam canvas automático e outras manual. Isso favorecia divergência visual, corte de descrições e sobreposição quando uma seção crescia.

Seis páginas eram construídas dentro do mesmo `setup`, com exceções próprias de largura, botões, labels e estados. Navegação por anterior/próximo ocultava destinos. Configurações tinham uma transição separada. A sincronização de valores precisava conhecer nomes específicos (`AutoSpam`, `AutoParry`, etc.), deixando outros controles sujeitos a uma apresentação desatualizada.

Conexões, tweens, tarefas de partículas, contornos animados e notificações eram administrados em registros diferentes. Vários controles flutuantes repetiam o mesmo arraste/pintura com nomes específicos. Os insets eram ignorados e a adaptação diminuía a janela inteira, reduzindo controles e texto em telas menores.

## Identidade preservada e padronização

A paleta original permanece como padrão: fundo RGB 8/8/22, superfície 14/14/34, cartão 20/20/44, violeta 99/102/241 e rosa 236/72/153. Gotham, contraste de texto claro e contorno azul/lilás continuam. Cores de sucesso, perigo, aviso e informação passam a ter significado compartilhado.

Todos os formulários usam a mesma estrutura de título, descrição, área de interação e erro, com controles de 40 px por padrão e variantes de 32/48 px. Espaçamentos seguem escala 4/8/12/16/24 e raios 6/8/12/16. Listas determinam as posições e a altura das seções. O conteúdo segue uma coluna legível, com Grid disponível para comparações de métricas/cartões.

Partículas e animações contínuas decorativas foram removidas. Transições pontuais usam o mesmo serviço, cancelamento e duração; existe preferência de movimento reduzido. A janela tem destinos visíveis e adapta a navegação sem diminuir toda a interface.

## Arquitetura entregue

- `ui-library/src/core`: Signal, Scope, Store, Theme e Context. Sem dependências de hub.
- `ui-library/src/components`: ações, campos, seleções, apresentação, layouts, dados e overlays.
- `ui-library/src/Window.luau`: janela, páginas e navegação adaptável.
- `ui-library/src/init.luau`: API e registro de factories por instância.
- `ui-library/scripts/build.py`: bundle determinístico, sem downloads no runtime.
- `exodus hub/modules/front/library.luau`: distribuição gerada.
- `exodus hub/modules/front/ui.luau`: adaptador explícito do Exodus; somente ele conhece as chaves, callbacks, módulos de gameplay e globals legados.

O loader recebe um módulo de biblioteca sem setup de gameplay e resolve sua API por permissões. A ferramenta de formatação preserva o bundle gerado; as fontes têm formatação própria verificada na CI. O teste estático dos contratos consulta a entrada original da biblioteca em vez de tentar inferir um módulo a partir dos módulos concatenados.

## Recursos do hub

| Recurso anterior | Integração atual |
| --- | --- |
| Auto parry/spam e taxa CPS/CPF/MS/Auto | Main, controles ligados ao Store e ao adaptador de configuração |
| Click method e ativação Toggle/Hold | Main, Dropdown e Segmented compartilhados |
| Ajustes de lead e sensibilidade | Settings, Slider/NumberInput com intervalo explícito |
| Atalhos e parada | Settings, captura central e compatibilidade com teclas e botões do mouse |
| Auto dark/fierce/jump/dash | Automatic, mesmo Toggle e visibilidade por capacidade |
| Ferramentas e ajustes universais | Indeed, descrições e dependências de habilitação preservadas |
| Dumper | Indeed, estado de carregamento e notificações de status/progresso/resultado |
| Anti AFK e crates | Utilities, lógica pertencente ao adaptador e scopes descartáveis |
| Notificações, modo desktop, rejoin/hop, reset e reload | Hub, controles compartilhados e confirmação de ações destrutivas |
| Botões móveis e manual spam | FloatingButton genérico, posição/tamanho persistidos, ações mantidas liberadas ao perder foco |
| Distância, travel time e gates | Overlays alimentados pelo adaptador, amostragem somente quando habilitados |
| Cleanup/fade/restore/notificação do loader | Hooks de compatibilidade restritos ao adaptador |

Não foram removidos módulos de gameplay nem alterados seus algoritmos. A telemetria agora apresenta um resumo dos dados, incluindo tempo final de uma troca congelada; não replica cada frase e anotação da visualização anterior. O catálogo antigo `UI.Components` foi substituído pela API independente; integrações externas devem migrar para `Library.new`/`Add`. Não havia consumidor desse catálogo no repositório.

## Correções verificadas

Store com patches atômicos e snapshots, rejeição de escrita/validação, retorno síncrono do host sem evento duplicado, atualização externa dos controles ligados, callback de mudança executado uma vez, bloqueio de interação desabilitada, normalização e rejeição de NaN/infinito, captura cancelável de teclas/mouse, liberação de ações mantidas, popup fora do clipping, fechamento de menu ao navegar, substituição de notificações por ID e descarte idempotente de árvores completas.

Testes adicionais cobrem remontagem do adaptador com as views reais de permissões, ausência de instâncias/timers após cleanup, repetição de menus e reconstrução de tabelas sem acumular recursos, geometria de erro de RadioGroup/TextArea, variantes de tamanho e adaptação a três viewports.

## Validação e limites

Compilação no Luau oficial e suíte de interação com a fronteira Roblox simulada. Testes anteriores de contratos e formatter continuam ativos. A suíte não executa remotes, anti AFK, crates, persistência real ou teleport; esses módulos permanecem serviços do host.

A aparência renderizada e a interação nativa ainda devem ser conferidas no Studio. Não há Studio/Roblox instalado neste ambiente Linux. Checklist reproduzível com `examples/showcase.client.luau`:

1. Abrir em 320×568, 568×320, 768×1024 e desktop; verificar leitura, rolamento, navegação horizontal e ausência de cortes.
2. Usar descrições longas em português; verificar truncamento e acrescentar Tooltip quando houver informação complementar.
3. Abrir dropdown na borda inferior, filtrar, selecionar múltiplos, dispensar por clique/Escape e navegar de página com menu aberto.
4. Operar com teclado, gamepad e touch real/emulado; confirmar foco de botões, slider e diálogo, e ausência de ativação após arraste.
5. Trocar tema, ativar movimento reduzido, validar erros de formulário e comparar estados enabled/disabled/loading.
6. No hub, verificar save/load, callbacks de recursos, telemetria, dumper, crates, atalhos mantidos e recarga; fechar e confirmar que todas as conexões são descartadas.

Compatibilidade com qualquer hub significa APIs sem nomes de domínio e suporte a parent/configuração/callbacks injetados; não é uma promessa de compatibilidade já testada com todos os hubs ou executores existentes.
