@IsTest(SeeAllData=true)
private class InboxBridgeApiTest {

    @IsTest
    static void postReplyCreatesCaseAndEmail() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/inbox/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'fromEmail' => '{{PROSPECT_EMAIL}}',
            'fromName'  => '{{PROSPECT_NAME}}',
            'subject'   => 'Re: {{SUBJECT_LINE}}',
            'message'   => 'Tell me more about your products.',
            'threadId'  => '{{THREAD_PREFIX}}12345'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        InboxBridgeApi.ReplyResult res = InboxBridgeApi.postReply();
        Test.stopTest();

        System.assertEquals('ok', res.status);
        System.assertNotEquals(null, res.caseId);
        Integer inboundCount = [
            SELECT COUNT() FROM EmailMessage
            WHERE ParentId = :res.caseId AND Incoming = true
        ];
        System.assertEquals(1, inboundCount, 'Exactly one inbound email should be recorded');
        Integer totalCount = [SELECT COUNT() FROM EmailMessage WHERE ParentId = :res.caseId];
        System.assert(totalCount >= 1, 'At least the inbound email should exist; auto-reply may add more');
    }

    @IsTest
    static void getThreadReturnsOutbound() {
        Case c = new Case(Subject = '{{SUBJECT_LINE}} [{{THREAD_PREFIX}}99999]', Status = 'New', Origin = 'Email');
        insert c;
        insert new EmailMessage(
            ParentId = c.Id,
            FromAddress = '{{AGENT_EMAIL}}',
            ToAddress = '{{PROSPECT_EMAIL}}',
            Subject = 'Re: {{SUBJECT_LINE}}',
            TextBody = 'Hi {{PROSPECT_FIRST_NAME}}, happy to share more details.',
            Incoming = false,
            MessageDate = System.now()
        );

        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/inbox/';
        req.httpMethod = 'GET';
        req.params.put('threadId', '{{THREAD_PREFIX}}99999');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        InboxBridgeApi.ThreadResult res = InboxBridgeApi.getThread();
        System.assertEquals('ok', res.status);
        System.assertEquals(1, res.messages.size());
    }

    @IsTest
    static void postReplyMissingFieldsReturns400() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/inbox/';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'fromEmail' => '{{PROSPECT_EMAIL}}'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        InboxBridgeApi.ReplyResult res = InboxBridgeApi.postReply();
        System.assertEquals('error', res.status);
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void scheduleEndpointCreatesEvent() {
        Case c = new Case(Subject = '{{SUBJECT_LINE}} [{{THREAD_PREFIX}}EVT01]', Status = 'New', Origin = 'Email');
        insert c;

        Datetime startDt = Datetime.now().addDays(2);
        Datetime endDt = startDt.addMinutes(30);

        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/inbox/schedule';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'threadId'      => '{{THREAD_PREFIX}}EVT01',
            'startIso'      => startDt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
            'endIso'        => endDt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''),
            'attendeeName'  => '{{PROSPECT_NAME}}',
            'attendeeEmail' => '{{PROSPECT_EMAIL}}',
            'repName'       => '{{AE_NAME}}'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        InboxBridgeApi.postReply();
        String responseStr = RestContext.response.responseBody.toString();
        Map<String, Object> res = (Map<String, Object>) JSON.deserializeUntyped(responseStr);
        System.assertEquals('ok', (String) res.get('status'));
        Id eventId = (Id) res.get('eventId');
        System.assertNotEquals(null, eventId);

        Event ev = [SELECT Id, Subject, WhatId, StartDateTime, OwnerId FROM Event WHERE Id = :eventId];
        System.assertEquals(c.Id, ev.WhatId);
        System.assert(ev.Subject.contains('{{PROSPECT_NAME}}'));

        List<Task> prepTasks = [
            SELECT Id, Subject, WhatId, ActivityDate, Status FROM Task
            WHERE WhatId = :c.Id AND Subject LIKE 'Prep for%'
        ];
        System.assertEquals(1, prepTasks.size(), 'Prep Task should be created alongside Event');
        Date today = Date.today();
        Date meetingDate = startDt.dateGmt();
        Date expectedDue = meetingDate < today ? today : meetingDate;
        System.assertEquals(expectedDue, prepTasks[0].ActivityDate);
        System.assertEquals('Not Started', prepTasks[0].Status);
    }

    @IsTest
    static void scheduleEndpointMissingFieldsReturns400() {
        RestRequest req = new RestRequest();
        req.requestUri = '/services/apexrest/inbox/schedule';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'threadId' => '{{THREAD_PREFIX}}EVT02'
        }));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        InboxBridgeApi.postReply();
        String responseStr = RestContext.response.responseBody.toString();
        Map<String, Object> res = (Map<String, Object>) JSON.deserializeUntyped(responseStr);
        System.assertEquals('error', (String) res.get('status'));
        System.assertEquals(400, RestContext.response.statusCode);
    }
}