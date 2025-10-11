#!/bin/bash

set -euo pipefail

SITO="${1:-}"
MAX_DEPTH="${2:-2}"
MAX_CONCURRENT="${3:-3}"
PDF_DIR="pdf_$(date +%Y%m%d_%H%M%S)"
FAILED_LOG="$PDF_DIR/failed.log"

# Validazione input
if [[ -z "$SITO" ]]; then
    echo "Uso: $0 <URL> [profondità_max] [processi_paralleli]"
    echo "Esempio: $0 https://example.com 2 3"
    exit 1
fi

if ! [[ "$SITO" =~ ^https?:// ]]; then
    echo "Errore: URL deve iniziare con http:// o https://"
    exit 1
fi

# Rileva il comando Chrome disponibile
detect_chrome() {
    if [[ -f "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]]; then
        echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    elif command -v google-chrome &> /dev/null; then
        echo "google-chrome"
    elif command -v chromium &> /dev/null; then
        echo "chromium"
    else
        echo "Errore: Nessun browser Chrome trovato"
        exit 1
    fi
}

# Implementa timeout portabile
portable_timeout() {
    local timeout_duration="$1"
    shift

    if command -v timeout &> /dev/null; then
        timeout "$timeout_duration" "$@"
    elif command -v gtimeout &> /dev/null; then
        gtimeout "$timeout_duration" "$@"
    else
        # Fallback con perl
        perl -e "
            alarm($timeout_duration);
            exec(@ARGV) or die \"exec failed: \$!\";
        " "$@" 2>/dev/null
    fi
}

# Verifica dipendenze essenziali
check_dependency() {
    case "$1" in
        "wget")
            if ! command -v wget &> /dev/null; then
                echo "Errore: wget non è installato. Installa con: brew install wget"
                exit 1
            fi
            ;;
    esac
}

check_dependency wget

CHROME_CMD=$(detect_chrome)
echo "🌐 Usando browser: $(basename "$CHROME_CMD")"

# Test Chrome prima di iniziare
echo "🔧 Test Chrome..."
if ! portable_timeout 10 "$CHROME_CMD" --headless --disable-gpu --version &>/dev/null; then
    echo "❌ Errore: Chrome non funziona correttamente"
    exit 1
fi
echo "✅ Chrome funziona"

# Funzione per convertire URL in nome file univoco
url_to_filename() {
    local url="$1"

    # Nome base pulito
    local base_name=$(echo "$url" | \
        sed 's|https\?://||' | \
        sed 's|/$||' | \
        tr '/' '_' | \
        tr -cd 'a-zA-Z0-9._-' | \
        cut -c1-80)

    # Hash per garantire univocità
    local hash=$(echo "$url" | shasum -a 256 | cut -c1-8)

    # Fallback se il nome base è vuoto
    [[ -z "$base_name" ]] && base_name="page"

    echo "${base_name}_${hash}.pdf"
}

# Conversione PDF robusta con logging errori
convert_to_pdf() {
    local url="$1"
    local output_file="$2"
    local retries=3

    for ((attempt=1; attempt<=retries; attempt++)); do
        if portable_timeout 60 "$CHROME_CMD" \
            --headless \
            --disable-gpu \
            --no-sandbox \
            --disable-dev-shm-usage \
            --disable-web-security \
            --disable-extensions \
            --virtual-time-budget=5000 \
            --print-to-pdf="$output_file" \
            "$url" 2>/dev/null; then

            # Verifica che il PDF sia stato creato e non sia vuoto
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                return 0
            fi
        fi

        [[ $attempt -lt $retries ]] && sleep 2
    done

    # Log fallimento
    echo "$(date '+%Y-%m-%d %H:%M:%S') FAILED: $url" >> "$FAILED_LOG"
    return 1
}

echo "🚀 Inizio estrazione da: $SITO"
echo "📁 PDF salvati in: ./$PDF_DIR"
echo "📊 Profondità max: $MAX_DEPTH, Processi paralleli: $MAX_CONCURRENT"

mkdir -p "$PDF_DIR"

# Estrazione URL
echo "🕷️  Crawling del sito..."
wget --spider \
     --recursive \
     --no-directories \
     --no-verbose \
     --level="$MAX_DEPTH" \
     --wait=1 \
     --reject-regex='.*\.(jpg|jpeg|png|gif|pdf|zip|tar\.gz|js|css|woff|woff2|ttf|ico|svg)(\?.*)?$' \
     --output-file=wget.log \
     "$SITO" 2>/dev/null || {
    echo "⚠️  Crawling completato (con alcuni errori)"
}

# Parsing URL robusto e standardizzato
echo "📝 Estrazione URL dal log..."

# Usa grep generico per tutti gli URL HTTP/HTTPS nel log
grep -Eo 'https?://[^[:space:]"]+' wget.log 2>/dev/null | \
    sed 's/:$//' | \
    grep "^$SITO" | \
    grep -v 'robots\.txt' | \
    sort -u > urls.txt || {

    # Fallback
    echo "$SITO" > urls.txt
}

NUM=$(wc -l < urls.txt | tr -d ' ')
echo "📄 Trovati $NUM URL da convertire"

if [[ $NUM -eq 0 ]]; then
    echo "❌ Nessun URL valido trovato"
    exit 1
fi

echo "📋 URL da convertire:"
cat urls.txt | head -5
[[ $NUM -gt 5 ]] && echo "... e altri $((NUM - 5)) URL"

# Funzione per conversione singola
convert_single() {
    local line="$1"
    local url counter total
    IFS='|' read -r counter url total <<< "$line"

    local filename=$(url_to_filename "$url")
    local output_file="$PDF_DIR/$filename"

    if convert_to_pdf "$url" "$output_file"; then
        echo "   ✅ ($counter/$total) $(basename "$filename")"
        return 0
    else
        echo "   ❌ ($counter/$total) FAILED: $(basename "$filename")"
        return 1
    fi
}

export -f convert_to_pdf url_to_filename portable_timeout convert_single
export CHROME_CMD PDF_DIR FAILED_LOG

echo "⚡ Inizio conversione (parallelismo: $MAX_CONCURRENT)..."

# Preparazione per parallelizzazione
nl urls.txt | while read counter url; do
    echo "$counter|$url|$NUM"
done | \
if command -v parallel &> /dev/null; then
    # Usa GNU parallel se disponibile
    parallel -j "$MAX_CONCURRENT" --colsep '|' 'convert_single {1}"|"{2}"|"{3}'
else
    # Fallback con xargs
    xargs -n1 -P"$MAX_CONCURRENT" -I{} bash -c 'convert_single "{}"'
fi

# Calcola statistiche finali
success=$(find "$PDF_DIR" -name "*.pdf" -type f | wc -l | tr -d ' ')
failed=$((NUM - success))

echo
echo "✨ Conversione completata!"
echo "📊 Risultati:"
echo "   ✅ Successi: $success/$NUM"
echo "   ❌ Falliti: $failed"

if [[ -f "$FAILED_LOG" && -s "$FAILED_LOG" ]]; then
    echo "   📄 Log errori: $FAILED_LOG"
    echo "   🔍 URL falliti:"
    while IFS= read -r line; do
        echo "      ${line#*FAILED: }"
    done < "$FAILED_LOG" | head -3
    [[ $(wc -l < "$FAILED_LOG") -gt 3 ]] && echo "      ... e altri"
fi

echo "   📁 Cartella: ./$PDF_DIR"

# Statistiche sui file creati
if [[ $success -gt 0 ]]; then
    echo "📄 PDF creati:"
    find "$PDF_DIR" -name "*.pdf" -type f -exec ls -lh {} \; | \
        head -5 | awk '{print "   " $9 " (" $5 ")"}'
    [[ $success -gt 5 ]] && echo "   ... e altri $((success - 5)) file"
    echo "📊 Dimensione totale: $(du -sh "$PDF_DIR" | cut -f1)"
fi

# Cleanup
echo "🧹 Pulizia file temporanei..."
rm -f wget.log urls.txt

echo "🎉 Script completato!"

# Suggerimenti finali
if [[ $failed -gt 0 ]]; then
    echo
    echo "💡 Suggerimenti per migliorare i risultati:"
    echo "   • Alcuni siti bloccano il crawling automatico"
    echo "   • Prova con profondità minore: $0 $SITO 1 $MAX_CONCURRENT"
    echo "   • Controlla $FAILED_LOG per dettagli sui fallimenti"
fi