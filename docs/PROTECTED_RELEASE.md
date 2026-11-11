# Distribuição protegida

O código-fonte permanece no repositório privado. O workflow `.github/workflows/build-protected.yml` cria uma distribuição separada, ofusca todos os arquivos Luau com o Prometheus e publica somente essa distribuição no GitHub Pages.

## Configuração obrigatória

1. Ative o GitHub Pages do repositório usando **GitHub Actions** como origem.
2. Crie o secret do repositório `EXODUS_AUTHORIZED_USER_IDS`.
3. Informe os Roblox UserIds autorizados separados por vírgula:

```text
123456789,987654321
```

Opcionalmente, crie estas variáveis do repositório:

- `EXODUS_ALLOWED_GAME_IDS`
- `EXODUS_ALLOWED_PLACE_IDS`
- `EXODUS_EXPIRES_AT` — timestamp Unix; vazio significa sem expiração.

Sem `EXODUS_AUTHORIZED_USER_IDS`, o build falha de propósito.

## Loadstring da distribuição

Depois de executar o workflow:

```lua
loadstring(game:HttpGet("https://repp35.github.io/Exodus-v2/loader.luau"))()
```

O loader verifica o executor, o manifesto da versão, a revisão da autorização, o UserId, a experiência, o lugar e a expiração antes de baixar os módulos. O fallback local fica desativado na distribuição protegida.
