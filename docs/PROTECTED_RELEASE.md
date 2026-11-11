# Distribuição versionada

O workflow de GitHub Pages publica cada build em uma pasta identificada pelo SHA do commit e expõe um `manifest.json` com `schema`, produto e revisão. O loader valida esses campos antes de aceitar a atualização.

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

Depois que o Pages estiver ativo:

```lua
loadstring(game:HttpGet("https://repp35.github.io/Exodus-v2/loader.luau"))()
```

O loader baixa o manifesto, valida a revisão, verifica a autorização do usuário e carrega os módulos daquela revisão. A autorização e qualquer bloqueio são aplicados no cliente.

## Limite real

Esta distribuição é versionada, não um mecanismo de sigilo. O workflow atual publica os arquivos Luau como estão; sem assinatura ou autorização fora do cliente, alguém com acesso ao código entregue ainda pode analisar ou modificar o loader. A lista de bloqueio reduz o uso normal por IDs bloqueados, mas não é uma proteção impossível de contornar.
