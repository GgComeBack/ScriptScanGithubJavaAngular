#!/bin/bash

# Script pour récupérer la liste des repositories GitHub avec leur branche principale
# et télécharger les fichiers pom.xml et package-lock.json et extraire des informations specifiques
# Usage: ./github_scan_java_angular.sh '' lombok,spring-data-r2dbc-dsl

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET="${1:-}"
OUTPUT_DIR="./github_files"
LIBRARIES="${2:-}"

# Vérification des paramètres
if [ -z "$TARGET" ] && [ -z "$GITHUB_TOKEN" ]; then
    echo "Usage: $0 <username|organization> [libraries]"
    echo "   OU: Exportez GITHUB_TOKEN pour lister vos propres repos"
    echo "Exemple: $0 torvalds"
    echo "Exemple: $0 torvalds lombok,jackson-databind,junit"
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

# Fonction optimisée pour extraire des informations du pom.xml
# Utilise un seul passage avec awk pour extraire toutes les informations nécessaires
parse_pom() {
    local pom_file=$1
    local repo_name=$2
    local default_branch=$3

    if [ ! -f "$pom_file" ]; then
        return
    fi

    # Préparer la liste des librairies à rechercher
    local lib_search=""
    if [ -n "$LIBRARIES" ]; then
        IFS=',' read -ra LIB_ARRAY <<< "$LIBRARIES"
        for lib in "${LIB_ARRAY[@]}"; do
            lib_trimmed=$(echo "$lib" | xargs)
            lib_search="${lib_search}${lib_trimmed}|"
        done
        lib_search="${lib_search%|}"  # Supprimer le dernier |
    fi

    # Un seul passage AWK pour tout extraire
    local result=$(awk -v libs="$lib_search" '
    BEGIN {
        java_version = "N/A"
        springboot_version = "N/A"
        in_parent = 0
        in_dependency = 0
        current_artifactId = ""
        split(libs, lib_array, "|")
        for (i in lib_array) {
            lib_versions[lib_array[i]] = "N/A"
            lib_search_dash[lib_array[i]] = lib_array[i]
            gsub(/-/, ".", lib_search_dash[lib_array[i]])
        }
    }

    # Extraction Java version
    /<java\.version>/ {
        match($0, /<java\.version>([^<]+)/, arr)
        if (arr[1] != "") java_version = arr[1]
    }
    /<maven\.compiler\.source>/ {
        if (java_version == "N/A") {
            match($0, /<maven\.compiler\.source>([^<]+)/, arr)
            if (arr[1] != "") java_version = arr[1]
        }
    }
    /<maven\.compiler\.target>/ {
        if (java_version == "N/A") {
            match($0, /<maven\.compiler\.target>([^<]+)/, arr)
            if (arr[1] != "") java_version = arr[1]
        }
    }

    # Extraction Spring Boot version
    /<parent>/ { in_parent = 1 }
    /<\/parent>/ { in_parent = 0 }

    in_parent && /<artifactId>spring-boot-starter-parent<\/artifactId>/ {
        getline
        while (getline && !/<\/parent>/) {
            if (match($0, /<version>([^<]+)/, arr)) {
                springboot_version = arr[1]
                break
            }
        }
    }

    # Spring Boot dans properties
    /<spring-boot\.version>/ {
        if (springboot_version == "N/A") {
            match($0, /<spring-boot\.version>([^<]+)/, arr)
            if (arr[1] != "") springboot_version = arr[1]
        }
    }
    /<spring\.boot\.version>/ {
        if (springboot_version == "N/A") {
            match($0, /<spring\.boot\.version>([^<]+)/, arr)
            if (arr[1] != "") springboot_version = arr[1]
        }
    }
    /<springboot\.version>/ {
        if (springboot_version == "N/A") {
            match($0, /<springboot\.version>([^<]+)/, arr)
            if (arr[1] != "") springboot_version = arr[1]
        }
    }

    # Extraction des versions de librairies
    /<dependency>/ { in_dependency = 1; current_artifactId = ""; dep_version = "" }
    /<\/dependency>/ {
        if (in_dependency && current_artifactId != "" && dep_version != "") {
            for (lib in lib_versions) {
                if (current_artifactId == lib) {
                    # Résoudre les propriétés ${...}
                    if (match(dep_version, /\$\{([^}]+)\}/, prop_arr)) {
                        lib_versions[lib] = "PROP:" prop_arr[1]
                    } else {
                        lib_versions[lib] = dep_version
                    }
                }
            }
        }
        in_dependency = 0
    }

    in_dependency && /<artifactId>/ {
        match($0, /<artifactId>([^<]+)/, arr)
        current_artifactId = arr[1]
    }

    in_dependency && /<version>/ {
        match($0, /<version>([^<]+)/, arr)
        dep_version = arr[1]
    }

    # Extraction des versions depuis properties
    {
        for (lib in lib_versions) {
            # Recherche avec tirets
            pattern = "<" lib "\\.version>"
            if (match($0, pattern)) {
                match($0, pattern "([^<]+)", arr)
                if (arr[1] != "" && lib_versions[lib] == "N/A") {
                    lib_versions[lib] = arr[1]
                }
            }
            # Recherche avec points
            pattern_dash = "<" lib_search_dash[lib] "\\.version>"
            if (match($0, pattern_dash)) {
                match($0, pattern_dash "([^<]+)", arr)
                if (arr[1] != "" && lib_versions[lib] == "N/A") {
                    lib_versions[lib] = arr[1]
                }
            }
        }
    }

    END {
        print "JAVA:" java_version
        print "SPRINGBOOT:" springboot_version
        for (lib in lib_versions) {
            print "LIB:" lib ":" lib_versions[lib]
        }
    }
    ' "$pom_file")

    # Résolution des propriétés référencées
    local java_version=$(echo "$result" | grep "^JAVA:" | cut -d: -f2)
    local springboot_version=$(echo "$result" | grep "^SPRINGBOOT:" | cut -d: -f2)

    # Construction de la ligne de résumé
    local summary_line="$repo_name | branch : $default_branch | Java: $java_version | Spring Boot: $springboot_version"

    # Ajout des versions de librairies
    if [ -n "$LIBRARIES" ]; then
        while IFS= read -r line; do
            if [[ $line == LIB:* ]]; then
                local lib_name=$(echo "$line" | cut -d: -f2)
                local lib_version=$(echo "$line" | cut -d: -f3-)

                # Résoudre les propriétés si nécessaire
                if [[ $lib_version == PROP:* ]]; then
                    local prop_name=${lib_version#PROP:}
                    lib_version=$(grep -oP "(?<=<$prop_name>)[^<]+" "$pom_file" 2>/dev/null || echo "N/A")
                fi

                summary_line="$summary_line | $lib_name: $lib_version"
            fi
        done <<< "$result"
    fi

    echo "$summary_line"
}

# Fonction optimisée pour extraire des informations du package-lock.json
# Utilise un seul appel jq pour extraire toutes les informations
parse_package_lock() {
    local package_file=$1
    local repo_name=$2
    local default_branch=$3

    if [ ! -f "$package_file" ]; then
        return
    fi

    # Préparer le filtre jq pour les librairies personnalisées
    local lib_filter=""
    if [ -n "$LIBRARIES" ]; then
        IFS=',' read -ra LIB_ARRAY <<< "$LIBRARIES"
        for lib in "${LIB_ARRAY[@]}"; do
            lib_trimmed=$(echo "$lib" | xargs)
            lib_filter="${lib_filter}, \"${lib_trimmed}\": (.dependencies.\"${lib_trimmed}\".version // .packages.\"node_modules/${lib_trimmed}\".version // \"N/A\")"
        done
    fi

    # Un seul appel jq pour tout extraire
    local result=$(jq -r "{
        angular: (.dependencies.\"@angular/core\".version // .packages.\"node_modules/@angular/core\".version // \"N/A\"),
        vue: (.dependencies.vue.version // .packages.\"node_modules/vue\".version // \"N/A\"),
        react: (.dependencies.react.version // .packages.\"node_modules/react\".version // \"N/A\")${lib_filter}
    } | to_entries | map(\"\(.key):\(.value)\") | join(\"|\")" "$package_file" 2>/dev/null)

    if [ -z "$result" ]; then
        return
    fi

    # Construction de la ligne de résumé
    local summary_line="$repo_name | branch : $default_branch"

    IFS='|' read -ra VERSIONS <<< "$result"
    for version_pair in "${VERSIONS[@]}"; do
        IFS=':' read -r key value <<< "$version_pair"
        # Capitaliser la première lettre
        key_display=$(echo "$key" | sed 's/^\(.\)/\U\1/')
        summary_line="$summary_line | $key_display: $value"
    done

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

# Fonction pour récupérer les repos
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
    echo ""

    while [ "$has_more" = true ]; do
        # Requête API GitHub
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
            # Extraction et traitement de chaque repository
            echo "$response" | jq -r '.[] | "\(.full_name)|\(.default_branch)"' | while IFS='|' read -r repo default_branch; do

                # Affichage
                printf "%-50s → %s\n" "$repo" "$default_branch"

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

                # Écriture de la ligne complète dans le summary
                if [ -n "$pom_summary" ]; then
                    echo "$pom_summary" >> "$SUMMARY_FILE"
                fi
                if [ -n "$pom_summary_app" ]; then
                    echo "$pom_summary_app" >> "$SUMMARY_FILE"
                fi
                if [ -n "$package_summary" ]; then
                    echo "$package_summary" >> "$SUMMARY_FILE"
                fi

                # Nettoyage : suppression du répertoire du repo après traitement
                if [ -d "$OUTPUT_DIR/$repo_safe" ]; then
                    rm -rf "$OUTPUT_DIR/$repo_safe"
                    echo "  🗑️  Fichiers nettoyés"
                fi

                echo ""
            done

            page=$((page + 1))
        fi
    done

    echo ""
    echo "✅ Récupération terminée"
    echo "📊 Résumé global des versions: $SUMMARY_FILE"
    echo "🗑️  Fichiers temporaires supprimés"
}

# Exécution
get_repos