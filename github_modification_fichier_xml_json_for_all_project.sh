#!/bin/bash

# Script pour détecter les repositories contenant certains fichiers
# et créer des Pull Requests automatiquement en parallèle
# Usage: ./github_modification_fichier_xml_json_for_all_project.sh <config_template.json>

set -e

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CONFIG_TEMPLATE="${1:-}"
TEMP_DIR="./github_modification_fichier_xml_json_for_all_project_$(date +%s)"
MAX_PARALLEL_JOBS=5  # Nombre maximum de PR en parallèle
PR_SCRIPT="./github_modification_fichier_xml_json.sh"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Fonctions d'affichage
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_repo() { echo -e "${MAGENTA}📦 $1${NC}"; }
log_file() { echo -e "${CYAN}📄 $1${NC}"; }

# Vérification des prérequis
check_requirements() {
    local missing_tools=()

    for tool in jq curl git; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Outils manquants: ${missing_tools[*]}"
        echo "Installation: sudo apt-get install ${missing_tools[*]} (Ubuntu/Debian)"
        echo "              brew install ${missing_tools[*]} (macOS)"
        exit 1
    fi

    if [ ! -f "$PR_SCRIPT" ]; then
        log_error "Script github_pr_modifier.sh introuvable"
        echo "Assurez-vous que le script est dans le même répertoire"
        exit 1
    fi

    if [ ! -x "$PR_SCRIPT" ]; then
        chmod +x "$PR_SCRIPT"
        log_info "Permissions d'exécution ajoutées à $PR_SCRIPT"
    fi
}

# Vérification des paramètres
check_parameters() {
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN non défini"
        echo "Exportez votre token: export GITHUB_TOKEN='ghp_xxx'"
        exit 1
    fi

    if [ -z "$CONFIG_TEMPLATE" ] || [ ! -f "$CONFIG_TEMPLATE" ]; then
        log_error "Fichier de configuration template manquant"
        echo ""
        echo "Usage: $0 <config_template.json>"
        echo ""
        echo "Format du fichier de configuration template:"
        cat << 'EOF'
{
  "target_files": [
    "pom.xml",
    "app/pom.xml",
    "package.json",
    "config/settings.xml"
  ],
  "new_branch_prefix": "feature/auto-update",
  "pr_title": "🤖 Mise à jour automatique de la configuration",
  "pr_body": "Cette PR met à jour automatiquement les fichiers de configuration.\n\n**Modifications appliquées:**\n- Mise à jour de la version\n- Ajout de nouvelles propriétés",
  "filters": {
    "exclude_repos": ["test-repo", "archived-project"],
    "include_only": [],
    "exclude_archived": true,
    "exclude_forks": true
  },
  "modifications": [
    {
      "file_path": "pom.xml",
      "type": "xml",
      "action": "update",
      "xpath": "//project/properties/spring-boot.version",
      "value": "3.2.0"
    },
    {
      "file_path": "package.json",
      "type": "json",
      "action": "update",
      "jq_path": ".engines.node",
      "value": ">=18.0.0"
    }
  ]
}
EOF
        exit 1
    fi
}

# Lecture de la configuration template
read_config_template() {
    log_info "Lecture de la configuration template"

    TARGET_FILES=($(jq -r '.target_files[]' "$CONFIG_TEMPLATE"))
    NEW_BRANCH_PREFIX=$(jq -r '.new_branch_prefix // "feature/auto-update"' "$CONFIG_TEMPLATE")
    PR_TITLE=$(jq -r '.pr_title' "$CONFIG_TEMPLATE")
    PR_BODY=$(jq -r '.pr_body' "$CONFIG_TEMPLATE")

    # Filtres
    EXCLUDE_ARCHIVED=$(jq -r '.filters.exclude_archived // true' "$CONFIG_TEMPLATE")
    EXCLUDE_FORKS=$(jq -r '.filters.exclude_forks // true' "$CONFIG_TEMPLATE")
    EXCLUDE_REPOS=($(jq -r '.filters.exclude_repos[]? // empty' "$CONFIG_TEMPLATE"))
    INCLUDE_ONLY=($(jq -r '.filters.include_only[]? // empty' "$CONFIG_TEMPLATE"))

    log_success "Configuration chargée"
    log_info "Fichiers cibles: ${TARGET_FILES[*]}"
    echo ""
}

# Récupération de tous les repositories
get_all_repositories() {
    log_info "Récupération de tous vos repositories..."

    local page=1
    local per_page=100
    local all_repos="[]"

    while true; do
        local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
            "https://api.github.com/user/repos?per_page=$per_page&page=$page&sort=updated&affiliation=owner,collaborator,organization_member")

        # Vérification des erreurs
        if echo "$response" | jq -e '.message' > /dev/null 2>&1; then
            local error_msg=$(echo "$response" | jq -r '.message')
            log_error "Erreur API: $error_msg"
            exit 1
        fi

        local repo_count=$(echo "$response" | jq 'length')

        if [ "$repo_count" -eq 0 ]; then
            break
        fi

        all_repos=$(jq -s '.[0] + .[1]' <(echo "$all_repos") <(echo "$response"))
        page=$((page + 1))
    done

    # Application des filtres
    local filtered_repos="$all_repos"

    if [ "$EXCLUDE_ARCHIVED" = "true" ]; then
        filtered_repos=$(echo "$filtered_repos" | jq '[.[] | select(.archived == false)]')
    fi

    if [ "$EXCLUDE_FORKS" = "true" ]; then
        filtered_repos=$(echo "$filtered_repos" | jq '[.[] | select(.fork == false)]')
    fi

    # Filtre exclude_repos
    if [ ${#EXCLUDE_REPOS[@]} -gt 0 ]; then
        for exclude in "${EXCLUDE_REPOS[@]}"; do
            filtered_repos=$(echo "$filtered_repos" | jq --arg name "$exclude" '[.[] | select(.name != $name)]')
        done
    fi

    # Filtre include_only (si spécifié, garde uniquement ces repos)
    if [ ${#INCLUDE_ONLY[@]} -gt 0 ]; then
        local include_filter=$(printf '"%s",' "${INCLUDE_ONLY[@]}" | sed 's/,$//')
        filtered_repos=$(echo "$filtered_repos" | jq "[.[] | select(.name | IN($include_filter))]")
    fi

    echo "$filtered_repos"
}

# Vérification si un fichier existe dans un repository
check_file_exists() {
    local repo_full_name=$1
    local branch=$2
    local file_path=$3

    local url="https://api.github.com/repos/${repo_full_name}/contents/${file_path}?ref=${branch}"
    local response=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" "$url")

    if echo "$response" | jq -e '.type' > /dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Détection des fichiers dans les repositories
detect_files_in_repos() {
    local repos_json=$1
    local repo_count=$(echo "$repos_json" | jq 'length')

    log_info "Analyse de $repo_count repositories..."
    echo ""

    local detected_repos="[]"
    local repo_index=0

    echo "$repos_json" | jq -c '.[]' | while read -r repo; do
        repo_index=$((repo_index + 1))
        local repo_name=$(echo "$repo" | jq -r '.name')
        local repo_full_name=$(echo "$repo" | jq -r '.full_name')
        local default_branch=$(echo "$repo" | jq -r '.default_branch')

        printf "[%3d/%3d] " "$repo_index" "$repo_count"
        log_repo "$repo_full_name"

        local found_files=()

        for file in "${TARGET_FILES[@]}"; do
            local exists=$(check_file_exists "$repo_full_name" "$default_branch" "$file")

            if [ "$exists" = "true" ]; then
                found_files+=("$file")
                log_file "  ✓ Trouvé: $file"
            fi
        done

        if [ ${#found_files[@]} -gt 0 ]; then
            local files_json=$(printf '%s\n' "${found_files[@]}" | jq -R . | jq -s .)
            local repo_info=$(echo "$repo" | jq --argjson files "$files_json" '. + {found_files: $files}')
            echo "$repo_info" >> "$TEMP_DIR/detected_repos.jsonl"
            log_success "  → ${#found_files[@]} fichier(s) détecté(s)"
        else
            echo "  ℹ️  Aucun fichier cible trouvé"
        fi

        echo ""

        # Petite pause pour éviter le rate limiting
        sleep 0.5
    done

    if [ -f "$TEMP_DIR/detected_repos.jsonl" ]; then
        jq -s '.' "$TEMP_DIR/detected_repos.jsonl"
    else
        echo "[]"
    fi
}

# Génération d'une configuration spécifique pour un repository
generate_repo_config() {
    local repo_full_name=$1
    local default_branch=$2
    local found_files=$3
    local output_file=$4

    # Générer un nom de branche unique avec timestamp
    local branch_name="${NEW_BRANCH_PREFIX}-$(date +%Y%m%d-%H%M%S)"

    # Filtrer les modifications pour ne garder que celles correspondant aux fichiers trouvés
    local filtered_modifications=$(jq -c --argjson files "$found_files" '
        .modifications | map(select(.file_path as $fp | $files | index($fp)))
    ' "$CONFIG_TEMPLATE")

    # Créer la configuration spécifique
    jq -n \
        --arg repo "$repo_full_name" \
        --arg base "$default_branch" \
        --arg branch "$branch_name" \
        --arg title "$PR_TITLE" \
        --arg body "$PR_BODY" \
        --argjson mods "$filtered_modifications" \
        '{
            repository: $repo,
            base_branch: $base,
            new_branch: $branch,
            pr_title: $title,
            pr_body: $body,
            modifications: $mods
        }' > "$output_file"
}

# Création d'une PR pour un repository (fonction pour exécution parallèle)
create_pr_for_repo() {
    local repo_full_name=$1
    local config_file=$2
    local log_file="${TEMP_DIR}/logs/${repo_full_name//\//_}.log"

    mkdir -p "$(dirname "$log_file")"

    {
        echo "================================================"
        echo "Repository: $repo_full_name"
        echo "Date: $(date)"
        echo "================================================"
        echo ""

        # Exécution du script PR avec la configuration spécifique
        if bash "$PR_SCRIPT" "$config_file" 2>&1; then
            echo ""
            echo "✅ PR créée avec succès pour $repo_full_name"
            echo "$repo_full_name" >> "$TEMP_DIR/success.txt"
        else
            echo ""
            echo "❌ Échec de la création de PR pour $repo_full_name"
            echo "$repo_full_name" >> "$TEMP_DIR/failed.txt"
        fi
    } > "$log_file" 2>&1
}

# Création des PR en parallèle
create_pull_requests() {
    local detected_repos=$1
    local repo_count=$(echo "$detected_repos" | jq 'length')

    if [ "$repo_count" -eq 0 ]; then
        log_warning "Aucun repository avec les fichiers cibles trouvés"
        return
    fi

    log_info "Création de PR pour $repo_count repository(ies)..."
    echo ""

    mkdir -p "$TEMP_DIR/configs"
    mkdir -p "$TEMP_DIR/logs"

    # Génération des configurations
    local config_files=()
    echo "$detected_repos" | jq -c '.[]' | while read -r repo; do
        local repo_full_name=$(echo "$repo" | jq -r '.full_name')
        local default_branch=$(echo "$repo" | jq -r '.default_branch')
        local found_files=$(echo "$repo" | jq -c '.found_files')

        local config_file="$TEMP_DIR/configs/${repo_full_name//\//_}.json"
        generate_repo_config "$repo_full_name" "$default_branch" "$found_files" "$config_file"

        echo "$config_file|$repo_full_name" >> "$TEMP_DIR/config_list.txt"
    done

    # Initialisation des fichiers de suivi
    touch "$TEMP_DIR/success.txt"
    touch "$TEMP_DIR/failed.txt"

    # Lancement des PR en parallèle
    log_info "Lancement de $MAX_PARALLEL_JOBS processus en parallèle..."
    echo ""

    cat "$TEMP_DIR/config_list.txt" | while IFS='|' read -r config_file repo_full_name; do
        # Attendre qu'il y ait moins de MAX_PARALLEL_JOBS processus
        while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_JOBS ]; do
            sleep 1
        done

        log_info "🚀 Lancement PR pour: $repo_full_name"
        create_pr_for_repo "$repo_full_name" "$config_file" &
    done

    # Attendre que tous les jobs se terminent
    log_info "Attente de la fin de tous les processus..."
    wait

    echo ""
    log_success "Toutes les PR ont été traitées"
}

# Affichage du rapport final
display_report() {
    echo ""
    echo "================================================"
    echo "          RAPPORT FINAL"
    echo "================================================"
    echo ""

    local success_count=0
    local failed_count=0

    if [ -f "$TEMP_DIR/success.txt" ]; then
        success_count=$(grep -c . "$TEMP_DIR/success.txt" 2>/dev/null || echo 0)
    fi

    if [ -f "$TEMP_DIR/failed.txt" ]; then
        failed_count=$(grep -c . "$TEMP_DIR/failed.txt" 2>/dev/null || echo 0)
    fi

    log_success "PR créées avec succès: $success_count"
    if [ $success_count -gt 0 ]; then
        echo ""
        cat "$TEMP_DIR/success.txt" | while read -r repo; do
            echo "  ✓ $repo"
        done
    fi

    echo ""
    log_error "PR échouées: $failed_count"
    if [ $failed_count -gt 0 ]; then
        echo ""
        cat "$TEMP_DIR/failed.txt" | while read -r repo; do
            echo "  ✗ $repo"
        done
    fi

    echo ""
    log_info "Logs détaillés disponibles dans: $TEMP_DIR/logs/"
    echo ""

    # Afficher les logs des échecs
    if [ $failed_count -gt 0 ]; then
        echo "================================================"
        echo "          DÉTAILS DES ÉCHECS"
        echo "================================================"
        echo ""

        cat "$TEMP_DIR/failed.txt" | while read -r repo; do
            local log_file="$TEMP_DIR/logs/${repo//\//_}.log"
            if [ -f "$log_file" ]; then
                echo "--- $repo ---"
                tail -n 20 "$log_file"
                echo ""
            fi
        done
    fi
}

# Nettoyage (optionnel - commenté pour garder les logs)
cleanup() {
    log_info "Les fichiers temporaires sont conservés dans: $TEMP_DIR"
    # Décommenter pour supprimer automatiquement
    # rm -rf "$TEMP_DIR"
}

# Fonction principale
main() {
    echo "================================================"
    echo "  GitHub Bulk PR - Création de PR en masse"
    echo "================================================"
    echo ""

    check_requirements
    check_parameters

    mkdir -p "$TEMP_DIR"

    read_config_template

    local all_repos=$(get_all_repositories)
    local total_repos=$(echo "$all_repos" | jq 'length')
    log_success "$total_repos repository(ies) récupéré(s)"
    echo ""

    echo "================================================"
    echo "          DÉTECTION DES FICHIERS"
    echo "================================================"
    echo ""

    local detected_repos=$(detect_files_in_repos "$all_repos")
    echo "$detected_repos" > "$TEMP_DIR/detected_repos.json"

    echo "================================================"
    echo "          CRÉATION DES PULL REQUESTS"
    echo "================================================"
    echo ""

    create_pull_requests "$detected_repos"

    display_report

    log_success "🎉 Processus terminé!"
}

# Gestion du signal d'interruption
trap cleanup EXIT

# Exécution
main