# Problemas e soluções

## Encontrados no caminho

| Problema | O que resolveu |
|---|---|
| % calculado somando tokens brutos não batia com o `/usage` | Leitura de cache domina o total mas pesa pouco no limite. Virou soma ponderada por custo (veja [como-funciona.md](como-funciona.md)). |
| Primeiro limite medido saiu baixo demais (7,9 mi em vez de ~18 mi) | Parte do % da sessão veio do claude.ai, que não aparece nos históricos. Agora a leitura real é âncora e o limite é medido pela diferença entre duas leituras. |
| `/usage` não tem saída de texto | Rodar o Claude Code dentro de `script` (pseudo-terminal), ler a tela e matar o processo assim que os números aparecem. |
| `claude "/usage"` saía na hora sem desenhar nada | Com o stdin fechado ele encerra. O app mantém um pipe aberto no stdin. |
| Na primeira vez, `/usage` fica parado em "Do you trust this folder?" | Abra uma vez `cd ~/.claudinho && claude` e escolha **Yes, I trust this folder**. Depois disso o app lê sozinho. |
| `@State` não compila só com as Command Line Tools | No SDK novo `@State` virou macro, e o plugin só vem com o Xcode. O formulário usa um `ObservableObject` com `@StateObject`. |
| ~5% de CPU com o painel fechado | O `MenuBarExtra` redesenhava o ícone a cada meio segundo, e o macOS copia o ícone pra cada tela. Ícone em AppKit, 1 quadro por segundo, cache de sprites e animação só quando trabalhando. |
| ~6% de CPU com o painel aberto | O painel inteiro redesenhava a cada quadro. O quadro foi pra um `ObservableObject` separado que só o desenho do chef observa. |
| Sessões abertas antes do `setup.py` não mudam de estado pelos hooks | É esperado: só sessões novas carregam os hooks. Reinicie. Enquanto isso o app usa os históricos. |

## Diagnóstico

```sh
cat ~/.claudinho/config.json        # limites e última leitura real
cat ~/.claudinho/state.json         # o que os hooks gravaram
cat ~/.claudinho/statusline.json    # o último % exato da statusLine
launchctl print gui/$UID/local.claudinho.monitor | grep -E "state|pid"
```

Pra ver o que o `/usage` escondido está recebendo:

```sh
cd ~/.claudinho && script -q /dev/null claude "/usage"
```
