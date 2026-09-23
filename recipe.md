# 2-Way Email Inbox Demo

## Overview

This recipe builds an interactive 2-way email inbox demo that simulates a prospect receiving a branded sales outreach email and replying inside a Gmail-like UI. An AI agent powered by Einstein LLM reads each reply and responds with substantive, knowledge-grounded answers drawn from an embedded product knowledge base. When the prospect requests a meeting, the agent offers calendar slots, books an Event + Prep Task on the salesperson's calendar in Salesforce, and hands off with an AI-generated engagement summary. If the prospect asks for a live agent, the Case escalates to Omni-Channel.

The demo runs entirely on a Salesforce org — no external servers, no third-party APIs beyond Einstein LLM. It's hosted on a public Salesforce Site so anyone with the URL can use it without a Salesforce login.

## Prerequisites

### Required Connections
- Salesforce org with **System Administrator** access (SDO or scratch org)

### Org Features (must be enabled before deployment)
- **Einstein Generative AI** — Setup → Einstein → Einstein Generative AI → Turn On
- **Enhanced Email** — Setup → Enhanced Email → Enable (makes the `EmailMessage` object available)
- **Salesforce Sites** — Setup → Sites → Register your My Domain for Sites if not already done
- **Omni-Channel** (optional) — only needed if you want live agent escalation routing

### Information Needed at Deploy Time
The recipe uses placeholders that must be replaced during deployment. Collect these from the user before starting:

| Placeholder | Description | Example |
|---|---|---|
| `{{COMPANY_NAME}}` | The fictional company running the demo (seller) | NexGen Networks |
| `{{COMPANY_TAGLINE}}` | Short tagline for the seller | Empowering Connected Business |
| `{{COMPANY_ADDRESS}}` | HQ address for email footer | 2100 Innovation Drive, Austin, TX 78701 |
| `{{AGENT_NAME}}` | The AI agent's display name | NexGen Discovery Agent |
| `{{AGENT_EMAIL}}` | The AI agent's from-address | outreach@nexgen-demo.invalid |
| `{{PROSPECT_NAME}}` | Full name of the prospect persona | James Wu |
| `{{PROSPECT_FIRST_NAME}}` | First name only | James |
| `{{PROSPECT_INITIALS}}` | Two-letter initials for avatar | JW |
| `{{PROSPECT_EMAIL}}` | Prospect's email address | james.wu@pinnacle-retail.example |
| `{{PROSPECT_COMPANY}}` | Prospect's organization name | Pinnacle Retail Group |
| `{{PROSPECT_TITLE}}` | Prospect's job title | IT Director |
| `{{THREAD_PREFIX}}` | Thread ID prefix for Case tagging (3-4 chars + hyphen) | NGN- |
| `{{THREAD_ID}}` | Default demo thread ID | NGN-DEMO01 |
| `{{SUBJECT_LINE}}` | Email subject line | James, See How NexGen Can Transform Your Multi-Site Network |
| `{{AE_NAME}}` | Account Executive name | Jennifer Park |
| `{{AE_TITLE}}` | AE's title | Account Executive, NexGen Networks |
| `{{AE_EMAIL}}` | AE's email address | jennifer.park@nexgen-demo.invalid |
| `{{AE_INITIALS}}` | AE's two-letter initials | JP |
| `{{ESCALATION_QUEUE}}` | DeveloperName of the Omni-Channel queue | NGN_Escalations |
| `{{PRIMARY_COLOR}}` | Brand primary color (hex) | #0D9488 |
| `{{DARK_COLOR}}` | Brand dark/navy color (hex) | #0F172A |
| `{{ACCENT_COLOR}}` | Brand accent/highlight color (hex) | #5EEAD4 |
| `{{KNOWLEDGE_BASE}}` | Full product knowledge base text (see Customization section) | (see below) |
| `{{INITIAL_EMAIL_HTML}}` | Branded HTML for the initial outreach email | (see below) |

## Source Files

All files are in `force-app/main/default/`:

| File | Purpose |
|---|---|
| `classes/InboxBridgeApi.cls` | REST API backend — all endpoints |
| `classes/InboxBridgeApi.cls-meta.xml` | API version metadata |
| `classes/AgentReplyService.cls` | AI reply engine + knowledge base |
| `classes/AgentReplyService.cls-meta.xml` | API version metadata |
| `classes/InboxBridgeApiTest.cls` | Test class |
| `classes/InboxBridgeApiTest.cls-meta.xml` | API version metadata |
| `triggers/EmailMessageReplyTrigger.trigger` | Trigger on inbound EmailMessage |
| `triggers/EmailMessageReplyTrigger.trigger-meta.xml` | Trigger metadata |
| `pages/InboxDemo.page` | Gmail-like inbox Visualforce page |
| `pages/InboxDemo.page-meta.xml` | Page metadata |
| `staticresources/InboxAssets/app.js` | Frontend JavaScript |
| `staticresources/InboxAssets/styles.css` | Gmail-like CSS styles |
| `staticresources/InboxAssets.resource-meta.xml` | Static resource metadata |
| `sites/InboxBridge.site-meta.xml` | Salesforce Site definition |
| `objects/LLM_Config__c/LLM_Config__c.object-meta.xml` | Custom Setting definition |
| `objects/LLM_Config__c/fields/Admin_Session__c.field-meta.xml` | Admin session token field |
| `objects/LLM_Config__c/fields/Instance_URL__c.field-meta.xml` | Instance URL field |

## Steps

### Step 1: Collect Configuration from the User

Before touching any files, prompt the user for every placeholder value listed in the "Information Needed" table above. Two placeholders require special handling:

- **`{{KNOWLEDGE_BASE}}`** — This is the entire product knowledge base the AI agent uses to answer questions. It should be a multi-paragraph text covering: company overview, core products (with features, typical outcomes, integration points), platform advantages, implementation timelines, support details, pricing guidance, competitive positioning, common Q&A, and prospect intelligence. See the Customization section at the bottom of this recipe for the full template.

- **`{{INITIAL_EMAIL_HTML}}`** — This is the branded HTML email shown when the inbox loads. It should be a fully styled HTML email (inline CSS, table-based layout, max-width 600px) with the seller's branding, product cards, CTAs, and footer. The user should provide this or you can generate it based on their brand.

### Step 2: Apply Placeholders to All Source Files

Replace every placeholder across all source files. The key substitutions per file:

**InboxBridgeApi.cls:**
- `{{AGENT_NAME}}` — agent display name in escalation reply and outbound emails (FromName)
- `{{AGENT_EMAIL}}` — agent from-address in outbound emails (FromAddress)
- `{{PROSPECT_FIRST_NAME}}` — in the escalation reply greeting ("Absolutely, {{PROSPECT_FIRST_NAME}}...")
- `{{COMPANY_NAME}}` — in escalation reply body and Event/Task subjects
- `{{ESCALATION_QUEUE}}` — DeveloperName in the queue query
- `{{PROSPECT_TITLE}}` — default title when auto-creating Contact records
- `{{COMPANY_NAME}}` — in Event/Task subjects (e.g., "{{COMPANY_NAME}} Discovery —")

**AgentReplyService.cls:**
- `{{THREAD_PREFIX}}` — the `DEMO_TAG` constant (line 6)
- `{{AGENT_NAME}}` — signing identity in prompts and fallback reply
- `{{AGENT_EMAIL}}` — FromAddress in outbound EmailMessages
- `{{COMPANY_NAME}}` — throughout the knowledge base prompt preamble and strict rules
- `{{PROSPECT_NAME}}`, `{{PROSPECT_FIRST_NAME}}`, `{{PROSPECT_COMPANY}}`, `{{PROSPECT_TITLE}}` — in the prospect intelligence section
- `{{KNOWLEDGE_BASE}}` — the entire `buildKnowledgeBase()` method body content between the prompt preamble and `=== END KNOWLEDGE BASE ===`

**app.js:**
- `{{THREAD_ID}}` — the `THREAD_ID` constant
- `{{PROSPECT_NAME}}` — the `FROM_NAME` constant
- `{{PROSPECT_EMAIL}}` — the `FROM_EMAIL` constant
- `{{SUBJECT_LINE}}` — the `SUBJECT_BASE` constant
- `{{PROSPECT_INITIALS}}` — in the sent message avatar and initials
- `{{PROSPECT_FIRST_NAME}}` — in the confirmation email greeting ("Hi {{PROSPECT_FIRST_NAME}}")
- `{{AE_NAME}}` — the `AE_NAME` constant
- `{{AE_TITLE}}` — the `AE_TITLE` constant
- `{{AE_EMAIL}}` — the `AE_EMAIL` constant
- `{{AE_INITIALS}}` — in the confirmation email avatar
- `{{COMPANY_NAME}}` — in agent reply avatar, confirmation email body, calendar invite
- `{{PROSPECT_COMPANY}}` — in calendar invite title ("{{COMPANY_NAME}} ↔ {{PROSPECT_COMPANY}} — Discovery")

**InboxDemo.page:**
- `{{PROSPECT_NAME}}` — in the `<title>` tag ("Inbox — {{PROSPECT_NAME}}")
- `{{PROSPECT_INITIALS}}` — in the account chip
- `{{SUBJECT_LINE}}` — in the thread header `<h1>`
- `{{AGENT_NAME}}` — in the initial message sender name
- `{{AGENT_EMAIL}}` — in the initial message sender email
- `{{PROSPECT_FIRST_NAME}}` — in the email body greeting
- `{{INITIAL_EMAIL_HTML}}` — the entire content of the `#initial-body` div

**InboxBridge.site-meta.xml:**
- Replace the `<siteAdmin>` and `<siteGuestRecordDefaultOwner>` email addresses with the target org admin's email, or leave as placeholder `{{ORG_ADMIN_EMAIL}}` — the deploy will fill it from the target org.

### Step 3: Build the Static Resource ZIP

The `InboxAssets` static resource must be a ZIP file containing `app.js` and `styles.css`. Build it:

```python
import zipfile, os

assets_dir = 'force-app/main/default/staticresources/InboxAssets'
zip_path = 'force-app/main/default/staticresources/InboxAssets.resource'

with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for fname in os.listdir(assets_dir):
        fpath = os.path.join(assets_dir, fname)
        if os.path.isfile(fpath):
            zf.write(fpath, fname)
```

### Step 4: Deploy Metadata to the Org

Use the metadata skill to deploy all source files. Deploy in a single push:

```bash
sf project deploy start --source-dir force-app --target-org {{ORG_ALIAS}} --wait 10
```

Verify all components deployed:
- 3 Apex classes (InboxBridgeApi, AgentReplyService, InboxBridgeApiTest)
- 1 Apex trigger (EmailMessageReplyTrigger)
- 1 Visualforce page (InboxDemo)
- 1 Static resource (InboxAssets)
- 1 Custom Setting (LLM_Config__c) with 2 fields
- 1 Site (InboxBridge)

### Step 5: Configure the Salesforce Site

1. Navigate to Setup → Sites.
2. If the `InboxBridge` site was created by the deployment, activate it. If not, create a new site:
   - **Label**: InboxBridge
   - **Site URL prefix**: inbox
   - **Active Site Home Page**: InboxDemo
   - **Site Admin**: The org admin user
   - **Guest Record Default Owner**: The org admin user
3. Activate the site.
4. Note the public URL: `https://{{ORG_DOMAIN}}.my.salesforce-sites.com/inbox`

### Step 6: Configure Guest User Permissions

Go to Setup → Sites → click your site name → Public Access Settings.

**Object Permissions:**
- **Case**: Read, Create, Edit
- **Contact**: Read, Create, Edit
- **Account**: Read, Create, Edit
- **EmailMessage**: Read, Create
- **Event**: Read, Create
- **Task**: Read, Create
- **LLM_Config__c**: Read

**Apex Class Access — add:**
- `InboxBridgeApi`
- `AgentReplyService`

**Visualforce Page Access — add:**
- `InboxDemo`

### Step 7: Add Remote Site Setting

The LLM HTTP fallback needs permission to call the org's own API:

1. Setup → Remote Site Settings → New
2. **Remote Site Name**: SelfOrg
3. **Remote Site URL**: `https://{{ORG_DOMAIN}}.my.salesforce.com`
4. **Active**: checked
5. Save

### Step 8: Set Session Timeout to 24 Hours

Setup → Session Settings → Set "Session Timeout" to 24 hours (maximum). This determines how long the stored admin token lasts before needing refresh.

### Step 9: Seed the LLM Session Token

The AI engine needs a valid admin session token stored in `LLM_Config__c`. Seed it with Anonymous Apex:

```apex
String sessionId = UserInfo.getSessionId();
String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
LLM_Config__c cfg = LLM_Config__c.getOrgDefaults();
if (cfg.Id == null) {
    cfg = new LLM_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
}
cfg.Admin_Session__c = sessionId;
cfg.Instance_URL__c = instanceUrl;
upsert cfg;
System.debug('Session token stored. Instance URL: ' + instanceUrl);
```

Alternatively, the token auto-refreshes whenever an admin visits the inbox URL and sends a message (the `storeAdminSession()` method in `InboxBridgeApi` captures the session on every POST).

### Step 10: Create the Escalation Queue (Optional)

If Omni-Channel escalation is desired:

1. Create a Queue:
   - **Label**: `{{COMPANY_NAME}} Escalations`
   - **Developer Name**: `{{ESCALATION_QUEUE}}`
   - **Supported Object**: Case
2. Enable Omni-Channel in Setup
3. Create a Service Channel for Case
4. Create a Presence Status mapped to the Case service channel
5. Assign agents to the queue and the Presence Status

### Step 11: Test the Demo

1. Open `https://{{ORG_DOMAIN}}.my.salesforce-sites.com/inbox` in a browser
2. Type a message about the seller's products (e.g., "Tell me more about your SD-WAN solution")
3. Click **Send** → wait 3-5 seconds
4. Click **Check for reply** → the AI agent should respond with a substantive, knowledge-grounded answer
5. Type "I'd love to set up a time to see a demo" → the scheduling UI appears with time slots
6. Click a time slot → Event + Task are created in Salesforce, and a confirmation email from the AE appears
7. Type "Can I speak to a real person?" → the escalation flow triggers with a transfer banner
8. Click **Reset Demo Data** to clear all Cases and EmailMessages for a clean restart
9. Check Salesforce: verify Case, Contact, Account, Event, and Task records exist

## Verification

- [ ] Public URL loads the Gmail-like inbox without requiring Salesforce login
- [ ] Sending a product question returns a substantive AI reply (not a generic fallback)
- [ ] The AI reply references real product details from the knowledge base
- [ ] "Schedule a call" triggers the time picker UI
- [ ] Selecting a time creates an Event and Prep Task in Salesforce
- [ ] "Speak to a real person" triggers escalation with the transfer banner
- [ ] The reply box remains active after escalation (prospect can keep messaging)
- [ ] "Reset Demo Data" clears all demo records from Salesforce
- [ ] The Case footer shows the Salesforce Case number(s) at the bottom of the page

## Troubleshooting

### Issue: AI returns generic "I don't have specific information" replies
**Cause:** The admin session token in `LLM_Config__c` has expired (tokens last up to 24 hours).
**Fix:** Re-run the Anonymous Apex from Step 9 to refresh the token. Or visit the inbox URL while logged in as admin and send a test message — the token auto-refreshes on POST.

### Issue: "Down for Maintenance" on the Sites URL
**Cause:** The Salesforce Site is inactive or the domain isn't registered.
**Fix:**
1. Setup → Sites → ensure the site is Active (green checkmark)
2. Ensure a Sites domain is registered (Setup → Sites → "Register My Salesforce Site Domain")
3. Verify the URL path prefix is `inbox`

### Issue: "Reset failed." when clicking Reset Demo Data
**Cause:** Guest users cannot delete Case records via DML (Salesforce platform restriction).
**Fix:** Ensure the admin session token is stored in `LLM_Config__c` — the reset function uses the admin session to delete records via the REST API. Re-run the Anonymous Apex from Step 9.

### Issue: 401 errors in the browser console
**Cause:** The Visualforce session has expired.
**This is expected behavior** — the frontend auto-falls back to the public Sites endpoint. If the Sites endpoint also fails, re-seed the LLM token.

### Issue: No AI reply at all (not even the fallback)
**Cause:** Einstein Generative AI is not enabled, or the admin user lacks Einstein AI permissions.
**Fix:**
1. Setup → Einstein → Turn On Einstein Generative AI
2. Ensure the admin user has the "Einstein Generative AI" permission set assigned
3. Re-seed the LLM token

### Issue: Event not appearing on "Today's Events"
**Cause:** The time picker always generates today's time slots, but timezone misalignment between the browser and org can cause the Event to land on a different date.
**Fix:** The `generateTimeSlots()` function in `app.js` uses the browser's local timezone. Ensure the org timezone matches the demo presenter's timezone, or adjust the slot generation logic.

### Issue: Token expires every 24 hours
**Limitation:** Salesforce's maximum session timeout is 24 hours. There is no permanent token option.
**Mitigation:**
1. Set session timeout to 24 hours (Setup → Session Settings)
2. The token auto-refreshes whenever an admin visits the demo and sends a message
3. Before a presentation, visit the inbox URL while logged in as admin and send a test message

## Customization Guide

### Knowledge Base Template

The `{{KNOWLEDGE_BASE}}` placeholder should contain the full product knowledge base. Use this structure:

```
COMPANY OVERVIEW:
{2-3 sentences about the company, what it does, who it serves}

─── CORE PRODUCTS (DETAILED) ───

{PRODUCT 1 NAME}:
• {Feature 1}
• {Feature 2}
• Typical outcomes: {metrics}
• Integration: {how it connects with other products}

{PRODUCT 2 NAME}:
• {Feature 1}
...

─── PLATFORM ADVANTAGES ───
{Why one vendor is better than many}

─── IMPLEMENTATION AND SUPPORT ───
{Timelines, migration approach, support tiers}

─── PRICING AND CONTRACTS ───
{Guidance without specific numbers}

─── COMPETITIVE POSITIONING ───
{How to position against competitors — never bash, focus on differentiation}

─── COMMON QUESTIONS AND ANSWERS ───
Q: "{Common question}"
A: {Substantive answer}

─── PROSPECT INTELLIGENCE ───
{Details about the specific prospect persona — their company, pain points, timeline, budget}
```

### Initial Email HTML Template

The `{{INITIAL_EMAIL_HTML}}` should be a complete, inline-styled HTML email (no external CSS). Key guidelines:
- Max-width 600px
- Table-based layout (email-safe)
- All styles inline
- Include: branded header with logo/company name, personalized greeting, 2-3 product highlight cards, stats bar, CTA button, footer with address and unsubscribe link
- Use the brand colors from `{{PRIMARY_COLOR}}`, `{{DARK_COLOR}}`, `{{ACCENT_COLOR}}`

## Notes

- The demo creates real Salesforce records (Cases, Contacts, Accounts, Events, Tasks, EmailMessages). Use the "Reset Demo Data" button between presentations.
- The admin token stored in `LLM_Config__c` is a Salesforce session ID, not an API key — it has the same access as the admin user and expires with the session.
- The frontend auto-detects whether it's running in an authenticated VF context or as a guest on the Sites URL, and adjusts its API calls accordingly. No configuration needed.
- The escalation flow keeps the reply box active so the prospect can continue messaging with the live agent in the same thread — this simulates a real handoff experience.
- Meeting scheduling always uses today's date for time slots so the Event shows up on the "Today's Events" tile during a live demo.
