# Biblioteca de UI do Exodus v2

A UI mantém o painel de 540 × 380, as seis páginas, a paleta escura com acentos violeta/rosa, contornos em gradiente, partículas e controles flutuantes. A refatoração troca a construção manual das páginas por componentes e modelos compartilhados. Toggles antes representados por textos ON/OFF usam o mesmo switch das outras opções. Espaçamentos e larguras agora seguem o layout, sem ampliar cards com UIScale permanente.

## O que mudou

| Antes | Agora |
| --- | --- |
| Dois conjuntos diferentes de componentes: API pública e páginas | As páginas usam exatamente `kit.Components`, também exposto por `ExodusUI.Components` |
| Coordenadas Y e CanvasSize calculados por cada página | `UIListLayout`, `AutomaticSize` e `AutomaticCanvasSize` em todas as páginas |
| Três implementações de transição, com cancelamento diferente em Config | Um controlador para páginas, Config, retorno e reconstruções |
| Alguns controles refletiam só seus próprios cliques | Binding por chave, inclusive alterações externas de sliders, seleção, taxa e atalhos |
| Montar sliders e o seletor de taxa regravava configurações | Montagem e setters apenas refletem valores; interação valida e grava |
| Eventos e tarefas espalhados entre páginas | Escopos com descarte de eventos, popups, capturas, tarefas e tweens |
| Dropdown público cortado pelo contêiner | Um dropdown compartilhado com portal, rolagem, seleção, clique externo e Escape |
| Sliders com regras diferentes para mouse/toque | Um dono por arrasto; navegação, ocultação e perda de foco interrompem a interação |
| Reconstrução podia perder página ou posição de rolagem | Snapshot por ID e coluna, incluindo a página de retorno de Config |

Não há promessa de ganho de FPS medido. As melhorias de desempenho são estruturais: evitar gravações na montagem, evitar repintar valores inalterados, cancelar animações substituídas e liberar recursos quando deixam de ser usados.

## Organização

| Arquivo em `exodus hub/modules/front/` | Responsabilidade |
| --- | --- |
| `uitheme.luau` | Tokens visuais e perfis de movimento |
| `uiruntime.luau` | Escopos, cancelamento de tweens e posse de ponteiro |
| `uiicons.luau` | PNGs locais com cache; alternativas nativas quando o executor não suporta assets locais |
| `uikit.luau` | Primitivos e componentes; independente dos recursos do jogo |
| `uipages.luau` | Validação de modelos, seções, colunas, navegação e expansão de filhos |
| `uiconfig.luau` | Definição declarativa das seis páginas e schema de configurações existente |
| `uiactions.luau` | Adaptação das ações do hub aos callbacks da biblioteca |
| `ui.luau` | Janela, controles flutuantes, telemetria, notificações e integração com o loader |

O loader registra os módulos da biblioteca e inicializa suas dependências pelo grafo de contratos existente. A distribuição continua copiando os módulos e assinando seus conteúdos. As rotinas de combate e movimento não foram modificadas.

## Criar uma biblioteca

Depois de inicializar `uitheme`, `uiruntime`, `uiicons` e `uikit` pelo loader (ou por seus métodos `setup`):

```lua
local kit = UIKit.create({
  parent = screenGui,
  read = function(key) return store[key] end,
  write = function(key, value)
    -- Validar, gravar e emitir as mudanças antes de retornar.
    return updateStore(key, value) -- false rejeita a alteração
  end,
  observe = function(callback)
    return observeStore(callback) -- conexão com Disconnect; callback recebe { [key] = value }
  end,
  notify = function(message, important) end,
  onCapture = function(active) end, -- permite suspender atalhos do aplicativo
  onOutline = function(gradient) end, -- opcional: registrar animação de contornos
  reducedMotion = false, -- true aplica os mesmos estados sem duração
})

local option = kit.Components.toggle(parent, {
  title = "Minha opção",
  description = "Descrição opcional.",
  key = "MyOption",
  onChange = function(value) end,
})
```

`parent`, `read`, `write` e `observe` são opcionais para componentes isolados com estado local. O dropdown precisa de `parent` apontando para um ScreenGui para criar seu portal. Sem `observe`, o consumidor chama `kit.refresh(changes)` após atualizar seu modelo.

As funções usam chamada com ponto (`option.setValue(true)`), não `:`.

## Componentes e regras comuns

Todos os componentes retornam `Root`, `setEnabled(boolean)`, `setVisible(boolean)` e `destroy()`. Os componentes com valor também retornam `setValue(value)` e `getValue()`.

- `label`: `text`/`title`, `setText(text)`.
- `button`: `title`, `description`, `onClick`, `shortcutKey`, `setText(text)`.
- `toggle`: booleano, `key` ou `value`; `getState` opcional para estado externo sem chave.
- `textInput`: `placeholder`, `parse`, `format`, `onSubmit(text, enterPressed)`, `setText`, `getText`.
- `number`: campo numérico finito, `min`, `max`, `displayScale`. Ex.: valor `0.3`, escala `100`, exibição `30`.
- `slider`: `min`, `max`, `increment`/`step`, `valueName`, `compact`. Suporta mouse, toque e setas quando selecionado.
- `dropdown`: `options`/`choices`, `placeholder`, `maxVisible`. O popup fica preso abaixo do acionador, acompanha movimento/escala e limita a altura com rolagem; ao abrir, pode rolar o contêiner para liberar espaço. Fecha ao navegar, minimizar, sair do viewport, clicar fora ou pressionar Escape.
- `segmented` e `tabs`: mesma API de seleção; as opções podem ser valores ou `{ value, label, color? }`. A cor vem da opção, de `definition.colors[value]`, de `tokens.SELECTOR_COLORS[value]` ou do accent, nessa ordem. CPS/CPF/MS/Auto e Toggle/Hold mantêm suas cores por modo.
- `progressBar`: valor normalizado entre `0` e `1`.
- `divider`: separador.
- `rate_selector`: composição do segmented e campo numérico para CPS/CPF/MS/Auto; não altera os valores ao montar ou trocar o modo.

Aliases para definições anteriores: `click → button`, `scroll → slider`, `off_on → toggle`, `keybind_selector → button`.

Regras de estado:

1. `setValue` é silencioso: não grava a configuração e não chama `onChange`.
2. Montar um componente apenas lê o estado inicial.
3. Uma interação grava a chave e só aceita o novo estado se `write` não retornar `false`.
4. `onChange` é chamado depois da gravação. Para estado local sem chave, pode retornar `false` para rejeitar a interação.
5. Campos inválidos ou gravações rejeitadas restauram o valor aceito. Números respeitam limites e sliders respeitam o incremento.
6. Mudanças emitidas pelo modelo atualizam todos os componentes vinculados à chave.
7. A captura de atalhos é exclusiva, aceita teclado e botões do mouse, e cancela com Escape, perda de foco, navegação ou descarte.

`kit.dismiss()` fecha popups, cancela captura e libera arrastos. `kit.suspend()` também interrompe os movimentos e bloqueia interações durante uma substituição; `kit.resume()` reativa e sincroniza os controles. `kit.destroy()` é idempotente e remove os controles e seus recursos. O consumidor continua sendo dono do ScreenGui e dos contêineres que criou.

`ExodusUI.Components` delega à mesma instância usada pelo hub depois de `ExodusUI.setup`. Para bibliotecas independentes, use `UIKit.create` e gerencie seu ciclo de vida.

## Definir páginas, seções e dependências

As páginas são uma lista ordenada com IDs estáveis. Não há lógica visual especial para Config ou Indeed.

```lua
local definitions = {
  {
    id = "main",
    title = "Main",
    columns = 2,
    sections = {
      {
        title = "Minha seção",
        column = 1,
        components = {
          { kind = "toggle", title = "Recurso", key = "FeatureEnabled" },
          {
            kind = "slider", title = "Intensidade", key = "FeatureValue",
            parentKey = "FeatureEnabled", min = 0, max = 10, increment = 0.1,
          },
        },
      },
    },
  },
  { id = "config", title = "Config", columns = 1, width = 300, utility = true, sections = {} },
}

local pages = UIPages.create(kit, panel, definitions, {
  desktop = true,
  resolve = function(definition) return definition end, -- adiciona callbacks de aplicação
  onComponent = function(definition, handle) end,
  onNavigate = function(state) end,
})
```

`columns` aceita 1 ou 2. `width` limita e centraliza o conteúdo de uma página. Seções e componentes aceitam `desktopOnly`/`mobileOnly`. `parentKey` agrupa controles abaixo do pai e usa a mesma expansão animada em qualquer página. `visibleWhen` condiciona a linha a uma chave booleana; `abilityOnly` usa `context.abilitiesEnabled` no hub. Filhos devem ter pais presentes no mesmo modelo e dispositivo. O schema rejeita IDs duplicados, tipos desconhecidos e dependências ausentes ou cíclicas.

No hub, `action` e `feature` são resolvidos em `uiactions.luau`. Para adicionar uma opção, adicione sua definição em `uiconfig.luau`, registre a chave no schema de configuração do módulo responsável e, se necessário, ligue a ação no adaptador. Não crie uma nova função de layout por página.

O controlador oferece:

| Método | Uso |
| --- | --- |
| `select(id, animated?)` | Selecionar página por ID; `false` aplica imediatamente |
| `step(-1 / 1)` | Navegar nas páginas principais, respeitando limites |
| `toggle(id)` | Abrir página auxiliar ou retornar à página de origem |
| `state()` | ID, título, índice, total, estado auxiliar e transição |
| `get(id)` | Instâncias da página, colunas e linhas |
| `getControl(key)` | Handle de uma chave; use chaves únicas quando consultar por esse método |
| `refresh()` | Reavaliar visibilidade externa, por exemplo ao mudar o modo de habilidades |
| `snapshot()` / `restore(snapshot)` | Preservar página, retorno e posição de cada coluna |
| `suspend()` | Concluir o estado visual atual e cancelar a navegação em andamento |
| `destroy()` | Descartar as páginas e seus componentes |

Mudanças de configuração observadas pelo kit atualizam automaticamente visibilidade e dependências. Snapshots são aplicados à nova árvore antes de abrir a janela. A troca de dispositivo e o modo PC usam esse caminho; o reset de configurações reconstrói com os valores padrão.

## Movimento e recursos

`uitheme.tokens.MOTION` define `press`, `feedback`, `control`, `page` e `panel`. Controles usam o mesmo easing cúbico de saída. Tempos diferentes representam funções diferentes, não implementações específicas de páginas. Somente efeitos ambientes, como a duração aleatória das partículas, usam tempos próprios.

`kit.createMotion(scope)` cria movimento pertencente a um escopo e inclui esse movimento em suspend/resume. `motion.group(canvasGroup, preset, properties, onComplete?)` sincroniza a transparência do grupo com seus contornos diretos, inclusive nos ciclos de minimizar/reabrir e substituir a UI. `motion.play(instance, preset, properties, onComplete?)` cancela tweens que disputam as mesmas propriedades; callbacks de sucesso não rodam para tweens cancelados. O controlador ainda usa uma geração de navegação para impedir callbacks antigos de reativarem páginas.

`uiruntime.scope()` oferece `add(resource, dispose?)`, `connect(signal, callback)`, `remove(resource)`, `forget(resource)`, `child()` e `destroy()`. `remove` descarta; `forget` apenas retira o registro. `alive` permite que tarefas com espera abandonem trabalho após o descarte.

## Validação e limite dos testes

```bash
python3 -m unittest discover -s "exodus hub/indeed/tests" -p "test_*.py"
python3 "exodus hub/indeed/tests/ui_transition_regression.py"
python3 "exodus hub/indeed/formatter.py" --check "exodus hub"
```

O teste comportamental executa Lua 5.4 com dublês das APIs Roblox e tradução das atribuições compostas de Luau. Requer `liblua5.4.so.0` (Ubuntu: `liblua5.4-0`). A CI instala essa dependência. O formatter valida a sintaxe Luau.

Os testes cobrem todas as páginas em PC/mobile, navegação rápida e Config, binding, falhas de gravação, números inválidos, exclusividade de ponteiro, captura de atalhos, dropdown na borda inferior, expansão, movimento reduzido, preservação de página/rolagem, liberação de hold, substituição/reload e descarte sem eventos ou tweens ativos.

Ainda é necessário conferir no Roblox: renderização, recorte e métricas de texto, rolagem e toque reais, arrasto com escala reduzida, alternância entre paisagem/retrato, notificações durante reload e fidelidade visual das seis páginas. Os testes simulados não substituem essa conferência nem medem FPS.

Na revisão ampliada, `cooldown_context_regression.py` e `fierce_grace_regression.py` também passam. Três harnesses antigos falham tanto nesta branch quanto no commit base `56e175c`: `parry_runtime_regression.py` e `spam_timer_regression.py` não fornecem `Utils` para `Remote.setup`; `update_channel_regression.py` não fornece `CONFIG` ao trecho extraído. Essas falhas foram reproduzidas numa cópia limpa do commit base. A CI desta alteração executa os contratos, os testes comportamentais e a regressão de transições da UI.

## Ícones sem glifos ou emojis

`kit.icon(parent, name, properties?)` cria um ImageLabel. `settings`, `chevron` e `minimize` são PNGs embarcados em `uiicons.luau`; a navegação reutiliza o chevron com rotação. Não há dependência de fonte para desenhar os ícones.

O PNG/SVG de configurações vem de [CHORUS-HUB---demo/assets/tabs](https://github.com/Repp35/CHORUS-HUB---demo/tree/main/assets/tabs), com a licença ISC preservada em `exodus hub/assets/ui/LUCIDE_LICENSE.txt`. Os PNGs e SVGs de origem ficam em `exodus hub/assets/ui`. Quando disponíveis, `writefile` e `getcustomasset`/`getsynasset` carregam os bytes locais, sem download em runtime; em ambientes sem esse suporte, o adaptador usa imagens nativas do Roblox.

Depois de editar um PNG, execute `python3 "exodus hub/indeed/build_ui_icons.py"` e o formatter. O gerador atualiza os bytes embarcados e a versão do caminho de cache, impedindo que uma textura antiga seja reutilizada. A CI executa o gerador com `--check` para detectar divergências.
