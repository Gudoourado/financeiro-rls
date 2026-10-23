# Roteiro — apresentação do Financeiro RLS no GitHub

- **Versão:** branch `docs/readme-visual`, base `b52816d`.
- **Como subir os testes:** `docker compose up -d --wait` na pasta `financeiro-rls`; a apresentação fica no README da branch no GitHub.
- **Coberto pelos testes (não precisa repetir à mão):** 10 testes de isolamento com PostgreSQL 17 e `app_runtime`; XML do banner válido, 18 links locais conferidos e `git diff --check` sem erro. O projeto não tem comando de lint.
- **Tempo:** cerca de 3 minutos.

Responda **passou**, **falhou** ou **bloqueado** após cada passo. O assistente registra o resultado antes de seguir.

## Caminho bom

1. Abra o README da branch `docs/readme-visual` no GitHub.

   **Esperado:** a capa azul “Dados isolados por usuário.” aparece inteira, seguida de “Financeiro RLS”, um resumo curto e três linhas de evidências.

   - [ ] passou · [ ] falhou · [ ] bloqueado — observação:

2. Clique em “entender a proteção” na linha “Explore”.

   **Esperado:** a página salta para “Como o isolamento funciona”, com quatro passos legíveis que explicam a transação, o papel `app_runtime` e o RLS.

   - [ ] passou · [ ] falhou · [ ] bloqueado — observação:

3. Expanda “O que cada teste verifica”.

   **Esperado:** aparece uma tabela com 10 verificações, de privilégios do papel até o limite da marca de usuário.

   - [ ] passou · [ ] falhou · [ ] bloqueado — observação:

4. Clique em “ver os resultados” na linha “Explore”.

   **Esperado:** aparecem Q3, Q2 e Q1 com os tempos “325–335 ms” → “0,09–0,10 ms” para Q3 e a decisão “Descartado” para Q2.

   - [ ] passou · [ ] falhou · [ ] bloqueado — observação:

## Caminho ruim: largura pequena

5. Reduza a janela do README para a largura de um celular.

   **Esperado:** o título da capa, o texto e o diagrama continuam legíveis; nenhuma coluna fica cortada sem possibilidade de rolagem.

   - [ ] passou · [ ] falhou · [ ] bloqueado — observação:

## Regressão provável

O GitHub pode renderizar o SVG de forma diferente da prévia local. Confira também se o link “ler o relatório completo” abre `docs/relatorio.md`.

## Limpeza

Depois da aprovação, `docker compose down` preserva o volume de testes. O PR pode ser integrado somente com o “aprovado”.

## Resultado

- Passaram 0 de 5. Melhorias pedidas: nenhuma até agora.
- Conferência técnica: 10 testes passaram; banner e links locais válidos.
- [ ] **Aprovado em** <data> · [ ] **Com problemas:** <o quê>
