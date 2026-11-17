# Exodus v2

## Validação local

Execute os comandos na raiz do repositório com Python 3.10 ou superior. O formatador usa o StyLua incluído no repositório em Linux x86-64 ou procura `stylua` no `PATH`.

```sh
python3 -m unittest discover -s 'exodus hub/indeed/tests' -p 'test_formatter_*.py'
python3 'exodus hub/indeed/formatter.py' --check
python3 'exodus hub/indeed/build_ui_icons.py' --check
```

Por padrão, o formatador percorre toda a pasta `exodus hub`. Use `--in-place` para aplicar a formatação aos arquivos `.luau`. O modo `--check` apenas informa se algum arquivo precisa ser formatado.
