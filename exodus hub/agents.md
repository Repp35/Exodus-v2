# AGENTS.md

## Princípio

Código profissional, compacto, sem decoração. A IA refatora o que está
errado, não decora o que está certo.

## Regras

1. **Escopo por módulo.** O que é exclusivo de um módulo fica nele. O
   que é compartilhado por 2+ vai pra `utils.luau` (serviços, lifecycle,
   hooks, config, state global).

2. **Sem acoplamento reverso.** Módulos não conhecem a estrutura do
   `loader`. O `loader` carrega, chama `setup` de cada módulo e coordena
   o runtime. Se o `loader` chama algo do módulo em loop de personagem,
   está errado — empurra pro próprio módulo.

3. **API pública é o que é usado.** Não exponha função por especulação.
   Se ninguém chama, não existe.

4. **Função morta = deletada.** Sem stub, sem wrapper. Tira também a
   chamada que a invocava.

5. **Fonte única de verdade.** Fórmula do raio, ping, cooldowns — quem
   define expõe, quem usa importa. Não recalcula.

6. **Heartbeat fica onde o estado vive.** `AutoClash` registra o próprio
   `Heartbeat:Connect` no `setup` e desliga no reset de personagem. O
   `loader` não faz loop de personagem para nenhum módulo.

7. **Bug encontrado durante revisão = corrigido.** Não deixa TODO, não
   comenta "fixme". Conserta.

8. **Versão bump em mudança significativa.** `SCRIPT_VERSION` em
   `utils.luau`. A UI lê `Utils.version()`, atualiza sozinha.

9. **Loop infinito de UI sempre tem saída.** Tasks de gradiente,
   partículas, etc. verificam `gui.Parent` antes de continuar.

## Comentários

- **Apenas** `-- [[ titulo ]]` no topo do módulo e `-- secao`
  separando blocos.
- Zero inline. Zero decorativo. Zero "isso faz X".

## O que a IA **não** faz

- Não adiciona `print`/`warn` de debug.
- Não cria documentação sem pedir.
- Não sugere `TODO`/`FIXME`/`XXX`.
- Não "melhora" nomenclatura que já é clara.
- Não adiciona dependência nova.
- Não deixa função pública sem caller conhecido.
- Não escreve teste.
