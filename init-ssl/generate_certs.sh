#!/bin/bash
################################################################################
# Script de génération de certificats SSL/TLS pour PostgreSQL avec mTLS
# Génère une CA, un certificat serveur et des certificats clients
################################################################################
set -e

CERT_DIR=${CERT_DIR:-/etc/certs}
DAYS_VALID=${DAYS_VALID:-365}
CLIENT_NAMES=${CLIENT_NAMES:-"admin,app_user,backup_user"}
PFX_PASSWORD=${PFX_PASSWORD:-"changeme"}
FQDN_IP=${FQDN_IP:-""}
FQDN_URL=${FQDN_URL:-""}

echo "=========================================="
echo "  Génération des Certificats SSL/TLS"
echo "=========================================="
echo "Répertoire: $CERT_DIR"
echo "Validité: $DAYS_VALID jours"
echo "Clients à générer: $CLIENT_NAMES"
echo "FQDN IP: ${FQDN_IP:-'(non défini)'}"
echo "FQDN URL: ${FQDN_URL:-'(non défini)'}"
echo "=========================================="

# Créer le répertoire si nécessaire
mkdir -p $CERT_DIR

################################################################################
# 1. GÉNÉRATION DE LA CA (Certificate Authority)
################################################################################
echo ""
echo "[1/3] Génération de la CA (Certificate Authority)..."
openssl req -new -x509 -days $DAYS_VALID -nodes -text \
    -out $CERT_DIR/ca.crt \
    -keyout $CERT_DIR/ca.key \
    -subj "/C=FR/ST=IDF/L=Paris/O=PostgreSQL-TDE/OU=Security/CN=PostgreSQL-TDE-CA"

chown 26:26 $CERT_DIR/ca.key $CERT_DIR/ca.crt 2>/dev/null || true
chmod 600 $CERT_DIR/ca.key
chmod 644 $CERT_DIR/ca.crt
echo "✓ CA générée: $CERT_DIR/ca.crt"

################################################################################
# 2. GÉNÉRATION DU CERTIFICAT SERVEUR
################################################################################
echo ""
echo "[2/3] Génération du certificat Serveur..."

# Création de la clé privée serveur
openssl req -new -nodes -text \
    -out $CERT_DIR/server.csr \
    -keyout $CERT_DIR/server.key \
    -subj "/C=FR/ST=IDF/L=Paris/O=PostgreSQL-TDE/OU=Database/CN=percona_postgres_tde"

# Construction dynamique du SAN (Subject Alternative Name)
SAN_LIST="DNS:percona_postgres_tde,DNS:localhost,DNS:db,IP:127.0.0.1"

# Ajouter l'IP publique si définie
if [ -n "$FQDN_IP" ]; then
    SAN_LIST="${SAN_LIST},IP:${FQDN_IP}"
    echo "  → Ajout de l'IP publique au SAN: $FQDN_IP"
fi

# Ajouter le FQDN si défini
if [ -n "$FQDN_URL" ]; then
    SAN_LIST="${SAN_LIST},DNS:${FQDN_URL}"
    echo "  → Ajout du FQDN au SAN: $FQDN_URL"
fi

echo "  SAN complet: $SAN_LIST"

# Signature du certificat serveur par la CA avec SANs
openssl x509 -req -in $CERT_DIR/server.csr -text -days $DAYS_VALID \
    -extfile <(printf "subjectAltName=$SAN_LIST") \
    -CA $CERT_DIR/ca.crt \
    -CAkey $CERT_DIR/ca.key \
    -CAcreateserial \
    -out $CERT_DIR/server.crt

# Nettoyage
rm $CERT_DIR/server.csr

# Permissions PostgreSQL requises
# PostgreSQL est strict : server.key doit être 0600 et appartenir à postgres (UID 26 dans Percona)
chown 26:26 $CERT_DIR/server.key $CERT_DIR/server.crt 2>/dev/null || true
chmod 600 $CERT_DIR/server.key
chmod 644 $CERT_DIR/server.crt
echo "✓ Certificat serveur généré: $CERT_DIR/server.crt"

################################################################################
# 3. GÉNÉRATION DES CERTIFICATS CLIENTS (mTLS)
################################################################################
echo ""
echo "[3/3] Génération des certificats Clients (mTLS)..."

# Convertir la liste séparée par virgules en lignes (compatible ash/bash)
CLIENT_LIST=$(echo "$CLIENT_NAMES" | tr ',' '\n')

for CLIENT_NAME in $CLIENT_LIST; do
    # Supprimer les espaces blancs
    CLIENT_NAME=$(echo "$CLIENT_NAME" | xargs)

    echo ""
    echo "→ Génération du certificat pour: $CLIENT_NAME"

    CLIENT_PREFIX="$CERT_DIR/client_${CLIENT_NAME}"

    # a. Création de la clé privée client
    openssl req -new -nodes -text \
        -out "$CLIENT_PREFIX.csr" \
        -keyout "$CLIENT_PREFIX.key" \
        -subj "/C=FR/ST=IDF/L=Paris/O=PostgreSQL-TDE/OU=Clients/CN=$CLIENT_NAME"

    # IMPORTANT: Le CN=$CLIENT_NAME doit correspondre au nom d'utilisateur PostgreSQL
    # pour que l'authentification par certificat fonctionne avec pg_hba.conf

    # b. Signature du certificat client par la CA
    openssl x509 -req -in "$CLIENT_PREFIX.csr" -text -days $DAYS_VALID \
        -CA $CERT_DIR/ca.crt \
        -CAkey $CERT_DIR/ca.key \
        -CAcreateserial \
        -out "$CLIENT_PREFIX.crt"

    # c. Suppression du CSR
    rm "$CLIENT_PREFIX.csr"

    # d. Génération du fichier PKCS#12 (.pfx) pour Windows/autres clients
    openssl pkcs12 -export -out "$CLIENT_PREFIX.pfx" \
        -inkey "$CLIENT_PREFIX.key" \
        -in "$CLIENT_PREFIX.crt" \
        -certfile $CERT_DIR/ca.crt \
        -passout pass:${PFX_PASSWORD} \
        -name "PostgreSQL Client - $CLIENT_NAME"

    # e. Permissions sécurisées
    chmod 600 "$CLIENT_PREFIX.key"
    chmod 644 "$CLIENT_PREFIX.crt"
    chmod 600 "$CLIENT_PREFIX.pfx"

    echo "  ✓ Fichiers générés:"
    echo "    - Certificat: $CLIENT_PREFIX.crt"
    echo "    - Clé privée: $CLIENT_PREFIX.key"
    echo "    - PKCS#12:    $CLIENT_PREFIX.pfx (mot de passe protégé)"
done

################################################################################
# RÉSUMÉ
################################################################################
echo ""
echo "=========================================="
echo "  ✓ Génération terminée avec succès !"
echo "=========================================="
echo ""
echo "Fichiers générés dans $CERT_DIR:"
echo "  - ca.crt, ca.key         (Autorité de Certification)"
echo "  - server.crt, server.key (Certificat serveur PostgreSQL)"
echo ""
echo "Certificats clients générés:"
for CLIENT_NAME in $CLIENT_LIST; do
    CLIENT_NAME=$(echo "$CLIENT_NAME" | xargs)
    echo "  - client_${CLIENT_NAME}.{crt,key,pfx}"
done
echo ""
echo "IMPORTANT: Pour se connecter avec mTLS, les clients doivent:"
echo "  1. Utiliser sslmode=verify-full"
echo "  2. Fournir client_<user>.crt et client_<user>.key"
echo "  3. Fournir ca.crt pour vérifier le serveur"
echo "  4. Le CN du certificat doit correspondre au nom d'utilisateur PostgreSQL"
echo ""
echo "Mot de passe des fichiers .pfx: (voir PFX_PASSWORD dans .env)"
echo "=========================================="