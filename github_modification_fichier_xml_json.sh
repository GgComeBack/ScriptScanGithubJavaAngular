#!/bin/bash

# Script pour modifier des fichiers XML/JSON dans GitHub et créer une Pull Request
# Version optimisée avec moins d'appels système
# Usage: ./github_modification_fichier_xml_json.sh <config_file.json>

set -e

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
CONFIG_FILE="${1:-}"
TEMP_DIR="./temp_pr_$(date +%s)"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonction d'affichage avec couleur
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Vérification des prérequis
check_requirements() {
    local missing_tools=()

    for tool in jq xmlstarlet git curl; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Outils manquants: ${missing_tools[*]}"
        echo ""
        echo "Installation:"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_tools[*]}"
        echo "  macOS: brew install ${missing_tools[*]}"
        exit 1
    fi
}

# Vérification des paramètres
check_parameters() {
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN non défini"
        echo "Exportez votre token: export GITHUB_TOKEN='ghp_xxx'"
        exit 1
    fi

    if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
        log_error "Fichier de configuration manquant ou invalide"
        echo ""
        echo "Usage: $0 <config_file.json>"
        echo ""
        echo "Format du fichier de configuration (JSON):"
        cat << 'EOF'
{
  "repository": "owner/repo-name",
  "base_branch": "main",
  "new_branch": "feature/update-config",
  "pr_title": "Update configuration files",
  "pr_body": "This PR updates configuration files automatically",
  "modifications": [
    {
      "file_path": "config/settings.xml",
      "type": "xml",
      "action": "update",
      "xpath": "//configuration/property[@name='version']",
      "value": "2.0.0"
    },
    {
      "file_path": "config/app.json",
      "type": "json",
      "action": "add",
      "jq_path": ".features",
      "value": {"newFeature": true}
    }
  ]
}
EOF
        exit 1
    fi
}

# Lecture de la configuration - optimisé avec un seul appel jq
read_config() {
    log_info "Lecture de la configuration depuis $CONFIG_FILE"

    # Un seul appel jq pour extraire toutes les valeurs nécessaires
    local config_data=$(jq -r '[.repository, .base_branch, .new_branch, .pr_title, .pr_body] | @tsv' "$CONFIG_FILE")

    IFS=$'\t' read -r REPO BASE_BRANCH NEW_BRANCH PR_TITLE PR_BODY <<< "$config_data"

    if [ "$REPO" = "null" ] || [ "$BASE_BRANCH" = "null" ] || [ "$NEW_BRANCH" = "null" ]; then
        log_error "Configuration incomplète (repository, base_branch, new_branch requis)"
        exit 1
    fi

    log_success "Configuration chargée: $REPO ($BASE_BRANCH → $NEW_BRANCH)"
}

# Clone du repository
clone_repository() {
    log_info "Clone du repository $REPO"

    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"

    git clone "https://oauth2:${GITHUB_TOKEN}@github.com/${REPO}.git" repo
    cd repo

    git config user.name "GitHub Bot"
    git config user.email "bot@github.com"
    git checkout "$BASE_BRANCH"
    git checkout -b "$NEW_BRANCH"

    log_success "Repository cloné et branche créée"
}

# Modification d'un fichier XML
modify_xml_file() {
    local file_path=$1
    local action=$2
    local xpath=$3
    local value=$4
    local attribute=$5

    log_info "Modification XML: $file_path"

    if [ ! -f "$file_path" ]; then
        log_error "Fichier non trouvé: $file_path"
        return 1
    fi

    case $action in
        "update")
            if [ -n "$attribute" ]; then
                xmlstarlet ed -L -u "${xpath}/@${attribute}" -v "$value" "$file_path"
            else
                xmlstarlet ed -L -u "$xpath" -v "$value" "$file_path"
            fi
            log_success "Valeur mise à jour"
            ;;

        "add")
            local parent_xpath=$(dirname "$xpath" | sed 's|^\.||')
            local element_name=$(basename "$xpath")
            xmlstarlet ed -L -s "$parent_xpath" -t elem -n "$element_name" -v "$value" "$file_path"
            log_success "Élément ajouté"
            ;;

        "delete")
            xmlstarlet ed -L -d "$xpath" "$file_path"
            log_success "Élément supprimé"
            ;;

        "add_attribute")
            xmlstarlet ed -L -i "$xpath" -t attr -n "$attribute" -v "$value" "$file_path"
            log_success "Attribut ajouté"
            ;;

        *)
            log_error "Action XML inconnue: $action"
            return 1
            ;;
    esac
}

# Modification d'un fichier JSON - optimisé
modify_json_file() {
    local file_path=$1
    local action=$2
    local jq_path=$3
    local value=$4

    log_info "Modification JSON: $file_path"

    if [ ! -f "$file_path" ]; then
        log_error "Fichier non trouvé: $file_path"
        return 1
    fi

    local temp_file="${file_path}.tmp"

    case $action in
        "update")
            # Détection automatique du type de valeur
            if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                # Nombre
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
                # Booléen
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            elif [[ "$value" =~ ^\{.*\}$ ]] || [[ "$value" =~ ^\[.*\]$ ]]; then
                # Objet ou tableau JSON
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            else
                # String
                jq "${jq_path} = \"${value}\"" "$file_path" > "$temp_file"
            fi
            mv "$temp_file" "$file_path"
            log_success "Valeur mise à jour"
            ;;

        "add")
            if [[ "$value" =~ ^\{.*\}$ ]] || [[ "$value" =~ ^\[.*\]$ ]]; then
                jq "${jq_path} += ${value}" "$file_path" > "$temp_file"
            else
                jq "${jq_path} += [\"${value}\"]" "$file_path" > "$temp_file"
            fi
            mv "$temp_file" "$file_path"
            log_success "Élément ajouté"
            ;;

        "delete")
            jq "del(${jq_path})" "$file_path" > "$temp_file"
            mv "$temp_file" "$file_path"
            log_success "Élément supprimé"
            ;;

        "merge")
            jq "${jq_path} *= ${value}" "$file_path" > "$temp_file"
            mv "$temp_file" "$file_path"
            log_success "Objets fusionnés"
            ;;

        *)
            log_error "Action JSON inconnue: $action"
            return 1
            ;;
    esac
}

# Application des modifications - optimisé
apply_modifications() {
    log_info "Application des modifications"

    local mod_count=$(jq '.modifications | length' "$CONFIG_FILE")

    # Extraire toutes les modifications en une seule fois
    local modifications=$(jq -c '.modifications[]' "$CONFIG_FILE")

    local i=0
    while IFS= read -r mod; do
        i=$((i+1))

        # Extraire les champs nécessaires en un seul appel jq
        local mod_data=$(echo "$mod" | jq -r '[.file_path, .type, .action] | @tsv')
        IFS=$'\t' read -r file_path file_type action <<< "$mod_data"

        echo ""
        log_info "Modification $i/$mod_count: $file_path"

        case $file_type in
            "xml")
                local xpath=$(echo "$mod" | jq -r '.xpath')
                local value=$(echo "$mod" | jq -r '.value // empty')
                local attribute=$(echo "$mod" | jq -r '.attribute // empty')
                modify_xml_file "$file_path" "$action" "$xpath" "$value" "$attribute"
                ;;

            "json")
                local jq_path=$(echo "$mod" | jq -r '.jq_path')
                local value=$(echo "$mod" | jq -c '.value // empty')

                if [ "$value" = "null" ] || [ -z "$value" ]; then
                    value=""
                fi

                modify_json_file "$file_path" "$action" "$jq_path" "$value"
                ;;

            *)
                log_error "Type de fichier non supporté: $file_type"
                ;;
        esac
    done <<< "$modifications"

    log_success "Toutes les modifications appliquées"
}

# Commit et push des changements
commit_and_push() {
    log_info "Commit et push des changements"

    if [ -z "$(git status --porcelain)" ]; then
        log_warning "Aucun changement détecté"
        return 1
    fi

    echo ""
    log_info "Fichiers modifiés:"
    git status --short
    echo ""

    git add -A
    git commit -m "$PR_TITLE"
    git push origin "$NEW_BRANCH"

    log_success "Changements poussés sur GitHub"
    return 0
}

# Création de la Pull Request - optimisé
create_pull_request() {
    log_info "Création de la Pull Request"

    local pr_data=$(jq -n \
        --arg title "$PR_TITLE" \
        --arg body "$PR_BODY" \
        --arg head "$NEW_BRANCH" \
        --arg base "$BASE_BRANCH" \
        '{title: $title, body: $body, head: $head, base: $base}')

    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO}/pulls" \
        -d "$pr_data")

    # Extraire url et number en un seul appel jq
    local pr_info=$(echo "$response" | jq -r '[.html_url, .number, .message] | @tsv')
    IFS=$'\t' read -r pr_url pr_number error_msg <<< "$pr_info"

    if [ "$pr_url" != "null" ] && [ -n "$pr_url" ]; then
        log_success "Pull Request créée avec succès!"
        echo ""
        echo "📋 PR #${pr_number}: $pr_url"
    else
        log_error "Échec de la création de la PR: ${error_msg:-Erreur inconnue}"

        if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
            echo "$response" | jq -r '.errors[] | "  - \(.message)"'
        fi

        return 1
    fi
}

# Nettoyage
cleanup() {
    log_info "Nettoyage des fichiers temporaires"
    cd ../..
    rm -rf "$TEMP_DIR"
    log_success "Nettoyage terminé"
}

# Fonction principale
main() {
    echo "================================================"
    echo "  GitHub PR Modifier - Modification automatique"
    echo "================================================"
    echo ""

    check_requirements
    check_parameters
    read_config

    trap cleanup EXIT

    clone_repository
    apply_modifications

    if commit_and_push; then
        create_pull_request
        echo ""
        log_success "🎉 Processus terminé avec succès!"
    else
        log_warning "Aucune Pull Request créée (pas de changements)"
    fi
}

# Exécution
main