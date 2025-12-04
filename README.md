# 🕷️ web2pdf-crawler

Questo script esegue un crawling di un sito web con profondità e parallelismo configurabili, convertendo le pagine HTML in PDF utilizzando **Brave** in modalità headless. Gestisce gli errori e mantiene un log delle conversioni fallite.

Richiede un sistema **Unix-like** con:
- `bash`
- `wget`
- **Brave** installato
- Node.js (per eseguire lo script)

## Uso
```bash
./web2pdf <URL> [profondità_max] [processi_paralleli]
