# Distribuição protegida

O código de desenvolvimento continua no repositório privado. O GitHub Actions copia os arquivos, gera uma versão ofuscada com o Prometheus e publica somente essa saída no GitHub Pages.

## Configuração

1. Ative o GitHub Pages do repositório usando **GitHub Actions** como origem.
2. O secret `EXODUS_BLOCKED_USER_IDS` é opcional. Se existir, informe os Roblox UserIds bloqueados separados por vírgula:

```text
123456789,987654321
```

Se o secret ficar vazio ou não existir, nenhum usuário será bloqueado.

Opcionalmente, crie estas variáveis do repositório:

- `EXODUS_ALLOWED_GAME_IDS`
- `EXODUS_ALLOWED_PLACE_IDS`
- `EXODUS_EXPIRES_AT` — timestamp Unix; vazio significa sem expiração.

## Loader

Depois que o Pages estiver ativo, o uso permanece:

```lua
loadstring(game:HttpGet("https://repp35.github.io/Exodus-v2/loader.luau"))()
```

O loader valida o executor, baixa o manifesto da revisão, verifica se o UserId está na lista de bloqueio e só então carrega os módulos daquela revisão. A lista de bloqueio é embutida junto da saída ofuscada de cada build.

## Limite real

Sem um servidor de autorização, essa proteção é uma barreira no cliente: alguém com acesso ao código entregue ainda pode tentar modificar o loader ou analisar o payload. Ela impede o uso normal por IDs bloqueados e reduz a exposição do fonte, mas não cria proteção impossível de contornar.
