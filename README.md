# 2-Way Email Inbox Demo — Setup Guide

A shareable, interactive sales demo that runs on any Salesforce org. A prospect sees a branded outreach email in a Gmail-like inbox, replies with questions, and an AI agent answers using a custom product knowledge base. Includes meeting scheduling, calendar invites, and live agent escalation — all on a public URL with no Salesforce login required.

---

## What You'll Need

- A Salesforce org with **System Administrator** access (SDO or scratch org recommended)
- The following features enabled in Setup:
  - **Einstein Generative AI** — Setup > Einstein > Turn On Einstein Generative AI
  - **Enhanced Email** — Setup > Enhanced Email > Enable
  - **Salesforce Sites** — Setup > Sites > Register your Sites domain if not done
  - **Omni-Channel** (optional) — only if you want live agent escalation

---

## Quick Start (Step by Step)

### 1. Decide on Your Demo Branding

Before deploying, choose values for each placeholder below. These personalize the entire demo — company name, prospect persona, AI agent identity, and sales rep info.

| What to Decide | Placeholder | Example |
|---|---|---|
| Your fictional company name | `{{COMPANY_NAME}}` | NexGen Networks |
| Company tagline | `{{COMPANY_TAGLINE}}` | Empowering Connected Business |
| Company address (email footer) | `{{COMPANY_ADDRESS}}` | 2100 Innovation Drive, Austin, TX 78701 |
| AI agent display name | `{{AGENT_NAME}}` | NexGen Discovery Agent |
| AI agent email address | `{{AGENT_EMAIL}}` | outreach@nexgen-demo.invalid |
| Prospect full name | `{{PROSPECT_NAME}}` | James Wu |
| Prospect first name | `{{PROSPECT_FIRST_NAME}}` | James |
| Prospect initials (2 letters) | `{{PROSPECT_INITIALS}}` | JW |
| Prospect email | `{{PROSPECT_EMAIL}}` | james.wu@pinnacle-retail.example |
| Prospect company | `{{PROSPECT_COMPANY}}` | Pinnacle Retail Group |
| Prospect job title | `{{PROSPECT_TITLE}}` | IT Director |
| Thread ID prefix (3-4 chars + hyphen) | `{{THREAD_PREFIX}}` | NGN- |
| Default thread ID | `{{THREAD_ID}}` | NGN-DEMO01 |
| Email subject line | `{{SUBJECT_LINE}}` | James, See How NexGen Can Transform Your Network |
| Account Executive name | `{{AE_NAME}}` | Jennifer Park |
| AE title | `{{AE_TITLE}}` | Account Executive, NexGen Networks |
| AE email | `{{AE_EMAIL}}` | jennifer.park@nexgen-demo.invalid |
| AE initials (2 letters) | `{{AE_INITIALS}}` | JP |
| Escalation queue DeveloperName | `{{ESCALATION_QUEUE}}` | NGN_Escalations |
| Primary brand color (hex) | `{{PRIMARY_COLOR}}` | #0D9488 |
| Dark brand color (hex) | `{{DARK_COLOR}}` | #0F172A |
| Accent brand color (hex) | `{{ACCENT_COLOR}}` | #5EEAD4 |

You'll also need:
- **`{{KNOWLEDGE_BASE}}`** — A multi-paragraph product knowledge base the AI uses to answer questions. See the "Writing Your Knowledge Base" section below.
- **`{{INITIAL_EMAIL_HTML}}`** — The branded HTML for the outreach email the prospect sees when they first open the inbox. See "Creating the Initial Email" below.

### 2. Replace Placeholders in All Source Files

Open each source file and find-and-replace every `{{PLACEHOLDER}}` with your chosen values. The files that need changes:

| File | What to Replace |
|---|---|
| `InboxBridgeApi.cls` | Agent name/email, prospect title, company name, escalation queue |
| `AgentReplyService.cls` | Thread prefix, agent identity, company name, prospect details, **entire knowledge base** |
| `app.js` | Thread ID, prospect name/email/initials, subject line, AE details, company names |
| `InboxDemo.page` | Prospect name/initials, subject line, agent name/email, **initial email HTML** |
| `EmailMessageReplyTrigger.trigger` | Thread prefix |
| `InboxBridgeApiTest.cls` | Prospect details, thread prefix, subject line, AE name |
| `InboxBridge.site-meta.xml` | Org admin email |
| `Escalations.queue-meta.xml` | Escalation queue name, company name, admin email |
| `SelfOrg.remoteSite-meta.xml` | Your org's My Domain URL |

Files that **don't need changes**: `styles.css`, all other `-meta.xml` files, `LLM_Config__c` object/field definitions.

### 3. Build the Static Resource ZIP

The `InboxAssets` static resource must be a ZIP containing `app.js` and `styles.css`. After replacing placeholders in `app.js`, create the ZIP:

```
# Create a directory and put both files in it
mkdir InboxAssets
cp app.js InboxAssets/
cp styles.css InboxAssets/

# ZIP them (the ZIP should contain the files at root level, not inside a subfolder)
cd InboxAssets
zip ../InboxAssets.resource *
cd ..
```

### 4. Organize Files for Deployment

Arrange files into the Salesforce project structure:

```
force-app/
  main/
    default/
      classes/
        InboxBridgeApi.cls
        InboxBridgeApi.cls-meta.xml
        AgentReplyService.cls
        AgentReplyService.cls-meta.xml
        InboxBridgeApiTest.cls
        InboxBridgeApiTest.cls-meta.xml
      triggers/
        EmailMessageReplyTrigger.trigger
        EmailMessageReplyTrigger.trigger-meta.xml
      pages/
        InboxDemo.page
        InboxDemo.page-meta.xml
      staticresources/
        InboxAssets.resource          (the ZIP file from step 3)
        InboxAssets.resource-meta.xml
      sites/
        InboxBridge.site-meta.xml
      objects/
        LLM_Config__c/
          LLM_Config__c.object-meta.xml
          fields/
            Admin_Session__c.field-meta.xml
            Instance_URL__c.field-meta.xml
        Case/
          fields/
            AI_Coach_Status__c.field-meta.xml
      remoteSiteSettings/
        SelfOrg.remoteSite-meta.xml
      queues/
        [YourQueueName].queue-meta.xml
```

Also create a `sfdx-project.json` at the project root:
```json
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "namespace": "",
  "sfdcLoginUrl": "https://login.salesforce.com",
  "sourceApiVersion": "62.0"
}
```

### 5. Deploy to Your Org

Authenticate to your org and deploy:

```bash
sf org login web --alias my-demo-org
sf project deploy start --source-dir force-app --target-org my-demo-org --wait 10
```

Verify all components deployed successfully:
- 3 Apex classes
- 1 Apex trigger
- 1 Visualforce page
- 1 Static resource
- 1 Custom Setting + 2 fields
- 1 Custom field on Case
- 1 Site
- 1 Remote Site Setting
- 1 Queue (if using escalation)

### 6. Configure the Salesforce Site

1. Go to **Setup > Sites**
2. Find the **InboxBridge** site and click **Activate** (green checkmark)
3. If the site wasn't created by the deployment, create a new one:
   - Label: `InboxBridge`
   - URL prefix: `inbox`
   - Active Site Home Page: `InboxDemo`
4. Note your public URL: `https://YOUR-ORG-DOMAIN.my.salesforce-sites.com/inbox`

### 7. Set Guest User Permissions

Go to **Setup > Sites > InboxBridge > Public Access Settings** and add:

**Object Permissions:**
| Object | Read | Create | Edit |
|---|---|---|---|
| Case | Yes | Yes | Yes |
| Contact | Yes | Yes | Yes |
| Account | Yes | Yes | Yes |
| EmailMessage | Yes | Yes | — |
| Event | Yes | Yes | — |
| Task | Yes | Yes | — |
| LLM_Config__c | Yes | — | — |

**Apex Class Access** — add: `InboxBridgeApi`, `AgentReplyService`

**Visualforce Page Access** — add: `InboxDemo`

### 8. Add Remote Site Setting

1. Go to **Setup > Remote Site Settings > New**
2. Name: `SelfOrg`
3. URL: `https://YOUR-ORG-DOMAIN.my.salesforce.com`
4. Active: checked
5. Save

> Note: If you included the `SelfOrg.remoteSite-meta.xml` in your deployment, update the URL to match your actual org domain.

### 9. Set Session Timeout to Maximum

Go to **Setup > Session Settings** and set the timeout to **24 hours**. This determines how long the admin token (needed for AI replies) stays valid.

### 10. Seed the AI Session Token

The AI engine needs a stored admin session. Run this as **Anonymous Apex** (Setup > Developer Console > Debug > Execute Anonymous):

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
System.debug('Token stored. Instance: ' + instanceUrl);
```

> **Important:** This token expires every 24 hours. Before a demo, re-run this Apex or simply visit the inbox URL while logged in as admin and send a test message — the token auto-refreshes.

### 11. Create the Escalation Queue (Optional)

If you want live agent escalation via Omni-Channel:

1. Create a Queue in Setup with the DeveloperName matching your `{{ESCALATION_QUEUE}}`
2. Set the supported object to **Case**
3. Enable Omni-Channel in Setup
4. Create a Service Channel for Case
5. Assign agents to the queue

### 12. Test It!

1. Open your public URL: `https://YOUR-ORG-DOMAIN.my.salesforce-sites.com/inbox`
2. Type a product question (e.g., "Tell me about your SD-WAN solution") and click **Send**
3. Wait 3-5 seconds, then click **Check for reply**
4. Verify the AI responds with real product knowledge (not a generic fallback)
5. Type "I'd love to set up a demo" — the time picker should appear
6. Select a time — an Event and Task should appear in Salesforce
7. Type "Can I speak to a real person?" — the escalation banner should appear
8. Click **Reset Demo Data** to clean up between presentations

---

## Writing Your Knowledge Base

The `{{KNOWLEDGE_BASE}}` placeholder in `AgentReplyService.cls` should contain your full product knowledge base. Use this structure:

```
COMPANY OVERVIEW:
[2-3 sentences about the company, what it does, who it serves]

--- CORE PRODUCTS (DETAILED) ---

[PRODUCT 1 NAME]:
- [Feature 1]
- [Feature 2]
- Typical outcomes: [metrics]
- Integration: [how it connects with other products]

[PRODUCT 2 NAME]:
- [Feature 1]
- [Feature 2]
...

--- PLATFORM ADVANTAGES ---
[Why one vendor is better than many]

--- IMPLEMENTATION AND SUPPORT ---
[Timelines, migration approach, support tiers]

--- PRICING AND CONTRACTS ---
[Guidance without specific numbers]

--- COMPETITIVE POSITIONING ---
[How to position against competitors — focus on differentiation, never bash]

--- COMMON QUESTIONS AND ANSWERS ---
Q: "[Common question]"
A: [Substantive answer]

--- PROSPECT INTELLIGENCE ---
[Details about the specific prospect persona — their company, pain points, timeline]
```

The more detailed your knowledge base, the better the AI agent's responses. Aim for 2,000-4,000 words covering every topic a prospect might ask about.

---

## Creating the Initial Email

The `{{INITIAL_EMAIL_HTML}}` placeholder in `InboxDemo.page` is the branded HTML email the prospect sees when the inbox loads. Guidelines:

- **Max width:** 600px
- **Layout:** Table-based (email-safe — no flexbox or grid)
- **Styles:** All inline (no external CSS)
- **Include:** Branded header with company name/logo, personalized greeting, 2-3 product highlight cards, stats bar, CTA button, footer with address and unsubscribe link
- **Colors:** Use your `{{PRIMARY_COLOR}}`, `{{DARK_COLOR}}`, and `{{ACCENT_COLOR}}`

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---|---|---|
| AI gives generic "I don't have specific information" replies | Admin session token expired | Re-run the Anonymous Apex from Step 10, or visit the inbox URL while logged in as admin and send a test message |
| "Down for Maintenance" on the Sites URL | Site inactive or domain not registered | Activate the site in Setup > Sites; register your Sites domain |
| "Reset failed" when clicking Reset Demo Data | Admin token missing | Re-seed the token (Step 10) — reset uses the admin session to delete records |
| 401 errors in browser console | VF session expired | Expected — the frontend auto-falls back to the public Sites endpoint |
| No AI reply at all | Einstein Generative AI not enabled | Enable it in Setup > Einstein; assign the permission set to the admin user |
| Event not on "Today's Events" | Timezone mismatch | Ensure org timezone matches the demo presenter's timezone |
| Token expires every 24 hours | Salesforce session limit | Set timeout to 24h (Step 9); re-visit the inbox URL before presentations |

---

## File Inventory

| File | Purpose |
|---|---|
| `InboxBridgeApi.cls` | REST API backend — reply, thread, schedule, and reset endpoints |
| `AgentReplyService.cls` | AI reply engine + product knowledge base + LLM invocation |
| `InboxBridgeApiTest.cls` | Test class (5 test methods) |
| `EmailMessageReplyTrigger.trigger` | Marks Cases as stale when new emails arrive |
| `InboxDemo.page` | Gmail-like Visualforce page |
| `app.js` | Frontend JavaScript — API layer, scheduling UI, escalation flow |
| `styles.css` | Gmail-like CSS (brand-neutral, no changes needed) |
| `InboxBridge.site-meta.xml` | Salesforce Site definition |
| `Escalations.queue-meta.xml` | Omni-Channel escalation queue |
| `LLM_Config__c.object-meta.xml` | Custom Setting for LLM session storage |
| `Admin_Session__c.field-meta.xml` | Admin session token field |
| `Instance_URL__c.field-meta.xml` | Instance URL field |
| `AI_Coach_Status__c.field-meta.xml` | Case status tracking field |
| `InboxAssets.resource-meta.xml` | Static resource metadata |
| `SelfOrg.remoteSite-meta.xml` | Remote Site Setting for self-API calls |
| All `*-meta.xml` files | Salesforce metadata (API version, status) |

---

## Tips for a Great Demo

- **Before presenting:** Always re-seed the admin token (Step 10) and send a test message to confirm AI replies work
- **Reset between demos:** Click "Reset Demo Data" to clear all Cases and EmailMessages
- **Customize the knowledge base:** The more specific and detailed your product info, the more impressive the AI responses
- **Show Salesforce alongside the inbox:** Open the org in a second tab to show Cases, Events, and Tasks being created in real time
- **Test the scheduling flow:** The time picker always uses today's date so Events appear on "Today's Events" during the demo
