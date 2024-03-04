@IsTest
private class AsyncProcessorTests extends AsyncProcessor {
  // normally an outer test class wouldn't be extending something
  // but a batch class cannot be defined by an inner class

  private static Integer batchLimit = Limits.getLimitQueryRows();
  private static Integer executeCallCounter = 0;
  private static Boolean executeWasFired = false;
  private static Boolean finishWasFired = false;
  private static Integer queueableChunkLimit = 1;

  public override void finish(Database.BatchableContext bc) {
    finishWasFired = true;
  }

  protected override void innerExecute(List<SObject> records) {
    executeCallCounter++;
    executeWasFired = true;
  }

  protected override Integer getLimitToBatch() {
    return batchLimit;
  }

  protected override Integer getQueueableChunkSize() {
    return queueableChunkLimit;
  }

  @IsTest
  static void throwsWhenGetIsNotCalled() {
    Exception ex;
    try {
      new AsyncProcessorTests().kickoff();
      Assert.fail('Above process should throw');
    } catch (Exception e) {
      ex = e;
    }

    Assert.isInstanceOfType(ex, AsyncException.class);
    Assert.areEqual(
      'Please call get() to retrieve the correct Process instance before calling kickoff',
      ex.getMessage()
    );
  }

  @IsTest
  static void doesNotThrowWhenMultipleKickoffsCalledLowerThanBatchSize() {
    List<SObject> records = new List<SObject>();
    AsyncProcessor processor = new AsyncProcessorTests();

    List<AsyncProcessor.Process> processes = new List<AsyncProcessor.Process>{
      processor.get(records),
      processor.get(records)
    };

    Test.startTest();
    for (AsyncProcessor.Process process : processes) {
      process.kickoff();
    }
    Assert.areEqual(2, Limits.getQueueableJobs());
    Test.stopTest();

    Assert.isTrue(executeWasFired);
    Assert.isTrue(finishWasFired);
    Assert.areEqual(2, executeCallCounter);
  }

  private virtual class FailProcessor extends AsyncProcessor {
    protected override void innerExecute(List<SObject> records) {
      throw new IllegalArgumentException('Fail');
    }
  }

  @IsTest
  static void properlyFiresErrorEventIfQueueableFails() {
    try {
      Test.startTest();
      new FailProcessor().get(new List<SObject>()).kickoff();
      Test.stopTest();
      Assert.fail('Exception should be thrown after stopTest is called');
    } catch (System.IllegalArgumentException unused) {
      // unfortunately Limits.getPublishImmediateDML() is reset here
      // and Test.getEventBus() doesn't allow us to interact with the fired
      // event in any kind of meaningful way, so we have to store a reference
      // within AsyncProcessor to assert on
      Assert.isNotNull(AsyncProcessor.firedErrorEvent);
      Assert.areEqual(
        IllegalArgumentException.class.getName(),
        AsyncProcessor.firedErrorEvent.ExceptionType
      );
      Assert.areEqual('Fail', AsyncProcessor.firedErrorEvent.Message);
      Assert.areEqual('EXECUTE', AsyncProcessor.firedErrorEvent.Phase);
    }
    // if you have a local trigger on BatchApexErrorEvent defined
    // you can call Test.getEventBus().deliver(); here to force
    // the second async context to finish, and perform assertions on
    // any logic designed in your handler for that event
  }

  @IsTest
  static void allowsBatchLimitToBeAdjusted() {
    batchLimit = 0;
    // here we have to actually do DML so that the batch start method
    // successfully passes data to the batch execute method
    insert new Account(Name = AsyncProcessorTests.class.getName());

    Test.startTest();
    new AsyncProcessorTests().get('SELECT Id FROM Account').kickoff();
    Test.stopTest();

    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE
          Status = 'Completed'
          AND JobType = 'BatchApexWorker'
          AND ApexClass.Name = :AsyncProcessorTests.class.getName()
      ]
    );
    Assert.isTrue(executeWasFired);
    Assert.isTrue(finishWasFired);
  }

  @IsTest
  static void requeuesWhenRecordSizeOverQueueableLimit() {
    List<Contact> contacts = new List<Contact>{
      new Contact(Id = '003000000000001'),
      new Contact(Id = '003000000000002')
    };
    Assert.isTrue(
      contacts.size() > queueableChunkLimit,
      'Test has started under wrong conditions'
    );

    Test.startTest();
    new AsyncProcessorTests().get(contacts).kickoff();
    Test.stopTest();

    Assert.areEqual(2, executeCallCounter);
  }

  @IsTest
  static void worksWithOrderBy() {
    Exception ex;

    try {
      Test.startTest();
      new AsyncProcessorTests()
        .get('SELECT Id FROM Contact ORDER BY AccountId')
        .kickoff();
      Test.stopTest();
    } catch (Exception e) {
      ex = e;
    }

    Assert.isNull(ex);
  }

  @IsTest
  static void worksWithAllRows() {
    Exception ex;

    try {
      Test.startTest();
      new AsyncProcessorTests().get('SELECT Id FROM Task ALL ROWS').kickoff();
      Test.stopTest();
    } catch (Exception e) {
      ex = e;
    }

    Assert.isNull(ex);
  }
}
