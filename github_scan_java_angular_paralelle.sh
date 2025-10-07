#!/bin/bash

# Script pour récupérer la liste des repositories GitHub avec leur branche principale
# et télécharger les fichiers pom.xml et package-lock.json en PARALLÈLE
# Usage: ./github_scan_java_angular.sh [username|organization] [libraries] [max_jobs]

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET="${1:-}"
OUTPUT_DIR="./github_files"
LIBRARIES="${2:-}"
MAX_PARALLEL_JOBS="${3:-10}"  # Nombre de repos à traiter en parallèle

# Vérification des paramètres
if [ -z "$TARGET" ] && [ -z "$GITHUB_TOKEN" ]; then
    echo "Usage: $0 <username|organization> [libraries] [max_jobs]"
    echo "   OU: Exportez GITHUB_TOKEN pour lister vos propres repos"
    echo "Exemple: $0 torvalds"
    echo "Exemple: $0 torvalds lombok,jackson-databind,junit 10"
    echo "Exemple: export GITHUB_TOKEN='ghp_xxx' && $0 '' lombok"
    exit 1
fi

# Vérification de jq
if ! command -v jq &> /dev/null; then
    echo "❌ Erreur: jq n'est pas installé."
    echo "   Installation: sudo apt-get install jq  (Debian/Ubuntu)"
    echo "                 brew install jq          (macOS)"
    exit 1
fi

# Configuration des headers pour l'API
if [ -n "$GITHUB_TOKEN" ]; then
    AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
else
    AUTH_HEADER=""
    echo "⚠️  Pas de token GitHub détecté. Limite de 60 requêtes/heure."
    echo "   Pour augmenter la limite, exportez GITHUB_TOKEN avec votre token."
    echo ""
fi

# Création du répertoire de sortie
mkdir -p "$OUTPUT_DIR"
TEMP_DIR="$OUTPUT_DIR/temp_$$"
mkdir -p "$TEMP_DIR"

# Initialisation du fichier de résumé global
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
echo "=== Résumé des repositories GitHub ===" > "$SUMMARY_FILE"
echo "Date: $(date)" >> "$SUMMARY_FILE"
if [ -n "$TARGET" ]; then
    echo "Cible: $TARGET" >> "$SUMMARY_FILE"
else
    echo "Cible: Utilisateur authentifié" >> "$SUMMARY_FILE"
fi
echo "" >> "$SUMMARY_FILE"

# Fonction pour extraire des informations du pom.xml
parse_pom() {
    local pom_file=$1
    local repo_name=$2
    local default_branch=$3

    if [ ! -f "$pom_file" ]; then
        return
    fi

    # Extraction de la version Java
    java_version=$(grep -oP '(?<=<java\.version>)[^<]+' "$pom_file" 2>/dev/null || \
                   grep -oP '(?<=<maven\.compiler\.source>)[^<]+' "$pom_file" 2>/dev/null || \
                   grep -oP '(?<=<maven\.compiler\.target>)[^<]+' "$pom_file" 2>/dev/null || \
                   echo "N/A")

    # Extraction de la version Spring Boot - méthode améliorée
    springboot_version=""
    if [ $(sed -n '/<parent>/,/<\/parent>/p' "$pom_file" | grep -c '<artifactId>spring-boot-starter-parent</artifactId>') -gt 0 ]; then
        springboot_version=$(sed -n '/<parent>/,/<\/parent>/p' "$pom_file" | grep -oP '(?<=<version>)[^<]+' | head -1 2>/dev/null)
    fi

    # Si pas trouvé, chercher dans les properties
    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version=$(grep -oP '(?<=<spring-boot.version>)[^<]+' "$pom_file" 2>/dev/null)
    fi
    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version=$(grep -oP '(?<=<spring.boot.version>)[^<]+' "$pom_file" 2>/dev/null)
    fi
    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version=$(grep -oP '(?<=<springboot.version>)[^<]+' "$pom_file" 2>/dev/null)
    fi

    # Chercher dans les dépendances spring-boot-starter
    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version=$(sed -n '/<artifactId>spring-boot-starter/,/<\/dependency>/p' "$pom_file" | grep -oP '(?<=<version>)[^<]+' | head -1 2>/dev/null)
    fi

    # Chercher spring-boot-dependencies
    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version=$(sed -n '/<artifactId>spring-boot-dependencies/,/<\/dependency>/p' "$pom_file" | grep -oP '(?<=<version>)[^<]+' | head -1 2>/dev/null)
    fi

    if [ -z "$springboot_version" ] || [ "$springboot_version" = "" ]; then
        springboot_version="N/A"
    fi

    # Construction de la ligne de résumé
    local summary_line="$repo_name | branch : $default_branch | Java: $java_version | Spring Boot: $springboot_version"

    # Recherche des librairies Maven spécifiques
    if [ -n "$LIBRARIES" ]; then
        IFS=',' read -ra LIB_ARRAY <<< "$LIBRARIES"
        for lib in "${LIB_ARRAY[@]}"; do
            lib_trimmed=$(echo "$lib" | xargs)

            # chercher dans les properties
            lib_version=$(grep -oP "(?<=<$lib_trimmed\.version>)[^<]+" "$pom_file" 2>/dev/null)
            if [ -z "$lib_version" ] || [ "$lib_version" = "" ]; then
                lib_trimmed_replace_dash="${lib_trimmed//-/.}"
                lib_version=$(grep -oP "(?<=<$lib_trimmed_replace_dash\.version>)[^<]+" "$pom_file" 2>/dev/null)
            fi

            # Chercher la version de la librairie dans les dependences
            if [ -z "$lib_version" ] || [ "$lib_version" = "" ]; then
                lib_trimmed_protected=$(echo "$lib" | xargs | sed 's/\//\\\//g')
                property=$(cat "$pom_file" | awk "/<artifactId>$lib_trimmed_protected<\/artifactId>/,/<\/dependency>/"' {if($0 ~ /<version>/) {match($0, /\$\{([^}]+)\}/, a); print a[1]}}')
                if [[ "$property" =~ ^[a-zA-Z.-]+$ ]]; then
                    lib_version=$(cat "$pom_file" | awk -v prop="$property" "/<$property>/ {gsub(/.*<$property>|<\/$property>.*/,\"\"); print}")
                else
                    lib_version="$property"
                fi
            fi

            if [ -n "$lib_version" ] && [ "$lib_version" != "" ]; then
                summary_line="$summary_line | $lib_trimmed: $lib_version"
            else
                summary_line="$summary_line | $lib_trimmed: N/A"
            fi
        done
    fi

    echo "$summary_line"
}

# Fonction pour extraire des informations du package-lock.json
parse_package_lock() {
    local package_file=$1
    local repo_name=$2
    local default_branch=$3

    if [ ! -f "$package_file" ]; then
        return
    fi

    local summary_line="$repo_name | branch : $default_branch"

    # Extraction de la version Angular
    angular_version=$(jq -r '.dependencies."@angular/core".version // .packages."node_modules/@angular/core".version // "N/A"' "$package_file" 2>/dev/null)
    summary_line="$summary_line | Angular: $angular_version"

    # Extraction de la version Vue
    vue_version=$(jq -r '.dependencies.vue.version // .packages."node_modules/vue".version // "N/A"' "$package_file" 2>/dev/null)
    summary_line="$summary_line | Vue: $vue_version"

    # Extraction de la version React
    react_version=$(jq -r '.dependencies.react.version // .packages."node_modules/react".version // "N/A"' "$package_file" 2>/dev/null)
    summary_line="$summary_line | React: $react_version"

    # Recherche des librairies NPM spécifiques
    if [ -n "$LIBRARIES" ]; then
        IFS=',' read -ra LIB_ARRAY <<< "$LIBRARIES"
        for lib in "${LIB_ARRAY[@]}"; do
            lib_trimmed=$(echo "$lib" | xargs)

            # Chercher dans dependencies ou packages
            lib_version=$(jq -r ".dependencies.\"$lib_trimmed\".version // .packages.\"node_modules/$lib_trimmed\".version // \"N/A\"" "$package_file" 2>/dev/null)

            if [ -n "$lib_version" ] && [ "$lib_version" != "N/A" ]; then
                summary_line="$summary_line | $lib_trimmed: $lib_version"
            else
                summary_line="$summary_line | $lib_trimmed: N/A"
            fi
        done
    fi

    echo "$summary_line"
}

# Fonction pour télécharger un fichier depuis GitHub
download_file() {
    local repo=$1
    local branch=$2
    local file_path=$3
    local output_subdir=$4

    local url="https://raw.githubusercontent.com/$repo/$branch/$file_path"
    local output_file="$OUTPUT_DIR/$output_subdir/$(basename $file_path)"

    # Création du sous-répertoire
    mkdir -p "$OUTPUT_DIR/$output_subdir"

    # Téléchargement du fichier
    if [ -n "$GITHUB_TOKEN" ]; then
        http_code=$(curl -s -w "%{http_code}" -o "$output_file" -H "Authorization: Bearer $GITHUB_TOKEN" "$url")
    else
        http_code=$(curl -s -w "%{http_code}" -o "$output_file" "$url")
    fi

    if [ "$http_code" = "200" ]; then
        echo "  ✓ Téléchargé: $file_path"
        return 0
    else
        rm -f "$output_file"
        return 1
    fi
}

# Fonction pour traiter un repository (sera exécutée en parallèle)
process_repository() {
    local repo=$1
    local default_branch=$2
    local temp_output="$TEMP_DIR/${repo//\//_}.txt"

    {
        # Affichage
        #printf "%-50s → %s\n" "$repo" "$default_branch"

        # Création d'un répertoire pour ce repo
        repo_safe=$(echo "$repo" | tr '/' '_')

        # Tentative de téléchargement des fichiers
        echo "  Recherche des fichiers..."

        # Variables pour stocker les résumés
        pom_summary=""
        package_summary=""
        pom_summary_app=""

        # pom.xml à la racine
        if download_file "$repo" "$default_branch" "pom.xml" "$repo_safe"; then
            echo "  📋 Analyse du pom.xml..."
            pom_summary=$(parse_pom "$OUTPUT_DIR/$repo_safe/pom.xml" "$repo | base " "$default_branch")
        fi

        # pom.xml dans le répertoire app
        if download_file "$repo" "$default_branch" "app/pom.xml" "$repo_safe"; then
            # Renommer pour éviter l'écrasement
            mv "$OUTPUT_DIR/$repo_safe/pom.xml" "$OUTPUT_DIR/$repo_safe/app_pom.xml" 2>/dev/null
            echo "  📋 Analyse du app/pom.xml..."
            pom_summary_app=$(parse_pom "$OUTPUT_DIR/$repo_safe/app_pom.xml" "$repo | app " "$default_branch")
        fi

        # package-lock.json à la racine
        if download_file "$repo" "$default_branch" "package-lock.json" "$repo_safe"; then
            echo "  📋 Analyse du package-lock.json..."
            package_summary=$(parse_package_lock "$OUTPUT_DIR/$repo_safe/package-lock.json" "$repo" "$default_branch")
        fi

        # Écriture dans un fichier temporaire
        if [ -n "$pom_summary" ]; then
            echo "$pom_summary" >> "$temp_output"
        fi
        if [ -n "$pom_summary_app" ]; then
            echo "$pom_summary_app" >> "$temp_output"
        fi
        if [ -n "$package_summary" ]; then
            echo "$repo | $package_summary" >> "$temp_output"
        fi

        # Nettoyage : suppression du répertoire du repo après traitement
        if [ -d "$OUTPUT_DIR/$repo_safe" ]; then
            rm -rf "$OUTPUT_DIR/$repo_safe"
            echo "  🗑️  Fichiers nettoyés"
        fi

        echo ""
    } 2>&1
}

# Export des fonctions pour les rendre disponibles dans les sous-shells
export -f process_repository
export -f download_file
export -f parse_pom
export -f parse_package_lock
export OUTPUT_DIR
export TEMP_DIR
export GITHUB_TOKEN
export AUTH_HEADER
export LIBRARIES

# Fonction pour récupérer les repos et les traiter en parallèle
get_repos() {
    local page=1
    local per_page=100
    local has_more=true

    # Détermination de l'URL API selon le contexte
    if [ -n "$GITHUB_TOKEN" ] && [ -z "$TARGET" ]; then
        base_url="https://api.github.com/user/repos"
        echo "📦 Récupération de vos repositories (utilisateur authentifié)"
    elif [ -n "$TARGET" ]; then
        base_url="https://api.github.com/users/$TARGET/repos"
        echo "📦 Récupération des repositories pour: $TARGET"
    else
        echo "❌ Erreur: TARGET requis sans token"
        exit 1
    fi

    echo "================================================"
    echo "Traitement en parallèle (max $MAX_PARALLEL_JOBS jobs simultanés)"
    echo "================================================"
    echo ""

    # Fichier pour stocker la liste de tous les repos
    local all_repos_file="$TEMP_DIR/all_repos.csv"
    > "$all_repos_file"

    # Récupération de tous les repos
    while [ "$has_more" = true ]; do
        if [ -n "$AUTH_HEADER" ]; then
            response=$(curl -s -H "$AUTH_HEADER" \
                "${base_url}?per_page=$per_page&page=$page&sort=updated")
        else
            response=$(curl -s \
                "${base_url}?per_page=$per_page&page=$page&sort=updated")
        fi

        # Vérification des erreurs
        if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
            error_msg=$(echo "$response" | jq -r '.message')
            echo "❌ Erreur API: $error_msg"
            exit 1
        fi

        # Vérification si le tableau est vide
        repo_count=$(echo "$response" | jq 'length')

        if [ "$repo_count" -eq 0 ]; then
            has_more=false
        else
            # Extraction et stockage de chaque repository
            echo "$response" | jq -r '.[] | "\(.full_name)|\(.default_branch)"' >> "$all_repos_file"
            page=$((page + 1))
        fi
    done

    local total_repos=$(wc -l < "$all_repos_file")
    echo "✅ $total_repos repositories récupérés"
    echo ""
    echo "🚀 Début du traitement parallèle..."
    echo ""

    # Traitement en parallèle avec GNU parallel si disponible
    if command -v parallel &> /dev/null; then
        echo "ℹ️  Utilisation de GNU parallel"
        cat "$all_repos_file" | parallel -j "$MAX_PARALLEL_JOBS" --colsep '|' process_repository {1} {2}
    else
        # Fallback: traitement avec jobs bash
        echo "ℹ️  Utilisation de jobs bash (installez 'parallel' pour de meilleures performances)"

        while IFS='|' read -r repo default_branch; do
            # Attendre qu'il y ait moins de MAX_PARALLEL_JOBS processus
            while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
                sleep 0.1
            done

            # Lancer le traitement en arrière-plan
            process_repository "$repo" "$default_branch" &
        done < "$all_repos_file"

        # Attendre que tous les jobs se terminent
        wait
    fi

    echo ""
    echo "✅ Traitement parallèle terminé"
    echo ""

    # Consolidation des résultats
    echo "📝 Consolidation des résultats..."
    for temp_file in "$TEMP_DIR"/*.txt; do
        if [ -f "$temp_file" ]; then
            cat "$temp_file" >> "$SUMMARY_FILE"
        fi
    done

    # Nettoyage du répertoire temporaire
    rm -rf "$TEMP_DIR"

    echo ""
    echo "✅ Récupération terminée"
    echo "📊 Résumé global des versions: $SUMMARY_FILE"
    echo "🗑️  Fichiers temporaires supprimés"
}

# Exécution
get_repos