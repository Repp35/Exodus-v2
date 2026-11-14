# UI Library

Biblioteca de interface Roblox/Luau independente de hub. Preserva a identidade escura, violeta/rosa e os contornos azul/lilás do Exodus. Não importa módulos de jogo, não usa `_G`, HTTP, filesystem de executor ou `loadstring` e não inicia ações de gameplay.

## Instalação

Com Rojo, use `default.project.json`: `src/init.luau` torna-se `ReplicatedStorage.UILibrary`, com os módulos internos como filhos. Requer execução no cliente.

Sem Rojo, copie o conteúdo de `../exodus hub/modules/front/library.luau` para um **ModuleScript**. Esse arquivo é um bundle autossuficiente gerado das mesmas fontes. Não edite o bundle.

```luau
local Library = require(game.ReplicatedStorage.UILibrary)
local ui = Library.new({ values = { enabled = true } })
local window = ui:Window({ title = "Meu hub", subtitle = "Configuração independente" })
local page = window:Page({ id = "general", title = "Geral" })
local section = page:Section({ title = "Preferências" })
local enabled = section:Add("Toggle", {
  id = "enabled",
  title = "Ativar recurso",
  key = "enabled",
  onChange = function(value) print(value) end,
})
-- ui:Destroy() encerra toda a árvore e suas conexões, tweens e timers.
```

`examples/showcase.client.luau` demonstra o catálogo, temas, layouts e overlays sem depender do Exodus.

## Catálogo

| Grupo | Componentes e sistemas |
| --- | --- |
| Ações | Button, Toggle, Checkbox, Keybind |
| Formulários | Input, NumberInput, TextArea, Slider |
| Seleção | Dropdown, MultiSelect, Segmented, RadioGroup, ColorPicker |
| Informação | Label, Badge, Alert, Progress, Stat, Image, Separator, Skeleton, EmptyState |
| Layout | Stack, Section, Card, Grid, Accordion, Tabs |
| Dados | Table com ordenação, filtro e estado vazio |
| Navegação e overlays | Window/Page, FloatingButton, Notify, Dialog, Tooltip |

Os 29 componentes de `Add` compartilham propriedade de recursos e tokens; os seis sistemas de navegação/overlay usam o mesmo contexto. A tabela usa colunas de largura igual e renderiza suas linhas; não oferece virtualização. ColorPicker edita hexadecimal RGB; transparência e HSV não estão nesta versão.

## Configuração do contexto

`Library.new(options)` aceita:

- `parent`: PlayerGui de destino; por padrão, PlayerGui do jogador local.
- `name`, `displayOrder`: identificação e ordem da ScreenGui.
- `theme`: overrides dos tokens definidos em `src/core/Theme.luau`.
- `values`: valores iniciais do store interno.
- `validate(key, value)`: retorna `true` ou `false, motivo`, antes de efetivar o patch.
- `write(patch)`: integração com persistência/estado externo; pode retornar `false, motivo` para rejeitar.
- `store`: store compatível fornecido pelo consumidor; seu ciclo de vida permanece com o consumidor.
- `onError(message)`: destino dos erros de callbacks.
- `reducedMotion`: aplica transições imediatamente quando verdadeiro.

`ui:SetTheme(patch)` resolve um tema completo a partir do padrão e atualiza as cores dos componentes existentes. Para preservar overrides anteriores, inclua-os no próximo patch. Tokens de geometria orientam a construção e não substituem todo o layout de uma árvore já construída. Valores e chaves desconhecidas de tema são rejeitados. `ui:SetReducedMotion(boolean)` altera as próximas transições.

`ui.Events:Connect(function(event, id, value) ... end)` observa `change`, `activate`, `page` e `visibility`. Eventos particulares também existem nos handles.

## Contrato de componentes

`section:Add(kind, props)`, `page:Add(kind, props)` e `ui:Component(kind, parent, props)` devolvem um handle.

Propriedades comuns: `id`, `title`, `description`, `value`, `key`, `visible`, `disabled`, `loading`, `height`, `size` (`small`, `control`, `large`), `validate(value)` e `onChange(value, previous)`.

- `GetValue()` devolve um snapshot; `SetValue(value, silent?)` retorna `true` ou `false, motivo`.
- `SetDisabled`, `SetLoading`, `SetVisible`, `SetText`, `SetError` e `Destroy` controlam o handle.
- `Changed:Connect(callback)` observa alterações originadas nesse controle.
- `root` permite integração com APIs nativas do Roblox.

`silent = true` atualiza a apresentação sem gravar o store nem disparar callbacks; é usado para espelhar dados externos. Exibição, botão e containers não possuem um valor e não implementam `SetValue`/`GetValue` de forma útil. Componentes de valor normalizam e validam antes de aceitar uma alteração.

`onChange` representa uma mudança iniciada pela API do controle ou pela interação. `ui.store.Changed` observa alterações globais, inclusive patches externos. Assinaturas e `Destroy` são idempotentes. Remover uma página elimina suas seções e assinaturas.

### Propriedades específicas

| Componentes | Propriedades |
| --- | --- |
| Button | `text`, `variant` (token semântico), `onClick(handle)`, `loadingText` |
| Toggle/Checkbox | boolean; Toggle: `onText`, `offText`; Checkbox: `text` |
| Input/TextArea | string; `placeholder`, `maxLength`, `readOnly`; commit ao perder foco |
| NumberInput/Slider | `min`, `max`, `step`; Slider: `suffix`, `format(value)`; rejeitam NaN/infinito e limitam ao intervalo |
| Segmented/RadioGroup/Dropdown/MultiSelect | `options = { "a", "b" }` ou `{ {value = "a", label = "A", disabled = true} }`; Dropdown: `searchable`; MultiSelect: lista de valores únicos |
| Keybind | KeyCode ou MouseButton1/2/3; Escape cancela captura; `onTrigger(down)`, `hold` |
| ColorPicker | `Color3`; editor de seis dígitos hexadecimais |
| Progress | ratio de 0 a 1; `variant` |
| Label/Badge/Alert/Stat | `text` ou `title`; Alert: `description`; Badge/Alert/Stat: `variant` |
| Image | `image` (asset Roblox), `height` |
| Grid | `columns`, `breakpoint`, `cellHeight`; alterna para uma coluna abaixo do breakpoint |
| Accordion | boolean inicial, `Add(kind, props)` |
| Tabs | `height`; `Tab({id, title})` devolve Stack; `SelectTab(id)` |
| Table | `columns = {{key, title, sortable?, format?}}`, `value = {rows}`, `height`, `emptyText`; métodos `Sort(key, descending?)`, `SetFilter(text)` |

### Estado externo

```luau
local ui = Library.new({ values = host.read(), write = host.write })
local connection = host.observe(function(patch) ui.store:Patch(patch, true) end)
ui.scope:Add(connection)
ui.store:Set("enabled", false)
ui.store:Subscribe("enabled", function(value) print(value) end, true)
```

Patches são validados integralmente antes da escrita. Escritas rejeitadas mantêm os valores anteriores. Retornos síncronos do host não duplicam o evento. Os valores devem ser árvores acíclicas, sem funções, e não podem ser removidos por `nil`; use valores explícitos de estado vazio.

### Janela e overlays

`ui:Window({id, title, subtitle, width, height, visible, onClose, onMove})`: `Page`, `SelectPage`, `SetVisible`, `Toggle`, `Destroy`. Navegação lateral passa a horizontal em janelas estreitas. Cada página tem rolagem independente. A janela permanece dentro do viewport e respeita os insets do Roblox.

`ui:Notify({id?, title, message, variant, duration})`: uma notificação com o mesmo `id` substitui a anterior; `duration = 0` persiste. Fila limitada a oito, até quatro visíveis e adaptação à altura disponível. O handle tem `SetText` e `Destroy`.

`ui:Dialog({title, message, variant, confirmText, cancelText, onConfirm, onCancel})`: diálogo exclusivo com seleção de gamepad contida, Escape e restauração de foco. `Destroy` fecha sem executar callback.

`ui:Tooltip(guiButton, {text})`: mostra ajuda no hover ou seleção de gamepad; o scope retornado pode ser destruído. No touch, instruções essenciais devem estar nas descrições.

`ui:FloatingButton({text, width, height, position, variant, onClick, onHold, onMove})`: botão arrastável com descarte, `SetText`, `SetVisible` e `SetSize`. Uma ação mantida é liberada quando o app perde foco ou o controle é ocultado/destruído.

Menus de seleção são exclusivos e renderizados fora das áreas que recortam conteúdo. Atalhos são suspensos durante digitação, captura de tecla, menu ou diálogo. Sliders também aceitam setas/D-pad quando selecionados. Tokens e seleções nativas ajudam a navegação; a matriz completa de dispositivos deve ser verificada no Studio.

## Extensão

`ui:Register(name, factory)` registra um componente apenas nessa instância. A factory recebe `(context, parent, props)`. Use `context.scope:Child()` para possuir recursos e `context:WatchTheme(scope, render)` para assinar o tema. `scope:Add`, `Child`, `Delay` e `Destroy` são as primitivas de propriedade. Não retenha conexões globais fora de um scope.

## Build e validação

Python 3.12+, Luau CLI 0.747 e StyLua incluído no repositório:

```sh
python3 ui-library/scripts/build.py
python3 ui-library/scripts/build.py --check
python3 ui-library/scripts/test.py --luau /caminho/luau --compiler /caminho/luau-compile
python3 -m unittest discover -s 'exodus hub/indeed/tests' -p 'test_*.py'
'exodus hub/indeed/stylua-linux-x86_64' --check --config-path ui-library/stylua.toml ui-library/src ui-library/tests ui-library/examples
```

O bundler resolve `require(script...)` em tempo de build, mantém cache de módulos e detecta imports ausentes. A CI compila as fontes e executa testes com uma fronteira Roblox simulada. Essa suíte valida estado, eventos e descarte; não simula rasterização, medidas de texto ou dispatch real de touch. Use o showcase e o checklist da análise para a verificação visual no Roblox Studio.
