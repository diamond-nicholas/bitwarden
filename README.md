# bitwarden

This shows exactly what i have done to get this setup

Steps
1. Created a t3.medium ec2 instance in aws 
2. SG inbound with port 22 for my ip, port 80 and 443 from anywhere
3. Created an elastic ip and allocated it to the instance so we have a static public ip that doesnt change
4. created a free sub-domain in https://www.duckdns.org/domains and called it http://nick-vault.duckdns.org/
5. Pointed the ip in the subdomain to the instance
6. tested and ensured it resolved to the elastic ip addr
7. Went through the documentation to install docker and compose and also install and run the bitwarden script https://bitwarden.com/en-gb/help/install-on-premise-linux/#install-docker-and-docker-compose
8. Within the installation few interactive questions were asked
9. I used let's encrypt and when i was asked for installation id and key
10. I was able to retrieve the installation id and key from here https://bitwarden.com/host/ by passing the email i used to register
11. To setup smtp i created a free account with https://mailtrap.io/home
12. In the instance there is a bitwarden shell script and an env i need to pass details of the smtp server so it runs well




# Bitwarden Self-Hosted — Technical Assessment

This repository documents how I deployed a self-hosted Bitwarden server on AWS, configured SMTP, and (bonus) synced users and groups from Okta using the Bitwarden Directory Connector.

| | |
|---|---|
| **Vault URL** | https://nick-vault.duckdns.org |
| **Platform** | AWS EC2 (`t3.medium`, Amazon Linux 2023, x86_64) |
| **TLS** | Let's Encrypt (issued and managed by the Bitwarden installer) |
| **SMTP** | Mailtrap Email Sandbox (STARTTLS on port 587) |
| **Directory sync** | Okta → Bitwarden Directory Connector (Enterprise trial license) |
| **Versions** | `bitwarden.sh` 2026.9.2 · Docker 25.0.14 · Docker Compose v5.6.0 |

---

## Table of contents

1. [Architecture](#1-architecture)
2. [Infrastructure (AWS)](#2-infrastructure-aws)
3. [DNS and network validation](#3-dns-and-network-validation)
4. [Docker and Docker Compose](#4-docker-and-docker-compose-amazon-linux-2023)
5. [Bitwarden service account](#5-bitwarden-service-account-and-directory)
6. [Bitwarden installation](#6-bitwarden-installation)
7. [SMTP configuration](#7-smtp-configuration)
8. [Account creation and email proof](#8-account-creation-and-email-proof)
9. [Bonus: Directory Connector with Okta](#9-bonus-directory-connector-with-okta)
10. [Security hardening](#10-security-hardening)
11. [Issues encountered and resolutions](#11-issues-encountered-and-resolutions)
12. [Production recommendations](#12-production-recommendations)

---

## 1. Architecture

```
                    ┌──────────────────────────┐
  Users / Clients ──►  nick-vault.duckdns.org  │  DuckDNS A record → Elastic IP
                    └────────────┬─────────────┘
                                 │ 80 (ACME + redirect) / 443 (HTTPS)
                    ┌────────────▼─────────────────────────────────┐
                    │ AWS EC2 t3.medium — Amazon Linux 2023        │
                    │ Security Group: 22 (my IP), 80, 443          │
                    │                                              │
                    │  /opt/bitwarden  (owner: bitwarden, 700)     │
                    │  └─ Docker Compose stack                     │
                    │     nginx · web · api · identity · admin ·   │
                    │     sso · events · icons · notifications ·   │
                    │     attachments · mssql                      │
                    └────────────┬───────────────────┬─────────────┘
                                 │ SMTP 587/STARTTLS │ HTTPS (license, push)
                    ┌────────────▼──────┐   ┌────────▼───────────────┐
                    │ Mailtrap Sandbox  │   │ Bitwarden cloud        │
                    └───────────────────┘   │ (installation ID/key)  │
                                            └────────────────────────┘

  Okta (IdP) ──► Directory Connector (admin laptop) ──► Self-hosted org API (HTTPS)
```

---

## 2. Infrastructure (AWS)

1. **EC2 instance:** launched a `t3.medium` (2 vCPU / 4 GB RAM) with Amazon Linux 2023 (x86_64) and a 30 GB gp3 root volume.
   - Bitwarden's minimum is 2 GB RAM; 4 GB gives headroom for the bundled MSSQL container.
   - I chose x86_64 over Graviton to avoid container-architecture issues.
2. **Security group (`bitwarden-sg`):**

   | Port | Protocol | Source | Purpose |
   |---|---|---|---|
   | 22 | TCP | My public IP (`/32`) | SSH administration only |
   | 80 | TCP | `0.0.0.0/0` | Let's Encrypt HTTP-01 challenge and HTTP→HTTPS redirect |
   | 443 | TCP | `0.0.0.0/0` | Bitwarden web vault, API and clients |

3. **Elastic IP:** allocated one and associated it with the instance, so the public IP survives stop/start and the DNS record stays valid.

---

## 3. DNS and network validation

1. Created a free subdomain at [DuckDNS](https://www.duckdns.org): **`nick-vault.duckdns.org`**.
2. Pointed the subdomain's A record to the Elastic IP. No AAAA (IPv6) record is set; a stray AAAA record can cause Let's Encrypt validation to fail.
3. **Validated resolution** from both inside the instance and my laptop:

   ```bash
   # Domain → IP
   dig +short nick-vault.duckdns.org
   dig +short AAAA nick-vault.duckdns.org   # expect empty

   # Instance public IP (IMDSv2)
   TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
     -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
   curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
     http://169.254.169.254/latest/meta-data/public-ipv4
   ```

   Both returned the Elastic IP.

4. **Validated end-to-end reachability on port 80.** I started a temporary listener, tested from my laptop, then stopped it so port 80 was free for Let's Encrypt:

   ```bash
   # On the instance
   sudo python3 -m http.server 80

   # From my laptop
   curl -I http://nick-vault.duckdns.org    # → HTTP/1.0 200 OK
   ```

---

## 4. Docker and Docker Compose (Amazon Linux 2023)

Bitwarden's guide links to Docker's official install pages, which don't cover Amazon Linux. On AL2023, Docker comes from `dnf`, but **the Compose v2 plugin is not packaged**, and `bitwarden.sh` requires `docker compose`. So I installed the plugin manually:

```bash
sudo dnf update -y
sudo dnf install -y docker
sudo systemctl enable --now docker

sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

docker --version
docker compose version
```

---

## 5. Bitwarden service account and directory

Following Bitwarden's guidance, the stack runs under a dedicated, unprivileged service account rather than `root` or `ec2-user`:

```bash
sudo adduser bitwarden
sudo usermod -aG docker bitwarden        # Docker access only, no sudo
sudo mkdir /opt/bitwarden
sudo chmod -R 700 /opt/bitwarden
sudo chown -R bitwarden:bitwarden /opt/bitwarden

# Lock the password: no direct login or brute-force surface.
# The account is only reachable via sudo from an admin user.
sudo passwd -l bitwarden

# Switch with a full login shell (sets HOME, PATH, and group membership)
sudo -iu bitwarden
cd /opt/bitwarden
docker ps    # confirms Docker access without sudo
```

The `bitwarden` user is intentionally **not** in sudoers (least privilege).

---

## 6. Bitwarden installation

1. **Installation ID and key:** retrieved from https://bitwarden.com/host using my email, selecting the **same data region as my Bitwarden cloud account**. The region must match for license downloads to work later.
2. **Downloaded and ran the installer** as the `bitwarden` user from `/opt/bitwarden`:

   ```bash
   curl -Lso bitwarden.sh "https://func.bitwarden.com/api/dl/?app=self-host&platform=linux" \
     && chmod 700 bitwarden.sh
   ./bitwarden.sh install
   ```

3. **Installer prompts and answers:**

   | Prompt | Answer |
   |---|---|
   | Domain name | `nick-vault.duckdns.org` |
   | Use Let's Encrypt? | `y` |
   | Email for Let's Encrypt | personal email (used for expiry notices only) |
   | Database name | `vault` |
   | Region | matched to my cloud account |
   | Installation ID / Key | from bitwarden.com/host |

4. **Started the stack and verified it:**

   ```bash
   ./bitwarden.sh start
   docker ps    # all bitwarden-* containers healthy
   ```

   `https://nick-vault.duckdns.org` loads with a valid Let's Encrypt certificate, and HTTP redirects to HTTPS.

---

## 7. SMTP configuration

I used the **Mailtrap Email Sandbox**. It accepts mail over authenticated SMTP and captures it in a web inbox instead of delivering it to real recipients, which is ideal for testing.

Mailtrap supports **STARTTLS on all ports**, where the connection starts in plain text and is upgraded to TLS. In Bitwarden, `smtp__ssl=true` means *implicit* TLS, so the correct setting is **`ssl=false` with port 587**. The session is still encrypted via STARTTLS.

I edited `./bwdata/env/global.override.env`, replacing the existing placeholder lines rather than appending duplicates:

```ini
globalSettings__mail__replyToEmail=no-reply@nick-vault.duckdns.org
globalSettings__mail__smtp__host=sandbox.smtp.mailtrap.io
globalSettings__mail__smtp__port=587
globalSettings__mail__smtp__ssl=false
globalSettings__mail__smtp__username=<redacted>
globalSettings__mail__smtp__password=<redacted>
adminSettings__admins=<admin email>
```

Then I applied the change:

```bash
./bitwarden.sh restart    # env changes need a restart; config.yml changes need ./bitwarden.sh rebuild
```

**Verification:** I requested a login link at `https://nick-vault.duckdns.org/admin`. The "Admin Login" email arrived in the Mailtrap sandbox, confirming SMTP works end to end.

---

## 8. Account creation and email proof

1. Created a new account on the self-hosted vault via **Create account**.
2. The server sent the verification email and then the **Welcome to Bitwarden!** email, both captured in Mailtrap:
   - **From:** `Bitwarden <no-reply@nick-vault.duckdns.org>`
   - **Subject:** Welcome to Bitwarden!

The sender domain proves the mail originated from the self-hosted server.

📸 `screenshots/01-welcome-email.png`

---

## 9. Bonus: Directory Connector with Okta

**Purpose:** enterprises manage identities centrally. The Directory Connector keeps Bitwarden organization membership in sync with the IdP:
- new hires are invited automatically
- IdP groups map to Bitwarden groups and collections
- disabled or removed users lose access on the next sync

### 9.1 Licensing
1. Created a Bitwarden cloud account and a **Free organization**, and shared the account email and org name with Bitwarden to be upgraded to an **Enterprise trial**.
2. In the cloud org, went to **Admin Console → Billing → Subscription → Download license** and entered my self-hosted **Installation ID**.
3. On the self-hosted vault, went to **New organization** and **uploaded the license file**. This creates a self-hosted org with Enterprise features.

### 9.2 Organization API key
In the self-hosted org, went to **Admin Console → Settings → Organization info → View API key** and copied the `client_id` and `client_secret` for the Directory Connector.

### 9.3 Okta
1. Created an Okta Integrator (free developer) org.
2. Added test users under **Directory → People** and groups (e.g. `Engineering`, `Security`) under **Directory → Groups**, then assigned members.
3. Created an API token under **Security → API → Tokens**.
   - The token inherits its creator's privileges. In production I'd create it from a dedicated **read-only admin** service account.

### 9.4 Directory Connector
1. Installed the Directory Connector desktop app.
2. Set the **self-hosted server URL** to `https://nick-vault.duckdns.org` before logging in.
3. Logged in with the **organization API key**.
4. Directory settings: type **Okta**, plus the Okta org URL and API token.
5. Sync settings: **Users** and **Groups** enabled, with an optional group filter (e.g. `include:Engineering,Security`).
6. Ran **Test sync** to preview the results, then **Sync now**.

### 9.5 Result
Okta users appear in **Admin Console → Members** with status **Invited**, and their groups appear under **Groups**. Invitation emails are delivered through the configured SMTP and are visible in Mailtrap.

📸 `screenshots/02-directory-connector-config.png` (token redacted)
📸 `screenshots/03-org-members.png`
📸 `screenshots/04-org-groups.png` (optional)

---

## 10. Security hardening

**Applied**
- SSH (22) restricted to a single `/32` source; HTTP/HTTPS are the only public ports.
- Dedicated, unprivileged `bitwarden` service account with no sudo and a locked password.
- `/opt/bitwarden` owned by `bitwarden` with mode `700`; installed as non-root, per Bitwarden guidance.
- Publicly trusted TLS via Let's Encrypt with automatic renewal through the Bitwarden stack.
- IMDSv2 used for instance metadata.

**Applied once test accounts were created**
- Open registration disabled:
  ```ini
  globalSettings__disableUserRegistration=true
  ```
  followed by `./bitwarden.sh restart`. Users now join through invitations or directory sync only.

---

## 11. Issues encountered and resolutions

| Issue | Cause | Resolution |
|---|---|---|
| `curl` to port 80 failed with "Could not connect" | Nothing was listening; the security group was correct (a fast refusal, not a timeout) | Started a temporary listener (`python3 -m http.server 80`) to test, then stopped it before installing |
| HTTPS "can't be reached" / HTTP "Not secure" before install | No certificate or TLS listener existed yet | Expected; resolved by the installer's Let's Encrypt step |
| `ls: Permission denied` and `bitwarden.sh: Permission denied` as `bitwarden` | `su bitwarden` kept the working directory at `/home/ec2-user` | Used `sudo -iu bitwarden` and `cd /opt/bitwarden` |
| `bitwarden is not in the sudoers file` | By design: the service account has no sudo | No change; Docker access comes via the `docker` group |
| `groupadd docker` succeeded silently | Docker wasn't installed yet | Installed Docker and the Compose plugin before running the installer |
| Compose missing on Amazon Linux 2023 | The Compose v2 plugin isn't in AL2023 repos | Installed the plugin binary into `/usr/local/lib/docker/cli-plugins` |
| Bitwarden emails not appearing in Gmail | The Mailtrap sandbox captures mail rather than delivering it | Checked the Mailtrap sandbox inbox |

---

## 12. Production recommendations

This deployment was built manually to follow Bitwarden's documented process. For production I would:

- **Codify the infrastructure in Terraform:**
  - VPC with a private subnet for the instance, fronted by an ALB or NLB
  - TLS via ACM or Let's Encrypt
  - no public SSH; administer via **SSM Session Manager** instead
  - security groups, Elastic IP/DNS (Route 53), encrypted EBS volumes, and IAM instance profiles
  - bootstrap with cloud-init (Docker, Compose plugin, `bitwarden` user, `/opt/bitwarden`)
- **Manage secrets** (SMTP credentials, installation key) in AWS Secrets Manager or SSM Parameter Store, rendered into `global.override.env` at deploy time rather than stored in plain text.
- **Use production SMTP** (e.g. Amazon SES, SendGrid or Mailgun) with SPF, DKIM and DMARC configured for the sending domain.
- **Back up and recover:**
  - nightly backups of `bwdata` and the MSSQL database (Bitwarden's built-in backups in `bwdata/mssql/backups`)
  - EBS snapshots via AWS Backup
  - off-instance, encrypted copies
  - periodic restore tests
- **Consider an external database** (managed MSSQL / RDS) for larger deployments, or the Bitwarden Lite single-container option for small ones.
- **Monitor and log:** CloudWatch agent for host metrics and container logs, alarms on disk, memory and certificate expiry, and uptime checks on `/alive`.
- **Patch and update:** OS patching via SSM Patch Manager, plus a regular Bitwarden update cadence (`./bitwarden.sh updateself && ./bitwarden.sh update`) with a pre-update backup.
- **Strengthen identity:** SSO (SAML/OIDC with Okta) alongside Directory Connector, with trusted devices or Key Connector depending on customer requirements, and enforced org policies (2FA, master password requirements).
- **Choose TLS to fit the environment:** a private CA for internal or air-gapped deployments, distributing the CA to clients such as the Directory Connector (`NODE_EXTRA_CA_CERTS`).
