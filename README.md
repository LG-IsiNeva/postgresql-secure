# 📄 PostgreSQL 17 avec TDE et mTLS Sécurisé

## 🚀 Vue d'ensemble

Instance **Percona Distribution for PostgreSQL 17** hautement sécurisée déployée avec Docker Compose.

### 🔒 Fonctionnalités de Sécurité

1. **Chiffrement Transparent des Données (TDE)**
   - Extension `pg_tde` de Percona
   - Chiffrement au repos de toutes les données sensibles
   - Gestion sécurisée des clés de chiffrement

2. **Authentification Mutuelle TLS (mTLS)**
   - TLS 1.3 obligatoire (protocoles faibles désactivés)
   - Chiffrements forts uniquement (AES-256-GCM, ChaCha20-Poly1305)
   - Authentification par certificat client obligatoire
   - Correspondance CN certificat ↔ utilisateur PostgreSQL
   - SSL obligatoire pour toutes les connexions réseau

3. **Gestion Sécurisée des Secrets**
   - Mots de passe générés aléatoirement (32 octets base64)
   - Docker Secrets pour l'isolation des credentials
   - Algorithme SCRAM-SHA-256 pour les hash de mots de passe

4. **Architecture Réseau Sécurisée**
   - Exposition via Traefik avec middleware de filtrage IP
   - Port personnalisable (défaut: 5434)
   - Réseau Docker isolé

### 📋 Prérequis

- Docker & Docker Compose v3.8+
- OpenSSL (pour la gestion des certificats)
- Réseau Traefik externe : `traefik_proxy`

---

## 🛠️ Installation et Configuration

### 1. Configuration Initiale

Le fichier `.env` contient toutes les variables de configuration :

```env
# PostgreSQL Configuration
PGPORT=5434
POSTGRES_USER=postgres
POSTGRES_DB=secure_db

# Certificats SSL/TLS
CERT_DIR=/etc/certs
DAYS_VALID=3650

# Utilisateurs à créer (séparés par des virgules)
# IMPORTANT: Ces noms seront utilisés comme CN dans les certificats
# et doivent correspondre aux noms d'utilisateurs PostgreSQL
CLIENT_NAMES=admin,app_user,backup_user

# Mot de passe pour les fichiers PFX/PKCS#12
PFX_PASSWORD=<généré_automatiquement>
```

**⚠️ IMPORTANT** : Les fichiers `secrets/postgres_password.txt` et `secrets/backup_encryption_pass.txt` contiennent des mots de passe sécurisés générés automatiquement. **Ne les commitez jamais dans Git !**

### 2. Création des Utilisateurs PostgreSQL

Avant de démarrer, vous devez créer les utilisateurs PostgreSQL correspondant aux noms dans `CLIENT_NAMES`. Créez le fichier `initdb/create_users.sql` :

```sql
-- Créer les utilisateurs correspondant aux certificats clients
CREATE USER admin WITH PASSWORD 'mot_de_passe_fort_1';
CREATE USER app_user WITH PASSWORD 'mot_de_passe_fort_2';
CREATE USER backup_user WITH PASSWORD 'mot_de_passe_fort_3';

-- Accorder les permissions appropriées
GRANT ALL PRIVILEGES ON DATABASE secure_db TO admin;
GRANT CONNECT ON DATABASE secure_db TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT CONNECT ON DATABASE secure_db TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
```

### 3. Démarrage des Services

```bash
# Démarrer les services (génération automatique des certificats)
docker-compose up -d

# Vérifier les logs
docker-compose logs -f cert_generator
docker-compose logs -f db
```

Le service `cert_generator` s'exécute en premier et génère :
- Une autorité de certification (CA)
- Un certificat serveur pour PostgreSQL
- Des certificats clients pour chaque utilisateur dans `CLIENT_NAMES`

-----

## 🔐 Gestion des Certificats et Clés

### A. Certificats Générés Automatiquement

Le script génère automatiquement tous les certificats nécessaires au démarrage :

| Fichier | Description | Utilisation |
|---------|-------------|-------------|
| `ca.crt` | Autorité de Certification racine | Valide les certificats serveur et clients |
| `ca.key` | Clé privée de la CA | **À protéger absolument** |
| `server.crt` | Certificat du serveur PostgreSQL | Authentification du serveur |
| `server.key` | Clé privée du serveur | **Permissions 600** |
| `client_<user>.crt` | Certificat client (un par utilisateur) | Authentification du client |
| `client_<user>.key` | Clé privée client | **À distribuer de manière sécurisée** |
| `client_<user>.pfx` | Format PKCS#12 pour Windows | Import facile sur Windows |

**⚠️ Sécurité des Clés Privées**
- Les fichiers `.key` et `.pfx` contiennent des clés privées
- Ne jamais les commiter dans Git (déjà dans `.gitignore`)
- Transférer uniquement via canaux sécurisés (SCP, SFTP, chiffrement)
- Les permissions sont automatiquement définies à 600

### B. Récupération des Certificats Clients

Pour copier les certificats depuis le container vers l'hôte :

```bash
# Copier tous les certificats
docker cp percona_postgres_tde:/etc/certs/. ./certs/

# Vérifier les certificats générés
ls -l certs/client_*.{crt,key,pfx}
```

### C. Connexion avec psql (Linux/Mac)

```bash
# Connexion avec l'utilisateur 'admin'
psql "host=localhost port=5434 dbname=secure_db user=admin \
      sslmode=verify-full \
      sslcert=certs/client_admin.crt \
      sslkey=certs/client_admin.key \
      sslrootcert=certs/ca.crt"

# Alternative avec variables d'environnement
export PGSSLMODE=verify-full
export PGSSLCERT=certs/client_admin.crt
export PGSSLKEY=certs/client_admin.key
export PGSSLROOTCERT=certs/ca.crt
psql -h localhost -p 5434 -U admin -d secure_db
```

### D. Installation des Certificats sur Windows

Pour utiliser mTLS depuis Windows, vous devez installer les certificats dans les magasins Windows appropriés.

#### Méthode 1 : Import via Interface Graphique (Recommandé pour tests)

**Étape 1 : Importer le certificat CA**
1. Double-cliquer sur `certs\ca.crt`
2. Cliquer sur "Installer le certificat..."
3. Sélectionner "Ordinateur local" (nécessite droits admin) ou "Utilisateur actuel"
4. Choisir "Placer tous les certificats dans le magasin suivant"
5. Parcourir → **Autorités de certification racines de confiance**
6. Suivant → Terminer

**Étape 2 : Importer le certificat client (.pfx)**
1. Double-cliquer sur `certs\client_admin.pfx` (remplacer `admin` par votre utilisateur)
2. Sélectionner "Utilisateur actuel"
3. Suivant → Entrer le mot de passe PFX (voir `.env` → `PFX_PASSWORD`)
4. Cocher "Marquer cette clé comme exportable" (optionnel, pour backup)
5. Choisir "Placer tous les certificats dans le magasin suivant"
6. Parcourir → **Personnel**
7. Suivant → Terminer

#### Méthode 2 : Import via PowerShell (Automatisé)

```powershell
# Variables de configuration
$PfxPassword = "2RwAQXP6EH9GS/Myqs+TvYa8UiE5DeGU"  # Remplacer par votre PFX_PASSWORD
$UserName = "admin"  # Nom d'utilisateur PostgreSQL

# 1. Importer la CA dans les autorités racines de confiance
Import-Certificate -FilePath "certs\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root

# 2. Importer le certificat client .pfx dans le magasin personnel
$SecurePassword = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
Import-PfxCertificate -FilePath "certs\client_$UserName.pfx" `
                      -CertStoreLocation Cert:\CurrentUser\My `
                      -Password $SecurePassword

# 3. Vérifier l'installation
Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object {$_.Subject -like "*PostgreSQL-TDE-CA*"}
Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {$_.Subject -like "*$UserName*"}
```

#### Méthode 3 : Import via certutil (Ligne de commande)

```powershell
# 1. Importer la CA (nécessite droits administrateur)
certutil -addstore -enterprise -f "Root" certs\ca.crt

# 2. Importer le certificat client
certutil -user -p "VOTRE_PFX_PASSWORD" -importpfx "Personal" certs\client_admin.pfx

# 3. Vérifier l'installation
certutil -user -store My
certutil -store Root | findstr "PostgreSQL-TDE-CA"
```

#### Test de Connexion depuis Windows

**Avec psql (si installé)**
```powershell
# Définir les variables d'environnement
$env:PGSSLMODE = "verify-full"
$env:PGSSLCERT = "certs\client_admin.crt"
$env:PGSSLKEY = "certs\client_admin.key"
$env:PGSSLROOTCERT = "certs\ca.crt"

# Se connecter
psql -h localhost -p 5434 -U admin -d secure_db
```

**Avec pgAdmin 4**
1. Créer un nouveau serveur
2. Onglet "Connexion" :
   - Nom d'hôte : `localhost`
   - Port : `5434`
   - Base de données : `secure_db`
   - Nom d'utilisateur : `admin`
3. Onglet "SSL" :
   - Mode SSL : `verify-full`
   - Certificat client : Parcourir → `certs\client_admin.crt`
   - Clé client : Parcourir → `certs\client_admin.key`
   - Certificat racine : Parcourir → `certs\ca.crt`

**Avec DBeaver**
1. Créer une nouvelle connexion PostgreSQL
2. Onglet "Main" :
   - Host : `localhost`
   - Port : `5434`
   - Database : `secure_db`
   - Username : `admin`
   - Password : (laisser vide pour authentification par certificat)
3. Onglet "Driver properties" :
   - Cliquer sur "Driver properties"
   - Ajouter/modifier les propriétés suivantes :
     - `ssl` = `true`
     - `sslmode` = `verify-full`
     - `sslcert` = `C:\path\to\certs\client_admin.crt`
     - `sslkey` = `C:\path\to\certs\client_admin.key`
     - `sslrootcert` = `C:\path\to\certs\ca.crt`
4. Onglet "SSL" (alternative) :
   - Cocher "Use SSL"
   - SSL mode : `verify-full`
   - SSL Factory : `org.postgresql.ssl.jdbc4.LibPQFactory`
   - Root certificate : Parcourir → `certs\ca.crt`
   - Client certificate : Parcourir → `certs\client_admin.crt`
   - Client certificate key : Parcourir → `certs\client_admin.key`
5. Tester la connexion avec "Test Connection"

**Note DBeaver** : Pour utiliser les fichiers de certificat, DBeaver nécessite parfois la conversion au format PEM. Les fichiers `.crt` et `.key` sont déjà au bon format. Si vous rencontrez des problèmes, vous pouvez aussi utiliser le fichier `.pfx` en le convertissant :

```powershell
# Extraire le certificat du .pfx
openssl pkcs12 -in certs\client_admin.pfx -nokeys -out certs\client_admin_dbeaver.crt

# Extraire la clé privée du .pfx
openssl pkcs12 -in certs\client_admin.pfx -nocerts -nodes -out certs\client_admin_dbeaver.key
```

### E. Configuration pour Applications .NET/C#

#### Option 1 : Utilisation du certificat .pfx (Recommandé)

```csharp
using Npgsql;
using System.Security.Cryptography.X509Certificates;

// Charger le certificat client depuis le fichier .pfx
var clientCert = new X509Certificate2(
    @"C:\path\to\certs\client_admin.pfx",
    "VOTRE_PFX_PASSWORD",
    X509KeyStorageFlags.UserKeySet
);

// Configuration de la connexion avec mTLS
var connString = new NpgsqlConnectionStringBuilder
{
    Host = "localhost",
    Port = 5434,
    Database = "secure_db",
    Username = "admin",

    // Configuration SSL/TLS
    SslMode = SslMode.VerifyFull,
    RootCertificate = @"C:\path\to\certs\ca.crt",

    // Timeout et performance
    Timeout = 30,
    CommandTimeout = 30,
    MaxPoolSize = 100
};

// Créer la connexion
using var dataSource = NpgsqlDataSourceBuilder
    .Create(connString.ToString())
    .UseClientCertificate(clientCert)
    .Build();

using var conn = await dataSource.OpenConnectionAsync();
Console.WriteLine("✓ Connexion mTLS réussie !");
```

#### Option 2 : Utilisation du magasin de certificats Windows

```csharp
using Npgsql;
using System.Security.Cryptography.X509Certificates;

// Récupérer le certificat depuis le magasin Windows
X509Certificate2 GetClientCertFromStore(string userName)
{
    var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
    store.Open(OpenFlags.ReadOnly);

    var certs = store.Certificates.Find(
        X509FindType.FindBySubjectName,
        userName,
        validOnly: true
    );

    store.Close();

    if (certs.Count == 0)
        throw new Exception($"Certificat pour '{userName}' introuvable dans le magasin");

    return certs[0];
}

// Configuration
var clientCert = GetClientCertFromStore("admin");
var connString = new NpgsqlConnectionStringBuilder
{
    Host = "localhost",
    Port = 5434,
    Database = "secure_db",
    Username = "admin",
    SslMode = SslMode.VerifyFull,
    RootCertificate = @"C:\path\to\certs\ca.crt"
};

using var dataSource = NpgsqlDataSourceBuilder
    .Create(connString.ToString())
    .UseClientCertificate(clientCert)
    .Build();

using var conn = await dataSource.OpenConnectionAsync();
```

#### Option 3 : String de connexion complète (Npgsql 6.0+)

```csharp
var connectionString =
    "Host=localhost;" +
    "Port=5434;" +
    "Database=secure_db;" +
    "Username=admin;" +
    "SSL Mode=VerifyFull;" +
    "Root Certificate=C:\\path\\to\\certs\\ca.crt;" +
    "Client Certificate=C:\\path\\to\\certs\\client_admin.crt;" +
    "Client Certificate Key=C:\\path\\to\\certs\\client_admin.key;";

using var conn = new NpgsqlConnection(connectionString);
await conn.OpenAsync();
```

#### Gestion des erreurs SSL/TLS courantes

```csharp
try
{
    await conn.OpenAsync();
    Console.WriteLine("✓ Connexion établie avec succès");
}
catch (NpgsqlException ex) when (ex.Message.Contains("certificate"))
{
    Console.WriteLine("❌ Erreur de certificat:");
    Console.WriteLine("  - Vérifiez que le certificat client est valide");
    Console.WriteLine("  - Vérifiez que le CN correspond au nom d'utilisateur");
    Console.WriteLine("  - Vérifiez que la CA est installée");
    Console.WriteLine($"  Détails: {ex.Message}");
}
catch (NpgsqlException ex) when (ex.Message.Contains("SSL"))
{
    Console.WriteLine("❌ Erreur SSL/TLS:");
    Console.WriteLine("  - Vérifiez que le serveur accepte TLS 1.2+");
    Console.WriteLine($"  Détails: {ex.Message}");
}
```

### F. Configuration IIS pour Applications Web ASP.NET

#### Prérequis
- Windows Server 2016+ ou Windows 10+
- IIS 10.0+
- .NET 6.0+ ou .NET Framework 4.8+
- Application pool configuré

#### Étape 1 : Importer les certificats sur le serveur

```powershell
# Exécuter en tant qu'administrateur

# 1. Importer la CA dans le magasin Machine (pas utilisateur)
certutil -addstore -enterprise -f "Root" "C:\path\to\certs\ca.crt"

# 2. Importer le certificat client dans le magasin Machine
$PfxPassword = ConvertTo-SecureString -String "VOTRE_PFX_PASSWORD" -Force -AsPlainText
Import-PfxCertificate -FilePath "C:\path\to\certs\client_app_user.pfx" `
                      -CertStoreLocation Cert:\LocalMachine\My `
                      -Password $PfxPassword `
                      -Exportable

# 3. Vérifier l'installation
Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object {$_.Subject -like "*app_user*"}
Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object {$_.Subject -like "*PostgreSQL-TDE-CA*"}
```

#### Étape 2 : Accorder les permissions à l'identité du pool d'applications

**Méthode 1 : Via MMC (Interface graphique)**
1. Ouvrir `certlm.msc` (Certificats - Ordinateur local)
2. Naviguer vers **Personnel** → **Certificats**
3. Trouver le certificat `client_app_user`
4. Clic droit → **Toutes les tâches** → **Gérer les clés privées**
5. Cliquer sur **Ajouter**
6. Entrer : `IIS AppPool\VotreNomDePoolApp` (exemple: `IIS AppPool\DefaultAppPool`)
7. Cocher **Lecture** et **Lecture et exécution**
8. OK → Appliquer

**Méthode 2 : Via PowerShell (Automatisé)**
```powershell
# Configuration
$AppPoolName = "DefaultAppPool"  # Remplacer par votre pool
$CertSubject = "CN=app_user"     # CN du certificat client

# Fonction pour accorder les permissions
function Grant-CertPermission {
    param(
        [string]$CertSubject,
        [string]$AppPoolIdentity
    )

    # Trouver le certificat
    $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object {$_.Subject -like "*$CertSubject*"} |
            Select-Object -First 1

    if (-not $cert) {
        throw "Certificat avec sujet '$CertSubject' introuvable"
    }

    # Obtenir le chemin de la clé privée
    $keyPath = $env:ProgramData + "\Microsoft\Crypto\RSA\MachineKeys\"
    $keyName = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
    $keyFullPath = $keyPath + $keyName

    # Accorder les permissions
    $acl = Get-Acl -Path $keyFullPath
    $permission = "IIS AppPool\$AppPoolIdentity", "Read", "Allow"
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.AddAccessRule($accessRule)
    Set-Acl -Path $keyFullPath -AclObject $acl

    Write-Host "✓ Permissions accordées à IIS AppPool\$AppPoolIdentity"
}

# Exécuter
Grant-CertPermission -CertSubject "app_user" -AppPoolIdentity $AppPoolName
```

#### Étape 3 : Configuration dans web.config ou appsettings.json

**appsettings.json**
```json
{
  "ConnectionStrings": {
    "PostgreSQL": "Host=localhost;Port=5434;Database=secure_db;Username=app_user;SSL Mode=VerifyFull;Trust Server Certificate=false"
  },
  "PostgreSQL": {
    "CertificateSettings": {
      "UseMachineCertStore": true,
      "ClientCertSubject": "CN=app_user",
      "RootCertPath": "C:\\inetpub\\certs\\ca.crt"
    }
  }
}
```

**Startup.cs / Program.cs (.NET 6+)**
```csharp
using Npgsql;
using System.Security.Cryptography.X509Certificates;

var builder = WebApplication.CreateBuilder(args);

// Configuration du certificat client
X509Certificate2 GetClientCertificate()
{
    var certSubject = builder.Configuration["PostgreSQL:CertificateSettings:ClientCertSubject"];
    var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);

    try
    {
        store.Open(OpenFlags.ReadOnly);
        var certs = store.Certificates.Find(
            X509FindType.FindBySubjectDistinguishedName,
            certSubject,
            validOnly: true
        );

        if (certs.Count == 0)
            throw new Exception($"Certificat '{certSubject}' introuvable");

        return certs[0];
    }
    finally
    {
        store.Close();
    }
}

// Configuration de Npgsql avec mTLS
var connectionString = builder.Configuration.GetConnectionString("PostgreSQL");
var clientCert = GetClientCertificate();
var rootCertPath = builder.Configuration["PostgreSQL:CertificateSettings:RootCertPath"];

var dataSourceBuilder = new NpgsqlDataSourceBuilder(connectionString);
dataSourceBuilder.UseClientCertificate(clientCert);
dataSourceBuilder.ConnectionStringBuilder.RootCertificate = rootCertPath;

builder.Services.AddSingleton(dataSourceBuilder.Build());

var app = builder.Build();
```

#### Étape 4 : Test et Vérification

**Test de connexion depuis l'application**
```csharp
[ApiController]
[Route("api/[controller]")]
public class HealthController : ControllerBase
{
    private readonly NpgsqlDataSource _dataSource;

    public HealthController(NpgsqlDataSource dataSource)
    {
        _dataSource = dataSource;
    }

    [HttpGet("database")]
    public async Task<IActionResult> CheckDatabase()
    {
        try
        {
            await using var conn = await _dataSource.OpenConnectionAsync();
            await using var cmd = new NpgsqlCommand(
                "SELECT version(), current_user, inet_server_addr(), " +
                "ssl_is_used() as ssl_active, ssl_version() as ssl_version, " +
                "ssl_cipher() as ssl_cipher",
                conn
            );

            await using var reader = await cmd.ExecuteReaderAsync();
            await reader.ReadAsync();

            return Ok(new
            {
                Version = reader.GetString(0),
                User = reader.GetString(1),
                ServerIP = reader.GetValue(2).ToString(),
                SslActive = reader.GetBoolean(3),
                SslVersion = reader.GetString(4),
                SslCipher = reader.GetString(5),
                Status = "Connected with mTLS"
            });
        }
        catch (Exception ex)
        {
            return StatusCode(500, new { Error = ex.Message });
        }
    }
}
```

#### Dépannage IIS

**Vérifier les événements Windows**
```powershell
# Logs d'application IIS
Get-EventLog -LogName Application -Source "ASP.NET*" -Newest 20

# Logs système liés aux certificats
Get-EventLog -LogName System | Where-Object {$_.Message -like "*certificat*"} | Select-Object -First 10
```

**Vérifier les permissions effectives**
```powershell
$AppPoolName = "DefaultAppPool"
$CertSubject = "app_user"

$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {$_.Subject -like "*$CertSubject*"}
$keyPath = $env:ProgramData + "\Microsoft\Crypto\RSA\MachineKeys\" + $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName

Get-Acl $keyPath | Format-List
```

**Activer les logs détaillés Npgsql**
```csharp
// Dans Program.cs
builder.Logging.AddFilter("Npgsql", LogLevel.Debug);
NpgsqlLoggingConfiguration.InitializeLogging(builder.Services.BuildServiceProvider().GetService<ILoggerFactory>());
```

-----

## 💾 Opérations de Sauvegarde et Restauration

Les scripts de sauvegarde chiffrent les dumps avec AES-256-CBC pour la sécurité au repos.

### 1. Sauvegarde Chiffrée

```bash
# Exécuter une sauvegarde chiffrée
docker exec -it percona_postgres_tde /usr/local/bin/backup.sh

# Les fichiers sont créés dans ./backups/ sur l'hôte
# Format: secure_db_YYYYMMDD_HHMMSS.dump.enc
```

### 2. Restauration Chiffrée

```bash
# Lister les sauvegardes disponibles
ls -lh backups/

# Restaurer une sauvegarde spécifique
docker exec -it percona_postgres_tde \
  /usr/local/bin/restore.sh /backups/secure_db_20231215_103045.dump.enc
```

**Note** : Le mot de passe de chiffrement est stocké dans `secrets/backup_encryption_pass.txt`

---

## 🔍 Vérification de la Sécurité

### Vérifier la Configuration SSL/TLS

```bash
# Vérifier que SSL est activé
docker exec percona_postgres_tde \
  psql -U postgres -c "SHOW ssl;"

# Vérifier la version TLS minimum
docker exec percona_postgres_tde \
  psql -U postgres -c "SHOW ssl_min_protocol_version;"

# Vérifier les chiffrements autorisés
docker exec percona_postgres_tde \
  psql -U postgres -c "SHOW ssl_ciphers;"
```

### Tester la Connexion mTLS

```bash
# Test avec certificat valide (doit réussir)
psql "host=localhost port=5434 dbname=secure_db user=admin \
      sslmode=verify-full \
      sslcert=certs/client_admin.crt \
      sslkey=certs/client_admin.key \
      sslrootcert=certs/ca.crt" \
  -c "SELECT current_user, inet_server_addr(), inet_server_port();"

# Test sans certificat (doit échouer)
psql "host=localhost port=5434 dbname=secure_db user=admin \
      sslmode=require" \
  -c "SELECT 1;"
# Erreur attendue: FATAL: connection requires a valid client certificate
```

### Vérifier le Chiffrement TDE

```bash
# Vérifier que pg_tde est chargé
docker exec percona_postgres_tde \
  psql -U postgres -c "SHOW shared_preload_libraries;"

# Vérifier la configuration du keyring
docker exec percona_postgres_tde \
  psql -U postgres -c "SHOW pg_tde.keyring_file;"
```

---

## 🛡️ Bonnes Pratiques de Sécurité

### 1. Gestion des Certificats

- ✅ Régénérer les certificats avant expiration (voir `DAYS_VALID`)
- ✅ Utiliser des certificats différents par environnement (dev/staging/prod)
- ✅ Révoquer immédiatement les certificats compromis
- ✅ Conserver la CA dans un lieu hautement sécurisé (offline si possible)

### 2. Rotation des Secrets

```bash
# Générer un nouveau mot de passe PostgreSQL
openssl rand -base64 32 > secrets/postgres_password.txt

# Générer un nouveau mot de passe de sauvegarde
openssl rand -base64 32 > secrets/backup_encryption_pass.txt

# Redémarrer le service
docker-compose restart db
```

### 3. Monitoring et Logs

```bash
# Surveiller les tentatives de connexion échouées
docker exec percona_postgres_tde \
  grep "FATAL" /var/lib/postgresql/data/log/postgresql-*.log

# Surveiller les connexions SSL
docker exec percona_postgres_tde \
  psql -U postgres -c "SELECT datname, usename, ssl, client_addr FROM pg_stat_ssl JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid;"
```

### 4. Firewall et Réseau

Le service est exposé via Traefik avec middleware de filtrage IP. Pour modifier les IP autorisées, éditez la configuration Traefik :

```yaml
# Dans votre configuration Traefik
middlewares:
  tcpSecureByIp:
    ipWhiteList:
      sourceRange:
        - "10.0.0.0/8"
        - "192.168.1.0/24"
```

---

## 📊 Architecture de Sécurité

```
┌─────────────────────────────────────────────────────────────┐
│                    CLIENT APPLICATION                       │
│  - Certificat client (client_user.crt + .key)               │
│  - CA pour vérifier le serveur (ca.crt)                     │
│  - TLS 1.3 avec chiffrements forts                          │
└────────────────────┬────────────────────────────────────────┘
                     │ mTLS (port 5434)
                     │
┌────────────────────▼────────────────────────────────────────┐
│                      TRAEFIK PROXY                          │
│  - Middleware de filtrage IP (tcpSecureByIp)                │
│  - Load balancing                                           │
└────────────────────┬────────────────────────────────────────┘
                     │
┌────────────────────▼───────────────────────────────────────┐
│               PERCONA POSTGRESQL 17                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Couche SSL/TLS                                       │  │
│  │ - Vérification certificat client (verify-full)       │  │
│  │ - Validation CN = nom utilisateur PostgreSQL         │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Couche Authentification                              │  │
│  │ - SCRAM-SHA-256 (pour connexions locales)            │  │
│  │ - Authentification par certificat (pour mTLS)        │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Couche Chiffrement (pg_tde)                          │  │
│  │ - Chiffrement transparent au repos                   │  │
│  │ - Keyring sécurisé (/data/db/pg_tde_keyring)         │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Stockage                                             │  │
│  │ - Données chiffrées sur disque                       │  │
│  │ - Volume Docker persistant                           │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

---

## 🚨 Dépannage

### Erreur: "connection requires a valid client certificate"

**Cause** : Le client ne fournit pas de certificat ou le certificat est invalide.

**Solution** :
```bash
# Vérifier que les fichiers existent
ls -l certs/client_admin.{crt,key}

# Vérifier les permissions
chmod 600 certs/client_admin.key
chmod 644 certs/client_admin.crt

# Vérifier la validité du certificat
openssl x509 -in certs/client_admin.crt -text -noout | grep -A2 "Validity"
```

### Erreur: "certificate verify failed"

**Cause** : La CA n'est pas reconnue ou le certificat serveur est invalide.

**Solution** :
```bash
# Vérifier la chaîne de certificats
openssl verify -CAfile certs/ca.crt certs/server.crt
openssl verify -CAfile certs/ca.crt certs/client_admin.crt
```

### Erreur: "FATAL: no pg_hba.conf entry"

**Cause** : Le Common Name (CN) du certificat ne correspond pas au nom d'utilisateur.

**Solution** :
```bash
# Vérifier le CN du certificat
openssl x509 -in certs/client_admin.crt -subject -noout
# Doit afficher: subject=C=FR, ST=IDF, L=Paris, O=PostgreSQL-TDE, OU=Clients, CN=admin

# S'assurer que l'utilisateur PostgreSQL existe
docker exec percona_postgres_tde \
  psql -U postgres -c "\du admin"
```

---

## 📝 Changelog

### Version 2.0 (Actuelle)
- ✨ Migration vers Percona PostgreSQL 17.6-1
- ✨ TLS 1.3 obligatoire avec chiffrements modernes
- ✨ Authentification mTLS avec verify-full
- ✨ Génération automatique de mots de passe sécurisés (32 octets)
- ✨ Support multi-utilisateurs avec certificats dédiés
- ✨ Documentation complète sur la sécurité
- 🔒 Désactivation de tous les protocoles/chiffrements faibles

---

## 📚 Ressources

- [Documentation Percona PostgreSQL](https://docs.percona.com/postgresql/)
- [pg_tde Extension](https://docs.percona.com/postgresql/17/tde.html)
- [PostgreSQL SSL Documentation](https://www.postgresql.org/docs/17/ssl-tcp.html)
- [Client Certificate Authentication](https://www.postgresql.org/docs/17/auth-cert.html)

---

## 📄 Licence

Ce projet est fourni à des fins éducatives et de démonstration. Adaptez la configuration de sécurité selon vos besoins spécifiques.