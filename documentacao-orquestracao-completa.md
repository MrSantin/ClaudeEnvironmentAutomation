# Orquestração Claude Code + Antigravity CLI — Guia Completo

> **Ambiente:** Windows 11 · Claude Code (assinatura Claude) · Antigravity CLI (assinatura Google AI Pro)
> **Escopo:** Integração via MCP + orquestração automática de modelos com fallback

---

## Índice

1. [Visão Geral](#1-visão-geral)
2. [Arquitetura](#2-arquitetura)
3. [Pré-requisitos](#3-pré-requisitos)
4. [Guia de Instalação — Passo a Passo](#4-guia-de-instalação--passo-a-passo)
5. [Servidor MCP — Detalhes Técnicos](#5-servidor-mcp--detalhes-técnicos)
6. [Orquestração de Modelos e Fallback](#6-orquestração-de-modelos-e-fallback)
7. [Regras Globais de Orquestração](#7-regras-globais-de-orquestração)
8. [Subagente Executor (Opcional)](#8-subagente-executor-opcional)
9. [Teste de Ponta a Ponta](#9-teste-de-ponta-a-ponta)
10. [Troubleshooting](#10-troubleshooting)
11. [Referência Rápida](#11-referência-rápida)

---

## 1. Visão Geral

### O Problema

Duas assinaturas de IA com capacidades complementares:

- **Claude Code** (assinatura Claude) — excelente para planejamento, arquitetura e decisões complexas
- **Antigravity CLI** (assinatura Google AI Pro) — acesso a múltiplos modelos (Gemini, Claude, GPT-OSS) com cotas independentes

Sem integração, cada ferramenta funciona isoladamente. O potencial de combinar
planejamento inteligente com execução massiva (e fallback automático entre modelos)
fica desperdiçado.

### A Solução

Uma arquitetura em duas camadas:

| Camada | Ferramenta | Responsabilidade |
|---|---|---|
| **Orquestração** | Claude Code | Planeja, arquiteta, decide, revisa |
| **Execução** | Antigravity CLI (`agy`) | Edita código, refatora, aplica mudanças multi-arquivo |

A ponte entre as camadas é um **servidor MCP (Model Context Protocol)** que expõe
o `agy` como ferramenta dentro do Claude Code, com fallback automático e anunciado.

Adicionalmente, **dentro do Antigravity**, uma cadeia de fallback entre modelos
garante que a quota esgotada de um modelo não interrompa o trabalho — os modelos
têm cotas independentes.

### Cotas Independentes por Modelo

Ponto fundamental: **esgotar a cota de um modelo NÃO afeta os outros.**

```
  Gemini 3.1 Pro    ████████████░░░░  75% usado
  Claude Opus 4.6   ██░░░░░░░░░░░░░░  12% usado  ← disponível
  Claude Sonnet 4.6 ░░░░░░░░░░░░░░░░   0% usado  ← disponível
  Gemini 3.5 Flash  ███░░░░░░░░░░░░░  18% usado  ← disponível
```

---

## 2. Arquitetura

```
Você  →  Claude Code (assinatura, OAuth)  ── planeja / orquestra
                     │
                     │ chama a tool MCP
                     ▼
     mcp__antigravity__gemini_execute(prompt, model?, timeout?)
                     │
          servidor MCP stdio (Python)  ── aloca PTY, roda `agy -p`, limpa ANSI
                     │
          ┌──────────┴───────────┐
          ▼                      ▼
     agy OK →                quota / erro / saída vazia
   devolve o texto           → tool ERROR: "GEMINI_UNAVAILABLE: ..."
                                → Claude executa ele mesmo (assinatura)
                                → AVISA você explicitamente
```

### Cadeia de Fallback entre Modelos (dentro do Antigravity)

```
┌─────────────────────────────────────────────────────────┐
│                    Fluxo de Fallback                    │
│                                                         │
│  Gemini 3.1 Pro (High)  ──quota──►  Claude Opus 4.6    │
│                                          │              │
│                                        quota            │
│                                          ▼              │
│                                    Claude Sonnet 4.6    │
│                                          │              │
│                                        quota            │
│                                          ▼              │
│                                  Gemini 3.5 Flash (H)   │
│                                          │              │
│                                        quota            │
│                                          ▼              │
│                                  Gemini 3.5 Flash (M)   │
│                                    (último recurso)     │
└─────────────────────────────────────────────────────────┘
```

### Premissas de Autenticação

- **A assinatura Claude só é usada se o Claude Code NÃO tiver `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY` persistidos.** O Gemini entra como **ferramenta**, nunca como troca de modelo base.
- **O `agy` autentica por OAuth da conta Google** e **ignora `GEMINI_API_KEY`**. É "usar o que você já paga".
- **Usar modelos Claude *dentro* do `agy` consome a quota do Google**, não seu plano Claude.

---

## 3. Pré-requisitos

| Ferramenta | Requisito | Verificação |
|---|---|---|
| **PowerShell** | 5.1+ (nativo do Windows) | `$PSVersionTable.PSVersion` |
| **Python** | 3.9+ no PATH | `python --version` |
| **Node.js/npm** | Para instalar o Claude Code | `node --version` |
| **Claude Code** | Instalado e autenticado | `claude --version` |
| **Antigravity CLI** | Instalado e autenticado (Google AI Pro) | `agy --version` |
| **SDK MCP (Python)** | `pip install "mcp[cli]"` | `python -c "import mcp"` |
| **pywinpty** | ConPTY para Windows nativo | `python -c "import winpty"` |

### Variáveis de Ambiente — Atenção

**Confirme que nenhum proxy vazou para o ambiente:**

```powershell
foreach ($v in "ANTHROPIC_BASE_URL","ANTHROPIC_API_KEY") {
  "{0}: usuario=[{1}] maquina=[{2}]" -f $v,
    [Environment]::GetEnvironmentVariable($v,"User"),
    [Environment]::GetEnvironmentVariable($v,"Machine")
}
# Ambos devem estar VAZIOS nos escopos usuário/máquina.
```

> **Cheque o escopo, não só `$env:`.** O que desliga a assinatura é a variável
> **persistida** (usuário/máquina). O próprio Claude Code injeta
> `ANTHROPIC_BASE_URL` no ambiente dos shells que ele cria — um
> `$env:ANTHROPIC_BASE_URL` preenchido **dentro** de uma sessão do Claude Code é
> esperado e inofensivo.

### Nomes de Modelo — Cuidado

> **O `--model` espera o NOME EXIBIDO, não um slug.** `"gemini-3.1-pro"` **não**
> é aceito. O `agy` quer a string exata da lista, com espaços e sufixo de esforço:
>
> ```
> Gemini 3.5 Flash (Medium)      Gemini 3.1 Pro (Low)         Claude Sonnet 4.6 (Thinking)
> Gemini 3.5 Flash (High)        Gemini 3.1 Pro (High)        Claude Opus 4.6 (Thinking)
> Gemini 3.5 Flash (Low)                                      GPT-OSS 120B (Medium)
> ```
>
> Confirme com `agy models` — a lista muda ao longo do tempo.

---

## 4. Guia de Instalação — Passo a Passo

### Passo 0 — Executar o Script Automatizado (Recomendado)

O script `setup-ambiente-completo.ps1` (incluso neste pacote) automatiza **todos
os passos abaixo**. Se preferir a instalação manual, siga os passos 1–8.

```powershell
# Execução com confirmação interativa
.\setup-ambiente-completo.ps1

# Execução sem confirmação (modo silencioso)
.\setup-ambiente-completo.ps1 -Force

# Apenas verificar o estado atual
.\setup-ambiente-completo.ps1 -Check

# Dry run (mostra o que seria feito sem alterar nada)
.\setup-ambiente-completo.ps1 -DryRun
```

### Passo 1 — Instalar Python 3.9+

Se o Python não estiver instalado:

```powershell
winget install Python.Python.3.12 --accept-source-agreements --accept-package-agreements
# Reinicie o terminal para atualizar o PATH
```

Confirme: `python --version` → deve mostrar 3.9 ou superior.

### Passo 2 — Instalar Node.js (necessário para o Claude Code)

```powershell
winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
```

Confirme: `node --version` e `npm --version`.

### Passo 3 — Instalar Claude Code

```powershell
npm install -g @anthropic-ai/claude-code
```

Autentique: `claude` (abre o navegador para OAuth com sua conta Anthropic/Claude).

Confirme: `claude --version`.

### Passo 4 — Instalar Antigravity CLI (`agy`)

```powershell
irm https://antigravity.google/cli/install.ps1 | iex
```

Autentique: `agy` (abre o navegador para Google Sign-In com a conta que tem Google AI Pro).

Confirme:
- `agy --version`
- `agy models` (lista os modelos disponíveis)

### Passo 5 — Instalar Dependências Python

```powershell
pip install "mcp[cli]" pywinpty
```

Confirme:
- `python -c "from mcp.server.fastmcp import FastMCP; print('OK')"`
- `python -c "from winpty import PtyProcess; print('OK')"`

### Passo 6 — Criar o Servidor MCP

O servidor é um script Python (~80 linhas) que expõe o `agy` como ferramenta MCP.

**Local:** `%USERPROFILE%\.claude\mcp\antigravity_mcp.py`

```powershell
# Criar o diretório
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.claude\mcp"

# O script setup-ambiente-completo.ps1 gera o arquivo automaticamente.
# Para edição manual, veja a seção 5 (Servidor MCP — Detalhes Técnicos).
```

### Passo 7 — Registrar o Servidor MCP no Claude Code

```powershell
claude mcp add --scope user antigravity -- python "$env:USERPROFILE\.claude\mcp\antigravity_mcp.py"
```

`--scope user` grava em `~/.claude.json` e vale em **todos os projetos**.

Confirme dentro de um projeto:
- `/mcp` → deve listar `antigravity` como *connected*

### Passo 8 — Configurar Regras Globais

Dois arquivos de regras são necessários:

#### 8a. Claude Code — `~/.claude/CLAUDE.md`

Regra de orquestração + fallback para o Claude Code. Instruções de como delegar
ao Antigravity e o que fazer quando o Gemini estiver indisponível.

#### 8b. Antigravity CLI — `~/.gemini/GEMINI.md`

Regra de fallback entre modelos para o agente do Antigravity. Cadeia de prioridade,
detecção proativa de quota, e delegação inteligente a subagentes.

#### 8c. Antigravity Settings — `~/.gemini/antigravity-cli/settings.json`

Modelo padrão alterado para `Gemini 3.1 Pro (High)` (em vez de Low).

> **Todos esses arquivos são criados automaticamente pelo script `setup-ambiente-completo.ps1`.**

### Passo 9 — Validar a Instalação

```powershell
# 1. Verificar artefatos
.\setup-ambiente-completo.ps1 -Check

# 2. Dentro de um projeto com o Claude Code:
claude
# /mcp → "antigravity" connected
# /memory → deve listar ~/.claude/CLAUDE.md

# 3. Testar a execução completa:
# Peça algo que envolva planejar + executar:
# "Refatore o módulo X para separar a responsabilidade Y.
#  Planeje primeiro; a execução delegue ao Antigravity."
```

---

## 5. Servidor MCP — Detalhes Técnicos

### Localização

`%USERPROFILE%\.claude\mcp\antigravity_mcp.py`

### Tools Expostas

| Tool | Parâmetros | Função |
|---|---|---|
| `gemini_execute` | `prompt` (obrigatório), `model?`, `timeout?` | Executa instrução via `agy -p` sob PTY |
| `gemini_models` | — | Lista modelos disponíveis (`agy models`) |

### Detecção de Falha em Três Camadas

O `agy` sinaliza falha de três formas diferentes — nenhuma cobre as outras duas:

1. **Exit code ≠ 0** → erro real (modelo inválido, auth, flag ruim). Sem checar, o
   `agy` imprime o erro no stdout e ele volta como "resposta do Gemini".

2. **Saída vazia** → bug #76: stdout descartado fora de TTY, com exit 0. Tratar
   como sucesso entregaria string vazia como resultado válido.

3. **Regex de quota** → negativa de quota que sai com exit 0. Palavras-chave:
   `quota`, `rate limit`, `resource exhausted`, `429`, `cooldown`, `try again`, etc.

### PTY — Por que é Necessário

O bug #76 do `agy` (binário closed-source em Go) descarta o stdout fora de TTY e
retorna exit 0. O pseudo-terminal contorna isso. No Windows, usa `pywinpty` (ConPTY);
no Unix/WSL, usa o módulo `pty` da stdlib.

### Limpeza de Saída (`_clean`)

O `agy` renderiza TUI com spinner animado. A limpeza:
1. Remove sequências ANSI (cores, movimentos de cursor)
2. Emula carriage return (`\r`) — só mantém o último segmento de cada linha

> **Ordem importa:** normalizar `\r\n` → `\n` ANTES do split por `\r`. Sem isso,
> o `\r` final de cada linha CRLF apaga o próprio conteúdo.

---

## 6. Orquestração de Modelos e Fallback

### Cadeia de Prioridade (do mais capaz ao mais leve)

| Prioridade | Modelo | Uso Ideal |
|:----------:|---|---|
| 1 | Gemini 3.1 Pro (High) | Execução pesada, refatorações extensas, multi-arquivo |
| 2 | Claude Opus 4.6 (Thinking) | Raciocínio profundo, arquitetura, decisões complexas |
| 3 | Claude Sonnet 4.6 (Thinking) | Raciocínio intermediário quando Opus esgotar |
| 4 | Gemini 3.5 Flash (High) | Tarefas rápidas, pesquisas, geração leve |
| 5 | Gemini 3.5 Flash (Medium) | Último recurso, cota mais generosa |

### Comportamento de Fallback

#### No Claude Code (via MCP)

Quando `gemini_execute` retorna `GEMINI_UNAVAILABLE`:

1. **NÃO tenta de novo** (quota semanal, cooldown de dias)
2. **AVISA o usuário** explicitamente
3. **Assume a execução** usando a assinatura Claude
4. **Revisa o resultado** via `git diff` após concluir

#### No Antigravity (entre modelos)

Quando detecta sinais de quota (`429`, `resource exhausted`, `cooldown`, etc.):

1. **NÃO tenta de novo** no mesmo modelo
2. **AVISA o usuário** com recomendação do próximo modelo:

> ⚠️ **Limite de modelo atingido**
> O modelo **Gemini 3.1 Pro (High)** atingiu o limite de quota.
> **Recomendo trocar para: Claude Opus 4.6 (Thinking)** via Model Selection
> nas configurações, para continuar sem interrupção.
> Modelos restantes na cadeia: Claude Sonnet 4.6, Gemini 3.5 Flash (High/Medium)

3. **Nunca deixa a tarefa incompleta**

### Delegação Inteligente a Subagentes

| Tipo de Tarefa | Modelo do Subagente |
|---|---|
| Pesquisa e leitura de arquivos | `flash` |
| Tarefas simples e mecânicas | `flash_lite` |
| Raciocínio complexo | `inherit` ou `pro` |
| Múltiplos subagentes em paralelo | `flash` (salvo se exigir raciocínio) |

### Override por Projeto

Ambas as regras globais podem ser sobrescritas por projeto:

- **Claude Code:** `CLAUDE.md` na raiz do projeto
- **Antigravity:** `GEMINI.md` na raiz do projeto ou `.agents/rules/`

A regra mais específica vence — mas apenas no ponto explicitamente sobrescrito.

---

## 7. Regras Globais de Orquestração

### Claude Code — `~/.claude/CLAUDE.md`

Contém:
- Divisão de trabalho: Claude planeja, `agy` executa
- Instrução para prompts autocontidos ao delegar
- Fallback obrigatório e anunciado
- Revisão obrigatória pós-execução (`git diff`, não o resumo textual)

### Antigravity — `~/.gemini/GEMINI.md`

Contém:
- Cadeia de prioridade de modelos
- Detecção proativa de limites de quota
- Formato padronizado de aviso ao usuário
- Estratégia de delegação inteligente a subagentes

### Settings do Antigravity — `~/.gemini/antigravity-cli/settings.json`

- Modelo padrão: `Gemini 3.1 Pro (High)` (sufixo High para respostas mais
  completas e raciocínio mais profundo)

---

## 8. Subagente Executor (Opcional)

O subagente `gemini-executor` é **opcional** — o orquestrador chama a tool direto
por padrão. Usar é questão de preferência:

- **Sem subagente (recomendado):** menos hops, menos tokens, menos indireção
- **Com subagente:** isolamento de contexto em sequências longas de execução

Se mantido, deve chamar a **tool MCP**:

```yaml
name: gemini-executor
tools: mcp__antigravity__gemini_execute
```

Para instalar com o subagente: `.\setup-ambiente-completo.ps1 -KeepSubagent`

---

## 9. Teste de Ponta a Ponta

### Teste do Fluxo Normal

1. `cd` num projeto real e abra o `claude`
2. `/mcp` → `antigravity` deve aparecer **connected**
3. `/memory` → `~/.claude/CLAUDE.md` deve estar entre os arquivos carregados
4. Peça algo que envolva planejar + executar:
   *"Refatore o módulo X para separar a responsabilidade Y. Planeje primeiro;
   a execução delegue ao Antigravity."*
5. Fluxo esperado: Claude planeja → chama `gemini_execute` → `agy` aplica →
   Claude revisa o diff

### Teste do Fallback

Temporariamente, logo após a checagem de prompt vazio em `gemini_execute`,
adicione:
```python
raise GeminiUnavailable("GEMINI_UNAVAILABLE: teste forcado")
```

Repita o teste: o Claude deve **avisar** e concluir sozinho. **Reverta depois.**

---

## 10. Troubleshooting

### Problemas do Claude Code / MCP

| Problema | Causa | Solução |
|---|---|---|
| `/mcp` não lista `antigravity` | Registro não pegou | `claude mcp list` — confirme `HOME`/usuário |
| MCP aparece como *failed* | Erro de import | `python ~/.claude/mcp/antigravity_mcp.py` — erro aparece na hora |
| `ModuleNotFoundError: mcp` | Python errado | `pip install "mcp[cli]"` no **mesmo Python** do registro |
| Toda chamada volta `GEMINI_UNAVAILABLE` | Bug #76 do PTY | `agy -p "OK"` num terminal real — se OK, confirme `pywinpty` |
| `GEMINI_API_KEY` sem efeito | `agy` ignora essa var | Remova-a para não confundir |
| Trava sem responder | Timeout curto | Aumente `timeout` na chamada ou `AGY_EXEC_TIMEOUT` |
| Modelo inválido | Slug em vez de nome | Use `agy models` e a string **exata** com espaços |
| Saída cheia de `⠋ Fetching...` | Limpeza de saída antiga | Reinstale com o script atual |
| Claude parou de usar assinatura | Vars persistidas | Confira `ANTHROPIC_*` no escopo usuário/máquina |

### Problemas do Antigravity / Modelos

| Problema | Causa | Solução |
|---|---|---|
| Agente não avisa sobre quota | `GEMINI.md` não carregado | Confirme que está em `~/.gemini/GEMINI.md` |
| Modelo padrão ainda é (Low) | `settings.json` não atualizado | Rode o script ou troque via Model Selection |
| Subagentes consomem cota do principal | `Model` não especificado | Subagentes devem usar `flash` |
| Quota esgotou em todos os modelos | Todas as cotas semanais | Aguarde o reset ou reduza o volume |

### Windows Nativo vs WSL

O PTY funciona no Windows nativo via `pywinpty`/ConPTY, mas o `agy` renderiza TUI
e a captura é menos rodada. Se travar de forma inconsistente, caia para o WSL:

```powershell
claude mcp add --scope user antigravity -- wsl python3 /home/<usuario>/.claude/mcp/antigravity_mcp.py
```

---

## 11. Referência Rápida

### Estrutura de Arquivos

```
%USERPROFILE%\
├── .claude\
│   ├── CLAUDE.md                        ← regras de orquestração (Claude Code)
│   ├── .claude.json                     ← registro do servidor MCP
│   ├── mcp\
│   │   └── antigravity_mcp.py           ← servidor MCP (Python)
│   └── agents\
│       └── gemini-executor.md           ← subagente (opcional)
│
└── .gemini\
    ├── GEMINI.md                        ← regras de fallback (Antigravity)
    └── antigravity-cli\
        └── settings.json               ← modelo padrão: Gemini 3.1 Pro (High)
```

### Comandos Úteis

```powershell
# Verificar estado completo
.\setup-ambiente-completo.ps1 -Check

# Instalar/atualizar tudo
.\setup-ambiente-completo.ps1 -Force

# Apenas simular
.\setup-ambiente-completo.ps1 -DryRun

# Desinstalar artefatos
.\setup-ambiente-completo.ps1 -Uninstall

# Restaurar backups
.\setup-ambiente-completo.ps1 -Restore

# Trocar modelo padrão
.\setup-ambiente-completo.ps1 -Model "Claude Opus 4.6 (Thinking)"

# Ver modelos disponíveis
agy models

# Verificar MCP dentro do Claude Code
claude → /mcp

# Verificar regras carregadas
claude → /memory
```
