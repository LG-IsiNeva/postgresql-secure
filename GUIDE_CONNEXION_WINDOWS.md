# Guide de connexion PostgreSQL depuis Windows avec mTLS

## Problème résolu
Les certificats SSL ont été régénérés lors du redémarrage du conteneur Docker. Vos anciens certificats client ne sont plus valides car ils ont été signés par un ancien CA (Certificate Authority).

## Certificats mis à jour
Tous les certificats ont été copiés dans le répertoire `certs/` :
- **Date de génération** : 10 mars 2026 à 08:22 UTC
- **Validité** : 3650 jours (10 ans) - jusqu'au 7 mars 2036
- **Nouveau CA fingerprint** : `5E:CC:A8:FB:1F:CF:98:39:80:1B:E9:2E:64:AA:4A:68:18:2A:22:11`

---

## Étape 1 : Récupérer les certificats

### Fichiers nécessaires pour la connexion

Vous devez transférer **3 fichiers** depuis le serveur vers votre poste Windows :

1. **ca.crt** - Certificat de l'autorité de certification (CA)
2. **client_[votre_utilisateur].pfx** - Votre certificat client au format PKCS#12
3. **Mot de passe PFX** : `2RwAQXP6EH9GS/Myqs+TvYa8UiE5DeGU`

### Utilisateurs disponibles
Choisissez le certificat correspondant à votre utilisateur PostgreSQL :
- `client_admin.pfx` → utilisateur `admin`
- `client_app_user.pfx` → utilisateur `app_user`
- `client_backup_user.pfx` → utilisateur `backup_user`
- `client_app_developer.pfx` → utilisateur `app_developer`

### Méthodes de transfert

**Option A : Via SCP (recommandé si vous avez un client SSH)**
```bash
# Depuis Windows PowerShell ou WSL
scp ubuntu@94.23.5.104:/home/ubuntu/system/postgresql-secure/certs/ca.crt .
scp ubuntu@94.23.5.104:/home/ubuntu/system/postgresql-secure/certs/client_admin.pfx .
```

**Option B : Via WinSCP ou FileZilla**
- Connectez-vous au serveur 94.23.5.104
- Téléchargez les fichiers depuis `/home/ubuntu/system/postgresql-secure/certs/`

**Option C : Afficher le contenu et copier-coller**
```bash
# Sur le serveur Linux
cat /home/ubuntu/system/postgresql-secure/certs/ca.crt
# Copier le contenu (de -----BEGIN CERTIFICATE----- à -----END CERTIFICATE-----)
# Créer un fichier ca.crt sur Windows et y coller le contenu
```

---

## Étape 2 : Installer les certificats sur Windows

### A. Installer le certificat CA (Autorité racine de confiance)

1. **Double-cliquez** sur `ca.crt`
2. Cliquez sur **"Installer le certificat..."**
3. Choisissez **"Ordinateur local"** (ou "Utilisateur actuel")
4. Cliquez sur **"Suivant"** puis **"Oui"** pour autoriser les modifications
5. Sélectionnez **"Placer tous les certificats dans le magasin suivant"**
6. Cliquez sur **"Parcourir..."** et sélectionnez **"Autorités de certification racines de confiance"**
7. Cliquez sur **"Suivant"** puis **"Terminer"**
8. Confirmez avec **"Oui"** dans la fenêtre de sécurité

### B. Installer le certificat client (PFX)

1. **Double-cliquez** sur `client_admin.pfx` (ou votre utilisateur)
2. Choisissez **"Ordinateur local"** (ou "Utilisateur actuel")
3. Cliquez sur **"Suivant"**
4. Vérifiez le chemin du fichier et cliquez sur **"Suivant"**
5. **Entrez le mot de passe PFX** : `2RwAQXP6EH9GS/Myqs+TvYa8UiE5DeGU`
6. **Cochez** : "Marquer cette clé comme exportable" (optionnel, pour sauvegarde)
7. Cliquez sur **"Suivant"**
8. Laissez **"Sélectionner automatiquement le magasin..."** (recommandé)
9. Cliquez sur **"Suivant"** puis **"Terminer"**

### C. Vérifier l'installation

1. Ouvrez **"Gérer les certificats utilisateur"** (Win+R → `certmgr.msc`)
2. Vérifiez :
   - **Autorités de certification racines de confiance** → **Certificats** → cherchez "PostgreSQL-TDE-CA"
   - **Personnel** → **Certificats** → cherchez votre certificat client (ex: "admin")

---

## Étape 3 : Configurer votre client PostgreSQL

### Option A : DBeaver

1. Ouvrez DBeaver et créez/modifiez votre connexion PostgreSQL
2. **Onglet "Main"** :
   - Host : `postgresql-secure.lgrdev.ovh` ou `94.23.5.104`
   - Port : `5434`
   - Database : `o2p_secure`
   - Username : `admin` (ou votre utilisateur)
   - Password : *laisser vide* (authentification par certificat)

3. **Onglet "SSL"** :
   - **Cochez** "Use SSL"
   - SSL mode : `verify-full`
   - Root certificate (CA) : chemin vers `ca.crt`
   - Client certificate : chemin vers `client_admin.crt` (vous devrez extraire le .crt du .pfx)
   - Client key : chemin vers `client_admin.key` (vous devrez extraire la clé du .pfx)

4. **Pour extraire .crt et .key depuis le .pfx** (avec OpenSSL sur Windows) :
   ```bash
   # Installer OpenSSL pour Windows : https://slproweb.com/products/Win32OpenSSL.html

   # Extraire le certificat client
   openssl pkcs12 -in client_admin.pfx -clcerts -nokeys -out client_admin.crt
   # Mot de passe : 2RwAQXP6EH9GS/Myqs+TvYa8UiE5DeGU

   # Extraire la clé privée
   openssl pkcs12 -in client_admin.pfx -nocerts -nodes -out client_admin.key
   # Mot de passe : 2RwAQXP6EH9GS/Myqs+TvYa8UiE5DeGU
   ```

### Option B : pgAdmin 4

1. Créez/modifiez votre serveur PostgreSQL
2. **Onglet "Connection"** :
   - Host : `postgresql-secure.lgrdev.ovh` ou `94.23.5.104`
   - Port : `5434`
   - Maintenance database : `o2p_secure`
   - Username : `admin`

3. **Onglet "SSL"** :
   - SSL mode : `verify-full`
   - Root certificate : chemin vers `ca.crt`
   - Client certificate : chemin vers `client_admin.crt` (extrait du PFX)
   - Client key : chemin vers `client_admin.key` (extrait du PFX)

### Option C : psql (ligne de commande)

```bash
psql "host=postgresql-secure.lgrdev.ovh port=5434 dbname=o2p_secure user=admin sslmode=verify-full sslrootcert=ca.crt sslcert=client_admin.crt sslkey=client_admin.key"
```

### Option D : Chaîne de connexion JDBC (Java/Spring Boot)

```properties
spring.datasource.url=jdbc:postgresql://postgresql-secure.lgrdev.ovh:5434/o2p_secure?ssl=true&sslmode=verify-full&sslrootcert=ca.crt&sslcert=client_admin.crt&sslkey=client_admin.key
spring.datasource.username=admin
# Pas de mot de passe nécessaire avec mTLS
```

---

## Étape 4 : Tester la connexion

1. Ouvrez votre client PostgreSQL (DBeaver, pgAdmin, etc.)
2. Essayez de vous connecter avec la nouvelle configuration
3. **Résultat attendu** :
   - ✅ Connexion réussie sans erreur SSL
   - ✅ Vous êtes authentifié en tant que votre utilisateur (ex: `admin`)

### En cas d'erreur

**Erreur : "SSL error: PKIX path validation failed"**
- Le certificat CA n'est pas installé ou n'est pas le bon
- Solution : Réimportez le nouveau `ca.crt`

**Erreur : "Certificate CN does not match username"**
- Le Common Name (CN) du certificat ne correspond pas au nom d'utilisateur
- Solution : Utilisez le bon certificat client (ex: `client_admin.pfx` pour `admin`)

**Erreur : "Connection refused"**
- Le serveur PostgreSQL n'est pas accessible
- Solution : Vérifiez que le conteneur Docker est démarré et que le port 5434 est accessible

---

## Informations techniques

### Détails des certificats

**Certificat serveur (server.crt)** :
- Common Name (CN) : `percona_postgres_tde`
- Subject Alternative Names (SAN) :
  - DNS: `percona_postgres_tde`, `localhost`, `db`, `postgresql-secure.lgrdev.ovh`
  - IP: `127.0.0.1`, `94.23.5.104`

**Certificats clients** :
- Chaque certificat client a un CN correspondant au nom d'utilisateur PostgreSQL
- Exemples : CN=admin, CN=app_user, CN=backup_user, CN=app_developer

### Configuration PostgreSQL (pg_hba.conf)

```
hostssl all all 0.0.0.0/0 cert clientcert=verify-full map=cert_map
```

Cette configuration impose :
1. **SSL obligatoire** (`hostssl`)
2. **Certificat client obligatoire** (`clientcert=verify-full`)
3. **Mapping CN → utilisateur** via `pg_ident.conf`

---

## Sauvegarder vos certificats

**IMPORTANT** : Sauvegardez les fichiers suivants dans un endroit sûr :
- `ca.crt`
- `client_[votre_utilisateur].pfx` (protégé par mot de passe)
- Le mot de passe PFX (dans un gestionnaire de mots de passe)

Ces certificats sont valides 10 ans et ne doivent plus être régénérés (après application de la Phase 2 du plan de résolution).

---

## Besoin d'aide ?

Si vous rencontrez des problèmes :
1. Vérifiez que les conteneurs Docker sont démarrés : `docker compose ps`
2. Consultez les logs PostgreSQL : `docker logs percona_postgres_tde`
3. Vérifiez la connectivité réseau vers le port 5434
4. Assurez-vous que Traefik autorise les connexions depuis votre IP

**Contact** : Consultez le fichier README.md pour plus d'informations sur l'architecture.
