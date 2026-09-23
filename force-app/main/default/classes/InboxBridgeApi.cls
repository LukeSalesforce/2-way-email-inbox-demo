@RestResource(urlMapping='/inbox/*')
global without sharing class InboxBridgeApi {

    @HttpPost
    global static ReplyResult postReply() {
        RestRequest req = RestContext.request;

        // Persist the admin session so the LLM HTTP fallback works even when
        // the VF session has expired and Sites is serving the page (guest user).
        storeAdminSession();

        String uri = req.requestURI != null ? req.requestURI : '';
        if (uri.endsWith('/schedule') || uri.endsWith('/schedule/')) {
            ScheduleResult sr = scheduleMeeting(req);
            RestContext.response.addHeader('Content-Type', 'application/json');
            RestContext.response.responseBody = Blob.valueOf(JSON.serialize(sr));
            return null;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
        String fromEmail = (String) body.get('fromEmail');
        String fromName = (String) body.get('fromName');
        String subject = (String) body.get('subject');
        String message = (String) body.get('message');
        String threadId = (String) body.get('threadId');

        if (String.isBlank(fromEmail) || String.isBlank(message)) {
            RestContext.response.statusCode = 400;
            return new ReplyResult('error', 'fromEmail and message are required', null);
        }

        // ── ESCALATION CHECK (before callout) ──
        Boolean isEscalation = AgentReplyService.containsEscalation(message);

        // ── CALLOUT PHASE (no DML yet) ──
        // Salesforce forbids HTTP callouts after DML in the same transaction.
        String aiReply = null;
        String taggedSubject = String.isNotBlank(subject) ? subject : 'Inbound from ' + fromEmail;
        if (String.isNotBlank(threadId) && !taggedSubject.contains(threadId)) {
            taggedSubject = taggedSubject + ' [' + threadId + ']';
        }
        if (!isEscalation) {
            try {
                aiReply = AgentReplyService.generateReplyFromText(taggedSubject, message);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'AI reply generation failed: ' + e.getMessage());
            }
        }

        // ── DML PHASE ──
        Case parent = findOrCreateCase(threadId, fromEmail, fromName, subject);

        AgentReplyService.skipTrigger = true;

        EmailMessage em = new EmailMessage(
            ParentId = parent.Id,
            FromAddress = fromEmail,
            FromName = fromName,
            ToAddress = '{{AGENT_EMAIL}}',
            Subject = subject,
            TextBody = message,
            HtmlBody = message,
            Incoming = true,
            Status = '0',
            MessageDate = System.now()
        );
        insert em;

        // ── ESCALATION PATH ──
        if (isEscalation) {
            String escalationReply = 'Absolutely, {{PROSPECT_FIRST_NAME}}. I\'m connecting you with a live member of our '
                + 'enterprise team right now. They\'ll have full context from our conversation so you '
                + 'won\'t need to repeat anything.\n\nA {{COMPANY_NAME}} specialist will be with you '
                + 'shortly.\n\n— {{AGENT_NAME}}';
            String replySubject = parent.Subject.startsWith('Re: ') ? parent.Subject : 'Re: ' + parent.Subject;
            EmailMessage outbound = new EmailMessage(
                ParentId = parent.Id,
                FromAddress = '{{AGENT_EMAIL}}',
                FromName = '{{AGENT_NAME}}',
                ToAddress = fromEmail,
                Subject = replySubject,
                TextBody = escalationReply,
                HtmlBody = AgentReplyService.textToHtml(escalationReply),
                Incoming = false,
                Status = '3',
                MessageDate = System.now()
            );
            insert outbound;

            escalateCaseForOmniChannel(parent);

            return new ReplyResult('ok', 'Escalated to live agent', parent.Id, true);
        }

        // ── NORMAL AI REPLY PATH ──
        if (String.isNotBlank(aiReply)) {
            String replySubject = parent.Subject.startsWith('Re: ') ? parent.Subject : 'Re: ' + parent.Subject;
            EmailMessage outbound = new EmailMessage(
                ParentId = parent.Id,
                FromAddress = '{{AGENT_EMAIL}}',
                FromName = '{{AGENT_NAME}}',
                ToAddress = fromEmail,
                Subject = replySubject,
                TextBody = aiReply,
                HtmlBody = AgentReplyService.textToHtml(aiReply),
                Incoming = false,
                Status = '3',
                MessageDate = System.now()
            );
            insert outbound;
        } else {
            String fallback = 'I don\'t have specific information on that topic in front of me right now. '
                + 'Let me loop in one of our enterprise specialists who can give you a definitive answer — '
                + 'they\'ll reach out shortly. If there\'s additional context about your organization\'s needs '
                + 'that would help them prep, just reply to this thread.\n\n— {{AGENT_NAME}}';
            String replySubject = parent.Subject.startsWith('Re: ') ? parent.Subject : 'Re: ' + parent.Subject;
            EmailMessage outbound = new EmailMessage(
                ParentId = parent.Id,
                FromAddress = '{{AGENT_EMAIL}}',
                FromName = '{{AGENT_NAME}}',
                ToAddress = fromEmail,
                Subject = replySubject,
                TextBody = fallback,
                HtmlBody = AgentReplyService.textToHtml(fallback),
                Incoming = false,
                Status = '3',
                MessageDate = System.now()
            );
            insert outbound;
        }

        return new ReplyResult('ok', 'Reply received', parent.Id, false);
    }

    private static ScheduleResult scheduleMeeting(RestRequest req) {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.requestBody.toString());
        String threadId = (String) body.get('threadId');
        String startIso = (String) body.get('startIso');
        String endIso = (String) body.get('endIso');
        String attendeeName = (String) body.get('attendeeName');
        String attendeeEmail = (String) body.get('attendeeEmail');
        String repName = (String) body.get('repName');

        if (String.isBlank(threadId) || String.isBlank(startIso) || String.isBlank(endIso)) {
            RestContext.response.statusCode = 400;
            return new ScheduleResult('error', 'threadId, startIso, endIso required', null);
        }

        List<Case> cases = [
            SELECT Id, CaseNumber FROM Case
            WHERE Subject LIKE :('%' + threadId + '%')
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (cases.isEmpty()) {
            RestContext.response.statusCode = 404;
            return new ScheduleResult('error', 'No case found for thread', null);
        }
        Case parent = cases[0];

        Datetime startDt;
        Datetime endDt;
        try {
            startDt = (Datetime) JSON.deserialize('"' + startIso + '"', Datetime.class);
            endDt = (Datetime) JSON.deserialize('"' + endIso + '"', Datetime.class);
        } catch (Exception e) {
            RestContext.response.statusCode = 400;
            return new ScheduleResult('error', 'Invalid date format: ' + e.getMessage(), null);
        }

        Id ownerId = resolveDemoRepOwnerId();
        String repLabel = String.isNotBlank(repName) ? repName : 'Sales Rep';
        String attendeeLabel = String.isNotBlank(attendeeName) ? attendeeName : attendeeEmail;

        String prospectLabel = String.isNotBlank(attendeeLabel) ? attendeeLabel : 'Prospect';
        String descBody = 'Auto-scheduled from {{COMPANY_NAME}} Discovery Outreach inbox.\n'
            + 'Prospect: ' + (String.isNotBlank(attendeeLabel) ? attendeeLabel : 'unknown')
            + (String.isNotBlank(attendeeEmail) ? ' <' + attendeeEmail + '>' : '') + '\n'
            + 'Rep: ' + repLabel + '\n'
            + 'Linked Case: ' + parent.CaseNumber;

        // ── CALLOUT PHASE (no DML yet) ──
        String threadSummary = buildThreadSummary(parent.Id);
        if (String.isNotBlank(threadSummary)) {
            try {
                String aiSummary = AgentReplyService.summarizeThread(threadSummary);
                if (String.isNotBlank(aiSummary)) {
                    threadSummary = aiSummary;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'AI summary failed, using raw transcript: ' + e.getMessage());
            }
        }

        // ── DML PHASE ──
        String eventDesc = descBody
            + (String.isNotBlank(threadSummary) ? '\n\n── Engagement Summary ──\n' + threadSummary : '');

        Event ev = new Event(
            OwnerId = ownerId,
            WhatId = parent.Id,
            Subject = '{{COMPANY_NAME}} Discovery — ' + prospectLabel,
            StartDateTime = startDt,
            EndDateTime = endDt,
            Location = 'Video conference',
            Description = eventDesc,
            IsAllDayEvent = false,
            ShowAs = 'Busy'
        );
        insert ev;

        Date meetingDate = startDt.dateGmt();
        Date today = Date.today();
        Date taskDue = meetingDate < today ? today : meetingDate;
        String taskDesc = 'Review the conversation summary below before the '
            + startDt.format('h:mm a') + ' call with ' + prospectLabel + '.\n\n' + descBody
            + (String.isNotBlank(threadSummary) ? '\n\n── Engagement Summary ──\n' + threadSummary : '');
        Task prepTask = new Task(
            OwnerId = ownerId,
            WhatId = parent.Id,
            Subject = 'Prep for {{COMPANY_NAME}} Discovery — ' + prospectLabel,
            ActivityDate = taskDue,
            Status = 'Not Started',
            Priority = 'Normal',
            Description = taskDesc
        );
        insert prepTask;

        return new ScheduleResult('ok', 'Event + prep Task created', ev.Id);
    }

    private static Id resolveDemoRepOwnerId() {
        List<User> admins = [
            SELECT Id FROM User
            WHERE Profile.Name = 'System Administrator'
              AND IsActive = true
            ORDER BY LastLoginDate DESC NULLS LAST
            LIMIT 1
        ];
        if (!admins.isEmpty()) return admins[0].Id;
        return UserInfo.getUserId();
    }

    private static String buildThreadSummary(Id caseId) {
        List<EmailMessage> thread = [
            SELECT FromName, FromAddress, TextBody, HtmlBody, Incoming,
                   MessageDate, Subject
            FROM EmailMessage
            WHERE ParentId = :caseId
            ORDER BY MessageDate ASC
        ];
        if (thread.isEmpty()) return null;

        List<String> parts = new List<String>();
        for (EmailMessage m : thread) {
            String sender = m.Incoming
                ? (String.isNotBlank(m.FromName) ? m.FromName : m.FromAddress)
                : '{{COMPANY_NAME}} AI Agent';
            String body = String.isNotBlank(m.TextBody) ? m.TextBody : '';
            if (String.isBlank(body) && String.isNotBlank(m.HtmlBody)) {
                body = m.HtmlBody.replaceAll('<[^>]*>', ' ').replaceAll('\\s+', ' ').trim();
            }
            if (body.length() > 500) {
                body = body.substring(0, 497) + '...';
            }
            parts.add(sender + ': ' + body);
        }
        return String.join(parts, '\n\n');
    }

    @HttpDelete
    global static ResetResult resetThread() {
        RestRequest req = RestContext.request;
        String threadId = req.params.get('threadId');
        if (String.isBlank(threadId)) {
            RestContext.response.statusCode = 400;
            return new ResetResult('error', 'threadId required', 0);
        }

        LLM_Config__c cfg = LLM_Config__c.getOrgDefaults();
        Boolean hasAdminSession = (cfg != null && String.isNotBlank(cfg.Admin_Session__c)
                                   && String.isNotBlank(cfg.Instance_URL__c));

        String pattern = '%' + threadId + '%';
        List<Case> cases = [SELECT Id FROM Case WHERE Subject LIKE :pattern];
        if (cases.isEmpty()) {
            return new ResetResult('ok', 'No cases found for thread ' + threadId, 0);
        }

        Set<Id> caseIds = new Set<Id>();
        for (Case c : cases) caseIds.add(c.Id);
        List<EmailMessage> emails = [SELECT Id FROM EmailMessage WHERE ParentId IN :caseIds];

        if (hasAdminSession) {
            String instanceUrl = cfg.Instance_URL__c.removeEnd('/');
            String token = cfg.Admin_Session__c;

            List<Id> allIds = new List<Id>();
            for (EmailMessage em : emails) allIds.add(em.Id);
            for (Case c : cases) allIds.add(c.Id);

            deleteViaRestApi(instanceUrl, token, allIds);
        } else {
            if (!emails.isEmpty()) delete emails;
            delete cases;
        }

        return new ResetResult('ok', 'Reset completed for thread ' + threadId, cases.size());
    }

    private static void deleteViaRestApi(String instanceUrl, String token, List<Id> recordIds) {
        Integer batchSize = 200;
        for (Integer i = 0; i < recordIds.size(); i += batchSize) {
            List<String> batch = new List<String>();
            for (Integer j = i; j < Math.min(i + batchSize, recordIds.size()); j++) {
                batch.add(String.valueOf(recordIds[j]));
            }
            String idsParam = String.join(batch, ',');
            String endpoint = instanceUrl + '/services/data/v62.0/composite/sobjects?ids=' + idsParam + '&allOrNone=false';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('DELETE');
            req.setHeader('Authorization', 'Bearer ' + token);
            req.setTimeout(30000);

            Http h = new Http();
            HttpResponse res = h.send(req);
            System.debug('Reset delete batch status: ' + res.getStatusCode() + ' body: ' + res.getBody().left(300));
        }
    }

    @HttpGet
    global static ThreadResult getThread() {
        RestRequest req = RestContext.request;
        String threadId = req.params.get('threadId');
        if (String.isBlank(threadId)) {
            RestContext.response.statusCode = 400;
            return new ThreadResult('error', 'threadId required', null);
        }

        List<Case> cases = [
            SELECT Id, CaseNumber, Subject, Status, ContactEmail, CreatedDate
            FROM Case
            WHERE Subject LIKE :('%' + threadId + '%')
            ORDER BY CreatedDate ASC
        ];
        ThreadResult result = new ThreadResult('ok', null, new List<EmailEntry>());
        if (cases.isEmpty()) {
            result.detail = 'No case yet';
            result.caseNumbers = new List<String>();
            return result;
        }
        Set<Id> caseIds = new Set<Id>();
        List<String> nums = new List<String>();
        for (Case c : cases) {
            caseIds.add(c.Id);
            nums.add(c.CaseNumber);
        }

        List<EmailMessage> msgs = [
            SELECT Id, FromAddress, FromName, ToAddress, Subject, TextBody,
                   HtmlBody, Incoming, MessageDate, Status
            FROM EmailMessage
            WHERE ParentId IN :caseIds AND Incoming = false
            ORDER BY MessageDate ASC
        ];
        List<EmailEntry> entries = new List<EmailEntry>();
        for (EmailMessage m : msgs) {
            entries.add(new EmailEntry(
                m.Id, m.FromAddress, m.FromName, m.Subject,
                String.isNotBlank(m.HtmlBody) ? m.HtmlBody : m.TextBody,
                m.MessageDate
            ));
        }
        result.messages = entries;
        result.caseNumbers = nums;
        result.detail = 'Found ' + nums.size() + ' case(s)';
        return result;
    }

    private static void escalateCaseForOmniChannel(Case c) {
        c.Status = 'Escalated';
        c.Priority = 'High';
        c.Description = (c.Description == null ? '' : c.Description + '\n\n')
            + 'Customer requested live agent at ' + System.now().format() + '.';

        Id queueId;
        List<Group> queues = [
            SELECT Id FROM Group
            WHERE Type = 'Queue' AND DeveloperName = '{{ESCALATION_QUEUE}}'
            LIMIT 1
        ];
        if (!queues.isEmpty()) {
            queueId = queues[0].Id;
            c.OwnerId = queueId;
        }
        Database.DMLOptions dmo = new Database.DMLOptions();
        dmo.assignmentRuleHeader.useDefaultRule = false;
        c.setOptions(dmo);
        update c;

        if (queueId != null) {
            Case verify = [SELECT OwnerId FROM Case WHERE Id = :c.Id];
            if (verify.OwnerId != queueId) {
                verify.OwnerId = queueId;
                verify.setOptions(dmo);
                update verify;
            }
        }

        try {
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
                WorkItemId = c.Id,
                UserId = online[0].UserId,
                ServiceChannelId = channelId
            );
            insert aw;
            System.debug('AgentWork created for case ' + c.Id + ' → user ' + online[0].UserId);
        } catch (Exception e) {
            System.debug('AgentWork push failed (non-fatal): ' + e.getMessage());
        }
    }

    private static Case findOrCreateCase(String threadId, String email, String name, String subject) {
        Contact con = resolveContact(email, name);

        if (String.isNotBlank(threadId)) {
            List<Case> existing = [
                SELECT Id, ContactId, Subject, Description FROM Case
                WHERE Subject LIKE :('%' + threadId + '%')
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!existing.isEmpty()) {
                Case ex = existing[0];
                if (con != null && ex.ContactId == null) {
                    ex.ContactId = con.Id;
                    update ex;
                }
                return ex;
            }
        }
        String tagged = String.isNotBlank(subject) ? subject : 'Inbound from ' + email;
        if (String.isNotBlank(threadId) && !tagged.contains(threadId)) {
            tagged = tagged + ' [' + threadId + ']';
        }
        Case c = new Case(
            Subject = tagged,
            Description = 'Inbound reply from inbox demo',
            Status = 'New',
            Origin = 'Email',
            SuppliedEmail = email,
            SuppliedName = name,
            ContactId = con != null ? con.Id : null,
            AccountId = con != null ? con.AccountId : null
        );
        insert c;
        return c;
    }

    private static Contact resolveContact(String email, String name) {
        if (String.isBlank(email)) return null;

        List<Contact> existing = [
            SELECT Id, AccountId FROM Contact
            WHERE Email = :email
            LIMIT 1
        ];
        if (!existing.isEmpty()) return existing[0];

        String domain = email.substringAfter('@');
        String orgName = domain.substringBefore('.').replace('-', ' ');
        orgName = orgName.substring(0, 1).toUpperCase() + orgName.substring(1);

        Account acct;
        List<Account> accts = [SELECT Id FROM Account WHERE Name LIKE :(orgName + '%') LIMIT 1];
        if (!accts.isEmpty()) {
            acct = accts[0];
        } else {
            acct = new Account(Name = orgName, Type = 'Prospect');
            insert acct;
        }

        String firstName = '';
        String lastName = name;
        if (String.isNotBlank(name) && name.contains(' ')) {
            String cleanName = name.replaceAll('(?i)^(Dr\\.?|Mr\\.?|Mrs\\.?|Ms\\.?)\\s+', '');
            Integer lastSpace = cleanName.lastIndexOf(' ');
            if (lastSpace > 0) {
                firstName = cleanName.substring(0, lastSpace);
                lastName = cleanName.substring(lastSpace + 1);
            }
        }

        Contact con = new Contact(
            AccountId = acct.Id,
            FirstName = firstName,
            LastName = String.isBlank(lastName) ? email.substringBefore('@') : lastName,
            Email = email,
            Title = '{{PROSPECT_TITLE}}'
        );
        insert con;
        return con;
    }

    global class ResetResult {
        public String status;
        public String detail;
        public Integer queued;
        public ResetResult(String s, String d, Integer c) { status = s; detail = d; queued = c; }
    }

    global class ScheduleResult {
        public String status;
        public String detail;
        public Id eventId;
        public ScheduleResult(String s, String d, Id e) { status = s; detail = d; eventId = e; }
    }

    global class ReplyResult {
        public String status;
        public String detail;
        public Id caseId;
        public Boolean escalated;
        public ReplyResult(String s, String d, Id c) { status = s; detail = d; caseId = c; escalated = false; }
        public ReplyResult(String s, String d, Id c, Boolean esc) { status = s; detail = d; caseId = c; escalated = esc; }
    }

    global class ThreadResult {
        public String status;
        public String detail;
        public List<EmailEntry> messages;
        public List<String> caseNumbers;
        public ThreadResult(String s, String d, List<EmailEntry> m) {
            status = s; detail = d; messages = m;
            caseNumbers = new List<String>();
        }
    }

    global class EmailEntry {
        public Id id;
        public String fromAddress;
        public String fromName;
        public String subject;
        public String body;
        public Datetime sentAt;
        public EmailEntry(Id i, String fa, String fn, String s, String b, Datetime t) {
            id = i; fromAddress = fa; fromName = fn; subject = s; body = b; sentAt = t;
        }
    }

    private static void storeAdminSession() {
        try {
            String sid = UserInfo.getSessionId();
            if (String.isBlank(sid)) return;

            String profileName = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId()].Profile.Name;
            if (profileName != 'System Administrator') return;

            String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
            LLM_Config__c cfg = LLM_Config__c.getOrgDefaults();
            cfg.Admin_Session__c = sid;
            cfg.Instance_URL__c = instanceUrl;
            upsert cfg;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'storeAdminSession failed (non-fatal): ' + e.getMessage());
        }
    }
}
