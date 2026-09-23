public without sharing class AgentReplyService {

    // Flag to prevent trigger from double-processing when called from REST API
    public static Boolean skipTrigger = false;

    private static final String DEMO_TAG = '{{THREAD_PREFIX}}';
    private static final Set<String> ESCALATION_PHRASES = new Set<String>{
        'speak to a human', 'talk to a human', 'live agent', 'real person',
        'human agent', 'speak with someone', 'speak to someone', 'real human',
        'connect me to a person', 'representative', 'rep please'
    };

    public static void handleInboundEmails(List<EmailMessage> newMessages) {
        List<Id> toProcess = new List<Id>();
        for (EmailMessage em : newMessages) {
            if (em.Incoming == true && em.ParentId != null && String.valueOf(em.ParentId).startsWith('500')) {
                toProcess.add(em.Id);
            }
        }
        if (!toProcess.isEmpty()) {
            processEmails(toProcess);
        }
    }

    public static void resetThreads(List<String> threadIds) {
        Set<String> patterns = new Set<String>();
        for (String t : threadIds) patterns.add('%' + t + '%');
        List<Case> cases = new List<Case>();
        for (String pat : patterns) {
            cases.addAll([SELECT Id FROM Case WHERE Subject LIKE :pat]);
        }
        if (!cases.isEmpty()) {
            delete cases;
        }
    }

    public static void processEmails(List<Id> emailIds) {
        // Always enqueue so the LLM callout runs outside the trigger transaction.
        // Use a specific admin user context to ensure Einstein AI permissions.
        if (!System.isQueueable() && !Test.isRunningTest()) {
            System.debug(LoggingLevel.INFO, 'Enqueuing ReplyJob for ' + emailIds.size() + ' email(s). Running user: ' + UserInfo.getUserId() + ' (' + UserInfo.getUserName() + ')');
            System.enqueueJob(new ReplyJob(emailIds));
            return;
        }
        System.debug(LoggingLevel.INFO, 'Processing emails synchronously. Running user: ' + UserInfo.getUserId() + ' (' + UserInfo.getUserName() + ')');
        processEmailsSync(emailIds);
    }

    public class ReplyJob implements Queueable, Database.AllowsCallouts {
        private List<Id> emailIds;
        public ReplyJob(List<Id> ids) { this.emailIds = ids; }
        public void execute(QueueableContext ctx) {
            System.debug(LoggingLevel.INFO, 'ReplyJob executing. Running user: ' + UserInfo.getUserId() + ' (' + UserInfo.getUserName() + ')');
            AgentReplyService.processEmailsSync(emailIds);
        }
    }

    @TestVisible
    public static void processEmailsSync(List<Id> emailIds) {
        List<EmailMessage> emails = [
            SELECT Id, ParentId, FromAddress, FromName, Subject, TextBody, HtmlBody, Incoming
            FROM EmailMessage
            WHERE Id IN :emailIds
        ];
        Set<Id> caseIds = new Set<Id>();
        for (EmailMessage em : emails) caseIds.add(em.ParentId);

        Map<Id, Case> caseMap = new Map<Id, Case>([
            SELECT Id, CaseNumber, Subject, Status, Description, SuppliedEmail, SuppliedName
            FROM Case
            WHERE Id IN :caseIds
        ]);

        for (EmailMessage em : emails) {
            Case c = caseMap.get(em.ParentId);
            if (c == null) continue;
            if (!c.Subject.contains(DEMO_TAG)) continue;
            if (c.Status == 'Escalated') continue;

            String inboundText = String.isNotBlank(em.TextBody) ? em.TextBody : stripHtml(em.HtmlBody);

            if (containsEscalation(inboundText)) {
                escalateCase(c, em);
                continue;
            }

            String reply = generateReply(c, em, inboundText);
            if (String.isNotBlank(reply)) {
                postReply(c, em, reply);
            }
        }
    }

    public static Boolean containsEscalation(String text) {
        if (String.isBlank(text)) return false;
        String lower = text.toLowerCase();
        for (String phrase : ESCALATION_PHRASES) {
            if (lower.contains(phrase)) return true;
        }
        return false;
    }

    private static void escalateCase(Case c, EmailMessage triggerEmail) {
        // Send the acknowledgement reply FIRST, before changing case status.
        // An org Flow on EmailMessage (outbound) sets the case to "Waiting on Customer",
        // so we send the email while status is still pre-escalation, then our
        // case update below overrides it to "Escalated".
        String body = 'Thanks for reaching out. I\'m connecting you with a {{COMPANY_NAME}} specialist '
            + 'who will follow up shortly. They\'ll have full context of our conversation so far.\n\n\u2014 {{AGENT_NAME}}';
        postReply(c, triggerEmail, body);

        // Now set escalation fields — this update fires AFTER the EmailMessage
        // Flow has already run, so our status sticks.
        c.Status = 'Escalated';
        c.Priority = 'High';
        c.Description = (c.Description == null ? '' : c.Description + '\n\n')
            + 'Customer requested live agent at ' + System.now().format() + '.';

        // Assign to escalation queue for Omni-Channel routing
        List<Group> queues = [
            SELECT Id FROM Group
            WHERE Type = 'Queue' AND DeveloperName = '{{ESCALATION_QUEUE}}'
            LIMIT 1
        ];
        if (!queues.isEmpty()) {
            c.OwnerId = queues[0].Id;
        }
        update c;

        // Push work directly to an available agent via AgentWork
        // (Enhanced Omni-Channel routing in this org does not process
        //  queue-based PSRs, so we bypass it with direct assignment)
        pushToAvailableAgent(c.Id);
    }

    private static void pushToAvailableAgent(Id caseId) {
        try {
            // Find the Cases service channel
            List<ServiceChannel> channels = [
                SELECT Id FROM ServiceChannel
                WHERE RelatedEntity = 'Case'
                LIMIT 1
            ];
            if (channels.isEmpty()) {
                System.debug('No Case service channel found — skipping AgentWork');
                return;
            }
            Id channelId = channels[0].Id;

            // Find an online agent with capacity on the Cases channel
            // The ServicePresenceStatus must be mapped to the Cases channel
            List<ServiceChannelStatus> mappings = [
                SELECT ServicePresenceStatusId FROM ServiceChannelStatus
                WHERE ServiceChannelId = :channelId
            ];
            Set<Id> statusIds = new Set<Id>();
            for (ServiceChannelStatus scs : mappings) {
                statusIds.add(scs.ServicePresenceStatusId);
            }
            if (statusIds.isEmpty()) {
                System.debug('No presence statuses mapped to Cases channel');
                return;
            }

            List<UserServicePresence> online = [
                SELECT UserId FROM UserServicePresence
                WHERE IsCurrentState = true
                  AND ServicePresenceStatusId IN :statusIds
                ORDER BY StatusStartDate ASC
                LIMIT 1
            ];
            if (online.isEmpty()) {
                System.debug('No agent online on Cases channel — work will remain in queue');
                return;
            }

            AgentWork aw = new AgentWork(
                WorkItemId = caseId,
                UserId = online[0].UserId,
                ServiceChannelId = channelId
            );
            insert aw;
            System.debug('AgentWork created for case ' + caseId + ' → user ' + online[0].UserId);
        } catch (Exception e) {
            // Don't fail the escalation if AgentWork creation fails
            System.debug('AgentWork push failed (non-fatal): ' + e.getMessage());
        }
    }

    /**
     * Generate a reply from raw text inputs — no DML needed.
     * Used by InboxBridgeApi to call the LLM BEFORE any DML,
     * avoiding the "uncommitted work" callout restriction.
     */
    public static String generateReplyFromText(String subject, String messageText) {
        String prompt = buildKnowledgeBase() +
            'Original outreach subject: ' + subject + '\n\n' +
            'Prospect just replied with:\n"""\n' + messageText + '\n"""\n\n' +
            'Write the body of your reply email now. Apply all strict rules above.';
        return callLlm(prompt);
    }

    /**
     * Summarize an email conversation thread into a concise narrative for
     * salesperson prep (Event/Task descriptions). Must be called BEFORE DML
     * in the same transaction since it performs an HTTP callout.
     */
    public static String summarizeThread(String transcript) {
        if (String.isBlank(transcript)) return null;
        String prompt = 'You are a sales assistant summarizing an email conversation between a prospect '
            + 'and an AI discovery agent for {{COMPANY_NAME}}. '
            + 'Write a concise 2-4 sentence narrative summary for the assigned salesperson. '
            + 'Focus on: what the prospect asked about, which products were discussed, '
            + 'what their interests/pain points are, and why they agreed to a meeting. '
            + 'Use the prospect\'s name. Do NOT use bullet points. Write in past tense, '
            + 'third person (e.g. "{{PROSPECT_FIRST_NAME}} asked about..."). Keep it under 400 characters.\n\n'
            + 'Conversation transcript:\n"""\n' + transcript + '\n"""';
        return callLlm(prompt);
    }

    /**
     * Core LLM invocation: tries ConnectApi first, then HTTP REST fallback.
     * Contains NO DML, so it is safe to call before or after DML operations.
     */
    private static String callLlm(String prompt) {
        System.debug(LoggingLevel.INFO, 'LLM prompt length: ' + prompt.length() + ' chars');

        // Strategy 1: Try ConnectApi (works when running as admin user with Einstein AI perms)
        try {
            ConnectApi.EinsteinLlmGenerationsInput input = new ConnectApi.EinsteinLlmGenerationsInput();
            input.promptTextOrId = prompt;
            ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            cfg.applicationName = 'PromptBuilderPreview';
            cfg.numGenerations = 1;
            cfg.maxTokens = 600;
            cfg.temperature = 0.5;
            input.additionalConfig = cfg;
            System.debug(LoggingLevel.INFO, 'LLM calling ConnectApi.generateMessages...');
            ConnectApi.EinsteinLLMGenerationsOutput res = ConnectApi.EinsteinLLM.generateMessages(input);
            System.debug(LoggingLevel.INFO, 'LLM call returned. Generations: ' +
                (res != null && res.generations != null ? String.valueOf(res.generations.size()) : 'null'));
            if (res != null && res.generations != null && !res.generations.isEmpty()) {
                String text = res.generations[0].text;
                if (String.isNotBlank(text)) {
                    System.debug(LoggingLevel.INFO, 'LLM reply length (ConnectApi): ' + text.length());
                    return text.trim();
                }
            }
            System.debug(LoggingLevel.WARN, 'LLM ConnectApi: No generations returned');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'ConnectApi failed (' + e.getTypeName() + '): ' + e.getMessage()
                + ' — trying HTTP REST fallback');
        }

        // Strategy 2: HTTP REST API using stored admin session from LLM_Config__c
        try {
            String reply = callEinsteinViaHttp(prompt);
            if (String.isNotBlank(reply)) {
                System.debug(LoggingLevel.INFO, 'LLM reply length (HTTP fallback): ' + reply.length());
                return reply.trim();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'HTTP LLM fallback also failed: ' + e.getTypeName() + ' - ' + e.getMessage()
                + '\nStack: ' + e.getStackTraceString());
        }

        return null;
    }

    private static String generateReply(Case c, EmailMessage em, String inboundText) {
        if (Test.isRunningTest()) return fallbackReply(c);
        String prompt = buildPrompt(c, inboundText);
        String reply = callLlm(prompt);
        return String.isNotBlank(reply) ? reply : fallbackReply(c);
    }

    /**
     * Call the Einstein LLM REST API directly via HTTP, using the admin session
     * stored in the LLM_Config__c Custom Setting. This works even when running
     * as the Sites guest user, because we use the admin's stored session token.
     */
    private static String callEinsteinViaHttp(String prompt) {
        LLM_Config__c cfg = LLM_Config__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.Admin_Session__c) || String.isBlank(cfg.Instance_URL__c)) {
            System.debug(LoggingLevel.WARN, 'No stored admin session in LLM_Config__c — cannot use HTTP fallback');
            return null;
        }

        String instanceUrl = cfg.Instance_URL__c.removeEnd('/');
        String endpoint = instanceUrl + '/services/data/v62.0/einstein/llm/prompt/generations';

        Map<String, Object> requestBody = new Map<String, Object>{
            'promptTextorId' => prompt,
            'additionalConfig' => new Map<String, Object>{
                'applicationName' => 'PromptBuilderPreview',
                'numGenerations' => 1,
                'maxTokens' => 600,
                'temperature' => 0.5
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + cfg.Admin_Session__c);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(requestBody));
        req.setTimeout(30000);

        System.debug(LoggingLevel.INFO, 'LLM HTTP callout to: ' + endpoint);
        Http h = new Http();
        HttpResponse res = h.send(req);
        System.debug(LoggingLevel.INFO, 'LLM HTTP status: ' + res.getStatusCode());

        if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Object genObj = result.get('generations');
            if (genObj instanceof List<Object>) {
                List<Object> gens = (List<Object>) genObj;
                if (!gens.isEmpty()) {
                    Map<String, Object> first = (Map<String, Object>) gens[0];
                    String text = (String) first.get('text');
                    return text;
                }
            }
            // Try alternate response shape
            Object gen = result.get('generation');
            if (gen instanceof Map<String, Object>) {
                Map<String, Object> genMap = (Map<String, Object>) gen;
                String text = (String) genMap.get('generatedText');
                if (String.isNotBlank(text)) return text;
            }
        }
        System.debug(LoggingLevel.WARN, 'LLM HTTP: non-200 response: ' + res.getStatusCode() + ' ' + res.getBody().left(500));
        return null;
    }

    private static String buildPrompt(Case c, String inboundText) {
        return buildKnowledgeBase() +
'Original outreach subject: ' + c.Subject + '\n\n' +
'Prospect just replied with:\n"""\n' + inboundText + '\n"""\n\n' +
'Write the body of your reply email now. Apply all strict rules above.';
    }

    private static String buildKnowledgeBase() {
        return
'You are a {{COMPANY_NAME}} sales development representative replying to a prospect\'s email. ' +
'Use the {{COMPANY_NAME}} KNOWLEDGE BASE below to answer the prospect\'s question directly and substantively. ' +
'Be concise (3-8 sentences), consultative, and specific. Cite real capabilities, products, ' +
'and approximate outcomes from the knowledge base when relevant. When the prospect asks about a specific ' +
'product, give concrete details — features, typical outcomes, how it integrates with their existing setup.\n\n' +

'STRICT RULES:\n' +
'1. NEVER respond with "let me circle back", "I\'ll check on a few specifics", or any other ' +
'   stalling/non-answer. Either answer from the knowledge base or explicitly say you don\'t have ' +
'   that information and offer to connect them with a specialist.\n' +
'2. If the prospect\'s question is clearly unrelated to {{COMPANY_NAME}}\'s services (e.g., personal advice, ' +
'   non-relevant topics), say: "That\'s outside what I can help with, ' +
'   but happy to keep the conversation focused on how {{COMPANY_NAME}} could help your organization."\n' +
'3. Do NOT promise specific pricing dollars or guaranteed timelines — give ranges and "typical" framing.\n' +
'4. Do NOT make up customer names, case studies, or numbers not in the knowledge base.\n' +
'5. Sign as "{{AGENT_NAME}}". Output ONLY the email body, no subject line, no preamble.\n' +
'6. If someone asks about a competitor by name, acknowledge the question without bashing the competitor. ' +
'   Focus on {{COMPANY_NAME}}\'s unique value.\n' +
'7. When answering product questions, mention how that product integrates with the rest of the ' +
'   ecosystem — the unified platform story is the key differentiator.\n' +
'8. ALWAYS include a relevant website link from the PRODUCT LINKS section below. Pick the most relevant ' +
'   product page for the topic discussed. Output the URL as a PLAIN URL — do NOT use markdown link syntax ' +
'   like [text](url). Just write the bare URL inline. The system will auto-link it.\n' +
'9. Do NOT proactively offer to schedule a meeting, demo, or call unless the prospect EXPLICITLY asks ' +
'   for one (e.g. "Can we set up a call?", "I\'d like a demo", "Let\'s schedule something", "Can I talk ' +
'   to someone?"). If they ask a product question, answer it thoroughly from the knowledge base. ' +
'   If the prospect does request a meeting or demo, say something like "Absolutely — just reply with a ' +
'   few times that work and I\'ll get it on the calendar." Keep the conversation informational until ' +
'   the prospect signals they want to move to a live conversation.\n\n' +

'=== {{COMPANY_NAME}} KNOWLEDGE BASE ===\n\n' +

'{{KNOWLEDGE_BASE}}' +

'\n\n--- PROSPECT INTELLIGENCE ---\n\n' +

'ABOUT THE PROSPECT:\n' +
'You are speaking with {{PROSPECT_NAME}}, {{PROSPECT_TITLE}} at {{PROSPECT_COMPANY}}.\n\n' +

'=== END KNOWLEDGE BASE ===\n\n';
    }

    private static String fallbackReply(Case c) {
        return 'I don\'t have specific information on that topic in front of me right now. ' +
            'Let me loop in one of our enterprise specialists who can give you a definitive answer — ' +
            'they\'ll reach out shortly. If there\'s additional context about your organization\'s needs ' +
            'that would help them prep, just reply to this thread.\n\n\u2014 {{AGENT_NAME}}';
    }

    private static void postReply(Case c, EmailMessage triggerEmail, String body) {
        EmailMessage outbound = new EmailMessage(
            ParentId = c.Id,
            FromAddress = '{{AGENT_EMAIL}}',
            FromName = '{{AGENT_NAME}}',
            ToAddress = triggerEmail.FromAddress,
            Subject = c.Subject.startsWith('Re: ') ? c.Subject : 'Re: ' + c.Subject,
            TextBody = body,
            HtmlBody = textToHtml(body),
            Incoming = false,
            Status = '3',
            MessageDate = System.now()
        );
        insert outbound;
    }

    /**
     * Convert plain text to HTML: linkify URLs, convert newlines to paragraphs/breaks.
     * Public so InboxBridgeApi can reuse it for outbound reply formatting.
     */
    public static String textToHtml(String text) {
        if (String.isBlank(text)) return '';
        // First, strip any markdown-style links [text](url) → just the url
        String cleaned = text.replaceAll('\\[([^\\]]+)\\]\\((https?://[^)]+)\\)', '$2');
        // Linkify bare URLs: https://... or http://...
        String linked = cleaned.replaceAll(
            '(https?://[^\\s,;)>\"]+)',
            '<a href="$1">$1</a>'
        );
        // Fix trailing sentence punctuation that got absorbed into URLs
        // e.g. <a href="https://example.com/.">https://example.com/.</a>
        // becomes <a href="https://example.com/">https://example.com/</a>.
        linked = linked.replaceAll(
            '<a href="([^"]+?)([.!?])">(.*?)([.!?])</a>',
            '<a href="$1">$3</a>$4'
        );
        // Convert double newlines to paragraph breaks, single newlines to <br/>
        return '<p>' + linked.replace('\n\n', '</p><p>').replace('\n', '<br/>') + '</p>';
    }

    private static String stripHtml(String html) {
        if (String.isBlank(html)) return '';
        return html.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim();
    }
}