#!/bin/bash

# Script pour modifier des fichiers XML/JSON dans GitHub et créer une Pull Request
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
NC='\033[0m' # No Color

# Fonction d'affichage avec couleur
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Vérification des prérequis
check_requirements() {
    local missing_tools=()

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi

    if ! command -v xmlstarlet &> /dev/null; then
        missing_tools+=("xmlstarlet")
    fi

    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi

    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Outils manquants: ${missing_tools[*]}"
        echo ""
        echo "Installation:"
        echo "  Ubuntu/Debian: sudo apt-get install jq xmlstarlet git curl"
        echo "  macOS: brew install jq xmlstarlet git curl"
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
    },
    {
      "file_path": "config/data.json",
      "type": "json",
      "action": "delete",
      "jq_path": ".deprecated"
    }
  ]
}
EOF
        exit 1
    fi
}

# Lecture de la configuration
read_config() {
    log_info "Lecture de la configuration depuis $CONFIG_FILE"

    REPO=$(jq -r '.repository' "$CONFIG_FILE")
    BASE_BRANCH=$(jq -r '.base_branch' "$CONFIG_FILE")
    NEW_BRANCH=$(jq -r '.new_branch' "$CONFIG_FILE")
    PR_TITLE=$(jq -r '.pr_title' "$CONFIG_FILE")
    PR_BODY=$(jq -r '.pr_body' "$CONFIG_FILE")

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

    # Clone avec authentification
    git clone "https://oauth2:${GITHUB_TOKEN}@github.com/${REPO}.git" repo
    cd repo

    # Configuration git
    git config user.name "GitHub Bot"
    git config user.email "bot@github.com"

    # Checkout de la branche de base
    git checkout "$BASE_BRANCH"

    # Création de la nouvelle branche
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
                # Mise à jour d'un attribut
                xmlstarlet ed -L -u "${xpath}/@${attribute}" -v "$value" "$file_path"
            else
                # Mise à jour du contenu
                xmlstarlet ed -L -u "$xpath" -v "$value" "$file_path"
            fi
            log_success "Valeur mise à jour"
            ;;

        "add")
            # Ajout d'un nouvel élément
            local parent_xpath=$(dirname "$xpath" | sed 's|^\.||')
            local element_name=$(basename "$xpath")

            xmlstarlet ed -L -s "$parent_xpath" -t elem -n "$element_name" -v "$value" "$file_path"
            log_success "Élément ajouté"
            ;;

        "delete")
            # Suppression d'un élément
            xmlstarlet ed -L -d "$xpath" "$file_path"
            log_success "Élément supprimé"
            ;;

        "add_attribute")
            # Ajout d'un attribut
            xmlstarlet ed -L -i "$xpath" -t attr -n "$attribute" -v "$value" "$file_path"
            log_success "Attribut ajouté"
            ;;

        *)
            log_error "Action XML inconnue: $action"
            return 1
            ;;
    esac
}

# Modification d'un fichier JSON
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
            # Mise à jour d'une valeur
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                # Valeur numérique
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            elif [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
                # Valeur booléenne
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            elif [[ "$value" =~ ^\{.*\}$ ]] || [[ "$value" =~ ^\[.*\]$ ]]; then
                # Objet ou tableau JSON
                jq "${jq_path} = ${value}" "$file_path" > "$temp_file"
            else
                # Valeur string
                jq "${jq_path} = \"${value}\"" "$file_path" > "$temp_file"
            fi
            mv "$temp_file" "$file_path"
            log_success "Valeur mise à jour"
            ;;

        "add")
            # Ajout d'un élément
            if [[ "$value" =~ ^\{.*\}$ ]] || [[ "$value" =~ ^\[.*\]$ ]]; then
                # Objet ou tableau
                jq "${jq_path} += ${value}" "$file_path" > "$temp_file"
            else
                # Valeur simple
                jq "${jq_path} += [\"${value}\"]" "$file_path" > "$temp_file"
            fi
            mv "$temp_file" "$file_path"
            log_success "Élément ajouté"
            ;;

        "delete")
            # Suppression d'un élément
            jq "del(${jq_path})" "$file_path" > "$temp_file"
            mv "$temp_file" "$file_path"
            log_success "Élément supprimé"
            ;;

        "merge")
            # Fusion d'objets
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

# Application des modifications
apply_modifications() {
    log_info "Application des modifications"

    local mod_count=$(jq '.modifications | length' "$CONFIG_FILE")
    local i=0

    while [ $i -lt $mod_count ]; do
        local file_path=$(jq -r ".modifications[$i].file_path" "$CONFIG_FILE")
        local file_type=$(jq -r ".modifications[$i].type" "$CONFIG_FILE")
        local action=$(jq -r ".modifications[$i].action" "$CONFIG_FILE")

        echo ""
        log_info "Modification $((i+1))/$mod_count: $file_path"

        case $file_type in
            "xml")
                local xpath=$(jq -r ".modifications[$i].xpath" "$CONFIG_FILE")
                local value=$(jq -r ".modifications[$i].value // empty" "$CONFIG_FILE")
                local attribute=$(jq -r ".modifications[$i].attribute // empty" "$CONFIG_FILE")

                modify_xml_file "$file_path" "$action" "$xpath" "$value" "$attribute"
                ;;

            "json")
                local jq_path=$(jq -r ".modifications[$i].jq_path" "$CONFIG_FILE")
                local value=$(jq -c ".modifications[$i].value // empty" "$CONFIG_FILE")

                # Si value est un objet/tableau, on le garde tel quel, sinon on le traite comme string
                if [ "$value" = "null" ] || [ -z "$value" ]; then
                    value=""
                fi

                modify_json_file "$file_path" "$action" "$jq_path" "$value"
                ;;

            *)
                log_error "Type de fichier non supporté: $file_type"
                ;;
        esac

        i=$((i+1))
    done

    log_success "Toutes les modifications appliquées"
}

# Commit et push des changements
commit_and_push() {
    log_info "Commit et push des changements"

    # Vérifier s'il y a des changements
    if [ -z "$(git status --porcelain)" ]; then
        log_warning "Aucun changement détecté"
        return 1
    fi

    # Afficher les fichiers modifiés
    echo ""
    log_info "Fichiers modifiés:"
    git status --short
    echo ""

    # Ajouter tous les fichiers modifiés
    git add -A

    # Commit
    git commit -m "$PR_TITLE"

    # Push
    git push origin "$NEW_BRANCH"

    log_success "Changements poussés sur GitHub"
    return 0
}

# Création de la Pull Request
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

    local pr_url=$(echo "$response" | jq -r '.html_url')
    local pr_number=$(echo "$response" | jq -r '.number')

    if [ "$pr_url" != "null" ] && [ -n "$pr_url" ]; then
        log_success "Pull Request créée avec succès!"
        echo ""
        echo "📋 PR #${pr_number}: $pr_url"
    else
        local error_msg=$(echo "$response" | jq -r '.message // "Erreur inconnue"')
        log_error "Échec de la création de la PR: $error_msg"

        # Afficher plus de détails si disponibles
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

    # Configuration du nettoyage en cas d'erreur
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