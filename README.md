<h1><mark>
⚠️ L'ensemble des scripts de ce projet github ont été testés et réalisés dans le cadre de projets personnels 
</mark>

<mark><b>Leurs excusions est de votre entiere responsabilitée</b></mark>
</h1>

# Script github_scan_java_angular

Ce script permet de scanner les repositories git non en paralléle en permettant
l'analyse :

- pour du code java du fichier pom.xml (maven) à la recherche
  de la version de java utiliser de springboot
  </br>
  Il va rechercher dans la branch par default du projet le fichier pom.xml
  et si l'architecture mise en place est un second pom.xml un repertoire app
  </br>
- pour du code front angular ou vue o react, il va parser le fichier package-lock.json à la recherche des versions
  utilisées

La recupération des résultats ce fait dans le repertoire `github_files` dans le fichier `summary.txt`

### Utilisation
Exemple d'utilisation avec un token github

```bash
# Installer les dépendances (si nécessaire)
sudo apt-get install jq git curl  # Ubuntu/Debian
brew install jq git curl          # macOS

# Configurer le token GitHub (attention à bien avoir les droits d'ecriture sur vos repo)
export GITHUB_TOKEN='ghp_votre_token'

# Exécuter le script
chmod +x github_scan_java_angular.sh
./github_scan_java_angular.sh '' lombok,jackson-databind,junit
```
Exemple d'utilisation sans token github (/!\ limitation à 60 requete minute sur les apis github)
```bash
# Installer les dépendances (si nécessaire)
sudo apt-get install jq git curl  # Ubuntu/Debian
brew install jq git curl          # macOS

# Exécuter le script
chmod +x github_scan_java_angular.sh
./github_scan_java_angular.sh GgComeBack lombok,jackson-databind,junit
```

# Script github_modification_fichier_xml_json.sh

un script bash complet qui permet de modifier des fichiers XML/JSON dans GitHub et créer automatiquement des Pull Requests. Voici les caractéristiques principales :
Fonctionnalités
Pour les fichiers XML :

- update : Mettre à jour une valeur ou un attribut
- add : Ajouter un nouvel élément
- delete : Supprimer un élément
- add_attribute : Ajouter un attribut

Pour les fichiers JSON :

- update : Mettre à jour une valeur
- add : Ajouter un élément
- delete : Supprimer un élément
- merge : Fusionner des objets

### Exemple de fichier de configuration
Créez un fichier config.json :

```json
{
  "repository": "votre-user/votre-repo",
  "base_branch": "main",
  "new_branch": "feature/auto-update",
  "pr_title": "Mise à jour automatique de la configuration",
  "pr_body": "Cette PR met à jour automatiquement les fichiers de configuration",
  "modifications": [
    {
      "file_path": "pom.xml",
      "type": "xml",
      "action": "update",
      "xpath": "//project/version",
      "value": "2.0.0"
    },
    {
      "file_path": "package.json",
      "type": "json",
      "action": "update",
      "jq_path": ".version",
      "value": "2.0.0"
    }
  ]
}
```

### Utilisation

```bash
# Installer les dépendances (si nécessaire)
sudo apt-get install jq xmlstarlet git curl  # Ubuntu/Debian
brew install jq xmlstarlet git curl          # macOS

# Configurer le token GitHub (attention à bien avoir les droits d'ecriture sur vos repo)
export GITHUB_TOKEN='ghp_votre_token'

# Exécuter le script
chmod +x github_modification_fichier_xml_json.sh
./github_modification_fichier_xml_json.sh config.json
```

# Script github_modification_fichier_xml_json_for_all_project

Script bash qui détecte automatiquement les repositories contenant les fichiers spécifiés et lance la création de PR en parallèle.

## Fonctionnalités principales

- **Détection automatique** : Scanne tous vos repositories GitHub accessibles avec le token
- **Filtrage intelligent** :
    - Exclut les repos archivés et les forks (configurable)
    - Liste blanche/noire de repositories
    - Détection de fichiers spécifiques
- **Exécution parallèle** : Crée jusqu'à 5 PR simultanément (configurable)
- **Logs détaillés** : Conserve les logs de chaque opération
- **Rapport final** : Affiche un résumé avec succès et échecs

## Exemple de configuration template

Créez `config_template.json` :

```json
{
  "target_files": [
    "pom.xml",
    "app/pom.xml",
    "package.json",
    "config/settings.xml"
  ],
  "new_branch_prefix": "feature/spring-boot-upgrade",
  "pr_title": "🤖 Mise à jour Spring Boot vers 3.2.0",
  "pr_body": "Cette PR met à jour automatiquement Spring Boot.\n\n**Modifications:**\n- Spring Boot 3.2.0\n- Java 17 minimum",
  "filters": {
    "exclude_repos": ["test-repo", "old-project"],
    "include_only": [],
    "exclude_archived": true,
    "exclude_forks": true
  },
  "modifications": [
    {
      "file_path": "pom.xml",
      "type": "xml",
      "action": "update",
      "xpath": "//project/parent[artifactId='spring-boot-starter-parent']/version",
      "value": "3.2.0"
    },
    {
      "file_path": "pom.xml",
      "type": "xml",
      "action": "update",
      "xpath": "//project/properties/java.version",
      "value": "17"
    }
  ]
}
```

## Utilisation

```bash
# Rendre les scripts exécutables
chmod +x github_modification_fichier_xml_json_for_all_project.sh github_modification_fichier_xml_json.sh

# Exporter le token
export GITHUB_TOKEN='ghp_votre_token'

# Lancer le scan et création de PR
./github_modification_fichier_xml_json_for_all_project.sh config_template.json
```

Le script va :
1. ✅ Récupérer tous vos repositories
2. 🔍 Détecter ceux qui contiennent les fichiers cibles
3. ⚙️ Générer une configuration spécifique pour chaque repo
4. 🚀 Créer les PR en parallèle (5 à la fois par défaut)
5. 📊 Afficher un rapport détaillé avec succès/échecs

Les logs sont conservés dans `github_modification_fichier_xml_json_for_all_project_<timestamp>/logs/` pour investigation en cas d'échec

/!\ la parallélisation est réalisée que pour les PRs pour le moment

# Script github_scan_java_angular_paralelle

Ce script permet de scanner les repositories en paralléle git en permettant
l'analyse :

- pour du code java du fichier pom.xml (maven) à la recherche
  de la version de java utiliser de springboot
  </br>
  Il va rechercher dans la branch par default du projet le fichier pom.xml
  et si l'architecture mise en place est un second pom.xml un repertoire app
  </br>
- pour du code front angular ou vue o react, il va parser le fichier package-lock.json à la recherche des versions
  utilisées

La recupération des résultats ce fait dans le repertoire `github_files` dans le fichier `summary.txt`


### Utilisation
Exemple d'utilisation avec un token github

```bash
# Installer les dépendances (si nécessaire)
sudo apt-get install jq git curl parallel # Ubuntu/Debian
brew install jq git curl parallel         # macOS

# Configurer le token GitHub (attention à bien avoir les droits d'ecriture sur vos repo)
export GITHUB_TOKEN='ghp_votre_token'

# Exécuter le script
chmod +x github_scan_java_angular_paralelle.sh
# Personnaliser le nombre de jobs parallèles (20 jobs)
./github_scan_java_angular_paralelle.sh '' lombok,jackson-databind,junit 10
```
Exemple d'utilisation sans token github (/!\ limitation à 60 requete minute sur les apis github)
```bash
# Installer les dépendances (si nécessaire)
sudo apt-get install jq git curl parallel # Ubuntu/Debian
brew install jq git curl parallel         # macOS

# Exécuter le script
chmod +x github_scan_java_angular_paralelle.sh
# Personnaliser le nombre de jobs parallèles (20 jobs)
./github_scan_java_angular_paralelle.sh GgComeBack lombok,jackson-databind,junit 10
```

La recupération des résultats ce fait dans le repertoire `github_files` dans le fichier `summary.txt`