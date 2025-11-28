# Notify Defender KPIs (Azure Logic App)

This project contains:

- An **ARM template** that deploys:
  - A Logic App that sends a **daily Microsoft 365 Defender KPI email**
  - An Azure Monitor **Workbook** to configure which workloads are included and who receives the email
  - API connections to **Office 365 Outlook** and **Security Copilot** (optional)
- A **PowerShell script** to grant the required permissions to the Logic App's managed identity
- Documentation and screenshots to help you get started

---

## Features

- 📧 Daily KPI email including:
  - Defender for Endpoint coverage and alert volume
  - Devices without telemetry
  - Vulnerability posture (high exposure, public exploits, zero-day/no-fix exposure)
  - Top machines by alert volume
  - Top users by alert / phishing volume
  - SOC operations KPI (incidents closed within SLA)
- 🧩 Optional **Security Copilot** sections:
  - Top threats based on exposure scores
  - SOC risk themes and recommendations
- 🛠️ Workbook-driven configuration:
  - Enable/disable MDE, MDI, MDO, MDA, unified Sentinel, Copilot
  - Configure destination mailboxes via ARM tags on the Logic App

---

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fzeta-codes%2Fnotify-defender-kpis%2Frefs%2Fheads%2Fmain%2Ftemplates%2Fnotify-defender-kpis.json)

---

## Quick Deploy

1. Click **Deploy to Azure** above.
2. Choose **Subscription** and **Resource Group**.
3. Fill in the parameters (see below).
4. Click **Review + create → Create**.
5. Run the **permissions script** and complete post-deploy steps.

---

### Parameters

| Parameter                      | Example / Default        | Description                                                                 |
|--------------------------------|--------------------------|-----------------------------------------------------------------------------|
| `logicApp_name`                | `NotifyDefenderKPIs`     | Name of the Logic App workflow.                                            |
| `office365_connection_name`    | `office365-conn`         | Name of the Office 365 Outlook connection resource.                        |
| `securitycopilot_connection_name` | `securitycopilot-conn` | Name of the Security Copilot connection resource (optional if unused).     |
| `destinationMail`              | `soc@contoso.com;secops@contoso.com` | Semicolon-separated list of recipient email addresses for the KPI email. |

---

## Repository structure

```text
templates/
  notify-defender-kpis.json          # Main ARM template

scripts/
  Assign-LogicAppPermissions.ps1     # Grants permissions to the Logic App MI

docs/
  images/
    workbook-overview.png            # Workbook screenshots
    email-sample.png                 # Example email output

README.md
LICENSE
