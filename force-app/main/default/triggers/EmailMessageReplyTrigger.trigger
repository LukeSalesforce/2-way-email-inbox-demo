trigger EmailMessageReplyTrigger on EmailMessage (after insert) {
    Set<Id> caseIds = new Set<Id>();
    for (EmailMessage em : Trigger.new) {
        if (em.ParentId != null && String.valueOf(em.ParentId).startsWith('500')) {
            caseIds.add(em.ParentId);
        }
    }
    // AI reply generation is handled exclusively by InboxBridgeApi (the REST endpoint).
    // The REST API generates the reply via callout BEFORE inserting the EmailMessage,
    // then posts the outbound reply in the same transaction. This trigger no longer
    // enqueues a second reply job — doing so caused duplicate agent responses.
    if (!caseIds.isEmpty()) {
        List<Case> toUpdate = new List<Case>();
        for (Case c : [SELECT Id, Subject, AI_Coach_Status__c FROM Case WHERE Id IN :caseIds]) {
            if (c.Subject != null && c.Subject.contains('{{THREAD_PREFIX}}')) {
                c.AI_Coach_Status__c = 'Stale';
                toUpdate.add(c);
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }
}