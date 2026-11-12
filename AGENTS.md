# Diretrizes de manutenção

## README imutável

`README.md` é um snapshot histórico e deve permanecer exatamente como está no
commit de origem da aplicação. Não o edite, formate, reorganize, complete ou
use como destino para documentação nova. Toda documentação técnica deve ficar
em `docs/`.

## Escopo da interface

Mudanças de UI devem permanecer em `exodus hub/modules/front`, em `docs/` e
nos testes diretamente relacionados. Não altere módulos de gameplay,
integrações ou contratos compartilhados por conveniência. Se uma correção de
integração for indispensável para a UI, documente o motivo e preserve a API
pública existente.

## Padrões da UI

- Use os tokens visuais e de motion definidos no início de `ui.luau`.
- Toda animação nova deve respeitar `twPlay`, o estado de movimento reduzido e
  o ciclo de vida de limpeza da UI.
- Transições concorrentes devem ser protegidas por geração/estado, sem timers
  fixos usados como substitutos de eventos de conclusão.
- Componentes interativos devem manter feedback de foco, hover e pressão sem
  adicionar trabalho por frame.
- Atualizações de telemetria devem ser limitadas ao intervalo útil e conexões
  devem passar por `trackConn` para serem limpas.
- Preserve as funcionalidades e os nomes dos contratos de `ExodusUI.setup`.

Consulte `docs/UI.md` antes de reorganizar componentes ou introduzir novos
padrões visuais.
