# Exodus v2

Hub Luau modular para reação, AutoParry, AutoSpam e ferramentas auxiliares.

## Uso

Com o GitHub Pages publicado:

```lua
loadstring(game:HttpGet("https://repp35.github.io/Exodus-v2/loader.luau"))()
```

O loader valida o manifesto, carrega a revisão identificada pelo SHA e inicializa os módulos respeitando os contratos internos.

## Arquitetura

- `loader.luau`: bootstrap, cache, manifesto, autorização e composição dos módulos.
- `modules/front`: configuração e interface.
- `modules/logic`: adaptador do jogo, remotes, ciclo de vida e módulos de reação.
- [`docs/API.md`](docs/API.md): contratos públicos e regras de sincronização.

## Desenvolvimento

Os testes estáticos e o formatador ficam em `exodus hub/indeed`:

```bash
python3 -m unittest discover -s 'exodus hub/indeed/tests' -v
python3 'exodus hub/indeed/formatter.py' --check 'exodus hub'
```
