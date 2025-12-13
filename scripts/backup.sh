#!/bin/bash
# scripts/backup.sh
# Sauvegarde chiffrée de la base de données PostgreSQL

set -e

# --- Configuration ---
BACKUP_DIR="/backups"
DB_NAME="${POSTGRES_DB:-secure_db}"
DB_USER="backup_user"
DB_PORT="${PGPORT:-5434}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump.enc"

# LIRE LE MOT DE PASSE DE CHIFFREMENT DEPUIS LE FICHIER SECRET
if [ -z "$BACKUP_PASS_FILE" ]; then
    echo "Erreur: BACKUP_PASS_FILE n'est pas défini."
    exit 1
fi

ENCRYPTION_PASS=$(cat "$BACKUP_PASS_FILE" | tr -d '\n')

if [ -z "$ENCRYPTION_PASS" ]; then
    echo "Erreur: Le secret de chiffrement de sauvegarde est vide."
    exit 1
fi

# LIRE LE MOT DE PASSE DE L'UTILISATEUR BACKUP
BACKUP_USER_PASS_FILE="/run/secrets/backup_user_password_secret"
if [ ! -f "$BACKUP_USER_PASS_FILE" ]; then
    echo "Erreur: Le fichier de mot de passe backup_user n'existe pas."
    exit 1
fi

BACKUP_USER_PASS=$(cat "$BACKUP_USER_PASS_FILE" | tr -d '\n')

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Erreur : Le répertoire de sauvegarde $BACKUP_DIR n'existe pas ou n'est pas monté."
  exit 1
fi

echo "--- Démarrage de la sauvegarde chiffrée de la base de données $DB_NAME ---"
echo "Utilisateur: $DB_USER | Port: $DB_PORT"

# Utilisation de pg_dump via socket Unix (pas de -h) et chiffrement à la volée avec pbkdf2
export PGPASSWORD="$BACKUP_USER_PASS"
pg_dump -Fc -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" | \
openssl enc -aes-256-cbc -pbkdf2 -e -pass pass:"$ENCRYPTION_PASS" -out "$OUTPUT_FILE"
unset PGPASSWORD

if [ $? -eq 0 ]; then
  echo "Sauvegarde chiffrée réussie : $OUTPUT_FILE"
  echo "Taille : $(du -h $OUTPUT_FILE | awk '{print $1}')"
else
  echo "Erreur lors de la sauvegarde ou du chiffrement."
fi