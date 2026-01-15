# Nextcloud + ONLYOFFICE auf Azure Container Apps (ACA) – One‑Click Deploy

Dieses Repo enthält ein IaC‑Deployment (Bicep + ARM JSON) für eine kleine Nextcloud‑Instanz (z. B. Verein: ~5 Nutzer) inklusive:
- **Azure Container Apps**: Nextcloud (production‑apache) + Redis + Cron
- **Azure Database for PostgreSQL Flexible Server** (Private Access / VNet Integration)
- **ONLYOFFICE Document Server** für **PDF‑Bearbeitung** im Browser
- **Azure Files** Persistenz
- **Kein ACR / kein Custom Image** (schnellster Weg)

> Hinweis: **Custom Domain + Managed Certificate** bindest du bewusst **nach dem Deploy** manuell im Portal (DNS CNAME/TXT erst möglich, wenn die App‑FQDN feststeht).

---

## 🚀 Deploy to Azure (Portal)

> **Wichtig:** Der Button funktioniert erst, wenn du dieses Repo auf GitHub liegen hast und die Dateien per **raw.githubusercontent.com** erreichbar sind.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FVertax1337%2Fnextcloud-azure%2Fmain%2Finfra%2Fazuredeploy.json)


### Was du ersetzen musst
Ersetze im Button‑Link oben:
- `REPLACE_WITH_RAW_TEMPLATE_JSON_URL` durch die **RAW‑URL** deiner `infra/azuredeploy.json`  
  Beispiel:
  ```
  https://raw.githubusercontent.com/<USER>/<REPO>/<BRANCH>/infra/azuredeploy.json
  ```

Optional kannst du auch eine deploy‑friendly Parameters-Datei nutzen:
- `infra/azuredeploy.v3.deployfriendly.parameters.json`  
  (setzt nur nicht‑sensitive Defaults; Secrets fragt das Portal dann ab)

Wenn du den Button direkt mit Parameters-Datei verlinken willst, nutze stattdessen:
```
https://portal.azure.com/#create/Microsoft.Template/uri/<RAW_JSON>?parameters=<RAW_PARAMETERS_JSON>
```

---

## 📦 Dateien im Repo

Empfohlene Struktur:
```
infra/
  azuredeploy.bicep
  azuredeploy.json
  azuredeploy.v3.deployfriendly.parameters.json
  azuredeploy.parameters.json   (optional, wenn du Werte fix hinterlegen willst)
```

---

## ✅ Nach dem Deploy (2–3 Minuten)

### 1) Custom Domain + Managed Certificate (manuell im Portal)
Für jede Container App (Nextcloud & ONLYOFFICE):
1. Container App → **Ingress** → Application URL (FQDN) merken
2. Container App → **Custom domains** → **Add**
3. DNS beim Provider setzen:
   - **CNAME** `cloud` → `<nc-fqdn>.azurecontainerapps.io`
   - **TXT** `asuid.cloud` → `<customDomainVerificationId>`
   - analog für `office`

Danach Managed Cert binden.

### 2) First Login / Trusted Domains
Wenn `NEXTCLOUD_TRUSTED_DOMAINS` auf `cloud.<domain>` gesetzt ist:
- **erst** Custom Domain binden,
- **dann** Nextcloud im Browser öffnen.

---

## 🔐 Secrets & Parameter (Portal-Formular)

Beim Deploy im Portal musst du u. a. setzen:
- Nextcloud Admin: `nextcloudAdminUser`, `nextcloudAdminPassword`
- Postgres: `postgresAdminUser`, `postgresAdminPassword`, `postgresDbName`
- ONLYOFFICE: `onlyofficeJwtSecret` (muss stabil sein, sonst bricht die Integration nach Updates)

---

## 🧰 Betrieb (kleiner Verein)
- Scale ist auf **1** ausgelegt (5 Nutzer)
- Updates: neue Revision in ACA erstellen (oder redeploy)
- Backup: DB + Files (Azure Files) regelmäßig sichern

---

## Lizenz / Haftung
Dieses Template ist eine technische Vorlage. Bitte prüfe Security‑Settings (MFA, Admin‑Zugänge, Backups) für euren Betrieb.
