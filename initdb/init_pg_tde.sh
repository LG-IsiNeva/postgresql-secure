#!/bin/bash
set -e

# Ce script est exécuté par l'entrypoint de Percona PostgreSQL
# pendant la phase d'initialisation. À ce moment, pg_tde n'est pas
# encore chargé (shared_preload_libraries nécessite un redémarrage).
# 
# L'image Percona avec ENABLE_PG_TDE=1 configure automatiquement 
# shared_preload_libraries via ALTER SYSTEM et redémarre le serveur
# après l'exécution des scripts d'init.
#
# Ce script crée uniquement le fichier keyring s'il n'existe pas.
# La création de l'extension pg_tde sera faite via un script SQL
# après le redémarrage complet du serveur.

# --- Lecture du mot de passe de la BDD depuis le Secret Docker ---
PASSWORD_FILE="${POSTGRES_PASSWORD_FILE:-/run/secrets/postgres_password_secret}"

if [ ! -f "$PASSWORD_FILE" ]; then
    echo "Erreur: Le fichier de mot de passe $PASSWORD_FILE n'existe pas."
    exit 1
fi

# Lire le mot de passe du fichier secret (supprime les nouvelles lignes)
DB_PASSWORD=$(cat "$PASSWORD_FILE" | tr -d '\n')

if [ -z "$DB_PASSWORD" ]; then
    echo "Erreur: Le mot de passe de la base de données est vide."
    exit 1
fi
# -----------------------------------------------------------------

echo "Configuration de pg_tde..."
echo "Le trousseau de clés sera initialisé au premier démarrage complet."
echo "Chemin du keyring: ${PG_TDE_KEYRING_FILE:-/data/db/pg_tde_keyring}"

# Créer le répertoire parent du keyring si nécessaire
KEYRING_DIR=$(dirname "${PG_TDE_KEYRING_FILE:-/data/db/pg_tde_keyring}")
mkdir -p "$KEYRING_DIR"

echo "Configuration pg_tde terminée. L'extension sera disponible après le redémarrage."
